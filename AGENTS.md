# Repository Guidelines

## Repository Status

The project is live: Git is initialized with a GitHub remote, the production
proxy client is sing-box (`10_design/sing-box-client/`, switched on
2026-11-19), and xray (`10_design/xray-client/`) is disabled but kept as the
rollback path. A repo-local `.git/hooks/pre-commit` blocks direct commits on
`main`/`master` — work on a branch, merge with `--no-ff`.

## Project Structure & Module Organization

```
proxy-ctl/
├── proxy.sh / test_proxy.sh   # shell-level proxy env tool (no_proxy etc.)
├── DESIGN.md / README.md / TODO.md / CHECKLIST.md
└── 10_design/                 # designs: xray-client, sing-box-client, VPS docs
```

Never commit secrets; real credentials live outside the repo (see the global
single-source rule).

## Build, Test, and Development Commands

There is no build system yet. Expected commands once tooling lands:

- `git init` — initialize the repository (each project is its own repo).
- `shellcheck scripts/*.sh` — lint shell scripts.
- `wg-quick up wg0` / `wg-quick down wg0` — bring a tunnel up/down for local testing.

## Coding Style & Naming Conventions

- Indentation: 2 spaces for shell/YAML, 4 spaces for Python.
- File names: lowercase with hyphens, e.g. `configure-client.sh`.
- Start shell scripts with `#!/usr/bin/env bash` and `set -euo pipefail`; stay
  POSIX-compatible unless Bash features are required.

## Testing Guidelines

Validate configuration before committing (for example `wg-quick strip <iface>`
or the client's built-in config check) and confirm a handshake in a disposable
environment. Record manual verification steps in `99_done/`. Name test scripts
`test_<subject>.sh` and keep them runnable without external infrastructure.

## Commit & Pull Request Guidelines

Write short, imperative commit summaries, optionally scoped, e.g.
`config: add split-tunnel routes`. Keep each commit focused on one change.

Pull requests should include a brief description of the change, the reason for
it, manual verification steps, and sanitized config or output snippets. Never
attach real keys, IPs, or endpoints.

## Security & Configuration Tips

- Never commit private keys, pre-shared keys, or credentials; keep them in
  `20_assets/` and list them in `.gitignore`.
- Provide `*.example` templates for any config file that holds secrets.
- Only test changes against infrastructure you are authorized to use.
