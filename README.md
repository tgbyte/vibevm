<p align="center">
  <img src="branding/wordmark.png" width="380" alt="vibevm — a safe sandbox for vibe-coding with Claude in auto mode">
</p>

<p align="center">
  A throwaway KVM virtual machine for running Claude Code in auto mode without
  putting your host, your credentials, or the network at risk.
</p>

---

**vibevm** is an [incus](https://linuxcontainers.org/incus/) KVM virtual machine
(Ubuntu 26.04 LTS) for running `claude --dangerously-skip-permissions` (auto mode)
safely. You edit projects on the host with your normal tools; Claude works on the
same files inside a disposable VM, where a destructive command, a leaked secret,
or a prompt-injection payload can't reach beyond the guest.

## Why a VM

Auto mode removes the approval prompt on every command and file write. vibevm
contains the fallout with three layers:

| Layer | How |
| --- | --- |
| **Blast radius** | A full KVM VM (separate kernel), disposable — trash it and restore the `clean` snapshot. |
| **Egress allowlist** | An in-VM domain-allowlisting proxy (`tinyproxy`); `nftables` default-drops everything else. |
| **Least privilege** | Claude runs as the unprivileged `vibe` user, no sudo; only a scoped API key is injected, at launch. |

The VM is the boundary that matters — treat the guest as untrusted and keep host
credentials out of it. (Why a real VM and not a container, and why it's just shell
scripts: [DESIGN.md](DESIGN.md#why-a-vm-not-containers).)

## Prerequisites

A Linux host with **incus + VM support** and hardware virtualization — `bootstrap.sh`
only starts the incus daemon, it doesn't install incus. Check KVM with
`[ -e /dev/kvm ]`, then install incus:

```sh
# Ubuntu 24.04+:   sudo apt install incus qemu-system
# Arch Linux:      sudo pacman -S incus qemu-base edk2-ovmf dnsmasq
```

Ubuntu's package is Incus 6.0 LTS; for 7.x use the
[Zabbly repo](https://github.com/zabbly/incus). On Arch, VMs need Secure Boot off
(`security.secureboot=false`) — it ships no signed firmware.

## Quick start

```sh
./bootstrap.sh          # one time (sudo); then re-login so the incus-admin group applies
./create-vm.sh          # build + provision the VM (a few minutes)
vibe                    # vibe-code in auto mode, in ~/workspace
```

Optionally, before `create-vm.sh`: `cp secrets.env.example secrets.env` (a scoped
API key) and `cp vibevm.conf.example vibevm.conf` (tune the build) — vibevm runs
with sensible defaults without them. `vibe` is the launcher; symlink it onto your
`PATH` (`ln -s "$PWD/vibe" ~/.local/bin/vibe`) or run it as `./vibe` from the repo.

## Everyday use

```sh
vibe [PROJECT]        # Claude in auto mode, in ~/workspace[/PROJECT]
vibe .                # the project for the host dir you're in (resolves the mount)
vibe shell [PROJECT]  # login shell in the VM
vibe config           # apply host config (mounts + allowlist) to the running VM
vibe persist          # back ~/.claude on the host so it survives rebuilds
vibe statusline       # re-sync your host status line into the VM
vibe firewall on|off|status   # toggle / inspect the egress allowlist
vibe stop             # pause the VM
vibe restore [SNAP]   # roll back to a snapshot (default 'clean')
./create-vm.sh --rebuild      # delete + recreate (host-backed state preserved)
```

Arguments after the project pass through to Claude — e.g. `vibe . --resume` or
`vibe . -c`. Tab completion for bash/zsh lives in `completions/` (install steps in
each file's header).

## Projects & git

Host directories are shared into the VM live (virtiofs) under `~/workspace`:

- **Drop-in:** put or `git clone` projects into `./workspace/<name>/`.
- **External paths:** list them in `./workspaces.conf` — `/abs/path` or
  `name=/abs/path`, one per line; prefix with `?` to skip quietly if the path is
  absent. Apply with `vibe config`.

**Pushing happens from the host** — the VM holds no git credentials and SSH is
blocked. The agent commits inside the VM (as your host git identity); because the
repo is shared, those commits are immediately on the host, where you `git push`.

## Configuration

Settings live in `vibevm.conf` (copy from `vibevm.conf.example`, gitignored); unset
keys fall back to `config.sh`:

| Setting | Default | Controls |
| --- | --- | --- |
| `VM_NAME` / `VM_IMAGE` | `vibevm` / `images:ubuntu/26.04` | instance name, base image |
| `VM_CPU` / `VM_MEM` / `VM_DISK` | `8` / `16GiB` / `40GiB` | resource limits |
| `NODE_DEFAULT`, `JAVA_VERSION`, `MAVEN_VERSION`, `GRADLE_VERSION`, … | see the example | tool versions |
| `APT_PACKAGES` | dev tooling (+ an always-on essential core) | extra apt packages |
| `NEXUS_MAVEN_URL` / `REGISTRY_MIRROR` | empty (public sources) | optional Maven / Docker mirrors |

Resource limits need `./create-vm.sh --rebuild`; version/package/mirror changes
apply on a plain `./create-vm.sh`.

**Egress allowlist** — the domains the VM may reach are in `./allowlist` (copy from
`allowlist.example`, one host regex per line). Edit it, then run **`vibe config`** to
push it into the running VM and restart the proxy (no rebuild needed).

`vibe firewall off` opens egress entirely (only the host operator can). For an LLM
gateway, set `ANTHROPIC_BASE_URL` (+ token) in `secrets.env` — `vibe` auto-allows
that host.

## Preinstalled tooling

**The default toolset is opinionated toward Java and frontend/web development.** On
top of a base of git, ripgrep, build-essential, Python 3 and zsh, `devtools.sh`
installs:

| Runtime | Notes |
| --- | --- |
| **Java** | SDKMAN — latest Temurin + JDK 21, Maven & Gradle (public repos, optional Nexus mirror) |
| **Node** | nvm — default Node 24; `nvm install/use <ver>` to switch |
| **Chrome + Lighthouse** | headless system Chrome, for web/perf audits |
| **Docker** | rootful (engine + compose + buildx) |

Different stack? Trim or swap it via `APT_PACKAGES` and the version knobs in
`vibevm.conf`, or edit `guest/devtools.sh`. Java builds and rootful Docker have
trade-offs — see [DESIGN.md](DESIGN.md#developer-runtimes--the-jvm-proxy).

## Trade-offs to know

- **HTTP/HTTPS only** through the proxy — use `https://` git remotes, not SSH.
- **Rootful Docker** is root-equivalent in the VM and its container traffic bypasses
  the allowlist; the VM, not the allowlist, is the boundary against Docker misuse.
- **No formal audit** — the isolation is best-effort, not third-party reviewed;
  judge it for your own risk. Review and fixes welcome ([SECURITY.md](SECURITY.md)).
- **Don't reuse credentials** — use a scoped API key, and keep host SSH/cloud creds
  out of `~/workspace`.

## Documentation & contributing

- How it works, threat model, design rationale: **[DESIGN.md](DESIGN.md)**
- Contributing & dev setup: **[CONTRIBUTING.md](CONTRIBUTING.md)**
- Reporting vulnerabilities: **[SECURITY.md](SECURITY.md)**

## License

[Apache 2.0](LICENSE) © 2026 TG Byte Software GmbH

## Trademarks

vibevm is an independent project, **not affiliated with or endorsed by Anthropic**.
"Claude" and "Claude Code" are trademarks of Anthropic, PBC, used here only
descriptively.
