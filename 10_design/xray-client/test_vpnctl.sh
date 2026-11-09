#!/usr/bin/env bash
# test_vpnctl.sh — 离线验收测试（不访问网络，不改真实系统）
# 覆盖 design.md 第 9 节的静态部分：T1/T2/T3/T7/T11/T13/T16 的核心逻辑，
# 以及 2026-11-09 新增的 T17（geo 代码清单）/ T18（IPv6 catch-all 守卫）/ T19（多 VLESS 出站）。
# 真实 systemd / GNOME 的 T4~T6、T8~T10、T12 需要在主机上人工验收。

set -uo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/vpnctl-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export MOCK="$TMP/mock"
export PATH="$MOCK/bin:$PATH"
mkdir -p "$HOME" "$MOCK/bin" "$MOCK/state"

PASS=0
FAIL=0
OUT="$TMP/out.log"

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; [[ -f $OUT ]] && sed -n '1,20p' "$OUT" | sed 's/^/     /'; }

run() { bash "$REPO/vpnctl.sh" "$@" >"$OUT" 2>&1; }
expect_rc() {
  local want=$1
  shift
  run "$@"
  local rc=$?
  [[ $rc -eq $want ]]
}

# ---------------------------------------------------------------------------
# mocks
# ---------------------------------------------------------------------------

cat > "$MOCK/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$MOCK/state/systemctl.log"
sub=""
for a in "$@"; do
  case $a in --user|--quiet|--no-pager) continue ;; -*) continue ;; *) sub=$a; break ;; esac
done
case $sub in
  is-active)
    if [[ -f "$MOCK/state/active" ]]; then echo active; exit 0; else echo inactive; exit 3; fi ;;
  start|restart)
    touch "$MOCK/state/active" "$MOCK/state/port"; exit 0 ;;
  stop)
    rm -f "$MOCK/state/active" "$MOCK/state/port"; exit 0 ;;
  show) echo 12345; exit 0 ;;
  is-enabled) echo enabled; exit 0 ;;
  *) exit 0 ;;
esac
EOF

cat > "$MOCK/bin/gsettings" <<'EOF'
#!/usr/bin/env bash
op=${1:-}; schema=${2:-}; key=${3:-}; value=${4:-}
f="$MOCK/state/gs_$(printf '%s' "$schema" | tr '/.' '__')_$key"
case $op in
  get) if [[ -f $f ]]; then printf "'%s'\n" "$(cat "$f")"; else printf "'none'\n"; fi ;;
  set) printf '%s\n' "$value" > "$f" ;;
  *) exit 1 ;;
esac
EOF

cat > "$MOCK/bin/ss" <<'EOF'
#!/usr/bin/env bash
echo "State Recv-Q Send-Q Local Address:Port Peer Address:Port Process"
if [[ -f "$MOCK/state/port" ]]; then
  echo 'LISTEN 0 4096 127.0.0.1:10808 0.0.0.0:* users:(("xray",pid=12345,fd=3))'
fi
EOF

cat > "$MOCK/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
case $url in
  *api.ipify.org*) echo "203.0.113.7" ;;
  *) cat "$MOCK/state/curl_code" 2>/dev/null || printf '204' ;;
esac
EOF

cat > "$MOCK/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat > "$MOCK/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$MOCK/state/notify.log"
EOF

cat > "$MOCK/bin/logger" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$MOCK/state/logger.log"
EOF

cat > "$MOCK/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
echo "journalctl $*"
EOF

cat > "$MOCK/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
echo "Linger=yes"
EOF

chmod +x "$MOCK/bin/"*

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

make_xray() {
  local path=$1 version=$2
  cat > "$path" <<EOF
#!/usr/bin/env bash
if [[ \${1:-} == version ]]; then
  echo "Xray $version (Xray, Penetrates Everything.) test"
  exit 0
fi
if [[ \${1:-} == run ]]; then
  cfg=""
  while [[ \$# -gt 0 ]]; do
    [[ \$1 == -c ]] && cfg=\$2
    shift
  done
  [[ -f \$cfg ]] || exit 1
  grep -q '__FAIL__' "\$cfg" && exit 1
  echo "Configuration OK."
  exit 0
fi
exit 1
EOF
  chmod +x "$path"
}

make_config() {
  cat > "$1" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "socks",
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "mixed",
      "settings": {"auth": "noauth", "udp": true, "allowTransparent": false}
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "198.51.100.10",
            "port": 443,
            "users": [
              {"id": "test-user-id", "encryption": "none", "flow": "xtls-rprx-vision"}
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "serverName": "example.com",
          "fingerprint": "chrome",
          "publicKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          "shortId": "0123456789abcdef"
        }
      }
    },
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {"domainStrategy": "AsIs", "rules": []}
}
JSON
}

