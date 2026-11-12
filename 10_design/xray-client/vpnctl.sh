#!/usr/bin/env bash
# vpnctl.sh — 方案 A 的唯一入口
# 设计文档：同目录 design.md（v0.3）
#
# 用法：./vpnctl.sh help
# 安装：./vpnctl.sh install --xray <官方 xray> --xray-sha256 <hex> \
#          --from-assets ~/.local/share/v2rayN/bin --disable-v2rayn-autostart
#
# 约定：
#   - 只用 $HOME 下的路径；不调用 sudo。
#   - 所有命令的退出码：0 成功 / 1 用法 / 2 校验 / 3 服务 / 4 健康 / 5 前置条件。
#   - 真实配置只存在于 ~/.config/xray/config.json（0600），本脚本不打印其内容。

set -euo pipefail

readonly PORT=10808
readonly PROXY_HOST=127.0.0.1
readonly SERVICE="xray-client"
readonly HEALTH_SERVICE="vpn-health"
UPGRADE_MIN_AGE_DAYS=60

readonly E_USAGE=1
readonly E_VALIDATE=2
readonly E_SERVICE=3
readonly E_HEALTH=4
readonly E_PREFLIGHT=5

# IPv6 path probe (2026-11-03): this host has public IPv6 and applications prefer it,
# but the exit VPS has no IPv6 route, so an IPv6 destination handed to the proxy outbound
# hangs until timeout (measured: 12 s per attempt, 3,105 "unexpected EOF" lines in 24 h).
# A healthy setup either answers or fails fast; only a *hang* is the fault signature.
readonly IPV6_PROBE_URL="https://[2001:67c:4e8:f002::a]/"
readonly IPV6_HANG_MS=3000

# Per-egress probe (2026-11-09): since 2026-11-05 Telegram leaves by the tailnet egress
# (`proxy-ts`) to dodge packet loss on the public path, but every other probe in this file
# goes through `proxy`. A dead tailnet therefore left the health record green while
# Telegram was down. A second mixed inbound that only routes to `proxy-ts` makes that path
# testable without touching the main one.
readonly TS_PORT="${TS_PORT:-10809}"
# The health probe must travel the tunnel it claims to test. `www.gstatic.com` is matched by
# `geosite:cn` in the current database and went out DIRECT — so a dead tunnel still produced
# a 204 (journal: "//www.gstatic.com:443 [socks -> direct]"). A second diagnostic inbound
# pinned to `proxy` removes that dependency on list membership.
readonly PROBE_PORT="${PROBE_PORT:-10810}"
readonly TS_PROBE_URL="${TS_PROBE_URL:-https://api.telegram.org/}"
readonly TS_MAX_TIME="${TS_MAX_TIME:-8}"

# Backup-egress probe (2026-11-12, design.md §6.11): one airport trojan node is the strict
# cold standby for `proxy`. Its own diagnostic inbound (127.0.0.1:10811) makes the backup
# path testable while the primary serves, and becomes the health verdict while the backup
# serves. The active egress is derived from `outbounds[0].tag` — the config is the only
# state, there is no separate mode file.
readonly BK_PORT="${BK_PORT:-10811}"
readonly BK_PROBE_URL="${BK_PROBE_URL:-https://www.gstatic.com/generate_204}"

# Throughput probe (2026-11-04): the 2026-11-03 failure was not a dead tunnel but a
# per-flow throttle towards Cloudflare/Fastly (~38 KB/s) that the 204 probe could not
# see. Measure one Cloudflare target (the WARP-routed direction) and one non-CF
# reference; record KB/s and only complain after two consecutive slow samples.
readonly TP_CF_URL="https://speed.cloudflare.com/__down?bytes=200000"
readonly TP_REF_URL="https://proof.ovh.net/files/1Mb.dat"
readonly TP_MAX_TIME=20
readonly TP_INTERVAL_S="${TP_INTERVAL_S:-600}"
readonly TP_MIN_KBPS="${TP_MIN_KBPS:-70}"
readonly TP_NOTIFY="${TP_NOTIFY:-0}"

H=${HOME:?HOME is not set}
CONFIG_DIR="$H/.config/xray"
CONFIG_FILE="$CONFIG_DIR/config.json"
VPN_CONF="$H/.config/vpn/vpn.conf"
STATE_DIR="$H/.local/state/vpn"
BACKUP_DIR="$STATE_DIR/backups"
UPGRADE_EVIDENCE="$STATE_DIR/upgrades"
STAGING="$STATE_DIR/staging"
HEALTH_FILE="$STATE_DIR/health.json"
ASSETS_FILE="$STATE_DIR/assets.json"
ASSET_DIR="$H/.local/share/xray"
# Code manifests (2026-11-09): the codes actually present in geosite.dat / geoip.dat so a
# rule can be rejected before a restart rather than after (2026-11-04: geosite:office).
GEO_MANIFEST_DIR="$STATE_DIR/geo-codes"
GEO_MANIFEST_BIN="$H/.local/bin/geo-manifest"
XRAY_LIB="$H/.local/lib/xray"
XRAY_BIN="$H/.local/bin/xray"
VPNCTL_BIN="$H/.local/bin/vpnctl"
UNIT_DIR="$H/.config/systemd/user"
AUTOSTART="$H/.config/autostart/v2rayN.desktop"
AUTOSTART_MARKER="$STATE_DIR/autostart-disabled"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

say() { printf '%s\n' "$*"; }
warn() { printf 'vpnctl: %s\n' "$*" >&2; }

die() {
  local code=$1
  shift
  printf 'vpnctl: %s\n' "$*" >&2
  exit "$code"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$E_PREFLIGHT" "missing command: $1"
}

is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }

now_iso() { date -Iseconds; }

sha_of() { sha256sum "$1" | awk '{print $1}'; }

version_of() {
  "$1" version 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]/) { print $i; exit }
    }
  }'
}

file_age_days() {
  local f=$1
  echo $(( ( $(date +%s) - $(stat -L -c %Y "$f") ) / 86400 ))
}

load_conf() {
  AUTO_OFF=0
  AUTO_FAILOVER=0
  HEALTH_URL="https://www.gstatic.com/generate_204"
  NOTIFY=1
  if [[ -f $VPN_CONF ]]; then
    # shellcheck disable=SC1090
    . "$VPN_CONF"
  fi
  AUTO_OFF=${AUTO_OFF:-0}
  AUTO_FAILOVER=${AUTO_FAILOVER:-0}
  NOTIFY=${NOTIFY:-1}
  HEALTH_URL=${HEALTH_URL:-https://www.gstatic.com/generate_204}
  UPGRADE_MIN_AGE_DAYS=${UPGRADE_MIN_AGE_DAYS:-60}
  [[ $UPGRADE_MIN_AGE_DAYS =~ ^[0-9]+$ ]] || UPGRADE_MIN_AGE_DAYS=60
}

# ---------------------------------------------------------------------------
# 运行状态探测
# ---------------------------------------------------------------------------

service_active() { systemctl --user is-active --quiet "$SERVICE" 2>/dev/null; }

port_open() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "sport = :$PORT" 2>/dev/null | awk 'NR > 1 { found = 1 } END { exit(found ? 0 : 1) }'
  else
    (exec 3<>"/dev/tcp/$PROXY_HOST/$PORT") 2>/dev/null
  fi
}

listener_pid() {
  command -v ss >/dev/null 2>&1 || return 0
  ss -ltnp "sport = :$PORT" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n 1
}

wait_port() {
  local i
  for i in $(seq 1 50); do
    port_open && return 0
    sleep 0.1
  done
  return 1
}

proxy_mode() {
  command -v gsettings >/dev/null 2>&1 || { printf ''; return 0; }
  gsettings get org.gnome.system.proxy mode 2>/dev/null | tr -d "'" || true
}

set_proxy_manual() {
  local k
  command -v gsettings >/dev/null 2>&1 || return 1
  for k in http https socks ftp; do
    gsettings set "org.gnome.system.proxy.$k" host "$PROXY_HOST" || return 1
    gsettings set "org.gnome.system.proxy.$k" port "$PORT" || return 1
  done
  gsettings set org.gnome.system.proxy mode 'manual' || return 1
}

set_proxy_off() {
  command -v gsettings >/dev/null 2>&1 || return 0
  gsettings set org.gnome.system.proxy mode 'none' || return 1
}

restore_mode() {
  case ${1:-} in
    manual) set_proxy_manual || true ;;
    none) set_proxy_off || true ;;
    *) : ;;
  esac
}

probe_http() {
  local code
  code=$(env -u http_proxy -u https_proxy -u all_proxy \
              -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
              curl -s -o /dev/null -w '%{http_code}' \
              --noproxy '' -x "http://$PROXY_HOST:$(health_port)" \
              -m 8 "$HEALTH_URL" 2>/dev/null) || return 1
  [[ $code == 204 ]]
}

probe_with_retry() {
  probe_http && return 0
  sleep 5
  probe_http
}

# Returns "<state> <elapsed_ms>": ok (IPv6 path answers), blocked (our routing rule fired
# quickly — healthy), hang (still waiting at the deadline), fail (fast but unexpected).
# Only "blocked" and "ok" are acceptable; the other two are faults.
probe_ipv6_path() {
  local started elapsed_ms code state
  started=$(date +%s%3N)
  code=$(env -u http_proxy -u https_proxy -u all_proxy \
              -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
              curl -s -o /dev/null -w '%{http_code}' \
              --noproxy '' -x "http://$PROXY_HOST:$PORT" \
              -m 6 "$IPV6_PROBE_URL" 2>/dev/null) || code=0
  elapsed_ms=$(( $(date +%s%3N) - started ))
  if [[ $code =~ ^[1-5][0-9][0-9]$ ]]; then
    state=ok
  elif (( elapsed_ms >= IPV6_HANG_MS )); then
    state=hang
  elif ipv6_block_rule_present; then
    state=blocked
  else
    state=fail
  fi
  printf '%s %s\n' "$state" "$elapsed_ms"
}

