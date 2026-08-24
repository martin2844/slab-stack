# Versioned installer

`install.sh` is the versioned stack installer. It is intentionally separate
from the small public bootstrap in `bootstrap/install.sh`: the public entry
point downloads and verifies a release bundle before invoking this script.

The public stable `install.sh` asset only downloads a versioned bundle, verifies
its checksum and detached Ed25519 signature, and executes this installer.
Keeping the public bootstrap small makes it reviewable and keeps installation
logic versioned with the stack manifest. A convenience install domain remains a
separate distribution concern.

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
installer/lib/backup.sh
installer/lib/systemd.sh
installer/lib/metadata-repair.sh
```

The current release implements private/domain rendering, root-private
secret generation, digest-pinned Compose reconciliation, administrator
bootstrap, readiness, idempotent reruns, Codex authentication through the
installed `slabctl`, and a managed `slab.service` lifecycle. On Ubuntu 22.04,
24.04, or 26.04 and Debian 12, a missing Docker Engine is installed from
Docker's official apt repository after its signing-key fingerprint is
verified. Stable support is intentionally narrower than recognized preview
hosts; see `docs/compatibility.md` in the distribution repository.

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

## Backup and restore

`slabctl` creates a consistent, root-private archive by briefly stopping the
running services, archiving every Compose-managed state volume, and starting
the stack again. The archive includes the installed release metadata, image
digests, SQLite migration versions, file sizes, and SHA-256 checksums. A backup
is not reported as successful until the complete archive verifies.

```sh
sudo slabctl backup
sudo slabctl backup /mnt/slab-backups
sudo slabctl backup /mnt/slab-backups/workspace-2026-08-23.tar.gz
sudo slabctl backup verify /mnt/slab-backups/workspace-2026-08-23.tar.gz
```

The default destination is `/var/backups/slab`. Archives contain workspace
secrets and therefore use mode `0600`; protect or encrypt the destination when
moving a backup off-host.

For an encrypted archive, generate and secure an age identity once, keep a
separate recovery copy, and pass the root-private identity file explicitly:

```sh
sudo apt-get install age
sudo sh -c 'umask 077; age-keygen -o /root/slab-backup.agekey'
sudo slabctl backup --encrypt-with /root/slab-backup.agekey /mnt/slab-backups
sudo slabctl backup verify \
  --identity /root/slab-backup.agekey \
  /mnt/slab-backups/slab-backup-<version>-<time>.tar.gz.age
```

Encryption wraps the same verified `slab-backup-v2` logical archive. Slab
decrypts and re-verifies the complete inner manifest before reporting success.

Restore is intentionally strict. Legacy v1 archives require the exact same
stack version. V2 archives are accepted when every applied database migration
is a supported prefix of the target release contract. Only product data is
restored, so a private backup can move to a domain install (and vice versa)
without coupling recovery to Caddy certificates or state. The stack must be
stopped. Inspect the operation first:

```sh
sudo slabctl restore --dry-run /mnt/slab-backups/workspace-2026-08-23.tar.gz
sudo slabctl stack stop
sudo slabctl restore /mnt/slab-backups/workspace-2026-08-23.tar.gz
```

The terminal restore state lists external providers that cannot carry their
host session to a new machine. Gmail and encrypted connector configuration stay
inside the restored product data. A configured Proton Bridge account is marked
`reauthentication_required`; after a host move, run `sudo slabctl proton setup`
before relying on that account.

Pass `--identity /root/slab-backup.agekey` for an encrypted archive.

Interactive restore requires typing `RESTORE`; automation must pass `--yes`
explicitly. A successful restore starts the services, runs the release's
idempotent migrations, and waits for health. If mutation begins but the restore
or readiness check fails, `config/restore-state.json` records
`RECOVERY_REQUIRED` and the command never claims success.

## Signed updates and rollback

Release discovery and host mutation are separate operations. Stable and
candidate channel pointers require a valid detached Ed25519 signature; the
selected bundle checksum is independently signed and every image remains
digest-pinned.

```sh
sudo slabctl update check
sudo slabctl update check --channel candidate
sudo slabctl update apply --channel candidate
```

Release engineering also has an isolated signed `drill` channel for destructive
rollback exercises on disposable hosts. It is rejected by default and is not an
installation or product update channel. An operator must opt in for one command
with `SLAB_RELEASE_ALLOW_DRILL_CHANNEL=1`; never enable it persistently or on a
workspace containing data that cannot be discarded.

`update apply` requires typing `UPDATE` unless `--yes` is supplied. It persists
maintenance mode in Slab Agents, waits for active Runs and approvals to drain,
creates a verified pre-update backup, applies one-shot migrations, and requires
container health plus `/ready` before recording `UPDATED`.

### Email metadata correction for affected 0.1.x releases

Releases `0.1.0-candidate.16` through `0.1.0-candidate.19`, the disposable
`0.1.0-drill.1`, stable `0.1.0` and `0.1.1`, plus the superseded
`0.1.2-candidate.20`, declared a third Email migration that their pinned Email
image does not contain. The mandatory pre-update backup correctly refuses that
mismatch. Repair only this known release metadata defect with the signed
candidate bundle, then run the normal update:

```sh
curl -fsSL https://github.com/martin2844/slab-stack/releases/latest/download/install.sh \
  | sudo sh -s -- --version 0.1.2-candidate.23 -- --repair-known-metadata