mkdir -p "$TMP/src/assets"
make_config "$TMP/src/config.json"
truncate -s 2097152 "$TMP/src/assets/geoip.dat"
truncate -s 2097152 "$TMP/src/assets/geosite.dat"
make_xray "$TMP/src/xray-261010" "26.10.10"
make_xray "$TMP/src/xray-261101" "26.11.01"
make_xray "$TMP/src/xray-pre" "26.11.01-rc1"
SHA_MAIN=$(sha256sum "$TMP/src/xray-261010" | awk '{print $1}')
SHA_NEXT=$(sha256sum "$TMP/src/xray-261101" | awk '{print $1}')
SHA_PRE=$(sha256sum "$TMP/src/xray-pre" | awk '{print $1}')

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/xray" "$HOME/.config/xray"
cp "$TMP/src/xray-261010" "$HOME/.local/bin/xray"
chmod +x "$HOME/.local/bin/xray"
cp "$TMP/src/assets/"* "$HOME/.local/share/xray/"
cp "$TMP/src/config.json" "$HOME/.config/xray/config.json"

# ---------------------------------------------------------------------------
# T1/T2/T3: validate
# ---------------------------------------------------------------------------

if grep -RInE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'       "$REPO" --include='*.md' --include='*.json' --include='*.sh' --include='*.service' --include='*.timer'       >/dev/null 2>&1; then
  bad "R9 repository contains a UUID-like string"
else
  ok "R9 repository has no UUID-like strings"
fi

if expect_rc 0 validate; then ok "T1 validate passes on a policy-compliant config"; else bad "T1 validate"; fi

jq '.inbounds[0].listen = "0.0.0.0"' "$HOME/.config/xray/config.json" > "$TMP/bad-listen.json"
if expect_rc 2 validate "$TMP/bad-listen.json"; then ok "T2 validate rejects 0.0.0.0 listen"; else bad "T2 validate 0.0.0.0"; fi

mv "$HOME/.local/share/xray/geosite.dat" "$TMP/geosite.bak"
if expect_rc 2 validate; then ok "T3 validate rejects missing geosite.dat"; else bad "T3 missing asset"; fi
mv "$TMP/geosite.bak" "$HOME/.local/share/xray/geosite.dat"

# ---------------------------------------------------------------------------
# T11: install --dry-run changes nothing
# ---------------------------------------------------------------------------

snapshot() { find "$HOME" -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null; }
snapshot > "$TMP/before.sha"
if expect_rc 0 install --dry-run --xray "$TMP/src/xray-261010" --xray-sha256 "$SHA_MAIN" \
      --from-config "$TMP/src/config.json" --from-assets "$TMP/src/assets" \
      --disable-v2rayn-autostart; then
  ok "T11 install --dry-run exits 0"
else
  bad "T11 dry-run exit"
fi
snapshot > "$TMP/after.sha"
if cmp -s "$TMP/before.sha" "$TMP/after.sha"; then ok "T11 dry-run did not modify HOME"; else bad "T11 dry-run modified HOME"; fi

# ---------------------------------------------------------------------------
# install (real, into temp HOME)
# ---------------------------------------------------------------------------

touch -d "2020-01-01 00:00:00" "$TMP/src/assets/geoip.dat" "$TMP/src/assets/geosite.dat"
mkdir -p "$HOME/.config/autostart"
printf '[Desktop Entry]\nType=Application\n' > "$HOME/.config/autostart/v2rayN.desktop"

if expect_rc 0 install --xray "$TMP/src/xray-261010" --xray-sha256 "$SHA_MAIN" \
      --from-config "$TMP/src/config.json" --from-assets "$TMP/src/assets" \
      --xray-source "https://example.invalid/release" --disable-v2rayn-autostart; then
  ok "install exits 0"
else
  bad "install exit"
fi

