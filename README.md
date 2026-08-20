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

Phase 0 scaffold. No stable channel is published yet. The Compose contract
references image variables that will be populated by a signed release manifest
after all five service images exist.

## Validate

```bash
./scripts/check.sh
```

The check validates JSON contracts, shell syntax, secret-free templates, image
pinning, network exposure, and Compose rendering with development fixtures.

## Repository layout

```text
contracts/   machine-readable release contracts
installer/   versioned installer implementation
templates/   Compose, Caddy, and host templates
scripts/     local and CI validation
tests/       fixtures and behavioral checks
```

