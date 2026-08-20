# Slab Stack

Distribution artifacts for the self-hosted Slab control plane.

This repository owns packaging and host lifecycle only:

- the verified installer bootstrap;
- the versioned installer bundle;
- Docker Compose and Caddy templates;
- immutable stack release manifests;
- `slabctl`;
- clean-VPS installation and upgrade tests.

It is not a runtime microservice. Docker Compose supervises containers and
Slab Agents orchestrates agent work.

The implementation source of truth is:

- [`docs/vps-self-hosted-installation-plan.md`](../slab-agents/docs/vps-self-hosted-installation-plan.md)

## Current status

The current immutable stack candidate is recorded in
[`releases/v0.1.0-candidate.9.json`](releases/v0.1.0-candidate.9.json). It pins
public amd64/arm64 images for all five services and the tested Slab Runner +
Codex CLI `0.148.0` pairing. No stable channel is published yet: the candidate
must still pass the complete Compose and clean-VPS installation matrix.

The candidate also has a versioned distribution contract. A release tag builds
a reproducible tarball, signs its SHA-256 sidecar with the offline Slab release
key, and publishes the bundle, checksum, detached Ed25519 signature, manifest,
and reviewed bootstrap as immutable GitHub Release assets. The bootstrap embeds
only the public trust root and refuses unsigned, modified, path-traversing, or
symlink-containing bundles.

The installer currently supports Ubuntu 22.04, 24.04, and 26.04 LTS plus
Debian 12 on amd64/arm64. On a clean host it installs Docker Engine and Compose
V2 from Docker's official apt repository after verifying the repository key
fingerprint.

The installed stack is registered as `slab.service`. systemd starts it after
Docker and the network are available, stops it before Docker shuts down, and
provides standard host lifecycle operations without exposing the Docker socket
to Slab Agents.

## Validate

```bash
./scripts/check.sh
```

The check validates every release manifest, shell syntax, secret-free
templates, image pinning, network exposure, and Compose rendering with
development fixtures. To render the immutable image environment for a release:

```bash
node scripts/render-image-env.mjs releases/v0.1.0-candidate.9.json
```

Once a candidate manifest is ready, run the destructive-to-its-own-fixture only
private-stack smoke on a free loopback port:

```bash
SLAB_STACK_SMOKE_PORT=39009 ./scripts/full-stack-smoke.sh
```

It creates a unique Compose project and temporary secrets, bootstraps login,
checks Work/Docs/Runner/Email through Slab Agents, verifies restart persistence,
and removes only that project and its volumes on exit.

## Package a release

Build the exact candidate bundle locally:

```bash
./scripts/package-release.sh releases/v0.1.0-candidate.9.json dist
```

The packaging step is deterministic for a given manifest and source tree. It
uses a digest-pinned, network-isolated GNU tar/gzip toolchain so developer and
CI hosts produce identical bytes. It does not sign locally. Tag publication runs the same packaging command and uses
the protected `SLAB_RELEASE_SIGNING_KEY_PEM` GitHub Actions secret. CI derives
the public key from that secret and refuses to publish unless it equals
[`contracts/release-signing-public.pem`](contracts/release-signing-public.pem).

Until the stable channel is promoted, a reviewed candidate can be installed
explicitly with the release bootstrap:

```bash
sudo sh install.sh --version 0.1.0-candidate.9
```

Bootstrap options precede installer options. For example, an inspect-only host
check is:

```bash
sudo sh install.sh --version 0.1.0-candidate.9 -- --dry-run
```

## Repository layout

```text
contracts/   machine-readable release contracts
bootstrap/   small public verifier and downloader
channels/    reviewed release-channel pointers
installer/   versioned installer implementation
templates/   Compose, Caddy, and host templates
scripts/     local and CI validation
tests/       fixtures and behavioral checks
```
