#!/usr/bin/env bash
# test_singboxctl.sh — offline acceptance test for singboxctl.sh
#
# Uses a mock xray config full of dummy values (TEST-NET addresses, a fake UUID)
# and a throwaway XDG_RUNTIME_DIR. Verifies what design.md §9/§10 promises:
#   - route.final follows the xray outbound order (backup mode stays backup);
#   - the runtime config lands in tmpfs with 0700/0600 permissions;
#   - stdout never carries secrets (no UUID, keys, short ID or server address);
#   - the staging tag/port map and inbound pins match the design;
#   - `sing-box check` passes when the real binary and rule-sets are present.
#
# No network access is used anywhere in this test.

set -uo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/singboxctl-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf 'skip %s\n' "$*"; }

DUMMY_UUID="11111111-2222-3333-4444-555555555555"
DUMMY_PK="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"   # 43-char base64url x25519 dummy
DUMMY_SID="0123456789abcdef"
DUMMY_ADDR_MAIN="198.51.100.10"
DUMMY_ADDR_BK="198.51.100.20"

mk_xray_config() {
  # $1 = output path, $2 = "backup-first" | "proxy-first"
  local out="$1" order="$2"
  local proxy_ts_addr="$DUMMY_ADDR_BK"
  local first second
  if [[ $order == backup-first ]]; then
    first=proxy-backup second=proxy
  else
    first=proxy second=proxy-backup
  fi
  python3 - "$out" "$first" "$second" "$DUMMY_UUID" "$DUMMY_PK" "$DUMMY_SID" \
      "$DUMMY_ADDR_MAIN" "$proxy_ts_addr" <<'PYEOF'
import json
import sys

out, first, second, uuid, pk, sid, addr_main, addr_bk = sys.argv[1:9]

def vless(tag, addr):
    return {
        "tag": tag,
        "protocol": "vless",
        "settings": {"vnext": [{"address": addr, "port": 8443,
                                "users": [{"id": uuid, "flow": "xtls-rprx-vision"}]}]},
        "streamSettings": {"security": "reality",
                           "realitySettings": {"serverName": "www.example.com",
                                               "fingerprint": "chrome",
                                               "publicKey": pk, "shortId": sid}},
    }

config = {
    "inbounds": [],
    "outbounds": [
        vless(first, addr_bk if first != "proxy" else addr_main),
        vless(second, addr_main if first != "proxy" else addr_bk),
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"},
        vless("proxy-ts", addr_bk),
    ],
}
with open(out, "w") as fh:
    json.dump(config, fh)
PYEOF
}

export XDG_RUNTIME_DIR="$TMP/runtime"
export SINGBOXCTL_TEMPLATE="$REPO/config.template.json"

# --- backup mode is preserved ---------------------------------------------
mk_xray_config "$TMP/xray-backup-first.json" backup-first
export SINGBOXCTL_XRAY_CONFIG="$TMP/xray-backup-first.json"

gen_out=$(bash "$REPO/singboxctl.sh" generate 2>&1) || { bad "generate exits zero"; gen_out=""; }
[[ -n $gen_out ]] && ok "generate exits zero"

cfg="$XDG_RUNTIME_DIR/sing-box-client/config-staging.json"
[[ -f $cfg ]] && ok "runtime config exists in XDG_RUNTIME_DIR" \
              || bad "runtime config exists in XDG_RUNTIME_DIR"

mode=$(stat -c '%a' "$cfg" 2>/dev/null || echo missing)
[[ $mode == 600 ]] && ok "runtime config mode 0600" || bad "runtime config mode 0600 (got $mode)"

dmode=$(stat -c '%a' "$XDG_RUNTIME_DIR/sing-box-client" 2>/dev/null || echo missing)
[[ $dmode == 700 ]] && ok "runtime dir mode 0700" || bad "runtime dir mode 0700 (got $dmode)"

echo "$gen_out" | grep -q 'route.final: proxy-backup' \
  && ok "backup-first xray order yields route.final=proxy-backup" \
  || bad "backup-first xray order yields route.final=proxy-backup"

# --- stdout must not leak secrets ------------------------------------------
leak=0
for secret in "$DUMMY_UUID" "$DUMMY_PK" "$DUMMY_SID" "$DUMMY_ADDR_MAIN" "$DUMMY_ADDR_BK"; do
  if echo "$gen_out" | grep -qF "$secret"; then leak=1; fi
