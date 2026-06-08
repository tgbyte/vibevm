# vibevm — a safe sandbox for vibe-coding with Claude in auto mode

A throwaway **incus KVM virtual machine** where you can run
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
| **Least privilege** | Claude runs as the unprivileged `vibe` user with **no sudo**, so it can't disable the firewall. IPv6 is off so the v4 allowlist is total. Only a *scoped* API key is injected, at launch. |

## Files

| File | Role |
| --- | --- |
| `bootstrap.sh` | One-time host setup (starts incus daemon, group, init). Needs sudo. |
| `create-vm.sh` | Launches + provisions the VM. Idempotent. |
| `vibe` | Launcher: `./vibe` (Claude auto mode) or `./vibe shell`. |
| `guest/provision.sh` | Runs inside the VM: tooling, Claude Code, `vibe` user, then calls `harden.sh`. |
| `guest/harden.sh` | Network policy: installs tinyproxy + the domain allowlist, points tools at it, enables the firewall. |
| `guest/init-firewall.sh` | The nftables rules that force all egress through tinyproxy. |
| `secrets.env` | Your scoped `ANTHROPIC_API_KEY` (gitignored; injected only at launch). |
| `project/` | Your code — shared **live** with the VM at `/home/vibe/project`. |

## Setup

```sh
./bootstrap.sh          # one time; sudo. Then start a NEW shell / restart Claude Code.
./create-vm.sh          # build + provision the VM (a few minutes)
cp secrets.env.example secrets.env && $EDITOR secrets.env   # optional: scoped API key
./vibe                  # vibe-code in auto mode
```

Put the project you want to work on in `./project/` (e.g. `git clone` into it). You
edit it on the host with your normal tools; Claude works on the same files inside
the VM.

## Day-to-day

```sh
./vibe                  # Claude in auto mode, in ~/project
./vibe shell            # plain shell in the VM (unprivileged vibe user)

incus snapshot restore vibevm clean   # roll back a messed-up VM
incus stop vibevm                     # pause
incus delete --force vibevm           # nuke it; re-run ./create-vm.sh to rebuild
```

## Adjusting the network allowlist

Egress is default-deny and allowlisted **by domain** (robust to CDN IP changes).
To allow more domains, edit the regex list (POSIX ERE, matched against the
request host) — either `/etc/tinyproxy/allowlist` in the VM directly:

```sh
incus exec vibevm -- nano /etc/tinyproxy/allowlist
incus exec vibevm -- systemctl restart tinyproxy
```

…or, to keep it reproducible across rebuilds, edit the allowlist block in
`guest/harden.sh` and re-apply:

```sh
incus file push guest/harden.sh vibevm/usr/local/bin/harden.sh --mode 0755
incus exec vibevm -- bash /usr/local/bin/harden.sh
```

Inspect the live policy: `incus exec vibevm -- nft list ruleset` and
`incus exec vibevm -- cat /etc/tinyproxy/allowlist`. Denied requests show up as
`403 Filtered`/`CONNECT tunnel failed` to the client and in tinyproxy's log.

## Caveats / known trade-offs

- **HTTP/HTTPS only**: egress goes through the proxy on ports 80/443, so other
  protocols are blocked. Use `https://` git remotes, not `git@github.com` (SSH).
  api.anthropic.com also has a direct-IP fallback so Claude works either way.
- **DNS**: queries are allowed to the VM's resolvers (needed for name resolution).
  A determined attacker could attempt DNS tunneling — acceptable here given the VM
  isolation, but worth knowing.
- **System packages**: the `vibe` user has no sudo by design. Install OS packages
  by adding them to `guest/provision.sh` and re-running, not from inside a session.
- **Don't reuse credentials**: use a scoped/low-privilege `ANTHROPIC_API_KEY`, and
  don't mount host SSH keys or cloud creds into `project/`.
