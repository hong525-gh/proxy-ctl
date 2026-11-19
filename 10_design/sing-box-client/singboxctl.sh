#!/usr/bin/env bash
# singboxctl.sh - staging-phase operator entry for the sing-box client (design: 10_design/sing-box-client/design.md)
#
# Reads connection parameters from the existing xray config (read-only),
# renders a runtime config into user-level tmpfs, and never prints secrets:
# only tags, field lengths and hashes reach stdout/stderr.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEMPLATE="${SINGBOXCTL_TEMPLATE:-$SCRIPT_DIR/config.template.json}"
readonly XRAY_CONFIG="${SINGBOXCTL_XRAY_CONFIG:-$HOME/.config/xray/config.json}"
readonly BIN_CURRENT="${SINGBOXCTL_BIN:-$HOME/.local/lib/sing-box/current/sing-box}"
readonly RULESET_DIR="${SINGBOXCTL_RULESET_DIR:-$HOME/.local/share/sing-box/rule-sets}"
readonly STATE_DIR="$HOME/.local/state/sing-box-client"
readonly RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sing-box-client"
readonly TEST_SERVICE="sing-box-client-test.service"

# staging tag -> port (production 10808-10811 stays owned by xray until cutover)
readonly STAGING_PORTS="socks=18080 ts-in=18081 probe-in=18082 bk-in=18083"

PROBE_204_URL="${PROBE_204_URL:-https://www.gstatic.com/generate_204}"
TS_PROBE_URL="${TS_PROBE_URL:-https://api.telegram.org/}"
DIRECT_PROBE_URL="${DIRECT_PROBE_URL:-https://www.baidu.com/}"
# gstatic.com is inside geosite-cn, so a "default outbound" probe to it would
# silently go direct (same trap xray's vpnctl documented). The route.final
# probe must use a target that no direct rule matches.
FINAL_PROBE_URL="${FINAL_PROBE_URL:-https://api.telegram.org/}"

usage() {
  cat <<'EOF'
usage: singboxctl.sh <command>

  install    verify binary/rule-set layout and print public hashes
  generate   render staging runtime config into $XDG_RUNTIME_DIR (0600)
  validate   generate + sing-box check + policy self-check
  run        generate, validate, then exec sing-box (for the systemd unit)
  status     service state + staging listeners (no secrets)
  check      health probes through the staging inbounds (service must run)
  scrub      filter stdin, replacing vless server addresses with srv-<hash12>
EOF
}

die() { echo "error: $*" >&2; exit 1; }

port_of() {
  local tag="$1" pair
  for pair in $STAGING_PORTS; do
    [[ $pair == "$tag="* ]] && { echo "${pair#*=}"; return 0; }
  done
  die "unknown staging tag: $tag"
}

cmd_install() {
  [[ -x $BIN_CURRENT ]] || die "sing-box binary missing at $BIN_CURRENT"
  "$BIN_CURRENT" version | head -1
  sha256sum "$BIN_CURRENT" | awk '{print "binary sha256: " $1}'
  local f
  for f in geoip-cn geosite-cn geosite-private; do
    [[ -f $RULESET_DIR/$f.srs ]] || die "rule-set missing: $RULESET_DIR/$f.srs"
    sha256sum "$RULESET_DIR/$f.srs" | awk -v n="$f" '{print n ".srs sha256: " $1}'
  done
  [[ -r $XRAY_CONFIG ]] || die "xray source config not readable: $XRAY_CONFIG"
  echo "xray source config: present (read-only)"
}