# The client-side IPv6 guard (2026-11-09): the exit VPS has no IPv6, so the proxy path is
# IPv4-only by policy — any IPv6 literal that reaches it is blackholed so the application
# falls back immediately instead of hanging (2026-11-03: 3,105 "unexpected EOF" in 24 h).
# The guard is one catch-all rule after the direct (CN/private) rules, not a list of
# prefixes: a list is always missing the next prefix someone forgets to add.
ipv6_block_rule_present() {
  [[ -f $CONFIG_FILE ]] || return 1
  jq -e 'any(.routing.rules[]?; (.outboundTag == "block") and ((.ip // []) | index("::/0") != null))' \
    "$CONFIG_FILE" >/dev/null 2>&1
}

probe_kbps() {
  # Prints KB/s for one URL through the local proxy (0 on failure).
  local url=$1
  local bytes
  bytes=$(env -u http_proxy -u https_proxy -u all_proxy \
               -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
               curl -s -o /dev/null --noproxy '' -x "http://$PROXY_HOST:$(health_port)" \
               -m "$TP_MAX_TIME" -w '%{speed_download}' "$url" 2>/dev/null) || bytes=0
  [[ $bytes =~ ^[0-9]+$ ]] || bytes=0
  printf '%s' $(( bytes / 1024 ))
}

has_global_ipv6() {
  ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 '
}

# Is the diagnostic inbound that is pinned to `proxy` configured?
probe_inbound_present() {
  [[ -f $CONFIG_FILE ]] || return 1
  jq -e 'any(.inbounds[]?; .tag == "probe-in")' "$CONFIG_FILE" >/dev/null 2>&1
}

# Which port the health probe should use: the pinned one when the config has it, otherwise
# the user-facing port (older configs, and the tests for the fallback).
health_port() {
  if probe_inbound_present; then printf '%s' "$PROBE_PORT"; else printf '%s' "$PORT"; fi
}

# Is the diagnostic inbound for the tailnet egress configured?
ts_inbound_present() {
  [[ -f $CONFIG_FILE ]] || return 1
  jq -e 'any(.inbounds[]?; .tag == "ts-in")' "$CONFIG_FILE" >/dev/null 2>&1
}

# Probe the tailnet egress through its own inbound. Prints "<state> <ms> <code>";
# state is ok for any 2xx/3xx (api.telegram.org answers 302), fail otherwise.
probe_ts() {
  local started elapsed code state
  started=$(date +%s%3N)
  code=$(env -u http_proxy -u https_proxy -u all_proxy \
              -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
              curl -s -o /dev/null -w '%{http_code}' \
              --noproxy '' -x "http://127.0.0.1:$TS_PORT" \
              -m "$TS_MAX_TIME" "$TS_PROBE_URL" 2>/dev/null) || code=0
  [[ $code =~ ^[0-9]{3}$ ]] || code=0
  elapsed=$(( $(date +%s%3N) - started ))
  if [[ $code =~ ^[23][0-9][0-9]$ ]]; then state=ok; else state=fail; fi
  printf '%s %s %s\n' "$state" "$elapsed" "$code"
}

# The tailnet egress needs a moment after a restart (WireGuard handshake + REALITY), so a
# single cold-start timeout must not be reported as a dead path: retry once, like the main
# 204 probe does.
probe_ts_with_retry() {
  local out
  out=$(probe_ts)
  if [[ ${out%% *} != ok ]]; then
    sleep "${TS_RETRY_WAIT:-2}"
    out=$(probe_ts)
  fi
  printf '%s\n' "$out"
}

# Is the diagnostic inbound for the backup egress configured?
bk_inbound_present() {
  [[ -f $CONFIG_FILE ]] || return 1
  jq -e 'any(.inbounds[]?; .tag == "bk-in")' "$CONFIG_FILE" >/dev/null 2>&1
}

# Which egress is serving: xray's default route is the FIRST outbound, so the mode is a
# pure function of the config — "primary" (proxy first) or "backup" (proxy-backup first).
failover_mode() {
  [[ -f $CONFIG_FILE ]] || { printf 'unknown'; return 0; }
  local first
  first=$(jq -r '.outbounds[0].tag // ""' "$CONFIG_FILE" 2>/dev/null)
  case $first in
    proxy) printf 'primary' ;;
    proxy-backup) printf 'backup' ;;
    *) printf 'unknown' ;;
  esac
}

# Probe the backup egress through its own inbound. Prints "<state> <ms> <code>";
# state is ok only for 204 (generate_204), like the main probe.
probe_bk() {
  local started elapsed code state
  started=$(date +%s%3N)
  code=$(env -u http_proxy -u https_proxy -u all_proxy \
              -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
              curl -s -o /dev/null -w '%{http_code}' \
              --noproxy '' -x "http://127.0.0.1:$BK_PORT" \
              -m "$TS_MAX_TIME" "$BK_PROBE_URL" 2>/dev/null) || code=0
  [[ $code =~ ^[0-9]{3}$ ]] || code=0
  elapsed=$(( $(date +%s%3N) - started ))
  if [[ $code == 204 ]]; then state=ok; else state=fail; fi
  printf '%s %s %s\n' "$state" "$elapsed" "$code"
}

probe_bk_with_retry() {
  local out
  out=$(probe_bk)
  if [[ ${out%% *} != ok ]]; then
    sleep "${TS_RETRY_WAIT:-2}"
    out=$(probe_bk)
  fi
  printf '%s\n' "$out"
}

query_exit_ip_bk() {
  env -u http_proxy -u https_proxy -u all_proxy \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      curl -s --noproxy '' -x "http://127.0.0.1:$BK_PORT" \
      -m 8 https://api.ipify.org 2>/dev/null || true
}

query_exit_ip() {
  env -u http_proxy -u https_proxy -u all_proxy \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      curl -s --noproxy '' -x "http://$PROXY_HOST:$(health_port)" \
      -m 8 https://api.ipify.org 2>/dev/null || true
}

