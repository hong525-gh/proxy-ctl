# Repository Guidelines

## Repository Status

This project is at bootstrap: the working directory is currently empty and Git
is not yet initialized. The conventions below define how contributors should
shape the VPN project as it grows.

## Project Structure & Module Organization

Layout follows the parent `10_PROJECTS` workspace conventions:

```
VPN/
├── 00_brief/     # Requirements, background, scope
├── 10_design/    # Designs, tunnel/config specs, architecture notes
├── 20_assets/    # Sample configs, certificates (secrets kept out of Git)
└── 99_done/      # Completed deliverables
```

Natural nesting is allowed. Keep VPN configuration artifacts such as `wg0.conf`
or `.ovpn` files under `10_design/`, and never commit secrets from `20_assets/`.

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
