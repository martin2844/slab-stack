# Versioned installer

The executable installer lands in this directory during Phase 4 of the plan.
It must not be published until the five image contracts pass.

The stable `install.sh` hosted at `slab.ar` will only download a versioned
bundle, verify its checksum and signature, and execute this installer. Keeping
the public bootstrap small makes it reviewable and keeps installation logic
versioned with the stack manifest.

Required entry points:

```text
installer/install.sh
installer/lib/preflight.sh
installer/lib/prompts.sh
installer/lib/docker.sh
installer/lib/secrets.sh
installer/lib/render.sh
installer/lib/health.sh
installer/lib/codex.sh
```

No executable placeholder is provided yet: a script that cannot install the
unpublished service images would create a false readiness signal.

