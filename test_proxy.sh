#!/usr/bin/env bash
# test_proxy.sh — offline acceptance test for proxy.sh
#
# No network, no real GNOME: `gsettings` is mocked by a script that reads fixtures from
# $TMP/state, and the "xray port" is a throwaway python listener. Verifies the three
# behaviours DESIGN.md promises, plus the rules added on 2026-11-09 and 2026-11-19:
#   - no_proxy is built from GNOME's ignore-hosts, with only the local exceptions appended;
#   - the local exceptions include the direct-by-default OpenCode domains;
#   - a non-interactive shell is left completely untouched.

set -uo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/proxyctl-test.XXXXXX")
trap '[[ -n ${LISTENER_PID:-} ]] && kill "$LISTENER_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

# The test runs inside a shell that already exports proxy variables; clear them so the
# "nothing was set" assertions mean something.
unset http_proxy https_proxy all_proxy no_proxy
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

mkdir -p "$TMP/bin" "$TMP/state"

# --- mock gsettings -------------------------------------------------------
cat > "$TMP/bin/gsettings" <<'EOF'
#!/usr/bin/env bash
key="${3:-}"
f="$TMP_STATE/$key"
if [[ ! -f $f ]]; then echo "'none'"; exit 0; fi
echo "$(cat "$f")"
EOF
chmod +x "$TMP/bin/gsettings"
export TMP_STATE="$TMP/state"

set_state() {   # set_state mode host port ignore-hosts
  printf "'%s'\n" "$1" > "$TMP/state/mode"
  printf "'%s'\n" "$2" > "$TMP/state/host"
  printf '%s\n'   "$3" > "$TMP/state/port"
  printf "%s\n"   "$4" > "$TMP/state/ignore-hosts"
}

# --- a throwaway listener standing in for xray ----------------------------
LISTEN_PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
python3 - "$LISTEN_PORT" <<'PY' &
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(8)
time.sleep(30)
PY
LISTENER_PID=$!
sleep 0.4

run_interactive() {   # prints the exported proxy variables
  PATH="$TMP/bin:$PATH" bash --norc -i -c \
    'source "'"$REPO"'/proxy.sh"; for v in http_proxy https_proxy all_proxy no_proxy; do printf "%s=%s\n" "$v" "${!v-}"; done' \
    2>"$TMP/stderr"
}

# --- 1. manual + reachable port -------------------------------------------
set_state manual 127.0.0.1 "$LISTEN_PORT" "['localhost', '127.0.0.0/8', '::1']"
OUT=$(run_interactive)
grep -qx "http_proxy=http://127.0.0.1:$LISTEN_PORT" <<<"$OUT" \
  && ok "manual + reachable port exports http_proxy" || bad "http_proxy not exported"
grep -qx "all_proxy=socks5://127.0.0.1:$LISTEN_PORT" <<<"$OUT" \
  && ok "manual + reachable port exports all_proxy (socks5)" || bad "all_proxy not exported"
NO_PROXY_LINE=$(sed -n 's/^no_proxy=//p' <<<"$OUT")
[[ $NO_PROXY_LINE == localhost,127.0.0.0/8,::1,* ]] \
  && ok "no_proxy starts with GNOME ignore-hosts" || bad "no_proxy does not reuse ignore-hosts: $NO_PROXY_LINE"
[[ $NO_PROXY_LINE == *",.kimi.com,kimi.com,api.kimi.com"* ]] \
  && ok "no_proxy appends the local kimi exceptions" || bad "kimi exceptions missing: $NO_PROXY_LINE"
[[ $NO_PROXY_LINE == *",.opencode.ai,opencode.ai,models.opencode.ai"* ]] \
  && ok "no_proxy appends the direct-by-default OpenCode exceptions" || bad "OpenCode exceptions missing: $NO_PROXY_LINE"
[[ $NO_PROXY_LINE != *"127.0.0.0/8,127.0.0.0/8"* ]] \
  && ok "no_proxy has no duplicated ignore-hosts entry" || bad "duplicate entry in no_proxy"

# --- 2. manual but the port is dead ---------------------------------------
set_state manual 127.0.0.1 1 "['localhost']"
OUT=$(run_interactive)
grep -q '^http_proxy=$' <<<"$OUT" && ok "dead port clears the proxy variables" || bad "dead port left a proxy variable"
grep -q '不可通' "$TMP/stderr" && ok "dead port warns on stderr" || bad "dead port warning missing"

# --- 3. system proxy off ---------------------------------------------------
set_state none "" 0 "['localhost']"
OUT=$(run_interactive)
grep -q '^https_proxy=$' <<<"$OUT" && ok "mode=none clears the proxy variables" || bad "mode=none left variables"
grep -q '\[proxy-ctl\]' "$TMP/stderr" && bad "mode=none printed a warning" || ok "mode=none stays silent"

# --- 4. non-interactive shell is untouched --------------------------------
OUT=$(PATH="$TMP/bin:$PATH" bash --norc -c \
  'source "'"$REPO"'/proxy.sh"; for v in http_proxy no_proxy; do printf "%s=%s\n" "$v" "${!v-}"; done')
grep -q '^http_proxy=$' <<<"$OUT" && grep -q '^no_proxy=$' <<<"$OUT" \
  && ok "non-interactive shell gets no proxy variables" || bad "non-interactive shell was modified"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
