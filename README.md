# proxy-ctl

A tiny Bash snippet that keeps your terminal's proxy environment
variables in sync with the GNOME system-proxy state — the same way
your browser already does.

## What it does

Every time you open a new interactive Bash shell, `proxy.sh`:

1. Reads GNOME's system proxy state via `gsettings`.
2. If it's `manual` **and** the configured host:port is reachable,
   exports `http_proxy` / `https_proxy` / `all_proxy` (+ uppercase
   variants) and `no_proxy`. `no_proxy` is built from GNOME's
   `ignore-hosts`, with only the local exceptions appended (`.local`,
   the kimi.com names, and the opencode.ai names). OpenCode uses a
   direct connection by default; there is no automatic proxy fallback
   when that direct connection fails.
3. Otherwise, unsets all of them so the shell goes direct.
4. Only prints anything (to `stderr`) when the state is anomalous —
   e.g. system proxy is on but the port is dead.

Non-interactive shells (`scp`, `rsync`, `sftp`, `git-over-ssh`,
`bash -c`) short-circuit at the very first line and touch nothing.

## Target environment

Designed and tested against one specific machine:

- Fedora Linux 44 (Workstation) / GNOME on Wayland
- Bash 5+
- GUI proxy tool: **v2rayN** with the **xray** core
- xray listening on `127.0.0.1:10808` (HTTP + SOCKS mux)

Other environments (KDE / XFCE, zsh / fish, WSL, SSH sessions
without D-Bus, GNOME `mode=auto` PAC) are explicitly out of scope.
See `DESIGN.md` for the full rationale.

## Install

```bash
mkdir -p ~/.config/proxy-ctl
cp proxy.sh ~/.config/proxy-ctl/proxy.sh
chmod +x ~/.config/proxy-ctl/proxy.sh

# then append this line to ~/.bashrc:
[ -f ~/.config/proxy-ctl/proxy.sh ] && . ~/.config/proxy-ctl/proxy.sh
```

Reload the current shell with `. ~/.bashrc`, or just open a new
terminal.

## Verify

```bash
$ env | grep -i proxy
http_proxy=http://127.0.0.1:10808
HTTP_PROXY=http://127.0.0.1:10808
https_proxy=http://127.0.0.1:10808
HTTPS_PROXY=http://127.0.0.1:10808
all_proxy=socks5://127.0.0.1:10808
ALL_PROXY=socks5://127.0.0.1:10808
no_proxy=localhost,127.0.0.0/8,::1,.local,.kimi.com,kimi.com,api.kimi.com,code.kimi.com,auth.kimi.com,telemetry-logs.kimi.com,.opencode.ai,opencode.ai,models.opencode.ai
NO_PROXY=localhost,127.0.0.0/8,::1,.local,.kimi.com,kimi.com,api.kimi.com,code.kimi.com,auth.kimi.com,telemetry-logs.kimi.com,.opencode.ai,opencode.ai,models.opencode.ai
```

Turn off system proxy in GNOME Settings → open a fresh terminal →
all of the above should be gone.

## Tests

```bash
$ bash test_proxy.sh
```

Offline: `gsettings` is mocked and the "xray port" is a throwaway
listener, so nothing real is touched. Covers the three behaviours
above plus "`no_proxy` really follows `ignore-hosts`" and
"non-interactive shells are untouched".

## Documents

- [DESIGN.md](DESIGN.md) — full design document (requirements,
  architecture, non-goals, scenario handling).
- [xray-client design](10_design/xray-client/design.md) — the current
  production proxy core design.
- [sing-box client design](10_design/sing-box-client/design.md) — the
  approved Scheme B design for a parallel sing-box client migration.
- [proxy.sh](proxy.sh) — the script itself, ~110 lines of annotated
  Bash.
- [test_proxy.sh](test_proxy.sh) — offline acceptance tests.

## Change Log