[[ -f $HOME/.config/xray/config.json ]] && ok "install wrote config" || bad "install config missing"
[[ $(stat -c '%a' "$HOME/.config/xray/config.json") == 600 ]] && ok "config mode 600" || bad "config mode"
[[ $(jq -r '.inbounds[0].listen' "$HOME/.config/xray/config.json") == 127.0.0.1 ]] && ok "install forced listen 127.0.0.1" || bad "listen not fixed"
[[ -f $HOME/.local/bin/xray ]] && ok "install wrote xray symlink" || bad "xray symlink missing"
[[ -f $HOME/.config/systemd/user/xray-client.service ]] && ok "install wrote unit" || bad "unit missing"
[[ -f $HOME/.local/state/vpn/upgrades/baseline-26.10.10.md ]] && ok "baseline evidence written" || bad "baseline evidence missing"
[[ $(stat -c %Y "$HOME/.local/share/xray/geoip.dat") == $(stat -c %Y "$TMP/src/assets/geoip.dat") ]] && ok "install preserves asset mtime" || bad "asset mtime not preserved"
[[ -f $HOME/.config/autostart/v2rayN.desktop.disabled ]] && ok "autostart renamed" || bad "autostart not renamed"
grep -q 'enable xray-client.service vpn-health.timer' "$MOCK/state/systemctl.log" && ok "units enabled" || bad "units not enabled"

# ---------------------------------------------------------------------------
# status / check / on / off
# ---------------------------------------------------------------------------

touch "$MOCK/state/active" "$MOCK/state/port"
"$MOCK/bin/gsettings" set org.gnome.system.proxy mode manual
if run status && grep -q 'service : active' "$OUT" && grep -q 'manual' "$OUT"; then ok "status shows active + manual"; else bad "status output"; fi

if expect_rc 0 check && [[ $(jq -r '.result' "$HOME/.local/state/vpn/health.json") == ok ]]; then
  ok "check records ok"
else
  bad "check ok"
fi

rm -f "$MOCK/state/port"
if expect_rc 4 check && [[ $(jq -r '.result' "$HOME/.local/state/vpn/health.json") == fail ]]; then
  ok "check records fail"
else
  bad "check fail"
fi
grep -q 'VPN 隧道异常' "$MOCK/state/notify.log" && ok "failure notification sent" || bad "failure notification missing"

# AUTO_OFF after 2 failed rounds
mkdir -p "$HOME/.config/vpn"
cat > "$HOME/.config/vpn/vpn.conf" <<'EOF'
AUTO_OFF=1
EOF
rm -f "$MOCK/state/port"
expect_rc 4 check
if [[ $(cat "$MOCK/state/gs_org_gnome_system_proxy_mode" 2>/dev/null) == none ]]; then
  ok "AUTO_OFF switched proxy off"
else
  bad "AUTO_OFF did not switch proxy off"
fi
rm -f "$HOME/.config/vpn/vpn.conf"

rm -f "$MOCK/state/active" "$MOCK/state/port"
"$MOCK/bin/gsettings" set org.gnome.system.proxy mode none
if expect_rc 0 on && [[ $(cat "$MOCK/state/gs_org_gnome_system_proxy_mode") == manual ]]; then
  ok "on enables proxy"
else
  bad "on"
fi
if expect_rc 0 off && [[ $(cat "$MOCK/state/gs_org_gnome_system_proxy_mode") == none ]]; then
  ok "off disables proxy"
else
  bad "off"
fi

# ---------------------------------------------------------------------------
# T13/T16: upgrade gates and rollback
# ---------------------------------------------------------------------------

OLD_DATE=$(date -d '90 days ago' +%F)
NEW_DATE=$(date +%F)

if expect_rc 2 upgrade "$TMP/src/xray-261101" --released "$OLD_DATE" --source "https://example.invalid/x"; then
  ok "T13 upgrade rejects missing --sha256"
else
  bad "T13 missing sha"
fi

if expect_rc 2 upgrade "$TMP/src/xray-261101" --sha256 "$SHA_NEXT" --released "$NEW_DATE" --source "https://example.invalid/x"; then
  ok "T13 upgrade rejects version newer than 60 days"
else
  bad "T13 too new"
fi

if expect_rc 2 upgrade "$TMP/src/xray-261101" --sha256 "$SHA_MAIN" --released "$OLD_DATE" --source "https://example.invalid/x"; then
  ok "T13 upgrade rejects sha mismatch"
else
  bad "T13 sha mismatch"
fi

if expect_rc 2 upgrade "$TMP/src/xray-pre" --sha256 "$SHA_PRE" --released "$OLD_DATE" --source "https://example.invalid/x"; then
  ok "T13 upgrade rejects pre-release"
else
  bad "T13 pre-release"
fi

touch "$MOCK/state/active" "$MOCK/state/port"
if expect_rc 0 upgrade "$TMP/src/xray-261101" --sha256 "$SHA_NEXT" --released "$OLD_DATE" --source "https://example.invalid/x"; then
  ok "upgrade succeeds with a 60-day-old stable build"
else
  bad "upgrade success"
