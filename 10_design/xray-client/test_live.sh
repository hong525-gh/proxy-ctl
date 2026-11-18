#!/usr/bin/env bash
# test_live.sh — 在真实主机上执行 T9 / T7 / T8
#
# 会做的事：
#   T9：停掉 xray-client，最多等 4 分钟，确认 health.json 变 fail（期间系统代理仍为 manual，
#       浏览器/终端可能断网）；然后重新 vpnctl on。
#   T7：用非法 JSON 跑 vpnctl edit，确认退出 2 且正式配置哈希不变。
#   T8：用“能通过 -test 但连不上”的配置跑 vpnctl edit，确认自动回滚、配置哈希不变。
#
# 安全措施：开始前备份配置；退出时若发现配置哈希变了，自动恢复备份并 vpnctl on。
# 用法：bash test_live.sh [--yes] [--only-t8]

set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VPNCTL="$REPO/vpnctl.sh"
CFG="$HOME/.config/xray/config.json"
STATE="$HOME/.local/state/vpn"
HEALTH="$STATE/health.json"
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="$STATE/backups/live-test-$TS.json"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/vpn-live.XXXXXX")
PASS=0
FAIL=0

say() { printf '%s\n' "$*"; }
warn() { printf 'test_live: %s\n' "$*" >&2; }
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }
die() { printf 'test_live: %s\n' "$*" >&2; exit 1; }

YES=0
ONLY_T8=0
for arg in "$@"; do
  case $arg in
    --yes) YES=1 ;;
    --only-t8) ONLY_T8=1 ;;
    *) die "未知参数：$arg" ;;
  esac
done

if (( YES == 0 )); then
  if (( ONLY_T8 )); then
    cat <<'EOF'
只跑 T8：用指向 127.0.0.1:1 的有效配置测试 vpnctl edit 自动回滚，约 20 秒。
结束时自动恢复配置并 vpnctl on。
EOF
  else
    cat <<'EOF'
这会：
- T9 停止 xray-client，最多等 4 分钟；期间系统代理仍是 manual，网络可能断；
- T7 用坏 JSON 测试 edit，不会重启；
- T8 用指向 127.0.0.1:1 的有效配置测试自动回滚，会短暂重启服务。
结束时自动恢复配置并 vpnctl on。
EOF
  fi
  read -r -p "继续? [y/N] " ans
  [[ $ans == [yY] ]] || exit 1
fi

[[ ${EUID:-$(id -u)} -ne 0 ]] || die "请用普通用户运行，不要用 root"
[[ -f $CFG ]] || die "找不到配置：$CFG（先完成 vpnctl install）"
command -v jq >/dev/null 2>&1 || die "缺少 jq"
command -v systemctl >/dev/null 2>&1 || die "缺少 systemctl"
systemctl --user is-active --quiet xray-client || die "服务未运行；先执行 vpnctl on"
if (( ONLY_T8 == 0 )); then
  systemctl --user is-active --quiet vpn-health.timer || die "健康定时器未运行；检查 vpn-health.timer"
fi

if [[ $(jq -r '[.outbounds[] | select(.protocol == "vless")] | length' "$CFG") != 1 ]]; then
  die "当前配置不是单条 VLESS；先切回 HK-REALITY 并重装"
fi

mkdir -p "$STATE/backups"
cp -p "$CFG" "$BACKUP"
chmod 600 "$BACKUP"
ORIG_HASH=$(sha256sum "$CFG" | awk '{print $1}')

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ -f $CFG ]]; then
    local now
    now=$(sha256sum "$CFG" | awk '{print $1}')
    if [[ $now != "$ORIG_HASH" ]]; then
      warn "配置在测试中被改动，恢复备份 $BACKUP"
      install -m 600 "$BACKUP" "$CFG" || true
    fi
  fi
  "$VPNCTL" on >/dev/null 2>&1 || warn "恢复服务失败，请手动运行 vpnctl on"
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# T9：停服务 -> 定时器在 3 分钟内把 health 标成 fail
# ---------------------------------------------------------------------------

