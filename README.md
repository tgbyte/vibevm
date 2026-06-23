<p align="center">
  <img src="branding/wordmark.png" width="380" alt="vibevm — a safe sandbox for vibe-coding with Claude in auto mode">
</p>

A throwaway **incus KVM virtual machine** (Ubuntu 26.04 LTS) where you can run
`claude --dangerously-skip-permissions` (auto / "YOLO" mode) without putting your
host, your credentials, or the wider network at risk.

## Why a VM (the threat model)

Auto mode removes the approval prompt on every shell command and file write. The
realistic risks: destructive commands, **credential theft / exfiltration** (your
`~/.ssh`, cloud tokens, `.env` files — amplified by *prompt injection* from a
malicious README, web page, or npm postinstall), uncontrolled network egress, and
host persistence.

This setup contains all of that with three layers:

| Layer | How |
| --- | --- |
| **Blast radius** | A full KVM VM (separate kernel). Trash it and restore the `clean` snapshot. |
| **Egress allowlist** | In-VM domain-allowlisting proxy (`tinyproxy`); `nftables` forces all web egress through it (default-drop otherwise). |
| **Least privilege** | Claude runs as the unprivileged `vibe` user with **no sudo**. IPv6 is off so the v4 allowlist is total. Only a *scoped* API key is injected, at launch. (Rootful Docker is a deliberate exception that relaxes this — see the Docker section.) |

## Files

| File | Role |
| --- | --- |
| `bootstrap.sh` | One-time host setup (starts incus daemon, group, init). Needs sudo. |
| `create-vm.sh` | Launches + provisions the VM. Idempotent. |
| `vibe` | Launcher: `./vibe` (Claude auto mode) or `./vibe shell`. |
| `config.sh` | Shared config loader: bakes defaults, overlaid by `vibevm.conf`. Sourced by the host scripts. |
| `vibevm.conf` | Host config — VM name/resources, tool versions, optional mirrors (gitignored; see `.example`). |
| `allowlist` | Egress domain allowlist pushed into the VM (gitignored; see `.example`). |
| `guest/provision.sh` | Runs inside the VM: tooling, Claude Code, `vibe` user, then calls `harden.sh`. |
| `guest/harden.sh` | Network policy: installs tinyproxy + the domain allowlist, points tools at it, enables the firewall. |
| `guest/devtools.sh` | Developer runtimes: Chrome (headless), nvm+Node, SDKMAN+Java/Maven/Gradle (public repos, optional Nexus mirror), lighthouse. |
| `guest/docker.sh` | Docker engine + compose + buildx (rootful); routes daemon pulls through tinyproxy. |
| `guest/init-firewall.sh` | The nftables rules that force all egress through tinyproxy. |
| `guest/firewall.sh` | `vibe-firewall` control script — toggles the egress allowlist on/off. |
| `secrets.env` | Your scoped `ANTHROPIC_API_KEY` (gitignored; injected only at launch). |
| `mount-workspaces.sh` | Mounts host project dirs into the VM under `~/workspace` (live virtiofs). |
| `workspaces.conf` | Host dirs to mount (gitignored; see `.example`). |
| `workspace/` | Drop/clone projects here; each subdir appears at `~/workspace/<name>`. |

## Setup

```sh
./bootstrap.sh          # one time; sudo. Then start a NEW shell / restart Claude Code.
cp secrets.env.example secrets.env && $EDITOR secrets.env   # optional: scoped API key
cp vibevm.conf.example vibevm.conf  && $EDITOR vibevm.conf   # optional: tune VM/versions/mirrors
./create-vm.sh          # build + provision the VM (a few minutes)
./vibe                  # vibe-code in auto mode
```

The two `cp` steps are optional — the repo runs unmodified with sensible
defaults. Put the projects you want to work on under `~/workspace` (see below).
You edit them on the host with your normal tools; Claude works on the same files
in the VM.

### Configuration (`vibevm.conf`)

Host-side settings live in `vibevm.conf` (copy from `vibevm.conf.example`,
gitignored). Anything you leave unset falls back to the default in `config.sh`:

