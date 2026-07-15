# proxy-ctl

A tiny Bash snippet that keeps your terminal's proxy environment
variables in sync with the GNOME system-proxy state — the same way
your browser already does.

## What it does

Every time you open a new interactive Bash shell, `proxy.sh`:

1. Reads GNOME's system proxy state via `gsettings`.
2. If it's `manual` **and** the configured host:port is reachable,
   exports `http_proxy` / `https_proxy` / `all_proxy` (+ uppercase
   variants) and `no_proxy`.
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
no_proxy=localhost,127.0.0.0/8,::1,.local
NO_PROXY=localhost,127.0.0.0/8,::1,.local
```

Turn off system proxy in GNOME Settings → open a fresh terminal →
all of the above should be gone.

## Documents

- [DESIGN.md](DESIGN.md) — full design document (requirements,
  architecture, non-goals, scenario handling).
- [proxy.sh](proxy.sh) — the script itself, ~80 lines of annotated
  Bash.

## License

MIT
