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
installer/lib/host-bootstrap.sh
installer/lib/prompts.sh
installer/lib/docker.sh
installer/lib/secrets.sh
installer/lib/render.sh
installer/lib/health.sh
installer/lib/codex.sh
installer/lib/lifecycle.sh
installer/lib/domain.sh
installer/lib/systemd.sh
```

The current candidate implements private/domain rendering, root-private
secret generation, digest-pinned Compose reconciliation, administrator
bootstrap, readiness, idempotent reruns, Codex authentication through the
installed `slabctl`, and a managed `slab.service` lifecycle. On Ubuntu 22.04,
24.04, or 26.04 and Debian 12, a missing Docker Engine is installed from
Docker's official apt repository after its signing-key fingerprint is
verified. Domain diagnostics and the remaining management commands are
subsequent plan gates.

The installer refuses to remove conflicting distribution Docker packages
automatically. This keeps host package removal explicit; resolve the reported
package list and rerun the same installation command.

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

## Service lifecycle

The installer atomically installs `/etc/systemd/system/slab.service`, refuses
to overwrite an unmanaged unit with that name, and enables it for every boot.
The unit runs the same registered, immutable Compose identity as `slabctl`.

```sh
sudo systemctl status slab
sudo systemctl restart slab
sudo systemctl stop slab
sudo systemctl start slab
sudo journalctl -u slab
```

The corresponding management entry points are also available directly:

```sh
sudo slabctl stack status
sudo slabctl stack restart
```

For a domain installation, verify that Caddy is serving a trusted certificate
and update the installation state after DNS propagation:

```sh
sudo slabctl domain verify
```

Stopping the service removes containers and project networks but never named
volumes. Starting it again reruns the idempotent migration jobs before the
long-running services, so Work, Docs, agents, Email metadata, and Codex auth
remain persistent.

The installation directory and every existing ancestor must be root-owned and
must not be group/world writable. This protects the root-run Compose boundary;
use the default `/opt/slab` unless you have prepared another trusted path.

`config/install-state.json` is an atomic, non-secret progress ledger. It records
the current attempt, completed phases, immutable Compose/access identity, and
the last known good result. Reruns reconcile that same identity and refuse
changes that would silently fork the stack into a second Compose project or
data set.

## Codex authentication

The installer places a versioned management command at `/usr/local/bin/slabctl`.
Device authorization is the headless-server default:

```sh
sudo slabctl codex login
sudo slabctl codex status
sudo slabctl codex logout
```

An API key can be supplied through a hidden prompt or stdin without storing it
in the installation config:

```sh
sudo slabctl codex login --api-key
```

Authentication is written only into the Runner's persistent Codex volume.
After login/logout, `slabctl` restarts Runner so `codex app-server` reloads the
credential state. A failed login does not roll back the healthy stack.