fi
[[ -f $HOME/.local/state/vpn/upgrades/26.11.01-$OLD_DATE.md ]] && ok "upgrade evidence written" || bad "upgrade evidence missing"
[[ $(readlink -f "$HOME/.local/lib/xray/current") == "$HOME/.local/lib/xray/26.11.01" ]] && ok "current switched to 26.11.01" || bad "current not switched"

if expect_rc 2 upgrade "$TMP/src/xray-261101" --sha256 "$SHA_NEXT" --released "$OLD_DATE" --source "https://example.invalid/x"; then
  ok "upgrade refuses the already-running version"
else
  bad "upgrade same version"
fi

if expect_rc 0 restart; then ok "restart validates and probes"; else bad "restart"; fi
if run ip && grep -q '203.0.113.7' "$OUT"; then ok "ip returns exit address"; else bad "ip"; fi

if expect_rc 0 rollback; then ok "rollback restores latest config backup"; else bad "rollback"; fi

mkdir -p "$TMP/newgeo"
truncate -s 2097152 "$TMP/newgeo/geoip.dat"
truncate -s 2097152 "$TMP/newgeo/geosite.dat"
if expect_rc 0 update-geo --from "$TMP/newgeo" --source "https://example.invalid/geo"; then
  ok "update-geo applies and probes"
else
  bad "update-geo"
fi
[[ -f $HOME/.local/state/vpn/assets.json ]] && ok "assets.json written" || bad "assets.json missing"

# rollback-on-failure: candidate passes config test but the tunnel probe fails
make_xray "$TMP/src/xray-bad" "26.12.01"
SHA_BAD=$(sha256sum "$TMP/src/xray-bad" | awk '{print $1}')
printf '500' > "$MOCK/state/curl_code"
if expect_rc 4 upgrade "$TMP/src/xray-bad" --sha256 "$SHA_BAD" --released "$OLD_DATE" --source "https://example.invalid/x"; then
  ok "T16 upgrade fails and rolls back"
else
  bad "T16 upgrade rollback exit"
fi
[[ $(readlink -f "$HOME/.local/lib/xray/current") == "$HOME/.local/lib/xray/26.11.01" ]] && ok "T16 rolled back to 26.11.01" || bad "T16 current wrong"
printf '204' > "$MOCK/state/curl_code"

# ---------------------------------------------------------------------------
# T7: edit with invalid config leaves the file untouched
# ---------------------------------------------------------------------------

BEFORE_EDIT=$(sha256sum "$HOME/.config/xray/config.json" | awk '{print $1}')
cat > "$MOCK/bin/editor-bad" <<'EOF'
#!/usr/bin/env bash
printf '__FAIL__\n' > "$1"
EOF
chmod +x "$MOCK/bin/editor-bad"
export EDITOR="$MOCK/bin/editor-bad"
expect_rc 2 edit
unset EDITOR
AFTER_EDIT=$(sha256sum "$HOME/.config/xray/config.json" | awk '{print $1}')
[[ $BEFORE_EDIT == "$AFTER_EDIT" ]] && ok "T7 invalid edit leaves config unchanged" || bad "T7 config changed"

# ---------------------------------------------------------------------------
# T8: edit with a valid but unreachable outbound -> automatic rollback
# ---------------------------------------------------------------------------

BEFORE_T8=$(sha256sum "$HOME/.config/xray/config.json" | awk '{print $1}')
cat > "$MOCK/bin/editor-dead" <<'EOF'
#!/usr/bin/env bash
jq '(.outbounds[] | select(.protocol == "vless") | .settings.vnext[0].address) = "127.0.0.1"
    | (.outbounds[] | select(.protocol == "vless") | .settings.vnext[0].port) = 1' "$1" > "$1.tmp"
mv "$1.tmp" "$1"
EOF
chmod +x "$MOCK/bin/editor-dead"
printf '500' > "$MOCK/state/curl_code"
export EDITOR="$MOCK/bin/editor-dead"
expect_rc 4 edit
unset EDITOR
printf '204' > "$MOCK/state/curl_code"
AFTER_T8=$(sha256sum "$HOME/.config/xray/config.json" | awk '{print $1}')
[[ $BEFORE_T8 == "$AFTER_T8" ]] && ok "T8 dead outbound edit rolled back" || bad "T8 config not restored"

# ---------------------------------------------------------------------------
# T17: geo code manifest — a code the database does not have is named, not restarted
# ---------------------------------------------------------------------------

mkdir -p "$TMP/geo"
python3 - "$TMP/geo" <<'PY'
import sys

