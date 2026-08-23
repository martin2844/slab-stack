#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURE_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/slab-backup-smoke.XXXXXX")
PROJECT_NAME=slabbackupsmoke$$
DEFAULT_RUNTIME_IMAGE=$(jq -r '.images.agents.ref + "@" + .images.agents.digest' \
  "$ROOT/releases/v0.1.0-candidate.19.json")
RUNTIME_IMAGE=${SLAB_BACKUP_SMOKE_IMAGE:-$DEFAULT_RUNTIME_IMAGE}
VOLUMES="agents_data runner_codex"

cleanup() {
  for logical_name in $VOLUMES; do
    docker volume rm -f "${PROJECT_NAME}_${logical_name}" >/dev/null 2>&1 || true
  done
  rm -rf "$FIXTURE_DIRECTORY"
}
trap cleanup EXIT HUP INT TERM

docker image inspect "$RUNTIME_IMAGE" >/dev/null 2>&1 || {
  echo "Backup smoke helper image is not available locally: $RUNTIME_IMAGE" >&2
  echo "Run the full-stack smoke first or pull it explicitly." >&2
  exit 1
}

INSTALL_DIRECTORY=$FIXTURE_DIRECTORY/installation
BACKUP_DIRECTORY=$FIXTURE_DIRECTORY/backups
mkdir -p "$INSTALL_DIRECTORY/config" "$INSTALL_DIRECTORY/secrets" "$BACKUP_DIRECTORY"
chmod 0700 "$INSTALL_DIRECTORY/secrets" "$BACKUP_DIRECTORY"

cp "$ROOT/releases/v0.1.0-candidate.19.json" \
  "$INSTALL_DIRECTORY/release-manifest.json"
for metadata_name in compose.yml compose.private.yml compose.domain.yml Caddyfile; do
  printf 'fixture: %s\n' "$metadata_name" > "$INSTALL_DIRECTORY/$metadata_name"
done
printf '0.1.0-candidate.19\n' > "$INSTALL_DIRECTORY/VERSION"
printf 'private\n' > "$INSTALL_DIRECTORY/config/access-mode"
printf 'SLAB_PUBLIC_URL=http://127.0.0.1:3009\n' \
  > "$INSTALL_DIRECTORY/config/install.env"
printf '{"schemaVersion":1,"projectName":"%s","status":"READY"}\n' \
  "$PROJECT_NAME" > "$INSTALL_DIRECTORY/config/install-state.json"
for secret_name in \
  work-api-key docs-api-key runner-token email-admin-key email-master-key session-secret
do
  printf 'original-%s\n' "$secret_name" > "$INSTALL_DIRECTORY/secrets/$secret_name"
  chmod 0444 "$INSTALL_DIRECTORY/secrets/$secret_name"
done

for logical_name in $VOLUMES; do
  docker volume create \
    --label "com.docker.compose.project=$PROJECT_NAME" \
    --label "com.docker.compose.volume=$logical_name" \
    "${PROJECT_NAME}_${logical_name}" >/dev/null
  docker run --rm --user 0 --entrypoint sh \
    --mount "type=volume,src=${PROJECT_NAME}_${logical_name},dst=/data" \
    "$RUNTIME_IMAGE" -c \
    'printf "%s\n" "$1" > "/data/$2"' fixture "$logical_name-original" "$logical_name.txt"
done
docker run --rm --user 0 --entrypoint chown \
  --mount "type=volume,src=${PROJECT_NAME}_agents_data,dst=/data" \
  "$RUNTIME_IMAGE" 10001:10001 /data
docker run --rm --user 10001 --entrypoint /app/node_modules/.bin/knex \
  --mount "type=volume,src=${PROJECT_NAME}_agents_data,dst=/data" \
  -e SLAB_WORKSPACE_DB=/data/slab-workspace.db \
  "$RUNTIME_IMAGE" --knexfile /app/knexfile.cjs migrate:latest >/dev/null

# shellcheck source=installer/lib/backup.sh
. "$ROOT/installer/lib/backup.sh"

slabctl_error() {
  echo "slabctl: $*" >&2
  return 1
}

slabctl_compose() {
  case "$*" in
    'config --volumes')
      for logical_name in $VOLUMES; do
        printf '%s\n' "$logical_name"
      done
      ;;
    'ps --status running -q') return 0 ;;
    *) echo "Unexpected Compose smoke call: $*" >&2; return 1 ;;
  esac
}

slabctl_stack_start() { return 0; }
slabctl_wait_for_healthy_stack() { return 0; }

SLABCTL_INSTALL_DIRECTORY=$INSTALL_DIRECTORY
SLABCTL_PROJECT_NAME=$PROJECT_NAME
SLABCTL_ACCESS_MODE=private
SLABCTL_BACKUP_RUNTIME_IMAGE=$RUNTIME_IMAGE
export SLABCTL_INSTALL_DIRECTORY SLABCTL_PROJECT_NAME SLABCTL_ACCESS_MODE \
  SLABCTL_BACKUP_RUNTIME_IMAGE

slabctl_backup_create "$BACKUP_DIRECTORY"
ARCHIVE=$(find "$BACKUP_DIRECTORY" -maxdepth 1 -name 'slab-backup-*.tar.gz' -print -quit)
[ -n "$ARCHIVE" ]
slabctl_backup_verify "$ARCHIVE" >/dev/null
tar -xOzf "$ARCHIVE" manifest.json | jq -e '
  .volumes[] |
  select(.logicalName == "agents_data") |
  .schema.kind == "sqlite" and
  .schema.migrationCount > 0 and
  (.schema.latestMigration | type == "string")
' >/dev/null
slabctl_restore_archive "$ARCHIVE" 1 0 >/dev/null

docker run --rm --user 0 --entrypoint sh \
  --mount "type=volume,src=${PROJECT_NAME}_agents_data,dst=/data" \
  "$RUNTIME_IMAGE" -c 'printf "changed\n" > /data/agents_data.txt'
chmod 0644 "$INSTALL_DIRECTORY/secrets/session-secret"
printf 'changed-secret\n' > "$INSTALL_DIRECTORY/secrets/session-secret"
chmod 0444 "$INSTALL_DIRECTORY/secrets/session-secret"

slabctl_restore_archive "$ARCHIVE" 0 1 >/dev/null

restored_value=$(docker run --rm --user 0 --entrypoint sh \
  --mount "type=volume,src=${PROJECT_NAME}_agents_data,dst=/data,readonly" \
  "$RUNTIME_IMAGE" -c 'cat /data/agents_data.txt')
[ "$restored_value" = agents_data-original ]
[ "$(sed -n '1p' "$INSTALL_DIRECTORY/secrets/session-secret")" = original-session-secret ]
jq -e '.status == "RESTORED"' \
  "$INSTALL_DIRECTORY/config/restore-state.json" >/dev/null

echo "Backup/restore smoke passed: $PROJECT_NAME"
