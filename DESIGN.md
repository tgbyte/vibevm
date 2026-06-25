# vibevm — design & internals

Companion to the [README](README.md). The README covers day-to-day use; this
document explains **how the sandbox is built and why**, the threat model in
depth, and the residual trade-offs. Read it if you want to audit the isolation,
extend the provisioning, or understand a particular mechanism.

## Threat model

`claude --dangerously-skip-permissions` (auto / "YOLO" mode) removes the approval
prompt on every shell command and file write. That is convenient and genuinely
risky. The realistic failure modes:

- **Destructive commands** — `rm -rf`, a bad migration, a force-push.
- **Credential theft / exfiltration** — reading your `~/.ssh`, cloud tokens, or
  `.env` files and sending them somewhere. This is sharply amplified by **prompt
  injection**: a malicious README, web page, issue comment, or npm postinstall
  script can carry instructions the agent then follows.
- **Uncontrolled network egress** — reaching arbitrary hosts to fetch payloads or
  to exfiltrate.
- **Host persistence** — leaving something behind that runs later.

vibevm contains these with three layers, defence-in-depth so that one failure is
not catastrophic:

| Layer | Mechanism | What it buys |
| --- | --- | --- |
| **Blast radius** | A full KVM virtual machine (separate kernel), disposable, with a `clean` snapshot. | A compromise is contained to a throwaway guest. Restore the snapshot or delete the VM and the damage is gone. |
| **Egress allowlist** | An in-VM domain-allowlisting proxy (`tinyproxy`); `nftables` default-drops all other egress and forces web traffic through it. | Exfiltration and payload fetches are limited to a small set of known-good domains, robust to CDN IP churn. |
| **Least privilege** | Claude runs as the unprivileged `vibe` user with **no sudo**; IPv6 is disabled; only a *scoped* API key is injected, and only at launch. | Even with full control of the session, the agent cannot change the network policy or read host secrets that were never given to it. |

The boundary that ultimately matters is the **VM** — separate kernel, throwaway,
snapshotted. The allowlist and least-privilege layers reduce what a single bad
run can do *before* you notice and reset, but you should treat the guest as
untrusted: keep real host credentials out of it.

## Why a VM, not containers

Two convictions shaped vibevm.

**Strong isolation through a real VM, not containers.** The agent runs with the
approval prompt disabled, so the isolation boundary has to hold against a
fully-capable process that may be acting on malicious instructions. Containers
share the host kernel — a single kernel-level escape, or a misconfigured
namespace or capability, reaches the host directly. A KVM virtual machine runs
its **own kernel** behind a hardware-virtualization boundary, so escaping it is a
far higher bar and the host kernel is never directly exposed to guest activity.
For a sandbox whose entire purpose is to contain untrusted execution, that
stronger boundary is worth the modest cost in RAM and start-up time. (The VM is
just as disposable as a container — snapshot, restore, delete — but the *kernel
separation* is the part that earns its keep here.)

**A compact, auditable codebase — not a stack of images.** vibevm is a handful of
shell scripts and config files driving stock incus and stock Ubuntu. There is no
custom Docker image to build, publish, version, and trust; no compose stack or
orchestration layer; nothing pulled from a registry you would have to vet. The
provisioning is plain `apt`, `curl`, and `nft` you can read line by line — which
matters for a security tool, where "I can see exactly what it does" is itself a
feature. It also keeps the project portable and easy to modify: change a script,
re-run `create-vm.sh`, done.

## Repository layout

**Host scripts** (run on your machine, orchestrate incus):

| File | Role |
| --- | --- |
| `install.sh` | One-time host setup: incus daemon, `incus-admin` group, minimal init, plus `vibe` on PATH and shell completions. Needs sudo. |
| `create-vm.sh` | Launches + provisions the VM. Idempotent; `--rebuild` deletes and recreates. |
| `config.sh` | Shared config loader: bakes defaults, overlaid by a gitignored `vibevm.conf`. Sourced by every host script. |
| `vibe` | Launcher: `vibe` (Claude auto mode), `vibe shell`, and the `mounts`/`statusline`/`persist`/`firewall` subcommands. |
| `mount-workspaces.sh` | Mounts host project dirs into the VM under `~/workspace` (live virtiofs). |
| `persist-claude.sh` | Backs `~/.claude` with host `./claude-home` so it survives rebuilds. |
| `sync-statusline.sh` | Installs the Claude status line into the VM. |