- 2026-11-19 — What: fixed tailnet traffic leaking into the proxy — template now routes `100.64.0.0/10` (CGNAT) and `.ts.net` to `direct` explicitly, with a matching offline assertion in `test_singboxctl.sh`. | Why: after the cutover, `http://100.105.202.118:8080/quiz` took 3.19s+ because sing-box's `ip_is_private` does not cover the CGNAT range, so tailnet IPs fell through to `route.final` and hairpinned via the VPS; the design rule "tailnet goes direct" was lost in implementation. | Who: user report -> assistant executed. | When: 2026-11-19 22:14. | Where: `10_design/sing-box-client/{config.template.json,test_singboxctl.sh,design.md}`; evidence `~/.local/state/sing-box-client/cutover/2026-11-19-tailnet-direct-fix.md`. | How: doc-first edit, 16/16 tests + production validate green, service restarted; quiz now 0.189s via `outbound/direct[direct]` (rollback: revert this commit and restart, or `vpnctl on`).
- 2026-11-19 — What: production cutover — sing-box now owns 10808-10811 (`sing-box-client.service`, enabled), xray is disabled but untouched as the rollback path (`vpnctl on`); GNOME system proxy unchanged (`manual`, 127.0.0.1:10808); `singboxctl.sh` gained the `SINGBOXCTL_PROFILE` switch. | Why: user instructed "直接切换" after the staging first run passed. | Who: user instruction -> assistant executed. | When: 2026-11-19 21:32-21:45. | Where: systemd user services, GNOME proxy, `10_design/sing-box-client/`; evidence `~/.local/state/sing-box-client/cutover/2026-11-19-production-cutover.md`. | How: design section 13.2 seven-step sequence plus a real rollback drill (xray restored and re-replaced); all test suites green (rollback: `systemctl --user stop sing-box-client.service && vpnctl on`).
- 2026-11-19 — What: staged the sing-box client for real use — source baseline (sing-box 1.14.1 + official rule-sets with SHA256 evidence), generator/validator/test service under `10_design/sing-box-client/`, first live run on ports 18080-18083 with journal scrub hardening; xray and ports 10808-10811 untouched. | Why: execute the approved Scheme B in its staging phase. | Who: user instruction -> assistant executed. | When: 2026-11-19. | Where: `10_design/sing-box-client/`, `~/.local/{lib,share,state}/sing-box*/`, systemd user unit `sing-box-client-test.service`. | How: branch commits `808eab9`, `a23a835` merged via `cfe3bb8`, `28d0b2c`; hardening commit `9549400`; full evidence in `~/.local/state/sing-box-client/` (rollback: `systemctl --user stop sing-box-client-test.service` and revert the named commits).
- 2026-11-19 — What: process-mistake record — commits `9549400` and `1ee49e0` were both made directly on `main` and pushed, bypassing the branch-then-merge rule **twice in one day**; installed repo-local `.git/hooks/pre-commit` that hard-blocks direct commits on `main`/`master` (merge commits unaffected). | Why: after each merge the shell was still on `main` and the commit landed there by oversight; the first "check the branch before committing" prevention proved to be theater — the check ran and the chain continued anyway, so prevention had to become mechanical per the mistakes rule. | Who: assistant mistake, self-reported. | When: 2026-11-19. | Where: commits `9549400` and `1ee49e0` on `main`; guard at `.git/hooks/pre-commit` (local, not version-controlled). | How: contents were fully tested beforehand, so history was kept rather than rewritten; hook verified to reject a test commit on `main` with exit 1 (rollback of this entry: revert the merge of this branch; remove the hook by deleting `.git/hooks/pre-commit`).
- 2026-11-19 — What: added the approved sing-box Scheme B design under `10_design/sing-box-client/` and linked it with the xray Scheme A design. | Why: user approved a documented client-side sing-box + Tailscale migration before implementation. | Who: user instruction -> assistant executed. | When: 2026-11-19. | Where: `README.md`, `10_design/xray-client/design.md`, and `10_design/sing-box-client/design.md`. | How: hand edit after protocol compatibility and project-architecture review; blast radius is documentation only (rollback: revert the `sing-box-client-design` merge commit).
- 2026-11-19 — What: added `.opencode.ai`, `opencode.ai`, and `models.opencode.ai` to the local `no_proxy` exceptions and documented direct-first behavior without automatic proxy fallback. | Why: user confirmed that OpenCode works directly and wants to avoid proxy-related resets unless direct connectivity fails. | Who: user instruction -> assistant executed. | When: 2026-11-19. | Where: `README.md`, `DESIGN.md`, `proxy.sh`, `test_proxy.sh`, and `~/.config/proxy-ctl/proxy.sh`. | How: updated documentation before code, added an offline assertion, and synchronized the verified script to the installed copy; blast radius is limited to OpenCode domain routing in newly started shells (rollback: restore `~/.config/proxy-ctl/proxy.sh.backup-20261119-direct-opencode-ai` and revert the `direct-opencode-ai` merge commit).

## License

MIT
