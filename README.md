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
[`releases/v0.1.0-candidate.15.json`](releases/v0.1.0-candidate.15.json). It pins
public amd64/arm64 images for all five services and the tested Slab Runner +
Codex CLI `0.148.0` pairing. No stable channel is published yet: the candidate
must still pass the complete Compose and clean-VPS installation matrix.

The candidate also has a versioned distribution contract. A release tag builds
a reproducible tarball, signs its SHA-256 sidecar and channel pointer with the
offline Slab release key, and publishes the bundle, checksum, detached Ed25519
signatures, manifest, and reviewed bootstrap as GitHub Release assets. Version
assets are immutable; dedicated channel releases hold signed mutable discovery
pointers. The bootstrap embeds only the public trust root and refuses unsigned,
modified, path-traversing, or symlink-containing metadata and bundles.

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
node scripts/render-image-env.mjs releases/v0.1.0-candidate.15.json
```

Once a candidate manifest is ready, run the destructive-to-its-own-fixture only
private-stack smoke on a free loopback port:

```bash
SLAB_STACK_SMOKE_PORT=39009 ./scripts/full-stack-smoke.sh
```

It creates a unique Compose project and temporary secrets, bootstraps login,
checks Work/Docs/Runner/Email through Slab Agents, verifies restart persistence,
and removes only that project and its volumes on exit.

The backup/restore contract also has a destructive-to-its-own-fixture smoke:

```bash
./scripts/check.sh
./scripts/backup-smoke.sh
```

It creates isolated labeled volumes, backs up non-empty data and secrets,
verifies the archive, mutates the fixture, restores it, verifies the original
bytes, and removes the fixture volumes on exit.

## Package a release

Build the exact candidate bundle locally:

```bash
./scripts/package-release.sh releases/v0.1.0-candidate.15.json dist
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
sudo sh install.sh --version 0.1.0-candidate.15
```

Bootstrap options precede installer options. For example, an inspect-only host
check is:

```bash
sudo sh install.sh --version 0.1.0-candidate.15 -- --dry-run
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

The installed manager supports read-only discovery and an explicit host update
lifecycle:

```bash
sudo slabctl update check --channel candidate
sudo slabctl update apply --channel candidate
sudo slabctl update rollback
```

Apply enters persisted dispatch maintenance, drains active Runs, creates and
verifies a mandatory backup, applies only digest-pinned images from signed
metadata, waits for service and application readiness, and records a sanitized
terminal state. Compatible failures restore the previous release files.
Incompatible migration failures stop with `RECOVERY_REQUIRED` and point to the
verified backup rather than claiming an unsafe image rollback worked.

Operational diagnosis is available without SSH archaeology:

```bash
sudo slabctl doctor
sudo slabctl support-bundle
```

The support archive is bounded, sanitized, root-private, and prints its exact
file list for review before creation. It excludes product databases, prompts,
messages, tool payloads, documents, and credential values.