if (( ONLY_T8 == 0 )); then

say "T9: 停止 xray-client，等待健康检查变 fail（最多 250 秒）..."
BEFORE_TS=$(jq -r '.ts // empty' "$HEALTH" 2>/dev/null || true)
systemctl --user stop xray-client

RESULT=""
for _ in $(seq 1 50); do
  sleep 5
  RESULT=$(jq -r '.result // empty' "$HEALTH" 2>/dev/null || true)
  NOW_TS=$(jq -r '.ts // empty' "$HEALTH" 2>/dev/null || true)
  if [[ $RESULT == fail && $NOW_TS != "$BEFORE_TS" ]]; then
    break
  fi
done

if [[ $RESULT == fail ]]; then
  ok "T9 health 变为 fail"
  jq -c '{ts, result, fails, reason, service}' "$HEALTH" 2>/dev/null || true
else
  bad "T9 250 秒内 health 没有变为 fail"
fi

if journalctl --user -t vpn-health --since "-10 min" --no-pager 2>/dev/null | grep -q 'VPN 隧道异常'; then
  ok "T9 journal 中有异常通知记录"
else
  warn "T9 journal 中没看到 VPN 隧道异常（桌面通知可能已弹出，但 journal 未记录）"
fi

"$VPNCTL" on >/dev/null || die "T9 后无法恢复服务"
"$VPNCTL" check >/dev/null || die "T9 后健康检查仍失败"
ok "T9 服务已恢复"

# ---------------------------------------------------------------------------
# T7：非法 JSON -> 退出 2，配置不变
# ---------------------------------------------------------------------------

say "T7: vpnctl edit 写入非法 JSON..."
cat > "$TMP/bad-editor" <<'EOF'
#!/usr/bin/env bash
printf '{ not valid json\n' > "$1"
EOF
chmod +x "$TMP/bad-editor"
BEFORE=$(sha256sum "$CFG" | awk '{print $1}')

set +e
EDITOR="$TMP/bad-editor" "$VPNCTL" edit >/dev/null 2>&1
RC=$?
set -e

AFTER=$(sha256sum "$CFG" | awk '{print $1}')
if [[ $RC -eq 2 && $BEFORE == "$AFTER" ]]; then
  ok "T7 非法配置被拒，正式配置未变"
else
  bad "T7 预期退出 2 且配置不变（实际 rc=$RC）"
fi

fi  # end of "if ONLY_T8 == 0"

# ---------------------------------------------------------------------------
# T8：有效但连不上的配置 -> 退出 4，自动回滚
# ---------------------------------------------------------------------------

say "T8: vpnctl edit 写入指向 127.0.0.1:1 的有效配置（约 20 秒）..."
cat > "$TMP/dead-editor" <<'EOF'
#!/usr/bin/env bash
jq '(.outbounds[] | select(.protocol == "vless") | .settings.vnext[0].address) = "127.0.0.1"
    | (.outbounds[] | select(.protocol == "vless") | .settings.vnext[0].port) = 1' "$1" > "$1.tmp"
mv "$1.tmp" "$1"
EOF
chmod +x "$TMP/dead-editor"
BEFORE=$(sha256sum "$CFG" | awk '{print $1}')

set +e
EDITOR="$TMP/dead-editor" "$VPNCTL" edit >/dev/null 2>&1
RC=$?
set -e

AFTER=$(sha256sum "$CFG" | awk '{print $1}')
if [[ $RC -eq 4 && $BEFORE == "$AFTER" ]]; then
  ok "T8 死节点配置已自动回滚，配置未变"
else
  bad "T8 预期退出 4 且配置不变（实际 rc=$RC）"
fi

"$VPNCTL" on >/dev/null || die "T8 后无法恢复服务"
"$VPNCTL" check >/dev/null || die "T8 后健康检查仍失败"
ok "T8 服务已恢复"

say ""
say "结果：$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
