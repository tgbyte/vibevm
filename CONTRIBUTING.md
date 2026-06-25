# Contributing to vibevm

Thanks for your interest in improving vibevm. It's a security-focused sandbox for
running Claude Code in auto mode, so contributions that strengthen the isolation,
broaden host/portability support, improve the developer experience, or sharpen the
docs are all welcome.

Start with [DESIGN.md](DESIGN.md) — it explains the architecture (host scripts vs.
guest scripts), the threat model, and the rationale behind the trade-offs. Most of
the project is shell; there is no build step.

## Reporting issues

Open a GitHub issue for bugs and feature requests. For a bug, please include:

- your host OS and `incus version`,
- the exact command you ran and the relevant output/logs,
- what you expected versus what happened.

For anything network/firewall-related, `vibe firewall status`,
`incus exec <vm> -- nft list ruleset`, and the tinyproxy log are usually the most
useful context.

## Security issues

vibevm's whole job is containment, so please treat sandbox-escape-class bugs
specially. If you find a way to **break out of the VM, defeat the egress
allowlist, or exfiltrate data past it**, report it privately (see
[SECURITY.md](SECURITY.md)) rather than opening a public issue, so it can be fixed
before disclosure.

## Development setup

You need the same thing as running vibevm: a Linux host with **incus** and **KVM**
virtualization. Then:

```sh
./install.sh                    # one-time host setup (sudo)
./create-vm.sh                  # build the VM
# …make your changes…
./create-vm.sh                  # re-provision in place (idempotent)
./create-vm.sh --rebuild        # or a clean rebuild from scratch
```

`create-vm.sh` and the `guest/` scripts are **idempotent / re-runnable** — keep
them that way. Keep site-specific values **out of committed files**: anything
private (hosts, mirrors, keys) belongs in the gitignored `vibevm.conf`, `allowlist`,
or `secrets.env`, never in `config.sh`, `allowlist.example`, or the guest scripts.

## Coding conventions

- **Bash**, with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Match the surrounding style. The scripts are deliberately well-commented —
  explain the *why*, especially for anything security- or ordering-sensitive.
- Make settings configurable through `config.sh` / `vibevm.conf` rather than
  hardcoding them; document new knobs in `vibevm.conf.example` and the README.
- Run `bash -n` on every script you touch, and `shellcheck` if you have it.

## Testing your change

- **Syntax:** `bash -n <script>` for each changed script.
- **Functional:** rebuild the VM and exercise the change end-to-end. For
  firewall/allowlist work, verify *both* that intended hosts are reachable and
  that others are still blocked (`403 Filtered` / failed `CONNECT`).
- Describe how you tested it in the PR — there is no automated CI for the VM build.

## Commit messages & pull requests

- Use the existing format: `<area>: <imperative summary>` in lowercase, e.g.
  `firewall: allowlist quay.io`, `devtools: pin gradle 8.10`, `docs: …`. Common
  areas: `config`, `firewall`, `devtools`, `docker`, `vibe`, `mounts`,
  `statusline`, `provision`, `docs`, `branding`.
- Keep commits and PRs focused; update the README / DESIGN.md /
  `vibevm.conf.example` when behavior or configuration changes.
- Branch off `main` and open your PR against `main`.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE), consistent with the rest of the project.
