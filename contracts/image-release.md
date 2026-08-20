# Image release contract

Each product repository publishes its own image. A stack release only consumes
already-tested image digests.

## Required workflow gates

1. Install dependencies from the committed lockfile.
2. Run lint, typecheck, unit/integration tests, and production build.
3. Build an image for the native CI architecture.
4. Start it as a non-root user with temporary volumes and secret fixtures.
5. Wait for `/health` and `/ready`.
6. Exercise one service-specific smoke operation.
7. Build and push `linux/amd64` and `linux/arm64` through Buildx.
8. Generate SBOM and provenance attestations.
9. Scan the published digest.
10. Sign the digest through GitHub OIDC.
11. Upload the digest and evidence for the stack release workflow.

## Tagging

For source tag `v1.2.3`, publish:

```text
v1.2.3
1.2
1
sha-<git-sha>
```

The immutable stack manifest references `v1.2.3@sha256:<digest>`. It never
resolves `latest`.

## Visibility

Stable installer images must be public and anonymously pullable. The release
workflow verifies this from a logged-out Docker client before promoting the
stack channel.