def entry(code):
    b = code.encode()
    inner = b"\x0a" + bytes([len(b)]) + b        # GeoSite/GeoIP { country_code = 1 }
    return b"\x0a" + bytes([len(inner)]) + inner  # database list { entry = 1 }

site = b"".join(entry(c) for c in ["CN", "GOOGLE", "TELEGRAM", "PRIVATE"])
ip = b"".join(entry(c) for c in ["CN", "TELEGRAM", "PRIVATE"])
pad = 2 * 1024 * 1024
with open(sys.argv[1] + "/geosite.dat", "wb") as fh:
    fh.write(site + b"\0" * (pad - len(site)))
with open(sys.argv[1] + "/geoip.dat", "wb") as fh:
    fh.write(ip + b"\0" * (pad - len(ip)))
PY
cp -p "$TMP/geo/geosite.dat" "$TMP/geo/geoip.dat" "$HOME/.local/share/xray/"
if expect_rc 0 geo-manifest; then ok "T17 geo-manifest reads the code list from the databases"; else bad "T17 geo-manifest"; fi
if grep -qx GOOGLE "$HOME/.local/state/vpn/geo-codes/geosite.txt"; then
  ok "T17 manifest lists the codes that exist"
else
  bad "T17 manifest content"
fi

# __FAIL__ stands in for the real binary: it makes the mock xray -test fail, which is how a
# code that never existed behaves in production (geosite:office, 2026-11-04).
jq '."_test" = "__FAIL__" | .routing.rules[0].domain = ["geosite:office"]' \
  "$HOME/.config/xray/config.json" > "$TMP/office.json"
if expect_rc 2 validate "$TMP/office.json"; then
  ok "T17 validate rejects a geosite code that is not in the database"
else
  bad "T17 unknown geosite code not rejected"
fi
if grep -q 'unknown geosite/geoip code' "$OUT"; then
  ok "T17 the failure names the offending code"
else
  bad "T17 failure does not name the code"
fi

jq '.routing.rules[0].domain = ["geosite:google"]' \
  "$HOME/.config/xray/config.json" > "$TMP/known.json"
if expect_rc 0 validate "$TMP/known.json"; then
  ok "T17 a known code still validates"
else
  bad "T17 known code rejected"
fi

# ---------------------------------------------------------------------------
# T18: the IPv6 guard is one catch-all rule, and status shows whether it is there
# ---------------------------------------------------------------------------

cp -p "$HOME/.config/xray/config.json" "$TMP/config-guard.json"
jq '.routing.rules += [{"type": "field", "ip": ["::/0"], "outboundTag": "block"}]' \
  "$TMP/config-guard.json" > "$TMP/with-guard.json"
install -m 600 "$TMP/with-guard.json" "$HOME/.config/xray/config.json"
run status
if grep -q 'guard   : IPv6' "$OUT"; then ok "T18 status reports the IPv6 guard"; else bad "T18 guard not reported"; fi

install -m 600 "$TMP/config-guard.json" "$HOME/.config/xray/config.json"
run status
if grep -q 'guard   : absent' "$OUT"; then ok "T18 status reports a missing guard"; else bad "T18 missing guard not reported"; fi

# ---------------------------------------------------------------------------
# T19: a second VLESS outbound (the tailnet egress) is accepted; a broken one is not
# ---------------------------------------------------------------------------

# The live config gained `proxy-ts` on 2026-11-05; until 2026-11-09 validate demanded
# exactly one VLESS outbound, so it silently refused the real config.
jq '.outbounds += [(.outbounds[] | select(.protocol == "vless") | .tag = "proxy-ts")]' \
  "$TMP/config-guard.json" > "$TMP/two-vless.json"
if expect_rc 0 validate "$TMP/two-vless.json"; then
  ok "T19 a second VLESS outbound is accepted"
else
  bad "T19 second VLESS outbound rejected"
fi

jq '(.outbounds[] | select(.protocol == "vless") | .streamSettings.realitySettings.shortId) = ""' \
  "$TMP/two-vless.json" > "$TMP/bad-vless.json"
if expect_rc 2 validate "$TMP/bad-vless.json"; then
  ok "T19 a VLESS outbound without REALITY shortId is rejected"
else
  bad "T19 broken VLESS outbound accepted"
fi

# ---------------------------------------------------------------------------
# uninstall restores autostart
# ---------------------------------------------------------------------------

if expect_rc 0 uninstall; then ok "uninstall exits 0"; else bad "uninstall"; fi
[[ -f $HOME/.config/autostart/v2rayN.desktop ]] && ok "uninstall restored autostart" || bad "autostart not restored"

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