| Setting | Default | What it controls |
| --- | --- | --- |
| `VM_NAME` | `vibevm` | incus instance name (all the host scripts target it). |
| `VM_IMAGE` | `images:ubuntu/26.04` | Base image. |
| `VM_CPU` / `VM_MEM` / `VM_DISK` | `8` / `32GiB` / `40GiB` | VM resource limits. |
| `NODE_DEFAULT` / `NVM_VERSION` | `24.16.0` / `v0.40.1` | nvm's default Node and the nvm release. |
| `JAVA_VERSION` / `JAVA_EXTRA_MAJORS` / `MAVEN_VERSION` / `GRADLE_VERSION` | SDKMAN latest / `21` / latest / latest | SDKMAN tool versions. |
| `NEXUS_MAVEN_URL` | *(empty)* | Optional Maven/Gradle mirror (see below). |
| `REGISTRY_MIRROR` | *(empty)* | Optional Docker registry pull-through mirror. |

The egress allowlist is configured separately in `./allowlist` (see
[Adjusting the network allowlist](#adjusting-the-network-allowlist)). Re-run
`./create-vm.sh --rebuild` after changing anything the VM is provisioned with.

### Mounting projects (`~/workspace`)

Multiple host directories can be mounted into the VM, each appearing at
`/home/vibe/workspace/<name>` (shared live via virtiofs). Two ways, combinable:

- **Drop-in:** put or `git clone` projects into `./workspace/<name>/` — every
  subdirectory there is mounted automatically.
- **External paths:** list host directories in `./workspaces.conf` (copy
  `workspaces.conf.example`); `/abs/path` or `name=/abs/path`, one per line.

Apply changes any time with `./vibe mounts`. Paths must be readable by the incus
daemon (anywhere under your home works). `./vibe` then starts Claude in
`~/workspace` (it sees all mounted projects), or `./vibe <name>` to start it
directly inside `~/workspace/<name>`.

### Git pushes

Pushing happens **from the host**, not the VM — the VM deliberately holds no git
credentials and SSH (port 22) is blocked by the firewall. The flow:

1. The agent **commits** inside the VM. Commits are attributed to your host git
   identity, which `./vibe` carries in at launch (as `GIT_AUTHOR_*`/`GIT_COMMITTER_*`
   env — nothing stored in the VM).
2. Because the repo is virtiofs-shared, those commits are immediately present in
   the host directory. **You `git push` from the host** there, with your normal
   SSH keys / credentials.

(If you ever want the agent to push autonomously instead, switch to an HTTPS
remote, allowlist the git host, and inject a scoped token at launch — see git
history / ask, as it trades some isolation for autonomy.)

### Custom API endpoint (`ANTHROPIC_BASE_URL`)

To point Claude at a gateway (e.g. LiteLLM) instead of `api.anthropic.com`, set in
`secrets.env`:

```sh
ANTHROPIC_BASE_URL=https://llm-gateway.example.com
ANTHROPIC_AUTH_TOKEN=...        # or ANTHROPIC_API_KEY, per your gateway
```

`./vibe` forwards these into the VM and — because Claude connects to its API
endpoint **directly** (not through tinyproxy) — automatically allows that host for
direct egress (appended to `/etc/vibe/api-hosts`, alongside `api.anthropic.com`).
No firewall edits needed; it works with the allowlist on.

## Day-to-day

```sh
./vibe [PROJECT]        # Claude in auto mode, in ~/workspace[/PROJECT]
./vibe mounts           # (re)mount project dirs after editing workspaces.conf
./vibe statusline       # re-sync your host Claude status line into the VM
./vibe persist          # back ~/.claude with host ./claude-home (survives rebuilds)
./vibe shell [PROJECT]  # login shell in the VM (in ~/workspace[/PROJECT])
./vibe firewall status  # show egress mode; `off` opens egress, `on` re-enforces

incus snapshot restore vibevm clean   # roll back a messed-up VM
incus stop vibevm                     # pause
./create-vm.sh --rebuild              # delete + recreate (host-backed state preserved)
```

### Persisting Claude's memory/history across rebuilds

`incus delete` wipes the VM disk, including `/home/vibe/.claude` (history,
sessions, file-based memory under `projects/<proj>/memory/`, plans, tasks, and
auth). To keep it, back that directory with a host folder:

```sh
./vibe persist          # close any running ./vibe session first
```

This migrates the current `~/.claude` to `./claude-home/` (gitignored) and mounts
it back at `/home/vibe/.claude` via virtiofs — so it lives on the host and
survives `incus delete`. `create-vm.sh` re-attaches it automatically on every
rebuild. Run `./vibe persist` **before** deleting the VM, or that state is lost
— though `./create-vm.sh --rebuild` does this capture for you automatically
before it deletes. (Project-level memory like `CLAUDE.md`/`memory/` *inside* a
project already persists via the workspace mount.)

Claude's main config lives in `~/.claude.json` — a file in `$HOME`, *outside*
`~/.claude` — so `./vibe` sets `CLAUDE_CONFIG_DIR=/home/vibe/.claude`, which makes
Claude keep both its config and state under the persisted mount. That's what
keeps you logged in across rebuilds (the OAuth credential and account info live
in `.claude.json` / `.credentials.json`).

## Preinstalled runtimes

Beyond the base tooling (git, git-filter-repo, ripgrep, build-essential, system Python 3 / Node),
`guest/devtools.sh` installs:

| Runtime | How | Notes |
| --- | --- | --- |
| **Node** | `nvm` (per-user, in `/home/vibe/.nvm`) | default = Node 24 (`NODE_DEFAULT`); `nvm install/use <ver>` to switch (downloads from the allowlisted nodejs.org). Shadows the system Node. |
| **Java** | `SDKMAN` (per-user, in `/home/vibe/.sdkman`) | default = latest Temurin; **JDK 21** also installed. `sdk use java 21.0.x-tem` (this shell) or `sdk default java <ver>-tem` (global) to switch; `JAVA_EXTRA_MAJORS` adds more. |
| **Maven + Gradle** | `SDKMAN` (per-user) | default = latest; resolve from public Maven Central + the Gradle Plugin Portal, or through a Nexus mirror if configured (see below). |
| **Chrome + Lighthouse** | `google-chrome-stable` (system) + `lighthouse` (global, nvm) | `CHROME_PATH` is preset; the setuid sandbox works for the `vibe` user. |

These are wired onto `PATH` via `/etc/profile.d/vibe-tools.sh`, so they're
available to `./vibe`, `./vibe shell`, and the commands Claude runs.

Lighthouse against an app running **inside** the VM works out of the box:

```sh
lighthouse http://localhost:3000 --only-categories=performance --quiet
```

Auditing an **external** URL also requires that site's domain in the allowlist
(Chrome routes through tinyproxy automatically). To pin versions reproducibly,
set `NODE_DEFAULT` / `JAVA_VERSION` / `JAVA_EXTRA_MAJORS` / `MAVEN_VERSION` /
`GRADLE_VERSION` in `vibevm.conf`.

### Java builds (default public, optional Nexus mirror)

The JVM ignores the `http_proxy` env vars the rest of the VM uses, so
`guest/devtools.sh` points Maven and Gradle at the tinyproxy egress proxy
explicitly. **By default they resolve from the public repositories** — Maven
Central (`repo.maven.apache.org`) and the Gradle Plugin Portal
(`plugins.gradle.org`), both on the default allowlist — so `mvn` and `gradle`
work with the firewall on, no per-project setup:

```sh
mvn -B verify           # or:  ./mvnw …
gradle build            # or:  ./gradlew …
```

**Optional Nexus mirror.** In a locked-down network you may prefer to mirror
**all** repository access through a single repository group (so builds never need
direct egress to public repos). Set `NEXUS_MAVEN_URL` in `vibevm.conf` and add its
host to `./allowlist`:

```sh
# vibevm.conf
NEXUS_MAVEN_URL=https://nexus.example.com/repository/maven-all/
```

| Tool | File | What it does (when a mirror is set) |
| --- | --- | --- |
| Maven | `~/.m2/settings.xml` | `<proxy>` → 127.0.0.1:8888; `<mirror>` `mirrorOf=*` → the mirror; `<server>` creds from the env. |
| Gradle | `~/.gradle/gradle.properties` + `~/.gradle/init.gradle` | `systemProp.*.proxy*` → the proxy; the init script replaces every project/plugin/buildscript repo with the (credentialed) mirror. |

If the mirror needs authentication, put `NEXUS_USERNAME` / `NEXUS_PASSWORD` in
`secrets.env`; `./vibe` forwards them into the session and Maven/Gradle read them
from the env at build time — nothing is written to the VM disk. For Gradle
plugins, the group must proxy the Gradle Plugin Portal. Note: project
**wrappers** (`mvnw`/`gradlew`) download their own distribution — point those at
the mirror too, or the distribution host (`*.gradle.org`) needs allowlisting.

## Docker (rootful)

Docker (engine + `docker compose` + `docker buildx`) is installed and `vibe` is
in the `docker` group, so `docker` works directly in `./vibe` / `./vibe shell`.

- **Image pulls** are made by the daemon and routed through tinyproxy, so the
  registry must be allowlisted. Allowed by default: Docker Hub
  (`docker.io`/`docker.com`) and `ghcr.io`. Add others (`quay.io`, `gcr.io`,
  `registry.k8s.io`, …) the same way as any domain (see below).
- **Container** traffic reaches the internet via Docker's own NAT and is *not*
  bound by the allowlist (the accepted trade-off of rootful Docker), so
  `RUN apt-get` / `npm install` in builds just work.

**Security trade-off:** the `docker` group is root-equivalent inside the VM, so a
compromised or over-eager agent could escalate to root, disable the firewall, and
exfiltrate via a container. The **VM (separate kernel, throwaway, snapshot)
remains the real isolation boundary** — keep host secrets and real credentials
out of it. (For strict egress instead, rebuild without `docker.sh`, or switch to
rootless Docker.)

## Adjusting the network allowlist

Egress is default-deny and allowlisted **by domain** (robust to CDN IP changes).
The list lives in `./allowlist` on the host — one POSIX ERE per line, matched
against the request host (copy from `allowlist.example`; `create-vm.sh` does this
for you on first run). `create-vm.sh` pushes it into the VM as
`/etc/tinyproxy/allowlist`.

To add domains reproducibly, edit `./allowlist` and re-apply (this survives
rebuilds, since the host file is the source of truth):

```sh
$EDITOR allowlist
incus file push allowlist vibevm/root/allowlist --mode 0644
incus exec vibevm -- bash /usr/local/bin/harden.sh   # re-installs the list + restarts tinyproxy
```

For a quick one-off tweak you can instead edit the live copy in the VM directly
(lost on rebuild):

```sh
incus exec vibevm -- nano /etc/tinyproxy/allowlist
incus exec vibevm -- systemctl restart tinyproxy
```

Inspect the live policy: `incus exec vibevm -- nft list ruleset` and
`incus exec vibevm -- cat /etc/tinyproxy/allowlist`. Denied requests show up as
`403 Filtered`/`CONNECT tunnel failed` to the client and in tinyproxy's log.
(Replace `vibevm` with your `VM_NAME` if you changed it.)

## Turning the egress firewall off

The allowlist can be toggled at runtime, and the choice persists across reboots:

```sh
./vibe firewall off      # open egress — allowlist no longer enforced
./vibe firewall on       # re-enforce the allowlist (default)
./vibe firewall status
```

`off` removes the nftables lockdown and stops tinyproxy filtering, giving the VM
unrestricted egress — handy when you knowingly need broad network access, at the
cost of the anti-exfiltration layer (the VM stays your isolation boundary). Only
the host operator can flip it; it needs root in the VM, so the `vibe` agent
can't disable it on its own.

## Caveats / known trade-offs

- **HTTP/HTTPS only**: egress goes through the proxy on ports 80/443, so other
  protocols are blocked. Use `https://` git remotes, not `git@github.com` (SSH).
  api.anthropic.com also has a direct-IP fallback so Claude works either way.
- **DNS**: queries are allowed to the VM's resolvers (needed for name resolution).
  A determined attacker could attempt DNS tunneling — acceptable here given the VM
  isolation, but worth knowing.
- **System packages**: the `vibe` user has no sudo by design. Install OS packages
  by adding them to `guest/provision.sh` and re-running, not from inside a session.
- **Rootful Docker weakens egress control**: the `docker` group is root-equivalent
  in the VM, and container traffic bypasses the allowlist. Rely on the VM boundary
  (not the allowlist) against Docker misuse — see the Docker section.
- **Don't reuse credentials**: use a scoped/low-privilege `ANTHROPIC_API_KEY`, and
  don't mount host SSH keys or cloud creds into `~/workspace`.