**Guest scripts** (pushed into the VM, run as root during provisioning):

| File | Role |
| --- | --- |
| `guest/provision.sh` | Entry point inside the VM: base tooling, Claude Code, the `vibe` user, then calls the scripts below. |
| `guest/harden.sh` | Network policy: installs tinyproxy + the allowlist, points tools at the proxy, enables the firewall service. |
| `guest/init-firewall.sh` | The nftables ruleset that forces all egress through tinyproxy. |
| `guest/firewall.sh` | `vibe-firewall` control script — toggles the egress allowlist on/off (root only). |
| `guest/devtools.sh` | Developer runtimes: Chrome (headless), nvm+Node, SDKMAN+Java/Maven/Gradle, OpenTofu, Lighthouse. |
| `guest/docker.sh` | Docker engine + compose + buildx (rootful); routes daemon pulls through tinyproxy. |
| `guest/timesync.sh` | Clock sync from the host via the KVM PTP device (no network). |
| `guest/statusline-command.sh` | The vibevm-branded Claude status line. |

**Configuration & state** (gitignored): `vibevm.conf` (host config), `allowlist`
(egress domains), `secrets.env` (API key / mirror creds), `workspaces.conf`
(extra mounts), `workspace/` (drop-in projects), `claude-home/` (persisted
`~/.claude`).

**Optional:** `completions/` holds bash and zsh tab-completion for the `vibe`
launcher (subcommands, `firewall` modes, and project names).

## Provisioning flow

`create-vm.sh`:

1. Launch the VM (`incus launch`, with `VM_CPU/VM_MEM/VM_DISK` limits).
2. Wait for the agent and for DNS.
3. Auto-seed `./allowlist` from `allowlist.example` if missing; push the guest
   scripts and the allowlist into the VM.
4. Run `provision.sh`, forwarding the configured build knobs (`NODE_DEFAULT`,
   `APT_PACKAGES`, `NEXUS_MAVEN_URL`, …) as environment variables.
5. Mount workspace dirs, persist `~/.claude`, install the status line.
6. Stop the VM and take the `clean` snapshot, then restart.

`provision.sh` runs, in order: disable IPv6 → enable the `universe` component →
install the essential core + `APT_PACKAGES` → install Node + Claude Code → create
the `vibe` user → time sync → developer runtimes → Docker → **harden (firewall)
last**. The network is open while provisioning runs (so installs work) and is
locked down only at the very end.

## Network egress

The egress design is the heart of the anti-exfiltration layer.

### Domain allowlist via tinyproxy

`tinyproxy` is a forward proxy configured with `FilterDefaultDeny Yes` and a
filter file of host regexes (`/etc/tinyproxy/allowlist`, one POSIX ERE per line,
matched case-insensitively against the request host). Allowlisting **by domain**
rather than IP is deliberate: CDN IPs churn constantly, domains don't. The list
is a host file (`./allowlist`) pushed into the VM, so it survives rebuilds and is
edited in one place. A denied request returns `403 Filtered` (HTTP) or a failed
`CONNECT` tunnel (HTTPS).

The shipped tinyproxy AppArmor profile only permits reading `tinyproxy.conf`, so
`harden.sh` adds a local override (`/etc/apparmor.d/local/tinyproxy`) granting
read on the filter file — without it, enforcing mode fails to start.

### nftables default-drop (`init-firewall.sh`)

tinyproxy only filters traffic that goes *through* it. `init-firewall.sh` makes
that mandatory with a default-drop `OUTPUT` chain in a dedicated `inet vibe`
table. The accepted paths:

- **loopback** and **established/related** connections.
- **tinyproxy's uid → ports 80/443** — the *only* process allowed to open
  outbound web connections. Everything else is forced through the proxy because
  it has no other way out.
- **DNS to the VM's own resolvers** only (parsed from `resolv.conf` and
  systemd-resolved). Needed for name resolution.
- **DHCP** lease renewal (UDP 67).
- **Direct 443 to the API host IPs** — Claude Code connects to its API endpoint
  directly, not through the proxy, so the resolved IPs of `api.anthropic.com`
  (plus any host in `/etc/vibe/api-hosts`) are allowed out on 443 as a set. This
  is the direct-IP fallback that keeps Claude working even if the proxy path has
  trouble.
- **Output onto the Docker bridges** (`docker0`, `br-*`) — *not* internet egress.
  Reaching a published container port (e.g. testcontainers hitting
  `localhost:<port>`) makes docker-proxy open a host→container leg that is
  locally generated and would otherwise hit the default-drop. Container *egress*
  is the FORWARD path (masqueraded out by Docker's own NAT) and never traverses
  this chain.

The script only ever deletes and recreates **its own** `inet vibe` table — never
`nft flush ruleset`, which would wipe Docker's NAT/filter tables and break
container networking on every reapply.

### The firewall toggle

`vibe-firewall` (`firewall.sh`, root only) has `on` / `off` / `apply` / `status`.
The mode is saved in `/etc/vibe/firewall` and re-applied at boot by
`vibe-firewall.service`. `on` writes the filtering tinyproxy config and installs
the nftables lockdown; `off` removes the table and stops tinyproxy filtering
(traffic still routes through it but passes). The unprivileged `vibe` user cannot
run it (nftables needs root), so a runaway or injected agent **cannot disable the
allowlist on its own** — only the host operator can, via `vibe firewall`.

### Residual network notes

- **IPv6 is disabled** (`provision.sh`) so the IPv4 allowlist is total — there is
  no v6 path around it.
- **HTTP/HTTPS only**: egress is restricted to 80/443 through the proxy; other
  protocols are blocked. Use `https://` git remotes, not SSH.
- **DNS tunneling**: queries to the VM's resolvers are allowed (you need name
  resolution), so a determined attacker could attempt to tunnel data over DNS.
  Accepted here given the VM isolation, but worth knowing.

## Identity & least privilege

Claude runs as `vibe`, an unprivileged user with **no sudo**. The user's uid/gid
are aligned to the host user's (`provision.sh` frees the image's default
`ubuntu:1000` and recreates `vibe` at the host uid) so virtiofs-shared files have
matching ownership on both sides. The scoped API key lives only in host
`secrets.env` and is injected as an environment variable at launch — never
written into the image, a snapshot, or the VM disk.

## Persistence across rebuilds

`incus delete` wipes the VM disk, including `/home/vibe/.claude` (history,
sessions, file-based memory, plans, tasks, and auth). `persist-claude.sh` backs
that directory with host `./claude-home` over virtiofs: on first run it migrates
any existing in-VM `~/.claude` to the host dir (only if the host dir is empty),
then attaches the mount. `create-vm.sh` re-attaches it on every rebuild, and
`--rebuild` captures `~/.claude` to the host *before* deleting.

Claude's main config is `~/.claude.json`, which lives in `$HOME` **outside**
`~/.claude`. So `vibe` sets `CLAUDE_CONFIG_DIR=/home/vibe/.claude`, relocating
both config and state under the persisted mount — that is what keeps you logged in
across rebuilds (the OAuth credential / account info live in `.claude.json` /
`.credentials.json`). Project-level memory (`CLAUDE.md`, `memory/` inside a
project) already persists via the workspace mount.

`persist-claude.sh` refuses to run while a `claude` process is live, since
attaching the mount would yank `~/.claude` out from under it.

## Time sync without network