cmd_generate() {
  install -d -m 0700 "$RUNTIME_DIR"
  SB_XRAY_CONFIG="$XRAY_CONFIG" SB_TEMPLATE="$TEMPLATE" SB_RULESET_DIR="$RULESET_DIR" \
  SB_RUNTIME_FILE="$RUNTIME_DIR/config-staging.json" \
  python3 - <<'PYEOF'
import hashlib
import json
import os
import sys

xray_path = os.environ["SB_XRAY_CONFIG"]
template_path = os.environ["SB_TEMPLATE"]
ruleset_dir = os.environ["SB_RULESET_DIR"]
out_path = os.environ["SB_RUNTIME_FILE"]

with open(xray_path) as fh:
    xray = json.load(fh)
with open(template_path) as fh:
    config = json.load(fh)

PROXY_TAGS = {"proxy", "proxy-backup", "proxy-ts"}

vless = {}
first_proxy_tag = None
for ob in xray.get("outbounds", []):
    if ob.get("protocol") != "vless":
        continue
    tag = ob.get("tag")
    if tag not in PROXY_TAGS:
        continue
    if first_proxy_tag is None:
        first_proxy_tag = tag
    server = ob["settings"]["vnext"][0]
    user = server["users"][0]
    stream = ob.get("streamSettings", {})
    reality = stream.get("realitySettings", {})
    vless[tag] = (server, user, stream, reality)

missing = PROXY_TAGS - vless.keys()
if missing:
    sys.exit("error: xray config is missing vless outbounds: %s" % sorted(missing))
if first_proxy_tag is None:
    sys.exit("error: no proxy outbound found in xray config")

for tag, (server, user, stream, reality) in vless.items():
    for field, value in (
        ("server address", server.get("address", "")),
        ("uuid", user.get("id", "")),
        ("reality public key", reality.get("publicKey", "")),
        ("reality short id", reality.get("shortId", "")),
    ):
        if not value:
            sys.exit("error: outbound %s is missing %s" % (tag, field))
    if user.get("flow") != "xtls-rprx-vision":
        sys.exit("error: outbound %s has unexpected flow %r" % (tag, user.get("flow")))
    if stream.get("security") != "reality":
        sys.exit("error: outbound %s is not reality-secured" % tag)

outbounds = [{
    "type": "direct",
    "tag": "direct"
}]
for tag in ("proxy", "proxy-backup", "proxy-ts"):
    server, user, stream, reality = vless[tag]
    outbounds.append({
        "type": "vless",
        "tag": tag,
        "server": server["address"],
        "server_port": server["port"],
        "uuid": user["id"],
        "flow": user["flow"],
        "tls": {
            "enabled": True,
            "server_name": reality.get("serverName") or (reality.get("serverNames") or [None])[0],
            "utls": {
                "enabled": True,
                "fingerprint": reality.get("fingerprint", "chrome")
            },
            "reality": {
                "enabled": True,
                "public_key": reality["publicKey"],
                "short_id": reality["shortId"]
            }
        }
    })

config["outbounds"] = outbounds

for rs in config["route"]["rule_set"]:
    rs["path"] = rs["path"].replace("__RULESET_DIR__", ruleset_dir)
config["route"]["final"] = first_proxy_tag

payload = json.dumps(config, indent=2).encode()
fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
try:
    os.write(fd, payload)
finally:
    os.close(fd)

digest = hashlib.sha256(payload).hexdigest()
summary = {
    tag: {
        "port": server["port"],
        "uuid_len": len(user["id"]),
        "pk_len": len(reality["publicKey"]),
        "sid_len": len(reality["shortId"]),
        "server_sha256_12": hashlib.sha256(server["address"].encode()).hexdigest()[:12],
    }
    for tag, (server, user, stream, reality) in vless.items()
}
print("generated: %s (0600, tmpfs)" % out_path)
print("config sha256: %s" % digest)
print("route.final: %s (derived from xray outbound order)" % first_proxy_tag)
for tag in ("proxy", "proxy-backup", "proxy-ts"):
    s = summary[tag]
    print("outbound %s: port=%s uuid_len=%s pk_len=%s sid_len=%s server_sha256_12=%s"
          % (tag, s["port"], s["uuid_len"], s["pk_len"], s["sid_len"], s["server_sha256_12"]))
PYEOF
}