notify_user() {
  local title=$1 body=$2
  if [[ ${NOTIFY:-1} == 1 ]] && command -v notify-send >/dev/null 2>&1; then
    notify-send -a vpnctl "$title" "$body" >/dev/null 2>&1 || true
  fi
  command -v logger >/dev/null 2>&1 && logger -t vpn-health "$title: $body" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 配置校验
# ---------------------------------------------------------------------------

assets_ok() {
  local d=$1 f
  for f in geoip.dat geosite.dat; do
    [[ -f $d/$f ]] || return 1
    [[ $(stat -L -c %s "$d/$f") -gt 1048576 ]] || return 1
  done
}

# --- geo code manifest -----------------------------------------------------
# `geosite:X` / `geoip:X` only works when the loaded database has X. A bad code makes
# xray refuse to start, which is how the proxy went down for an hour on 2026-11-04
# (`geosite:office` never existed). The manifest is the list of codes the current
# databases really contain; validate uses it to name the offending code instead of
# only echoing xray's error.

geo_manifest_bin() {
  if [[ -x $SCRIPT_DIR/geo-manifest.py ]]; then
    printf '%s\n' "$SCRIPT_DIR/geo-manifest.py"
  elif [[ -x $GEO_MANIFEST_BIN ]]; then
    printf '%s\n' "$GEO_MANIFEST_BIN"
  else
    return 1
  fi
}

# Rebuild both manifests from $1 (assets dir). Returns 1 when unavailable, never fatal:
# a missing manifest must not be able to block an otherwise valid config.
geo_manifest_build() {
  local assets=$1 bin
  bin=$(geo_manifest_bin) || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  install -d -m 700 "$GEO_MANIFEST_DIR" || return 1
  python3 "$bin" "$assets/geosite.dat" -o "$GEO_MANIFEST_DIR/geosite.txt" >/dev/null 2>&1 || return 1
  python3 "$bin" "$assets/geoip.dat" -o "$GEO_MANIFEST_DIR/geoip.txt" >/dev/null 2>&1 || return 1
  return 0
}

# Prints the codes the config uses that the manifest does not have, space separated.
# Empty output means either "all known" or "no usable manifest" (checked separately).
geo_missing_codes() {
  local cfg=$1 assets=$2 code fam missing=() mf
  command -v jq >/dev/null 2>&1 || return 0
  # Rebuild when a manifest is absent or older than the database it describes.
  if [[ ! -s $GEO_MANIFEST_DIR/geosite.txt || $GEO_MANIFEST_DIR/geosite.txt -ot $assets/geosite.dat ||
        ! -s $GEO_MANIFEST_DIR/geoip.txt || $GEO_MANIFEST_DIR/geoip.txt -ot $assets/geoip.dat ]]; then
    geo_manifest_build "$assets" || return 0
  fi
  # No size heuristic here: this check only *reports* a code, and it is consulted solely
  # after xray -test has already failed, so a wrong manifest can mislabel an already-broken
  # config but can never reject a working one.

  local -a used
  mapfile -t used < <(jq -r '[.. | strings | select(startswith("geosite:") or startswith("geoip:"))] | unique | .[]' "$cfg" 2>/dev/null)
  for code in "${used[@]:-}"; do
    [[ -n $code ]] || continue
    fam=${code%%:*}
    code=${code#*:}
    [[ $code == private ]] && continue   # built into xray, not in the .dat
    if [[ $fam == geosite ]]; then mf="$GEO_MANIFEST_DIR/geosite.txt"; else mf="$GEO_MANIFEST_DIR/geoip.txt"; fi
    grep -qixF -- "$code" "$mf" || missing+=("$fam:${code,,}")
  done
  printf '%s' "${missing[*]:-}"
}

policy_ok() {
  local cfg=$1
  # 2026-11-09: the live config has carried two VLESS outbounds since 2026-11-05
  # (`proxy` plus the tailnet `proxy-ts`), so "exactly one" made every validate — and
  # therefore restart, edit and install — refuse a perfectly working config. Require one
  # or more, and require every one of them to be REALITY + Vision with a non-empty key.
  jq -e '
    (.inbounds | length) > 0
    and ([.inbounds[] | select(.protocol == "mixed" and (.port|tostring) == "10808")] | length) == 1
    and ([.inbounds[] | select((.port|tostring) == "10808")][0].listen) == "127.0.0.1"
    and ([.inbounds[] | select(.listen == "0.0.0.0")] | length) == 0
    and ([.inbounds[] | select(.tag != "ts-in" and .tag != "probe-in" and .tag != "bk-in" and .listen != "127.0.0.1")] | length) == 0
    and ([.inbounds[] | select(.tag == "probe-in" and (.protocol != "mixed" or (.port|tostring) != "10810" or .listen != "127.0.0.1"))] | length) == 0
    and ([.inbounds[] | select(.tag == "ts-in" and (.protocol != "mixed" or (.port|tostring) != "10809" or .listen != "127.0.0.1"))] | length) == 0
    and ([.inbounds[] | select(.tag == "bk-in" and (.protocol != "mixed" or (.port|tostring) != "10811" or .listen != "127.0.0.1"))] | length) == 0
    and ([.routing.rules[]? | select((.inboundTag // []) | index("ts-in"))] | length)
        == ([.inbounds[] | select(.tag == "ts-in")] | length)
    and ([.routing.rules[]? | select((.inboundTag // []) | index("probe-in"))] | length)
        == ([.inbounds[] | select(.tag == "probe-in")] | length)
    and ([.routing.rules[]? | select((.inboundTag // []) | index("bk-in"))] | length)
        == ([.inbounds[] | select(.tag == "bk-in")] | length)
    and ([.outbounds[] | select(.protocol == "vless")] | length) >= 1
    and ([.outbounds[]
          | select(.protocol == "vless")
          | select(((.streamSettings.realitySettings.publicKey // "") | length) == 0
                   or ((.streamSettings.realitySettings.shortId // "") | length) == 0
                   or .settings.vnext[0].users[0].flow != "xtls-rprx-vision")]
         | length) == 0
  ' "$cfg" >/dev/null 2>&1
}

policy_diag() {
  local cfg=$1
  jq -c '{
    mixed: ([.inbounds[] | select(.protocol == "mixed")] | length),
    listen: ([.inbounds[] | select(.protocol == "mixed")][0].listen // null),
    port: ([.inbounds[] | select(.protocol == "mixed")][0].port // null),
    any_zero: ([.inbounds[] | select(.listen == "0.0.0.0")] | length),
    outbounds: [.outbounds[].protocol],
    vless: ([.outbounds[] | select(.protocol == "vless")] | length),
    ts_in: ([.inbounds[] | select(.tag == "ts-in")] | length),
    ts_rule: ([.routing.rules[]? | select((.inboundTag // []) | index("ts-in"))] | length),
    probe_in: ([.inbounds[] | select(.tag == "probe-in")] | length),
    probe_rule: ([.routing.rules[]? | select((.inboundTag // []) | index("probe-in"))] | length),
    bk_in: ([.inbounds[] | select(.tag == "bk-in")] | length),
    bk_rule: ([.routing.rules[]? | select((.inboundTag // []) | index("bk-in"))] | length),
    vless_tags: [.outbounds[] | select(.protocol == "vless") | .tag],
    vless_bad: [.outbounds[]
                | select(.protocol == "vless")
                | select(((.streamSettings.realitySettings.publicKey // "") | length) == 0
                         or ((.streamSettings.realitySettings.shortId // "") | length) == 0
                         or .settings.vnext[0].users[0].flow != "xtls-rprx-vision")
                | .tag]
  }' "$cfg" >&2 2>/dev/null || true
}

validate_cfg() {
  local cfg=$1 assets=$2 bin=$3 out missing test_failed=0
  [[ -f $cfg ]] || die "$E_VALIDATE" "config not found: $cfg"
  jq empty "$cfg" 2>/dev/null || die "$E_VALIDATE" "invalid JSON: $cfg"
  [[ -x $bin ]] || die "$E_VALIDATE" "xray binary not executable: $bin"
  assets_ok "$assets" || die "$E_VALIDATE" "missing or too small geo assets in $assets"
  out=$(XRAY_LOCATION_ASSET="$assets" "$bin" run -test -format=json -c "$cfg" 2>&1) || test_failed=1
  # Name the offending code before echoing xray's message: "geosite:office is not in the
  # database" is the sentence that saves the next hour (2026-11-04).
  missing=$(geo_missing_codes "$cfg" "$assets" 2>/dev/null || true)
  if (( test_failed )); then
    printf '%s\n' "$out" >&2
    if [[ -n $missing ]]; then
      die "$E_VALIDATE" "unknown geosite/geoip code(s): $missing — not in the loaded databases; a code that never existed makes xray refuse to start"
    fi
    die "$E_VALIDATE" "xray config test failed"
  fi
  # xray accepted the config, so these codes are real (built-in or newer than the .dat):
  # warn, never block.
  [[ -n $missing ]] && warn "geo codes absent from the manifest though xray accepted them: $missing"
  if ! policy_ok "$cfg"; then
    warn "policy summary (no secrets):"
    policy_diag "$cfg"
    die "$E_VALIDATE" "policy check failed: need one mixed inbound on 127.0.0.1:10808 and one VLESS REALITY outbound with xtls-rprx-vision; if the source is v2rayN, select the self-hosted VLESS+REALITY node first"
  fi
  say "config: $cfg sha256:$(sha_of "$cfg" | cut -c1-8)"
  say "assets: $assets ok"
  if [[ -s $GEO_MANIFEST_DIR/geosite.txt ]]; then
    say "geo codes: $(wc -l <"$GEO_MANIFEST_DIR/geosite.txt") site / $(wc -l <"$GEO_MANIFEST_DIR/geoip.txt") ip known"
  fi
}

# ---------------------------------------------------------------------------
# 健康状态
# ---------------------------------------------------------------------------

health_field() {
  local key=$1
  [[ -f $HEALTH_FILE ]] || return 0
  jq -r --arg k "$key" '.[$k] // empty' "$HEALTH_FILE" 2>/dev/null || true
}

health_write() {
  local result=$1 fails=$2 svc=$3 port=$4 mode=$5 http_code=$6 exit_ip=$7 reason=$8 last_notify=$9
  local ipv6_state=${10:-none} ipv6_ms=${11:-0} ipv6_local=${12:-false}
  local tp_cf=${13:-0} tp_ref=${14:-0} tp_state=${15:-none} tp_slow=${16:-0} tp_ts=${17:-}
  local ts_state=${18:-skip} ts_ms=${19:-0} ts_code=${20:-0}
  local bk_state=${21:-skip} bk_ms=${22:-0} bk_code=${23:-0}
  local tmp="$HEALTH_FILE.tmp.$$"
  install -d -m 700 "$STATE_DIR"
  jq -n \
    --arg ts "$(now_iso)" \
    --arg result "$result" \
    --argjson fails "$fails" \
    --arg service "$svc" \
    --argjson port "$port" \
    --arg proxy_mode "$mode" \
    --argjson http_code "$http_code" \
    --arg exit_ip "$exit_ip" \
    --arg reason "$reason" \
    --arg last_notify "$last_notify" \
    --arg ipv6_state "$ipv6_state" \
    --argjson ipv6_ms "$ipv6_ms" \
    --argjson ipv6_local "$ipv6_local" \
    --argjson tp_cf_kbps "$tp_cf" \
    --argjson tp_ref_kbps "$tp_ref" \
    --arg tp_state "$tp_state" \
    --argjson tp_slow "$tp_slow" \
    --arg tp_ts "$tp_ts" \
    --arg ts_state "$ts_state" \
    --argjson ts_ms "$ts_ms" \
    --argjson ts_code "$ts_code" \
    --arg bk_state "$bk_state" \
    --argjson bk_ms "$bk_ms" \
    --argjson bk_code "$bk_code" \
    '{ts:$ts, result:$result, fails:$fails, service:$service, port:$port,
      proxy_mode:$proxy_mode, http_code:$http_code, exit_ip:$exit_ip,
      reason:$reason, last_notify:$last_notify,
      ipv6_state:$ipv6_state, ipv6_ms:$ipv6_ms, ipv6_local:$ipv6_local,
      tp_cf_kbps:$tp_cf_kbps, tp_ref_kbps:$tp_ref_kbps, tp_state:$tp_state,
      tp_slow:$tp_slow, tp_ts:$tp_ts,
      ts_state:$ts_state, ts_ms:$ts_ms, ts_code:$ts_code,
      bk_state:$bk_state, bk_ms:$bk_ms, bk_code:$bk_code}' > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$HEALTH_FILE"
}

# ---------------------------------------------------------------------------
# 命令：check
# ---------------------------------------------------------------------------

cmd_check() {
  local quiet=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --quiet) quiet=1 ;;
      *) die "$E_USAGE" "unknown option: $1" ;;
    esac
    shift
  done

  load_conf
  need_cmd jq

  local mode active prev_result prev_fails fails result reason http_code exit_ip
  local ipv6_state=none ipv6_ms=0 ipv6_local=false
  mode=$(proxy_mode)
  if service_active; then active=active; else active=inactive; fi
  prev_result=$(health_field result); [[ -n $prev_result ]] || prev_result=none
  prev_fails=$(health_field fails); [[ $prev_fails =~ ^[0-9]+$ ]] || prev_fails=0
  fails=$prev_fails
  result=skipped
  reason=""
  http_code=0
  exit_ip=""

  if [[ $mode != manual && $active != active ]]; then
    reason="proxy off and service inactive"
    health_write skipped 0 "$active" false "$mode" 0 "" "$reason" "$(health_field last_notify)"
    (( quiet )) || say "health: skipped ($reason)"
    return 0
  fi

  local port=false
  if port_open; then port=true; fi

  if [[ $active != active ]]; then
    result=fail; reason="service inactive"; http_code=0
  elif [[ $port != true ]]; then
    result=fail; reason="port closed"; http_code=0
  elif probe_http; then
    result=ok; http_code=204; exit_ip=$(query_exit_ip)
  elif { sleep 5; probe_http; }; then
    result=ok; http_code=204; exit_ip=$(query_exit_ip)
  else
    result=fail; reason="http probe failed"; http_code=0
  fi

  # IPv6 path: the machine prefers IPv6 while the exit VPS may not route it. A hang here
  # is a real fault (the user sees apps freeze); a fast failure is the intended guard.
  if has_global_ipv6; then
    ipv6_local=true
    if [[ $result == ok ]]; then
      read -r ipv6_state ipv6_ms < <(probe_ipv6_path) || true
      case $ipv6_state in
        hang) result=fail; reason="ipv6 destination hangs (${ipv6_ms}ms); proxy cannot route IPv6"; http_code=0 ;;
        fail) result=fail; reason="ipv6 destination fails fast (${ipv6_ms}ms) with no block rule; apps may not fall back"; http_code=0 ;;
      esac
    fi
  fi

  # Per-egress probe: the tailnet path carries Telegram only. A failure here must not fail
  # the whole tunnel (AUTO_OFF would cut every other site), so it is recorded and warned
  # about separately.
  local ts_state=skip ts_ms=0 ts_code=0
  if [[ $result == ok ]] && ts_inbound_present; then
    read -r ts_state ts_ms ts_code < <(probe_ts_with_retry) || true
  fi

  # Backup egress (design.md §6.11): probed through its own inbound whenever the service
  # is up, in BOTH modes — in primary mode it tells us whether a fallback target exists,
  # in backup mode it IS the serving path and becomes the verdict.
  local primary_result=$result fmode bk_state=skip bk_ms=0 bk_code=0
  fmode=$(failover_mode)
  if [[ $active == active && $port == true ]] && bk_inbound_present; then
    read -r bk_state bk_ms bk_code < <(probe_bk_with_retry) || true
  fi
  if [[ $fmode == backup && $active == active && $port == true ]]; then
    if [[ $bk_state == ok ]]; then
      result=ok; http_code=$bk_code; reason="serving via backup"; exit_ip=$(query_exit_ip_bk)
    else
      result=fail; reason="backup probe failed"; http_code=0
    fi
  fi

  # Throughput sample (every TP_INTERVAL_S only, to keep the probe cheap)
  local tp_cf=0 tp_ref=0 tp_state=none tp_slow=0 tp_ts="" tp_prev_ts tp_prev_slow now
  tp_prev_ts=$(health_field tp_ts)
  tp_prev_slow=$(health_field tp_slow); [[ $tp_prev_slow =~ ^[0-9]+$ ]] || tp_prev_slow=0
  tp_cf=$(health_field tp_cf_kbps); [[ $tp_cf =~ ^[0-9]+$ ]] || tp_cf=0
  tp_ref=$(health_field tp_ref_kbps); [[ $tp_ref =~ ^[0-9]+$ ]] || tp_ref=0
  tp_state=$(health_field tp_state); [[ -n $tp_state ]] || tp_state=none
  tp_ts=$tp_prev_ts
  tp_slow=$tp_prev_slow
  now=$(date +%s)
  if [[ $result == ok ]] && { [[ -z $tp_prev_ts ]] || (( now - $(date -d "$tp_prev_ts" +%s 2>/dev/null || echo 0) >= TP_INTERVAL_S )); }; then
    tp_cf=$(probe_kbps "$TP_CF_URL")
    tp_ref=$(probe_kbps "$TP_REF_URL")
    tp_ts=$(now_iso)
    if (( tp_cf >= TP_MIN_KBPS && tp_ref >= TP_MIN_KBPS )); then
      tp_state=ok; tp_slow=0
    else
      tp_state=slow; tp_slow=$((tp_prev_slow + 1))
      if [[ ${TP_NOTIFY:-0} == 1 ]] && (( tp_slow >= 2 )) && [[ $tp_prev_slow -lt 2 ]]; then
        notify_user "VPN 速度异常" "CF ${tp_cf} KB/s / 参照 ${tp_ref} KB/s（阈值 ${TP_MIN_KBPS}）"
      fi
    fi
  fi

  local last_notify notify_ts
  last_notify=$(health_field last_notify)
  notify_ts=$last_notify

  if [[ $result == ok ]]; then
    fails=0
    if [[ $prev_result == fail && ${NOTIFY:-1} == 1 ]]; then
      notify_user "VPN 隧道已恢复" "出口 ${exit_ip:-unknown}；vpnctl status 查看详情"
      notify_ts=$(now_iso)
    fi
  else
    fails=$((prev_fails + 1))
    if [[ $prev_result != fail && ${NOTIFY:-1} == 1 ]]; then
      notify_user "VPN 隧道异常" "${reason}；运行 vpnctl status 查看，vpnctl off 恢复直连"
      notify_ts=$(now_iso)
    fi
  fi

  # Failover decision (design.md §6.11): with AUTO_FAILOVER=1, two consecutive failed
  # rounds on the primary plus a green backup probe trigger an automatic switch; once the
  # primary answers again (it is probed every round, even in backup mode) the switch is
  # reverted. With a standby to switch to, AUTO_OFF is meaningless and stays inert.
  if [[ ${AUTO_FAILOVER:-0} == 1 ]]; then
    if [[ $fmode == primary && $result == fail && $fails -ge 2 && $bk_state == ok ]]; then
      if use_failover backup >/dev/null 2>&1; then
        reason="primary dead (${fails} rounds); auto-failover to backup"
        result=ok; http_code=204; fails=0
        exit_ip=$(query_exit_ip_bk)
        notify_user "VPN 已切换到机场备用" "主出口连续失败；恢复后自动切回。vpnctl use primary 可手动切回"
      else
        reason="$reason; auto-failover to backup FAILED"
        notify_user "VPN 备用切换失败" "自动切换到备用出口未成功；vpnctl status 查看"
      fi
      notify_ts=$(now_iso)
      fmode=$(failover_mode)
    elif [[ $fmode == backup && $primary_result == ok ]]; then
      if use_failover primary >/dev/null 2>&1; then
        reason="primary recovered; auto-failback to primary"
        exit_ip=$(query_exit_ip)
        notify_user "VPN 已切回自建出口" "主出口恢复，机场备用退回待命"
      else
        notify_user "VPN 回切失败" "主出口已恢复但切回失败；请手动 vpnctl use primary"
      fi
      notify_ts=$(now_iso)
      fmode=$(failover_mode)
    fi
  elif [[ $result == fail && $fails -ge 2 && ${AUTO_OFF:-0} == 1 ]]; then
    set_proxy_off || true
    systemctl --user stop "$SERVICE" >/dev/null 2>&1 || true
    reason="$reason; auto-off"
    notify_user "VPN 已切回直连" "连续 ${fails} 轮探测失败，系统代理已关闭"
    notify_ts=$(now_iso)
  fi

  health_write "$result" "$fails" "$active" "$port" "${mode:-unknown}" "$http_code" "$exit_ip" "$reason" "$notify_ts" "$ipv6_state" "$ipv6_ms" "$ipv6_local" \
    "$tp_cf" "$tp_ref" "$tp_state" "$tp_slow" "$tp_ts" "$ts_state" "$ts_ms" "$ts_code" \
    "$bk_state" "$bk_ms" "$bk_code"

  if (( quiet )); then
    return 0
  fi
  if [[ $result == ok ]]; then
    say "health: ok (http $http_code, exit ${exit_ip:-unknown}, ipv6 $ipv6_state, fails 0)"
    return 0
  fi
  say "health: fail ($reason, fails $fails)"
  return "$E_HEALTH"
}

# ---------------------------------------------------------------------------
# 命令：status
# ---------------------------------------------------------------------------

cmd_status() {
  local active mode pid health config_info xray_ver geo_info v2ray_state warnings=()
  if service_active; then active="active"; else active=$(systemctl --user is-active "$SERVICE" 2>/dev/null || true); fi
  [[ -n $active ]] || active=unknown
  mode=$(proxy_mode); [[ -n $mode ]] || mode=unknown
  pid=$(listener_pid)
  health=$(health_field result); [[ -n $health ]] || health=none

  config_info="not installed"
  if [[ -f $CONFIG_FILE ]]; then
    config_info="$CONFIG_FILE $(stat -c '%a' "$CONFIG_FILE") sha256:$(sha_of "$CONFIG_FILE" | cut -c1-8) $(stat -c '%y' "$CONFIG_FILE" | cut -c1-16)"
  fi

  xray_ver="not installed"
  if [[ -x $XRAY_BIN ]]; then
    xray_ver=$(version_of "$XRAY_BIN"); [[ -n $xray_ver ]] || xray_ver=unknown
  fi

  geo_info="missing"
  if [[ -f $ASSET_DIR/geoip.dat && -f $ASSET_DIR/geosite.dat ]]; then
    geo_info="geoip.dat $(stat -L -c '%y' "$ASSET_DIR/geoip.dat" | cut -c1-10) sha256:$(sha_of "$ASSET_DIR/geoip.dat" | cut -c1-8) / geosite.dat $(stat -L -c '%y' "$ASSET_DIR/geosite.dat" | cut -c1-10) sha256:$(sha_of "$ASSET_DIR/geosite.dat" | cut -c1-8)"
    local age_geo age_site age
    age_geo=$(file_age_days "$ASSET_DIR/geoip.dat")
    age_site=$(file_age_days "$ASSET_DIR/geosite.dat")
    age=$(( age_geo > age_site ? age_geo : age_site ))
    if (( age > 90 )); then
      warnings+=("geo assets are ${age} days old (> 90)")
    fi
  fi

  v2ray_state="not running"
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f '/opt/v2rayN/v2rayN' >/dev/null 2>&1 && v2ray_state="running (quit v2rayN, or run vpnctl off before using it)"
  else
    v2ray_state=unknown
  fi

  local ipv6_state ipv6_ms tp_cf tp_ref tp_state tp_slow ts_state ts_ms ts_code
  local bk_state bk_ms bk_code fmode
  ipv6_state=$(health_field ipv6_state); [[ -n $ipv6_state ]] || ipv6_state=unknown
  ipv6_ms=$(health_field ipv6_ms); [[ $ipv6_ms =~ ^[0-9]+$ ]] || ipv6_ms=0
  tp_cf=$(health_field tp_cf_kbps); [[ $tp_cf =~ ^[0-9]+$ ]] || tp_cf=0
  tp_ref=$(health_field tp_ref_kbps); [[ $tp_ref =~ ^[0-9]+$ ]] || tp_ref=0
  tp_state=$(health_field tp_state); [[ -n $tp_state ]] || tp_state=unknown
  tp_slow=$(health_field tp_slow); [[ $tp_slow =~ ^[0-9]+$ ]] || tp_slow=0
  ts_state=$(health_field ts_state); [[ -n $ts_state ]] || ts_state=unknown
  ts_ms=$(health_field ts_ms); [[ $ts_ms =~ ^[0-9]+$ ]] || ts_ms=0
  ts_code=$(health_field ts_code); [[ $ts_code =~ ^[0-9]+$ ]] || ts_code=0
  bk_state=$(health_field bk_state); [[ -n $bk_state ]] || bk_state=unknown
  bk_ms=$(health_field bk_ms); [[ $bk_ms =~ ^[0-9]+$ ]] || bk_ms=0
  bk_code=$(health_field bk_code); [[ $bk_code =~ ^[0-9]+$ ]] || bk_code=0
  fmode=$(failover_mode)
  if (( tp_slow >= 2 )); then
    warnings+=("throughput below ${TP_MIN_KBPS} KB/s for ${tp_slow} consecutive samples (CF ${tp_cf}, ref ${tp_ref}): check the WARP egress or the VPS route")
  fi
  if [[ $ts_state == fail ]]; then
    warnings+=("tailnet egress probe failed (http $ts_code, ${ts_ms}ms): Telegram traffic via proxy-ts is down; check tailscale status")
  fi
  if [[ $fmode == backup ]]; then
    warnings+=("running on the AIRPORT BACKUP (default route -> proxy-backup); run 'vpnctl use primary' once the VPS recovers")
  elif [[ $health == fail && $bk_state == ok ]]; then
    warnings+=("primary is down but the backup is available: vpnctl use backup")
  fi
  if [[ $ipv6_state == hang || $ipv6_state == fail ]]; then
    warnings+=("IPv6 probe $ipv6_state (${ipv6_ms}ms): apps that prefer IPv6 will freeze or fall back slowly; restore the block rule or give the exit node IPv6")
  fi
  if [[ $mode == manual ]] && ! port_open; then
    warnings+=("system proxy is manual but $PROXY_HOST:$PORT is not listening; run: vpnctl off")
  fi
  if [[ $active == active && $v2ray_state == running* ]]; then
    warnings+=("v2rayN is running while $SERVICE is active; both may fight for port $PORT")
  fi
  if [[ -f $CONFIG_FILE ]]; then
    local perm
    perm=$(stat -c '%a' "$CONFIG_FILE")
    [[ $perm == 600 ]] || warnings+=("config permissions are $perm, expected 600")
  fi

  say "service : $active"
  if port_open; then
    say "port    : $PROXY_HOST:$PORT listening${pid:+ (pid $pid)}"
  else
    say "port    : $PROXY_HOST:$PORT not listening"
  fi
  say "proxy   : $mode${mode:+ }-> $PROXY_HOST:$PORT"
  if [[ -f $HEALTH_FILE ]]; then
    say "health  : $(jq -r '"\(.result) (\(.reason // "ok")), \(.http_code), exit \(.exit_ip // "-")"' "$HEALTH_FILE" 2>/dev/null) at $(health_field ts)"
  else
    say "health  : no data"
  fi
  say "ipv6    : $ipv6_state (${ipv6_ms} ms)"
  if ipv6_block_rule_present; then
    say "guard   : IPv6 → block for proxied destinations (exit has no IPv6)"
  else
    say "guard   : absent — IPv6 literals can hang on the proxy path; add the ::/0 block rule"
  fi
  if probe_inbound_present; then
    say "probe   : pinned to proxy via 127.0.0.1:$PROBE_PORT"
  else
    say "probe   : via 127.0.0.1:$PORT (not pinned — the probe may follow a rule to direct)"
  fi
  say "egress  : telegram via proxy-ts: $ts_state (http $ts_code, ${ts_ms} ms)"
  say "failover: $fmode (default route -> $(jq -r '.outbounds[0].tag // "?"' "$CONFIG_FILE" 2>/dev/null || echo '?'))"
  if bk_inbound_present; then
    say "backup  : airport via proxy-backup: $bk_state (http $bk_code, ${bk_ms} ms)"
  else
    say "backup  : not configured"
  fi
  say "speed   : cf ${tp_cf} KB/s · ref ${tp_ref} KB/s (${tp_state}, min ${TP_MIN_KBPS})"
  say "config  : $config_info"
  say "xray    : $xray_ver"
  say "geo     : $geo_info"
  say "v2rayN  : $v2ray_state"
  if (( ${#warnings[@]} )); then
    local w
    for w in "${warnings[@]}"; do warn "$w"; done
  else
    say "warn    : none"
  fi
}

# ---------------------------------------------------------------------------
# 命令：on / off / restart / ip
# ---------------------------------------------------------------------------

cmd_on() {
  need_cmd gsettings
  need_cmd systemctl
  load_conf
  [[ -f $CONFIG_FILE ]] || die "$E_PREFLIGHT" "config not installed: $CONFIG_FILE"
  [[ -x $XRAY_BIN ]] || die "$E_PREFLIGHT" "xray not installed: $XRAY_BIN"

  if port_open && ! service_active; then
    local pid
    pid=$(listener_pid)
    die "$E_PREFLIGHT" "port $PORT is already in use${pid:+ by pid $pid}; quit v2rayN first"
  fi

  local prev
  prev=$(proxy_mode)
  systemctl --user reset-failed "$SERVICE" >/dev/null 2>&1 || true
  if ! systemctl --user start "$SERVICE"; then
    restore_mode "$prev"
    die "$E_SERVICE" "failed to start $SERVICE"
  fi
  if ! wait_port; then
    restore_mode "$prev"
    die "$E_SERVICE" "$SERVICE started but $PROXY_HOST:$PORT is not listening"
  fi
  if ! probe_with_retry; then
    restore_mode "$prev"
    die "$E_HEALTH" "tunnel probe failed; system proxy restored to '${prev:-unknown}'"
  fi
  if ! set_proxy_manual; then
    restore_mode "$prev"
    die "$E_PREFLIGHT" "failed to write GNOME proxy settings"
  fi
  systemctl --user start "$HEALTH_SERVICE.timer" >/dev/null 2>&1 || warn "could not start $HEALTH_SERVICE.timer"
  say "proxy on: $PROXY_HOST:$PORT (mode manual)"
}

cmd_off() {
  if ! set_proxy_off; then
    warn "failed to set GNOME proxy mode to none (continuing)"
  fi
  systemctl --user stop "$SERVICE" >/dev/null 2>&1 || true
  say "proxy off; $SERVICE stopped"
}

restart_and_probe() {
  systemctl --user restart "$SERVICE" || return "$E_SERVICE"
  wait_port || return "$E_SERVICE"
  probe_with_retry || return "$E_HEALTH"
  return 0
}

cmd_restart() {
  load_conf
  validate_cfg "$CONFIG_FILE" "$ASSET_DIR" "$XRAY_BIN"
  local rc=0
  restart_and_probe || rc=$?
  if (( rc != 0 )); then
    die "$rc" "restart or health probe failed; run vpnctl logs"
  fi
  say "restarted; tunnel ok"
}

cmd_ip() {
  load_conf
  probe_http || die "$E_HEALTH" "proxy is not reachable; run vpnctl status"
  local ip
  ip=$(query_exit_ip)
  [[ -n $ip ]] || die "$E_HEALTH" "could not query exit IP"
  say "$ip"
}

# ---------------------------------------------------------------------------
# 命令：edit / rollback
# ---------------------------------------------------------------------------

backup_config() {
  install -d -m 700 "$BACKUP_DIR"
  local dest="$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).json"
  cp -p "$CONFIG_FILE" "$dest"
  chmod 600 "$dest"
  ls -1t "$BACKUP_DIR"/config-*.json 2>/dev/null | tail -n +11 | xargs -r rm -f
}

cmd_edit() {
  load_conf
  [[ -f $CONFIG_FILE ]] || die "$E_PREFLIGHT" "config not installed: $CONFIG_FILE"
  need_cmd jq
  local editor=${EDITOR:-vi}
  command -v "$editor" >/dev/null 2>&1 || die "$E_PREFLIGHT" "editor not found: $editor"
  local tmpdir tmp
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/vpn-config.XXXXXX")
  tmp="$tmpdir/config.json"
  cp "$CONFIG_FILE" "$tmp"
  chmod 600 "$tmp"

  "$editor" "$tmp" || { rm -rf "$tmpdir"; die "$E_USAGE" "editor exited non-zero"; }

  if cmp -s "$CONFIG_FILE" "$tmp"; then
    rm -rf "$tmpdir"
    say "config unchanged"
    return 0
  fi

  if ! ( validate_cfg "$tmp" "$ASSET_DIR" "$XRAY_BIN" ); then
    rm -rf "$tmpdir"
    exit "$E_VALIDATE"
  fi
  backup_config
  local backup
  backup=$(ls -1t "$BACKUP_DIR"/config-*.json | head -n 1)
  install -m 600 "$tmp" "$CONFIG_FILE"
  rm -rf "$tmpdir"

  if restart_and_probe; then
    say "config applied; tunnel ok"
    return 0
  fi

  warn "new config failed health check; rolling back"
  install -m 600 "$backup" "$CONFIG_FILE"
  if restart_and_probe; then
    notify_user "VPN 配置已回滚" "新配置未通过健康检查，已恢复上一份并重启成功"
    die "$E_HEALTH" "new config failed; rolled back to $(basename "$backup")"
  fi
  notify_user "VPN 配置回滚后仍失败" "需要人工处理：vpnctl logs"
  die "$E_HEALTH" "rollback also failed; run vpnctl logs"
}

cmd_rollback() {
  load_conf
  local backup
  backup=$(ls -1t "$BACKUP_DIR"/config-*.json 2>/dev/null | head -n 1 || true)
  [[ -n $backup ]] || die "$E_PREFLIGHT" "no config backups in $BACKUP_DIR"
  validate_cfg "$backup" "$ASSET_DIR" "$XRAY_BIN"
  install -m 600 "$backup" "$CONFIG_FILE"
  if ! restart_and_probe; then
    die "$E_HEALTH" "rollback to $(basename "$backup") failed health check"
  fi
  say "rolled back to $(basename "$backup")"
}

# ---------------------------------------------------------------------------
# 命令：use backup|primary（主备切换，design.md §6.11）
# ---------------------------------------------------------------------------

# Move the requested egress to the front of outbounds (xray's default route is the first
# outbound), then validate → backup → install → restart → probe the TARGET egress; any
# failure restores the previous config. Shared by `vpnctl use` and the AUTO_FAILOVER path.
use_failover() {
  local target=$1 tag
  case $target in
    backup)  tag=proxy-backup ;;
    primary) tag=proxy ;;
    *) warn "use: unknown target '$target' (want backup|primary)"; return "$E_USAGE" ;;
  esac
  [[ $(failover_mode) == "$target" ]] && return 0
  jq -e --arg t "$tag" 'any(.outbounds[]?; .tag == $t)' "$CONFIG_FILE" >/dev/null 2>&1 || {
    warn "use $target: outbound '$tag' is not in the config"; return "$E_PREFLIGHT"; }
  if [[ $target == backup ]] && ! bk_inbound_present; then
    warn "use backup: bk-in inbound is not in the config"; return "$E_PREFLIGHT"
  fi

  local tmpdir tmp
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/vpn-use.XXXXXX")
  tmp="$tmpdir/config.json"
  if ! jq --arg t "$tag" '.outbounds |= ([.[] | select(.tag == $t)] + [.[] | select(.tag != $t)])' \
        "$CONFIG_FILE" > "$tmp"; then
    rm -rf "$tmpdir"; warn "use $target: jq rewrite failed"; return "$E_VALIDATE"
  fi
  chmod 600 "$tmp"
  if ! validate_cfg "$tmp" "$ASSET_DIR" "$XRAY_BIN" >/dev/null 2>&1; then
    rm -rf "$tmpdir"; warn "use $target: candidate failed validation"; return "$E_VALIDATE"
  fi
  backup_config
  local backup
  backup=$(ls -1t "$BACKUP_DIR"/config-*.json | head -n 1)
  install -m 600 "$tmp" "$CONFIG_FILE"
  rm -rf "$tmpdir"

  if service_active; then
    if ! { systemctl --user restart "$SERVICE" && wait_port; }; then
      warn "use $target: restart failed; restoring previous mode"
      install -m 600 "$backup" "$CONFIG_FILE"
      systemctl --user restart "$SERVICE" >/dev/null 2>&1 || true
      return "$E_SERVICE"
    fi
    local probe_ok=1 i
    for i in 1 2; do
      if [[ $target == backup ]]; then
        [[ $(probe_bk) == ok\ * ]] && { probe_ok=0; break; }
      else
        probe_http && { probe_ok=0; break; }
      fi
      sleep 5
    done
    if (( probe_ok != 0 )); then
      warn "use $target: probe failed; rolling back to previous mode"
      install -m 600 "$backup" "$CONFIG_FILE"
      systemctl --user restart "$SERVICE" >/dev/null 2>&1 || true
      wait_port || true
      return "$E_HEALTH"
    fi
  else
    warn "service is inactive; mode switch takes effect on the next start"
  fi
  return 0
}

cmd_use() {
  local target=${1:-}
  [[ -n $target ]] || die "$E_USAGE" "usage: vpnctl use backup|primary"
  load_conf
  need_cmd jq
  [[ -f $CONFIG_FILE ]] || die "$E_PREFLIGHT" "config not installed: $CONFIG_FILE"
  local rc=0
  use_failover "$target" || rc=$?
  (( rc == 0 )) || die "$rc" "use $target failed; previous mode kept"
  say "mode: $(failover_mode) (default route -> $(jq -r '.outbounds[0].tag // "?"' "$CONFIG_FILE"))"
}

# ---------------------------------------------------------------------------
# 命令：install
# ---------------------------------------------------------------------------

INSTALL_DONE=0
STAGE=""
CONFIG_BACKUP=""
ASSETS_BACKUP=""
OLD_CURRENT=""

cleanup_install() {
  local rc=$?
  if (( rc != 0 && INSTALL_DONE == 0 )); then
    if [[ -n $CONFIG_BACKUP && -f $CONFIG_BACKUP ]]; then
      cp -p "$CONFIG_BACKUP" "$CONFIG_FILE" 2>/dev/null || true
    fi
    if [[ -n $ASSETS_BACKUP && -d $ASSETS_BACKUP ]]; then
      cp -p "$ASSETS_BACKUP"/geoip.dat "$ASSET_DIR/geoip.dat" 2>/dev/null || true
      cp -p "$ASSETS_BACKUP"/geosite.dat "$ASSET_DIR/geosite.dat" 2>/dev/null || true
    fi
    if [[ -n $OLD_CURRENT ]]; then
      ln -sfn "$OLD_CURRENT" "$XRAY_LIB/current" 2>/dev/null || true
    fi
    warn "install failed; restored previous files (service not started)"
  fi
  [[ -n $STAGE && -d $STAGE ]] && rm -rf "$STAGE" || true
  return 0
}

cmd_install() {
  local dry=0
  local xray_src=""
  local xray_sha=""
  local xray_source=""
  local cfg_src="$H/.local/share/v2rayN/binConfigs/config.json"
  local assets_src="$H/.local/share/v2rayN/bin"
  local disable_autostart=0

  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run) dry=1 ;;
      --xray) xray_src=${2:-}; shift ;;
      --xray-sha256) xray_sha=${2:-}; shift ;;
      --xray-source) xray_source=${2:-}; shift ;;
      --from-config) cfg_src=${2:-}; shift ;;
      --from-assets) assets_src=${2:-}; shift ;;
      --disable-v2rayn-autostart) disable_autostart=1 ;;
      *) die "$E_USAGE" "unknown option: $1" ;;
    esac
    shift
  done

  need_cmd jq
  need_cmd curl
  need_cmd ss
  need_cmd systemctl
  need_cmd gsettings
  need_cmd sha256sum
  need_cmd install

  local avail
  avail=$(df -Pm "$H" 2>/dev/null | awk 'NR == 2 { print $4 }')
  if [[ $avail =~ ^[0-9]+$ ]] && (( avail < 100 )); then
    die "$E_PREFLIGHT" "less than 100 MB free on $H"
  fi
  if command -v loginctl >/dev/null 2>&1; then
    local linger
    linger=$(loginctl show-user "${USER:-$(id -un)}" --property=Linger 2>/dev/null || true)
    [[ $linger == Linger=yes ]] || warn "Linger is not enabled; the service will not start until you log in"
  fi

  [[ -f $cfg_src ]] || die "$E_PREFLIGHT" "config source not found: $cfg_src"
  assets_ok "$assets_src" || die "$E_PREFLIGHT" "geo assets not found or too small in $assets_src (need geoip.dat and geosite.dat > 1 MB)"

  if (( ! dry )) && [[ -z $xray_src ]]; then
    die "$E_VALIDATE" "missing --xray; download an official Xray release and pass its path"
  fi
  if (( ! dry )) && [[ -z $xray_sha ]]; then
    die "$E_VALIDATE" "missing --xray-sha256; compute sha256sum on the official binary first"
  fi
  if (( dry )) && [[ -z $xray_src ]]; then
    xray_src="<official xray binary>"
  fi

  if (( ! dry )); then
    [[ -x $xray_src ]] || die "$E_PREFLIGHT" "xray binary not executable: $xray_src"
    xray_sha=${xray_sha,,}
    [[ $xray_sha =~ ^[0-9a-f]{64}$ ]] || die "$E_VALIDATE" "--xray-sha256 must be 64 hex characters (got ${#xray_sha})"
    local actual
    actual=$(sha_of "$xray_src")
    [[ $actual == "$xray_sha" ]] || die "$E_VALIDATE" "sha256 mismatch: expected $xray_sha, got $actual"
  fi

  local ver="unknown"
  if (( dry )); then
    if [[ -x $xray_src ]]; then ver=$(version_of "$xray_src"); fi
  else
    ver=$(version_of "$xray_src")
    [[ -n $ver ]] || die "$E_VALIDATE" "could not parse xray version from $xray_src"
    if [[ ${ver,,} =~ (pre|rc|beta|alpha|nightly) ]]; then
      die "$E_VALIDATE" "refusing pre-release build: $ver"
    fi
  fi

  for f in xray-client.service vpn-health.service vpn-health.timer; do
    [[ -f $SCRIPT_DIR/$f ]] || die "$E_PREFLIGHT" "missing unit template: $SCRIPT_DIR/$f (run install from the repository directory)"
  done

  if command -v pgrep >/dev/null 2>&1 && pgrep -f '/opt/v2rayN/v2rayN' >/dev/null 2>&1; then
    warn "v2rayN appears to be running; quit it before starting the service"
  fi
  if port_open; then
    warn "port $PORT is currently in use; the service will not start until v2rayN is closed"
  fi

  if (( dry )); then
    if [[ -x $xray_src && -f $cfg_src ]]; then
      local tmpdir tmpcfg
      tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/vpn-install-check.XXXXXX")
      tmpcfg="$tmpdir/config.json"
      jq '.inbounds |= map(if .protocol == "mixed" then .listen = "127.0.0.1" else . end)' "$cfg_src" > "$tmpcfg"
      if ! ( validate_cfg "$tmpcfg" "$assets_src" "$xray_src" ); then
        rm -rf "$tmpdir"
        die "$E_VALIDATE" "dry-run validation failed; nothing installed"
      fi
      rm -rf "$tmpdir"
    fi
    say "dry-run plan:"
    say "  xray     : $xray_src ($ver)"
    [[ -n $xray_sha ]] && say "  sha256   : ${xray_sha,,}"
    say "  config   : $cfg_src -> $CONFIG_FILE (listen 127.0.0.1)"
    say "  assets   : $assets_src -> $ASSET_DIR"
    say "  units    : $UNIT_DIR/$SERVICE.service, $HEALTH_SERVICE.service, $HEALTH_SERVICE.timer"
    say "  enable   : $SERVICE.service $HEALTH_SERVICE.timer (not started)"
    if (( disable_autostart )); then
      say "  autostart: rename $AUTOSTART -> $AUTOSTART.disabled"
    else
      say "  autostart: unchanged"
    fi
    [[ -n $xray_source ]] && say "  source   : $xray_source"
    say "dry-run: no changes; rerun without --dry-run to install"
    return 0
  fi

  STAGE="$STATE_DIR/staging"
  rm -rf "$STAGE"
  install -d -m 700 "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR" "$UPGRADE_EVIDENCE" "$STAGE" "$STAGE/assets"
  install -d -m 755 "$ASSET_DIR" "$XRAY_LIB" "$(dirname "$XRAY_BIN")" "$(dirname "$VPNCTL_BIN")" "$UNIT_DIR"

  trap cleanup_install EXIT

  install -m 755 "$xray_src" "$STAGE/xray"
  install -p -m 644 "$assets_src/geoip.dat" "$STAGE/assets/geoip.dat"
  install -p -m 644 "$assets_src/geosite.dat" "$STAGE/assets/geosite.dat"

  jq '.inbounds |= map(if .protocol == "mixed" then .listen = "127.0.0.1" else . end)' \
    "$cfg_src" > "$STAGE/config.json"
  chmod 600 "$STAGE/config.json"

  validate_cfg "$STAGE/config.json" "$STAGE/assets" "$STAGE/xray"

  install -d -m 755 "$XRAY_LIB/$ver"
  install -m 755 "$STAGE/xray" "$XRAY_LIB/$ver/xray"
  if [[ -L $XRAY_LIB/current ]]; then
    OLD_CURRENT=$(readlink -f "$XRAY_LIB/current" || true)
  fi
  if [[ -f $CONFIG_FILE ]]; then
    CONFIG_BACKUP="$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).json"
    cp -p "$CONFIG_FILE" "$CONFIG_BACKUP"
  fi
  if [[ -f $ASSET_DIR/geoip.dat ]]; then
    ASSETS_BACKUP="$BACKUP_DIR/assets-$(date +%Y%m%d-%H%M%S)"
    install -d -m 700 "$ASSETS_BACKUP"
    cp -p "$ASSET_DIR/geoip.dat" "$ASSET_DIR/geosite.dat" "$ASSETS_BACKUP"/
  fi

  ln -sfn "$XRAY_LIB/$ver" "$XRAY_LIB/current"
  ln -sfn "$XRAY_LIB/current/xray" "$XRAY_BIN"
  install -m 600 "$STAGE/config.json" "$CONFIG_FILE"
  install -p -m 644 "$STAGE/assets/geoip.dat" "$STAGE/assets/geosite.dat" "$ASSET_DIR"/
  install -m 755 "$SCRIPT_DIR/vpnctl.sh" "$VPNCTL_BIN"
  if [[ -f $SCRIPT_DIR/geo-manifest.py ]]; then
    install -m 755 "$SCRIPT_DIR/geo-manifest.py" "$GEO_MANIFEST_BIN"
  fi
  geo_manifest_build "$ASSET_DIR" || warn "geo code manifest unavailable; unknown geosite/geoip codes will only be reported by xray"
  install -m 644 "$SCRIPT_DIR/xray-client.service" "$SCRIPT_DIR/$HEALTH_SERVICE.service" "$SCRIPT_DIR/$HEALTH_SERVICE.timer" "$UNIT_DIR"/

  {
    say "# Xray baseline evidence"
    say "- version: $ver"
    say "- sha256: ${xray_sha,,}"
    say "- source: ${xray_source:-official release (path: $xray_src)}"
    say "- geoip_sha256: $(sha_of "$assets_src/geoip.dat")"
    say "- geosite_sha256: $(sha_of "$assets_src/geosite.dat")"
    say "- recorded_at: $(now_iso)"
  } > "$UPGRADE_EVIDENCE/baseline-$ver.md"
  chmod 600 "$UPGRADE_EVIDENCE/baseline-$ver.md"

  systemctl --user daemon-reload
  systemctl --user enable "$SERVICE.service" "$HEALTH_SERVICE.timer"

  if (( disable_autostart )); then
    if [[ -f $AUTOSTART ]]; then
      mv "$AUTOSTART" "$AUTOSTART.disabled"
      say "$AUTOSTART" > "$AUTOSTART_MARKER"
      chmod 600 "$AUTOSTART_MARKER"
      say "autostart disabled: $AUTOSTART.disabled"
    else
      warn "autostart file not found: $AUTOSTART"
    fi
  fi

  INSTALL_DONE=1
  say "installed xray $ver; units enabled (service not started)"
  say "next: quit v2rayN, then run: vpnctl on"
}

# ---------------------------------------------------------------------------
# 命令：upgrade
# ---------------------------------------------------------------------------

version_lt() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1) == "$1" ]]
}

cmd_upgrade() {
  local path="" sha="" released="" source="" security=0 reason="" allow_downgrade=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --sha256) sha=${2:-}; shift ;;
      --released) released=${2:-}; shift ;;
      --source) source=${2:-}; shift ;;
      --security-fix) security=1 ;;
      --reason) reason=${2:-}; shift ;;
      --allow-downgrade) allow_downgrade=1 ;;
      -*) die "$E_USAGE" "unknown option: $1" ;;
      *) path=$1 ;;
    esac
    shift
  done

  load_conf
  [[ -n $path ]] || die "$E_USAGE" "usage: vpnctl upgrade <path> --sha256 H --released YYYY-MM-DD --source URL"
  [[ -f $path ]] || die "$E_PREFLIGHT" "file not found: $path"
  [[ -f $CONFIG_FILE ]] || die "$E_PREFLIGHT" "config not installed; run vpnctl install first"
  [[ -x $XRAY_BIN ]] || die "$E_PREFLIGHT" "xray not installed; run vpnctl install first"
  [[ -n $sha ]] || die "$E_VALIDATE" "missing --sha256"
  [[ -n $released ]] || die "$E_VALIDATE" "missing --released"
  [[ -n $source ]] || die "$E_VALIDATE" "missing --source"

  sha=${sha,,}
  [[ $sha =~ ^[0-9a-f]{64}$ ]] || die "$E_VALIDATE" "--sha256 must be 64 hex characters (got ${#sha})"
  local actual
  actual=$(sha_of "$path")
  [[ $actual == "$sha" ]] || die "$E_VALIDATE" "sha256 mismatch: expected $sha, got $actual"

  local ver
  ver=$(version_of "$path")
  [[ -n $ver ]] || die "$E_VALIDATE" "could not parse version from $path"
  if [[ ${ver,,} =~ (pre|rc|beta|alpha|nightly) ]]; then
    die "$E_VALIDATE" "refusing pre-release build: $ver"
  fi

  local rel_epoch now age
  rel_epoch=$(date -d "$released" +%s 2>/dev/null) || die "$E_VALIDATE" "invalid --released date: $released"
  now=$(date +%s)
  (( rel_epoch <= now )) || die "$E_VALIDATE" "--released is in the future: $released"
  age=$(( (now - rel_epoch) / 86400 ))
  if (( age < UPGRADE_MIN_AGE_DAYS )); then
    if (( security == 1 )) && [[ -n $reason ]]; then
      warn "security exception: version is only ${age} days old (min $UPGRADE_MIN_AGE_DAYS)"
    else
      die "$E_VALIDATE" "refusing too-new version: ${age} days old (minimum $UPGRADE_MIN_AGE_DAYS); use --security-fix --reason for a real fix"
    fi
  fi

  local current=""
  if [[ -x $XRAY_BIN ]]; then current=$(version_of "$XRAY_BIN"); fi
  if [[ -n $current ]] && version_lt "$ver" "$current" && (( allow_downgrade == 0 )); then
    die "$E_VALIDATE" "refusing downgrade $current -> $ver; use --allow-downgrade only for a reviewed rollback"
  fi
  if [[ -n $current && $ver == "$current" ]]; then
    die "$E_VALIDATE" "already running $ver; nothing to upgrade"
  fi

  install -d -m 700 "$UPGRADE_EVIDENCE" "$XRAY_LIB/$ver"
  if [[ $path -ef $XRAY_LIB/$ver/xray ]]; then
    :
  else
    cp -p "$path" "$XRAY_LIB/$ver/xray"
  fi
  chmod 755 "$XRAY_LIB/$ver/xray"

  local evidence="$UPGRADE_EVIDENCE/$ver-$released.md"
  {
    say "# Xray upgrade evidence"
    say "- version: $ver"
    say "- released: $released (${age} days old)"
    say "- source: $source"
    say "- sha256: $sha"
    say "- previous: ${current:-none}"
    say "- security_fix: $security"
    say "- reason: ${reason:-none}"
    say "- recorded_at: $(now_iso)"
  } > "$evidence"
  chmod 600 "$evidence"

  if ! XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_LIB/$ver/xray" run -test -format=json -c "$CONFIG_FILE" >/dev/null 2>&1; then
    rm -rf "$XRAY_LIB/$ver"
    die "$E_VALIDATE" "new binary failed config test; nothing switched"
  fi

  local old_target="" was_active=0
  [[ -L $XRAY_LIB/current ]] && old_target=$(readlink -f "$XRAY_LIB/current" || true)
  service_active && was_active=1
  ln -sfn "$XRAY_LIB/$ver" "$XRAY_LIB/current"

  if (( was_active )); then
    if ! restart_and_probe; then
      warn "new version failed health check; switching back"
      if [[ -n $old_target ]]; then
        ln -sfn "$old_target" "$XRAY_LIB/current"
        restart_and_probe || true
      fi
      notify_user "VPN 内核升级已回滚" "$ver 未通过健康检查，已切回 ${current:-上一版本}"
      die "$E_HEALTH" "upgrade failed; rolled back to ${current:-previous}"
    fi
  else
    say "service is inactive; $ver will take effect on the next start"
  fi

  local d cur_target
  cur_target=$(readlink -f "$XRAY_LIB/current" || true)
  for d in "$XRAY_LIB"/*/; do
    d=${d%/}
    [[ ${d##*/} == current ]] && continue
    [[ -n $cur_target && $(readlink -f "$d") == "$cur_target" ]] && continue
    [[ -d $d ]] && rm -rf "$d"
  done

  say "upgraded ${current:-unknown} -> $ver; evidence: $evidence"
}

# ---------------------------------------------------------------------------
# 命令：update-geo
# ---------------------------------------------------------------------------

cmd_update_geo() {
  local from="" source=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --from) from=${2:-}; shift ;;
      --source) source=${2:-}; shift ;;
      *) die "$E_USAGE" "unknown option: $1" ;;
    esac
    shift
  done
  [[ -n $from ]] || die "$E_USAGE" "usage: vpnctl update-geo --from <dir> --source <url>"
  [[ -n $source ]] || die "$E_VALIDATE" "missing --source"
  assets_ok "$from" || die "$E_VALIDATE" "geoip.dat/geosite.dat missing or too small in $from"

  install -d -m 700 "$BACKUP_DIR" "$ASSET_DIR"
  local stamp geo_bak site_bak
  stamp=$(date +%Y%m%d-%H%M%S)
  geo_bak="$BACKUP_DIR/geoip-$stamp.dat"
  site_bak="$BACKUP_DIR/geosite-$stamp.dat"
  [[ -f $ASSET_DIR/geoip.dat ]] && cp -p "$ASSET_DIR/geoip.dat" "$geo_bak"
  [[ -f $ASSET_DIR/geosite.dat ]] && cp -p "$ASSET_DIR/geosite.dat" "$site_bak"

  install -p -m 644 "$from/geoip.dat" "$from/geosite.dat" "$ASSET_DIR"/
  geo_manifest_build "$ASSET_DIR" || warn "geo code manifest unavailable; unknown geosite/geoip codes will only be reported by xray"

  if ! XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -format=json -c "$CONFIG_FILE" >/dev/null 2>&1; then
    warn "new geo files failed xray -test; restoring previous files"
    [[ -f $geo_bak ]] && install -p -m 644 "$geo_bak" "$ASSET_DIR/geoip.dat"
    [[ -f $site_bak ]] && install -p -m 644 "$site_bak" "$ASSET_DIR/geosite.dat"
    geo_manifest_build "$ASSET_DIR" >/dev/null 2>&1 || true
    die "$E_VALIDATE" "geo update rejected by xray -test"
  fi

  load_conf
  if service_active; then
    if ! restart_and_probe; then
      warn "health check failed after geo update; restoring previous files"
      [[ -f $geo_bak ]] && install -p -m 644 "$geo_bak" "$ASSET_DIR/geoip.dat"
      [[ -f $site_bak ]] && install -p -m 644 "$site_bak" "$ASSET_DIR/geosite.dat"
      restart_and_probe || true
      die "$E_HEALTH" "geo update rolled back"
    fi
  else
    say "service is inactive; new geo files will take effect on the next start"
  fi

  jq -n \
    --arg updated_at "$(now_iso)" \
    --arg source "$source" \
    --arg geo_sha "$(sha_of "$ASSET_DIR/geoip.dat")" \
    --arg site_sha "$(sha_of "$ASSET_DIR/geosite.dat")" \
    '{updated_at:$updated_at, source:$source, geoip_sha256:$geo_sha, geosite_sha256:$site_sha}' \
    > "$ASSETS_FILE"
  chmod 600 "$ASSETS_FILE"
  say "geo updated from $source; sha256 recorded"
}

# ---------------------------------------------------------------------------
# 命令：uninstall / logs
# ---------------------------------------------------------------------------

cmd_uninstall() {
  local purge=0 yes=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --purge) purge=1 ;;
      --yes) yes=1 ;;
      *) die "$E_USAGE" "unknown option: $1" ;;
    esac
    shift
  done

  systemctl --user disable --now "$SERVICE.service" "$HEALTH_SERVICE.timer" >/dev/null 2>&1 || true

  if [[ -f $AUTOSTART_MARKER ]]; then
    local orig
    orig=$(cat "$AUTOSTART_MARKER")
    if [[ -f $orig.disabled ]]; then
      mv "$orig.disabled" "$orig"
      say "autostart restored: $orig"
    fi
    rm -f "$AUTOSTART_MARKER"
  fi

  if (( purge )); then
    if (( ! yes )); then
      local ans
      read -r -p "Remove config, assets, binaries and state? [y/N] " ans
      [[ $ans == [yY] ]] || die "$E_USAGE" "aborted"
    fi
    rm -rf "$CONFIG_DIR" "$ASSET_DIR" "$XRAY_LIB" "$STATE_DIR"
    rm -f "$VPNCTL_BIN" "$GEO_MANIFEST_BIN" "$UNIT_DIR/$SERVICE.service" "$UNIT_DIR/$HEALTH_SERVICE.service" "$UNIT_DIR/$HEALTH_SERVICE.timer"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    say "purged config, assets, binaries and state"
  else
    say "service disabled; config/assets kept"
  fi
}

# Rebuild the code manifest from the assets in use (also done by install / update-geo).
cmd_geo_manifest() {
  local assets=${1:-$ASSET_DIR}
  load_conf
  assets_ok "$assets" || die "$E_VALIDATE" "geoip.dat/geosite.dat missing or too small in $assets"
  geo_manifest_build "$assets" || die "$E_PREFLIGHT" "cannot build manifest: need python3 and geo-manifest.py"
  say "geosite: $(wc -l <"$GEO_MANIFEST_DIR/geosite.txt") codes"
  say "geoip:   $(wc -l <"$GEO_MANIFEST_DIR/geoip.txt") codes"
  say "manifest: $GEO_MANIFEST_DIR"
}

cmd_logs() {
  local follow=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      -f|--follow) follow=1 ;;
      *) die "$E_USAGE" "unknown option: $1" ;;
    esac
    shift
  done
  need_cmd journalctl
  if (( follow )); then
    journalctl --user -u "$SERVICE" -n 100 -f
  else
    journalctl --user -u "$SERVICE" -n 100 --no-pager
  fi
}

# ---------------------------------------------------------------------------
# 帮助
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
vpnctl — xray 本地配置文件代理控制

用法:
  vpnctl install [--dry-run] --xray <官方二进制> --xray-sha256 <hex>
                 [--xray-source <url>] [--from-config <config.json>]
                 [--from-assets <dir>] [--disable-v2rayn-autostart]
  vpnctl validate [config.json]
  vpnctl on | off | restart | status | ip
  vpnctl check [--quiet]
  vpnctl edit | rollback
  vpnctl use backup|primary
  vpnctl upgrade <path> --sha256 <hex> --released YYYY-MM-DD --source <url>
                 [--security-fix --reason <text>] [--allow-downgrade]
  vpnctl update-geo --from <dir> --source <url>
  vpnctl geo-manifest [<assets-dir>]
  vpnctl logs [-f]
  vpnctl uninstall [--purge] [--yes]
  vpnctl help

退出码: 0 成功 / 1 用法 / 2 校验 / 3 服务 / 4 健康 / 5 前置条件
EOF
}

main() {
  local cmd=${1:-help}
  [[ $# -gt 0 ]] && shift

  case $cmd in
    install) cmd_install "$@" ;;
    validate)
      local cfg=${1:-$CONFIG_FILE}
      validate_cfg "$cfg" "$ASSET_DIR" "$XRAY_BIN" ;;
    on) cmd_on ;;
    off) cmd_off ;;
    restart) cmd_restart ;;
    status) cmd_status ;;
    check) cmd_check "$@" ;;
    ip) cmd_ip ;;
    edit) cmd_edit ;;
    rollback) cmd_rollback ;;
    use) cmd_use "$@" ;;
    upgrade) cmd_upgrade "$@" ;;
    update-geo) cmd_update_geo "$@" ;;
    geo-manifest) cmd_geo_manifest "$@" ;;
    logs) cmd_logs "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    help|-h|--help) usage ;;
    *) usage; exit "$E_USAGE" ;;
  esac
}

main "$@"
