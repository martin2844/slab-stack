# Compatibility

Slab's stable support promise is intentionally narrower than every platform the
installer can recognize. A host is supported only after the complete signed
bundle has passed a native release gate or an equivalent clean-VPS exercise.

## Stable host matrix

| Host | Architecture | Private install | Idempotent reconcile | Evidence |
| --- | --- | --- | --- | --- |
| Ubuntu 24.04 LTS | amd64 | Supported | Supported | Native GitHub-hosted VM |
| Ubuntu 24.04 LTS | arm64 | Supported | Supported | Native GitHub-hosted VM |
| Ubuntu 26.04 LTS | amd64 | Supported | Supported | Clean VPS |

Ubuntu 26.04 amd64 additionally covers domain/TLS installation, a signed update
from an earlier candidate, verified backup/restore to another host, systemd
restart recovery, and the forced bad-update rollback drill.

Ubuntu 22.04 and Debian 12 remain installer-compatible previews. They are not in
the stable support matrix until the same packaged release gate passes on native
hosts. Ubuntu 26.04 arm64 is also outside the current stable promise.

## Runtime and deployment contract

- Docker Engine with Compose V2 is installed from Docker's official repository
  when absent.
- Service images are public, digest-pinned, and publish both `linux/amd64` and
  `linux/arm64` manifests.
- The guided server-IP mode binds the panel to the VPS address on port `3009`.
  Declarative installations may still choose a loopback-only binding.
- Domain mode uses Caddy for reverse proxying and automatic TLS.
- Codex CLI `0.148.0` is the stable runtime pairing for Slab `0.1.2`.
- Gemini CLI `0.56.0` is an experimental account-authenticated runtime. Its
  OAuth state is isolated in a dedicated Runner volume and hard-budget Runs
  fail closed because the CLI has no native token/cost ceiling. The volume is
  host-local and Gemini must be authenticated again after a portable restore.
  Restore clears Gemini runtime session IDs so the next chat turn starts fresh
  and rehydrates the durable product conversation instead of resuming missing
  provider-local history.
- Proton Bridge authentication is host-bound and must be repeated after moving
  a backup to another host.

The native matrix workflow is
[`host-matrix.yml`](../.github/workflows/host-matrix.yml). Stable channel
publication is gated on both native Ubuntu 24.04 jobs; the Ubuntu 26.04 VPS
exercise remains the physical-host complement to CI.
