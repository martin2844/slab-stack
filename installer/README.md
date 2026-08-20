# Versioned installer

`install.sh` is the versioned stack installer. It is intentionally separate
from the future small bootstrap hosted at `https://slab.ar/install.sh`: the
public bootstrap will download and verify a release bundle before invoking
this script.

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

The current candidate implements private/domain rendering, root-private
secret generation, digest-pinned Compose reconciliation, administrator
bootstrap, readiness, and idempotent reruns. Codex onboarding, Docker package
installation, systemd/slabctl, and domain diagnostics remain subsequent plan
gates.

Interactive private install:

```sh
sudo ./installer/install.sh
```

Non-interactive private install:

```text
# /root/slab-install.conf (chmod 0600)
SLAB_INSTALL_DIRECTORY=/opt/slab
SLAB_ACCESS_MODE=private
SLAB_PRIVATE_BIND_IP=127.0.0.1
SLAB_PRIVATE_PORT=3009
SLAB_COMPOSE_PROJECT_NAME=slab
SLAB_ADMIN_PASSWORD_FILE=/root/slab-admin-password
```

```sh
sudo ./installer/install.sh \
  --non-interactive \
  --config /root/slab-install.conf
```

The password file must be root-owned, mode `0400` or `0600`, contain one
line, and is read only long enough to pipe the password to the in-container
bootstrap command. It is never copied into the installation directory,
Compose environment, state file, or process arguments.

The password file is only required while the initial administrator still
needs to be created. A ready installation can be reconciled without that
one-time file, and its existing administrator password is never rotated.

The installation directory and every existing ancestor must be root-owned and
must not be group/world writable. This protects the root-run Compose boundary;
use the default `/opt/slab` unless you have prepared another trusted path.

`config/install-state.json` is an atomic, non-secret progress ledger. It records
the current attempt, completed phases, immutable Compose/access identity, and
the last known good result. Reruns reconcile that same identity and refuse
changes that would silently fork the stack into a second Compose project or
data set.