The egress firewall has no rule for NTP (UDP 123), so `systemd-timesyncd` could
never reach a time server. Instead of poking an NTP hole, `timesync.sh` loads the
KVM virtual PTP device (`/dev/ptp0`) and points `chrony` at it as a refclock — the
guest reads the host clock directly, zero packets leave the VM. `makestep 1 -1`
lets chrony step the clock on any offset at any time, so it re-corrects quickly
after a host suspend/resume freezes the guest vCPUs.

## Developer runtimes & the JVM proxy

`devtools.sh` installs per-user runtimes (nvm+Node, SDKMAN+Java/Maven/Gradle),
system Chrome for Lighthouse, and OpenTofu, wired onto `PATH` via
`/etc/profile.d/vibe-tools.sh`. Versions are pinned by `vibevm.conf`
(`NODE_DEFAULT`, `JAVA_VERSION`, …).

The JVM is a special case: it ignores the `http_proxy` env vars the rest of the
VM uses, so Maven and Gradle are pointed at the egress proxy **explicitly**.

- **Default (public):** `~/.m2/settings.xml` and `~/.gradle/gradle.properties`
  carry the proxy host/port (127.0.0.1:8888); resolution goes to Maven Central
  (`repo.maven.apache.org`) and the Gradle Plugin Portal (`*.gradle.org`), both
  on the default allowlist. No mirror, works out of the box.
- **Optional Nexus mirror:** set `NEXUS_MAVEN_URL` in `vibevm.conf` (and add its
  host to `./allowlist`). Then `settings.xml` gains a `<mirror>` `mirrorOf=*` and
  `~/.gradle/init.gradle` rewrites every project/plugin/buildscript repository to
  the mirror. Credentials (`NEXUS_USERNAME`/`NEXUS_PASSWORD`) come from the
  session env (forwarded from `secrets.env`), never written to the VM disk. Useful
  in locked-down networks where builds shouldn't reach public repos directly.

Project **wrappers** (`mvnw`/`gradlew`) download their own distribution, so the
distribution host must be reachable (`*.gradle.org` is allowlisted; for a mirror,
point the wrapper at it too).

## Docker (rootful) — rationale & trade-off

Docker is installed rootful and `vibe` is in the `docker` group, so `docker`
works directly in a session. Two consequences:

- **Daemon image pulls** are locally-generated traffic, so they hit the egress
  allowlist — `docker.sh` routes them through tinyproxy and the registries must be
  allowlisted (Docker Hub + ghcr.io by default; add `quay.io`, `gcr.io`, etc.). An
  optional `REGISTRY_MIRROR` configures a pull-through mirror.
- **Container traffic** reaches the internet via Docker's own NAT (the nftables
  FORWARD path), which the allowlist does **not** cover — so `RUN apt-get` /
  `npm install` in builds just work, at the cost of egress control inside
  containers.

The deliberate trade-off: the `docker` group is **root-equivalent** inside the
VM, so a compromised or over-eager agent could escalate to root, disable the
firewall, and exfiltrate via a container. This is why the **VM remains the real
isolation boundary** — keep host secrets out of it. For strict egress instead,
rebuild without `docker.sh` or switch to rootless Docker.

## Configuration & provisioning knobs

`config.sh` is sourced by every host script. It sources a gitignored
`vibevm.conf` (if present) first, then applies `${VAR:=default}` so user values
win — meaning the repo runs unmodified with no config file, and any single knob
can be overridden without restating the rest. `create-vm.sh` forwards the
provisioning-relevant knobs into the VM as environment variables; the guest
scripts read them with matching fallbacks (so a standalone guest-script run still
works).

Two design choices worth calling out:

- **Essential vs configurable packages.** `provision.sh` always installs a small
  essential core (`ca-certificates curl git nftables jq`) that the firewall, git
  commits, downloads, and the status line depend on — so a trimmed `APT_PACKAGES`
  can't break the VM. `APT_PACKAGES` is the dev tooling on top.
- **Mirrors default to public.** `NEXUS_MAVEN_URL` and `REGISTRY_MIRROR` are empty
  by default (public sources used directly) and opt-in, so the open-source default
  needs no private infrastructure.

See the README's [Configuration](README.md#configuration) section for the full
knob table.