done
if [[ -f $cfg ]]; then
  # the runtime file itself may hold secrets (0600 tmpfs), but never the output
  :
fi
[[ $leak == 0 ]] && ok "generate output contains no UUID/key/short-ID/address" \
                 || bad "generate output contains no UUID/key/short-ID/address"

# --- primary mode is preserved too ------------------------------------------
mk_xray_config "$TMP/xray-proxy-first.json" proxy-first
gen_out2=$(SINGBOXCTL_XRAY_CONFIG="$TMP/xray-proxy-first.json" \
  bash "$REPO/singboxctl.sh" generate 2>&1) || gen_out2=""
echo "$gen_out2" | grep -q 'route.final: proxy (derived' \
  && ok "proxy-first xray order yields route.final=proxy" \
  || bad "proxy-first xray order yields route.final=proxy"

# --- structure of the generated config ---------------------------------------
python3 - "$cfg" <<'PYEOF' && ok "staging ports, pins, no block outbound, no 0.0.0.0" \
                          || bad "staging ports, pins, no block outbound, no 0.0.0.0"
import json
import sys

with open(sys.argv[1]) as fh:
    c = json.load(fh)

expected = {"socks": 18080, "ts-in": 18081, "probe-in": 18082, "bk-in": 18083}
inbounds = {i["tag"]: i for i in c["inbounds"]}
assert set(inbounds) == set(expected), inbounds.keys()
for tag, port in expected.items():
    assert inbounds[tag]["listen"] == "127.0.0.1"
    assert inbounds[tag]["listen_port"] == port
assert "0.0.0.0" not in json.dumps(c)

outbounds = {o["tag"] for o in c["outbounds"]}
assert outbounds == {"direct", "proxy", "proxy-backup", "proxy-ts"}, outbounds

pins = {ib: r.get("outbound") for r in c["route"]["rules"] for ib in r.get("inbound", [])}
assert pins == {"ts-in": "proxy-ts", "probe-in": "proxy", "bk-in": "proxy-backup"}, pins

actions = [(r.get("network"), r.get("port"), r.get("action"), r.get("ip_version"))
           for r in c["route"]["rules"]]
assert any(a == "reject" and p == [443] for _, p, a, _ in actions), "quic reject missing"
assert any(a == "reject" and v == 6 for _, _, a, v in actions), "ipv6 reject missing"
PYEOF

# --- missing outbound is a hard error ----------------------------------------
python3 - "$TMP/xray-broken.json" <<'PYEOF'
import json
import sys
c = {"inbounds": [], "outbounds": [{"tag": "direct", "protocol": "freedom"}]}
with open(sys.argv[1], "w") as fh:
    json.dump(c, fh)
PYEOF
if SINGBOXCTL_XRAY_CONFIG="$TMP/xray-broken.json" bash "$REPO/singboxctl.sh" generate >/dev/null 2>&1; then
  bad "generate fails when vless outbounds are missing"
else
  ok "generate fails when vless outbounds are missing"
fi

# --- end-to-end validate with the real binary (skipped when absent) -----------
if [[ -x $HOME/.local/lib/sing-box/current/sing-box \
   && -f $HOME/.local/share/sing-box/rule-sets/geoip-cn.srs ]]; then
  val_out=$(SINGBOXCTL_XRAY_CONFIG="$TMP/xray-backup-first.json" \
    bash "$REPO/singboxctl.sh" validate 2>&1) || val_out=""
  echo "$val_out" | grep -q 'policy self-check: ok' \
    && ok "validate: policy self-check passes" \
    || bad "validate: policy self-check passes"
  echo "$val_out" | grep -q 'sing-box check: ok' \
    && ok "validate: sing-box check passes" \
    || bad "validate: sing-box check passes"
  vleak=0
  for secret in "$DUMMY_UUID" "$DUMMY_PK" "$DUMMY_SID" "$DUMMY_ADDR_MAIN" "$DUMMY_ADDR_BK"; do
    if echo "$val_out" | grep -qF "$secret"; then vleak=1; fi
  done
  [[ $vleak == 0 ]] && ok "validate output contains no secrets" \
                    || bad "validate output contains no secrets"
else
  skip "validate: real sing-box binary/rule-sets not installed"
  skip "validate: real sing-box binary/rule-sets not installed"
  skip "validate: real sing-box binary/rule-sets not installed"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL == 0 ]]