cmd_validate() {
  cmd_generate
  local cfg="$RUNTIME_DIR/config-staging.json"
  SB_RUNTIME_FILE="$cfg" SB_XRAY_CONFIG="$XRAY_CONFIG" SB_STAGING_PORTS="$STAGING_PORTS" \
  python3 - <<'PYEOF'
import json
import os
import sys

with open(os.environ["SB_RUNTIME_FILE"]) as fh:
    config = json.load(fh)
with open(os.environ["SB_XRAY_CONFIG"]) as fh:
    xray = json.load(fh)

errors = []
def check(cond, msg):
    if not cond:
        errors.append(msg)

expected_ports = dict(p.split("=") for p in os.environ["SB_STAGING_PORTS"].split())

inbounds = {i["tag"]: i for i in config["inbounds"]}
check(set(inbounds) == set(expected_ports), "inbound tags mismatch: %s" % sorted(inbounds))
for tag, port in expected_ports.items():
    ib = inbounds.get(tag, {})
    check(ib.get("listen") == "127.0.0.1", "inbound %s not on 127.0.0.1" % tag)
    check(ib.get("listen_port") == int(port), "inbound %s port != %s" % (tag, port))
    check(ib.get("type") == "mixed", "inbound %s is not mixed" % tag)

raw = json.dumps(config)
check("0.0.0.0" not in raw, "config contains 0.0.0.0")
check("::" not in [i.get("listen") for i in config["inbounds"]], "inbound listening on IPv6 any")

outbounds = {o["tag"]: o for o in config["outbounds"]}
check("block" not in outbounds, "block outbound must not exist")
for tag in ("proxy", "proxy-backup", "proxy-ts"):
    ob = outbounds.get(tag, {})
    tls = ob.get("tls", {})
    reality = tls.get("reality", {})
    check(ob.get("type") == "vless", "%s not vless" % tag)
    check(ob.get("flow") == "xtls-rprx-vision", "%s flow wrong" % tag)
    check(len(ob.get("uuid", "")) == 36, "%s uuid length wrong" % tag)
    check(bool(ob.get("server")), "%s server empty" % tag)
    check(reality.get("enabled") is True, "%s reality disabled" % tag)
    check(bool(reality.get("public_key")), "%s public key empty" % tag)
    check(bool(reality.get("short_id")), "%s short id empty" % tag)
    check(tls.get("utls", {}).get("enabled") is True, "%s utls disabled" % tag)
check(set(outbounds) == {"direct", "proxy", "proxy-backup", "proxy-ts"},
      "unexpected outbounds: %s" % sorted(outbounds))

xray_first = next(o["tag"] for o in xray["outbounds"]
                  if o.get("protocol") == "vless"
                  and o.get("tag") in ("proxy", "proxy-backup", "proxy-ts"))
check(config["route"]["final"] == xray_first,
      "route.final %s != xray first proxy %s" % (config["route"]["final"], xray_first))

pins = {}
for rule in config["route"]["rules"]:
    for ib in rule.get("inbound", []):
        pins[ib] = rule.get("outbound")
check(pins.get("ts-in") == "proxy-ts", "ts-in pin wrong")
check(pins.get("probe-in") == "proxy", "probe-in pin wrong")
check(pins.get("bk-in") == "proxy-backup", "bk-in pin wrong")

for rs in config["route"]["rule_set"]:
    check(rs.get("type") == "local", "rule-set %s not local" % rs.get("tag"))
    check(os.path.isfile(rs.get("path", "")), "rule-set file missing: %s" % rs.get("tag"))

mode = os.stat(os.environ["SB_RUNTIME_FILE"]).st_mode & 0o777
check(mode == 0o600, "runtime config mode is %o, want 600" % mode)

if errors:
    for e in errors:
        print("policy error: %s" % e, file=sys.stderr)
    sys.exit(1)
print("policy self-check: ok (%d inbounds, %d outbounds, final=%s)"
      % (len(inbounds), len(outbounds), config["route"]["final"]))
PYEOF
  [[ -x $BIN_CURRENT ]] || die "sing-box binary missing"
  "$BIN_CURRENT" check -c "$cfg"
  echo "sing-box check: ok"
}

# Scrub server addresses from log lines: sing-box writes `dial tcp <server>:<port>`
# into error logs on dial failures, and design section 9.2 forbids full server
# addresses in the journal. Each address is replaced by srv-<sha256[:12]>.
cmd_scrub() {
  # fd 3 keeps the caller's stdin (the log stream); python's own stdin is the
  # heredoc carrying the program, so it cannot double as the data channel.
  python3 - "$RUNTIME_DIR/config-staging.json" 3<&0 <<'PYEOF'
import hashlib
import json
import sys

# journald only sees what we flush; without line buffering everything would
# sit in the block buffer until sing-box exits.
sys.stdout.reconfigure(line_buffering=True)

with open(sys.argv[1]) as fh:
    config = json.load(fh)
addrs = {
    ob["server"]: "srv-" + hashlib.sha256(ob["server"].encode()).hexdigest()[:12]
    for ob in config.get("outbounds", [])
    if ob.get("type") == "vless" and ob.get("server")
}
with open("/dev/fd/3") as data:
    for line in data:
        for addr, repl in addrs.items():
            line = line.replace(addr, repl)
        sys.stdout.write(line)
sys.stdout.flush()
PYEOF
}

cmd_run() {
  cmd_validate
  exec "$BIN_CURRENT" run -c "$RUNTIME_DIR/config-staging.json" > >(cmd_scrub) 2>&1
}

cmd_status() {
  systemctl --user is-active "$TEST_SERVICE" 2>/dev/null || echo "inactive"
  ss -ltn 2>/dev/null | awk 'NR==1 || /:1808[0-3] /' || true
}

cmd_check() {
  local results=()
  probe() {
    local tag="$1" url="$2" expect="$3"
    local port
    port="$(port_of "$tag")"
    local out code
    out=$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' \
      --connect-timeout 10 --max-time 30 \
      -x "socks5h://127.0.0.1:$port" "$url" 2>&1) || true
    code="${out%% *}"
    printf '%-9s port=%s expect=%-12s http=%s url=%s\n' \
      "$tag" "$port" "$expect" "$code" "$url"
  }
  probe probe-in "$PROBE_204_URL" proxy
  probe bk-in "$PROBE_204_URL" proxy-backup
  probe ts-in "$TS_PROBE_URL" proxy-ts
  probe socks "$FINAL_PROBE_URL" "route.final"
  probe socks "$DIRECT_PROBE_URL" direct
}

case "${1:-}" in
  install)  cmd_install ;;
  generate) cmd_generate ;;
  validate) cmd_validate ;;
  run)      cmd_run ;;
  status)   cmd_status ;;
  check)    cmd_check ;;
  scrub)    cmd_scrub ;;
  *)        usage; exit 2 ;;
esac