sudo slabctl update apply --channel candidate --yes
```

The repair is narrowly gated to exact official manifest hashes, the exact
pinned Email image, and a live Email database whose applied migrations are
exactly `[1,2]`. It takes the normal management lock, preserves the original
manifest root-only, and does not modify containers, images, volumes, databases,
or application data. Any other state is rejected rather than guessed.

For a successful update whose migrations permit image rollback:

```sh
sudo slabctl update rollback
```

The exact result is recorded root-only in `config/update-state.json`, including
the previous and target versions, backup location, recovery directory, rollback
compatibility, and terminal guidance. `RECOVERY_REQUIRED` means the operator
must keep the stack stopped and use the referenced verified backup; `slabctl`
never claims an unsafe rollback succeeded.

## Diagnostics and support bundle

Run the host-side diagnostic without exposing application content:

```sh
sudo slabctl doctor
sudo slabctl doctor --json
```

It checks installed release identity and permissions, Docker/Compose, service
health, SQLite migration metadata, disk/inode capacity, runtime availability,
the last recorded backup, the signed update channel, and the configured public
health endpoint. A runtime that has not been authenticated and a missing backup
are warnings; unsafe release identity, unhealthy services, unreadable schemas,
or an unreachable configured endpoint fail the diagnosis.

For support, review the exact included file list before creating a root-private
archive:

```sh
sudo slabctl support-bundle
sudo slabctl support-bundle --yes /mnt/support
```

The bundle contains structured doctor output, release metadata, Compose status,
bounded sanitized logs, configuration-presence booleans, and identifiers for up
to 25 recent terminal Runs. It excludes SQLite databases, secret files and
values, prompts, messages, tool payloads, and document bodies.

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

## Gemini authentication

Gemini CLI is an optional experimental runtime that uses Google's official
account authorization and does not require a usage-key in Slab Agents. On a
headless host, run:

```sh
sudo slabctl gemini login
sudo slabctl gemini status
sudo slabctl gemini logout
```

`slabctl` starts Gemini with `NO_BROWSER=true`. Open the URL it displays on
your computer, complete Google's authorization, return to the server, and type
`/quit` once the Gemini prompt appears. OAuth state is stored only in the
Runner's dedicated `runner_gemini` volume; it is never copied into Compose
environment, the control-plane database, or model context. Login/logout
restarts Runner so runtime health changes deterministically. After a successful
login, enable Gemini from Settings → Runtime and assign it to an Agent.

The OAuth volume survives restarts and updates on the same host. It is excluded
from portable Slab backups, so authenticate Gemini again after restoring onto
another host. Restore also clears saved Gemini runtime session IDs; the next
chat turn starts a fresh Gemini session and rehydrates the durable product
conversation.

Gemini reports aggregate Run usage. It does not expose a native hard token or
cost limit through this CLI path, so Runs with hard token/cost budgets fail
closed before execution. Headless Gemini also cannot round-trip Slab prompt
approvals: prompt-gated tools are omitted, while explicitly approved tools are
available for the Run.

## Proton Bridge

On amd64 and arm64, `slab-email` includes Proton's headless Bridge backend built
from its verified official source with a patched Go toolchain. The
interactive installer offers to connect a mailbox only after the core stack is
healthy. Skipping is safe; configure it later from Slab Agents Settings or run:

```sh
sudo slabctl proton status
sudo slabctl proton setup
```

The setup command reads the Proton password and any second factor without
terminal echo. Those values pass directly to Bridge and are not written to the
installer config, shell history, Compose environment, or Slab database. Only
Bridge's generated mailbox credential is retained by `slab-email`, encrypted at
rest. Non-interactive installs intentionally skip account login because secrets
must not be placed in declarative installer configuration.
