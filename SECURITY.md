# Security Policy

vibevm is a sandbox: its job is to contain Claude Code running with the approval
prompt disabled. Reports that show the containment failing are taken seriously.

## No formal audit

vibevm's isolation is a **best-effort, defense-in-depth design by its
maintainers — it has not undergone a formal third-party security audit or a
professional hardening review.** It is provided as-is (see the
[LICENSE](LICENSE)); evaluate whether its guarantees fit your own risk tolerance
before trusting it with anything sensitive, and keep real host credentials out of
the guest. Security review, hardening, and fixes are exactly the kind of
contribution we welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Reporting a vulnerability

**Please do not open a public issue for a security vulnerability.** Instead, either:

- email **security@tgbyte.de**, or
- use GitHub's **private vulnerability reporting** ("Report a vulnerability" in the
  repository's *Security* tab).

Helpful details to include: what you found, step-by-step reproduction, the impact,
and the affected commit (`git rev-parse HEAD`). We'll acknowledge your report
within a few business days and keep you updated on the fix. Please give us a
reasonable window to release a fix before public disclosure (coordinated
disclosure).

## In scope

The isolation boundary is supposed to hold against a fully-capable, possibly
prompt-injected agent inside the VM. In scope, for example:

- **Guest → host escape** — breaking out of the VM to the host (VM/hypervisor
  escape).
- **Defeating the egress allowlist** — the unprivileged `vibe` user disabling or
  bypassing the firewall *on its own*, without the host-operator controls.
- **Unintended exfiltration** — moving data out past the egress allowlist through
  a channel the design doesn't account for.
- **Host secret exposure** — reaching host credentials or data the design intends
  to keep out of the guest.
- **Provisioning flaws** that silently weaken the isolation described in
  [DESIGN.md](DESIGN.md) (e.g. the firewall failing open, the `vibe` user gaining
  unintended privileges).

## Known limitations (not vulnerabilities)

These are deliberate, documented trade-offs (see [DESIGN.md](DESIGN.md)) — please
don't report them as vulnerabilities:

- **Rootful Docker is root-equivalent.** The `docker` group can escalate to root
  inside the VM, and container egress leaves via Docker's NAT, bypassing the
  allowlist. The **VM is the isolation boundary**, not the allowlist; rely on it
  accordingly, or rebuild without `docker.sh`.
- **DNS can be a covert channel.** Queries to the VM's own resolvers are permitted
  (needed for name resolution), so a determined attacker could attempt DNS
  tunneling.
- **The operator can open egress.** `vibe firewall off` intentionally disables
  the allowlist; only the host operator can do this, and it's a supported action.
- **Out of scope:** anything requiring host root, a malicious host operator,
  physical access, or credentials the operator deliberately placed in the guest.

The VM (separate kernel, throwaway, snapshot) is the boundary that matters; the
egress allowlist and least-privilege layers are defense-in-depth, not guarantees.
Keep real host credentials out of the guest.

## Supported versions

vibevm is distributed as source from this repository; security fixes land on
`main`. Track `main` for updates — there are no separately maintained release
branches.
