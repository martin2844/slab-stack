#!/bin/sh

SLABCTL_BACKUP_FORMAT=slab-backup-v2
SLABCTL_BACKUP_LEGACY_FORMAT=slab-backup-v1

slabctl_backup_required_files() {
  cat <<'EOF'
metadata/Caddyfile
metadata/VERSION
metadata/compose.domain.yml
metadata/compose.private.yml
metadata/compose.yml
metadata/config-access-mode
metadata/config-install-state.json
metadata/config-install.env
metadata/release-manifest.json
secrets/docs-api-key
secrets/email-admin-key
secrets/email-master-key
secrets/runner-token
secrets/session-secret
secrets/work-api-key
EOF
}

slabctl_backup_runtime_image() {
  if [ -n "${SLABCTL_BACKUP_RUNTIME_IMAGE:-}" ]; then
    printf '%s\n' "$SLABCTL_BACKUP_RUNTIME_IMAGE"
    return 0
  fi
  jq -er '.images.agents.ref + "@" + .images.agents.digest' \
    "$SLABCTL_INSTALL_DIRECTORY/release-manifest.json"
}

slabctl_backup_destination() {
  requested_destination=${1:-/var/backups/slab}
  encrypted=${2:-0}
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  stack_version=$(sed -n '1p' "$SLABCTL_INSTALL_DIRECTORY/VERSION")
  archive_name=slab-backup-$stack_version-$timestamp.tar.gz
  [ "$encrypted" -eq 0 ] || archive_name=$archive_name.age

  case "$requested_destination" in
    *.tar.gz | *.tar.gz.age)
      destination=$requested_destination
      if [ "$encrypted" -eq 1 ]; then
        case "$destination" in *.age) ;; *) destination=$destination.age ;; esac
      else
        case "$destination" in
          *.age)
            slabctl_error "an .age destination requires --encrypt-with"
            return 1
            ;;
        esac
      fi
      destination_directory=$(dirname -- "$destination")
      ;;
    *)
      destination_directory=$requested_destination
      destination=$destination_directory/$archive_name
      ;;
  esac

  [ ! -L "$destination_directory" ] || {
    slabctl_error "backup destination directory cannot be a symbolic link"
    return 1
  }
  mkdir -p "$destination_directory"
  [ -d "$destination_directory" ] || {
    slabctl_error "backup destination is not a directory: $destination_directory"
    return 1
  }
  destination_basename=$(basename -- "$destination")
  destination_directory=$(CDPATH='' cd -- "$destination_directory" && pwd) || return 1
  destination=$destination_directory/$destination_basename
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    slabctl_error "backup archive already exists: $destination"
    return 1
  fi
  printf '%s\n' "$destination"
}

slabctl_validate_age_identity() {
  identity_file=$1
  if [ ! -f "$identity_file" ] || [ -L "$identity_file" ]; then
    slabctl_error "age identity must be a regular non-symbolic-link file"
    return 1
  fi
  expected_uid=${SLABCTL_EXPECTED_OWNER_UID:-0}
  [ "$(stat -c '%u' "$identity_file")" -eq "$expected_uid" ] || {
    slabctl_error "age identity has an unexpected owner"
    return 1
  }
  identity_mode=$(stat -c '%a' "$identity_file")
  case "$identity_mode" in
    ?00 | ??00) ;;
    *)
      slabctl_error "age identity must not be accessible by group or other users"
      return 1
      ;;
  esac
}

slabctl_require_age() {
  if ! command -v age >/dev/null 2>&1 ||
    ! command -v age-keygen >/dev/null 2>&1
  then
    slabctl_error "encrypted backups require the age and age-keygen commands"
    return 1
  fi
}

slabctl_archive_is_age_encrypted() {
  [ "$(head -n 1 "$1" 2>/dev/null || true)" = age-encryption.org/v1 ]
}

slabctl_volume_names() {
  slabctl_compose config --volumes | LC_ALL=C sort -u
}

slabctl_volume_scope() {
  case "$1" in
    caddy_data | caddy_config) printf '%s\n' infrastructure ;;
    *) printf '%s\n' product ;;
  esac
}

slabctl_product_volume_names() {
  for logical_name in $(slabctl_volume_names); do
    [ "$(slabctl_volume_scope "$logical_name")" = product ] || continue
    printf '%s\n' "$logical_name"
  done | LC_ALL=C sort -u
}

slabctl_expected_migrations() {
  logical_name=$1
  jq -cer --arg logicalName "$logical_name" '
    .dataCompatibility.volumes[$logicalName].migrations |
    select(type == "array") |
    map(tostring)
  ' "$SLABCTL_INSTALL_DIRECTORY/release-manifest.json"
}

slabctl_resolve_volume() {
  logical_name=$1
  case "$logical_name" in
    '' | *[!a-zA-Z0-9_.-]*)
      slabctl_error "unsafe Compose volume name: $logical_name"
      return 1
      ;;
  esac

  matches=$(docker volume ls -q \
    --filter "label=com.docker.compose.project=$SLABCTL_PROJECT_NAME" \
    --filter "label=com.docker.compose.volume=$logical_name") || return 1
  match_count=$(printf '%s\n' "$matches" | awk 'NF { count += 1 } END { print count + 0 }')
  if [ "$match_count" -eq 1 ]; then
    printf '%s\n' "$matches"
    return 0
  fi
  [ "$match_count" -eq 0 ] || {
    slabctl_error "expected one Docker volume for $logical_name, found $match_count"
    return 1
  }

  legacy_volume=${SLABCTL_PROJECT_NAME}_$logical_name
  if docker volume inspect "$legacy_volume" >/dev/null 2>&1; then
    printf '%s\n' "$legacy_volume"
    return 0
  fi
  slabctl_error "expected one Docker volume for $logical_name, found 0"
  return 1
}

slabctl_database_schema() {
  logical_name=$1
  docker_volume=$2
  case "$logical_name" in
    agents_data) image_key=agents; database_path=/data/slab-workspace.db ;;
    work_data) image_key=work; database_path=/data/slab.db ;;
    docs_data) image_key=docs; database_path=/data/slab-docs.db ;;
    email_data) image_key=email; database_path=/data/slab-email.db ;;
    *)
      printf '%s\n' '{"kind":"opaque","migrationCount":null,"latestMigration":null,"userVersion":null}'
      return 0
      ;;
  esac

  expected_migrations=$(slabctl_expected_migrations "$logical_name") || {
    slabctl_error "release manifest has no data compatibility contract for $logical_name"
    return 1
  }
  image=$(jq -er --arg key "$image_key" \
    '.images[$key].ref + "@" + .images[$key].digest' \
    "$SLABCTL_INSTALL_DIRECTORY/release-manifest.json") || return 1
  # SQLite may need to update WAL/SHM coordination files even when the database
  # connection itself is read-only. Services are stopped before this probe.
  docker run --rm --user 0 --entrypoint node \
    --mount "type=volume,src=$docker_volume,dst=/data" \
    "$image" -e '
      const Database = require("better-sqlite3");
      const database = new Database(process.argv[1], {
        readonly: true,
        fileMustExist: true,
      });
      const logicalName = process.argv[2];
      const expectedMigrations = JSON.parse(process.argv[3]);
      const migrationQueries = {
        agents_data: "SELECT name AS migration FROM knex_migrations ORDER BY id",
        work_data: "SELECT id AS migration FROM migrations ORDER BY id",
        docs_data: "SELECT version AS migration FROM schema_migrations ORDER BY version",
        email_data: "SELECT version AS migration FROM schema_migrations ORDER BY version",
      };
      let migrations = [];
      try {
        migrations = database
          .prepare(migrationQueries[logicalName])
          .all()
          .map((row) => String(row.migration));
      } catch (error) {
        if (!String(error.message).includes("no such table")) throw error;
      }
      process.stdout.write(JSON.stringify({
        kind: "sqlite",
        migrationCount: migrations.length,
        latestMigration: migrations.at(-1) ?? null,
        appliedMigrations: migrations,
        expectedMigrations,
        matchesRelease: JSON.stringify(migrations) === JSON.stringify(expectedMigrations),
        userVersion: database.pragma("user_version", { simple: true }),
      }));
      database.close();
    ' "$database_path" "$logical_name" "$expected_migrations"
}

slabctl_external_auth_metadata() {
  docker_volume=$1
  image=$(jq -er '.images.email.ref + "@" + .images.email.digest' \
    "$SLABCTL_INSTALL_DIRECTORY/release-manifest.json") || return 1
  docker run --rm --user 0 --entrypoint node \
    --mount "type=volume,src=$docker_volume,dst=/data" \
    "$image" -e '
      const Database = require("better-sqlite3");
      const database = new Database("/data/slab-email.db", {
        readonly: true,
        fileMustExist: true,
      });
      let configuredAccounts = 0;
      try {
        configuredAccounts = Number(database.prepare(
          "SELECT COUNT(*) AS count FROM email_accounts WHERE provider = ?"
        ).get("proton_bridge").count);
      } catch (error) {
        if (!String(error.message).includes("no such table")) throw error;
      }
      const metadata = configuredAccounts > 0 ? [{
        provider: "proton_bridge",
        configuredAccounts,
        portability: "reauthentication_required",
      }] : [];
      process.stdout.write(JSON.stringify(metadata));
      database.close();
    '
}

slabctl_schema_matches_release() {
  schema=$1
  [ "$(printf '%s\n' "$schema" | jq -r '.kind')" != sqlite ] ||
    printf '%s\n' "$schema" | jq -e '.matchesRelease == true' >/dev/null
}

slabctl_copy_backup_file() {
  source_path=$1
  archive_path=$2
  stage_directory=$3
  if [ ! -f "$source_path" ] || [ -L "$source_path" ]; then
    slabctl_error "backup source is missing or unsafe: $source_path"
    return 1
  fi
  target_path=$stage_directory/$archive_path
  mkdir -p "$(dirname -- "$target_path")"
  install -m 0600 "$source_path" "$target_path"
}

slabctl_record_backup_file() {
  stage_directory=$1
  archive_path=$2
  output_file=$3
  checksum=$(sha256sum "$stage_directory/$archive_path" | awk '{print $1}') || return 1
  bytes=$(stat -c '%s' "$stage_directory/$archive_path") || return 1
  jq -nc --arg path "$archive_path" --arg sha256 "$checksum" \
    --argjson bytes "$bytes" '{path:$path,sha256:$sha256,bytes:$bytes}' \
    >> "$output_file"
}

slabctl_archive_volume() (
  runtime_image=$1
  docker_volume=$2
  stage_directory=$3
  archive_path=$4
  docker run --rm --user 0 --entrypoint tar \
    --mount "type=volume,src=$docker_volume,dst=/source,readonly" \
    --mount "type=bind,src=$stage_directory,dst=/backup" \
    "$runtime_image" -C /source -czf "/backup/$archive_path" .
)

slabctl_write_backup_state() {
  archive=$1
  archive_sha256=$2
  verified_at=$3
  state_path=$SLABCTL_INSTALL_DIRECTORY/config/backup-state.json
  temporary_state=$SLABCTL_INSTALL_DIRECTORY/config/.backup-state.$$
  jq -n --arg archive "$archive" --arg sha256 "$archive_sha256" \
    --arg verifiedAt "$verified_at" \
    '{schemaVersion:1,lastSuccessfulBackup:{archive:$archive,sha256:$sha256,verifiedAt:$verifiedAt}}' \
    > "$temporary_state"
  chmod 0600 "$temporary_state"
  mv "$temporary_state" "$state_path"
}

slabctl_backup_create() (
  umask 077
  requested_destination=${1:-}
  encryption_identity=${2:-}
  encrypted=0
  if [ -n "$encryption_identity" ]; then
    encrypted=1
    slabctl_require_age || exit 1
    slabctl_validate_age_identity "$encryption_identity" || exit 1
  fi
  destination=$(slabctl_backup_destination "$requested_destination" "$encrypted") || exit 1
  destination_directory=$(dirname -- "$destination")
  stage_directory=$(mktemp -d "$destination_directory/.slab-backup.XXXXXX") || exit 1
  chmod 0700 "$stage_directory"
  partial_archive=$stage_directory/final-archive
  was_running=0

  # shellcheck disable=SC2317
  cleanup_backup() {
    cleanup_status=$?
    rm -rf "$stage_directory"
    if [ "$was_running" -eq 1 ]; then
      if ! slabctl_stack_start >/dev/null 2>&1; then
        echo "slabctl: backup finished with the stack stopped; run 'sudo slabctl stack start'" >&2
        [ "$cleanup_status" -ne 0 ] || cleanup_status=1
      fi
    fi
    exit "$cleanup_status"
  }
  trap cleanup_backup EXIT
  trap 'exit 130' HUP INT TERM

  mkdir -p "$stage_directory/metadata" "$stage_directory/secrets" \
    "$stage_directory/volumes"
  chmod 0700 "$stage_directory/metadata" "$stage_directory/secrets" \
    "$stage_directory/volumes"

  for metadata_name in \
    release-manifest.json VERSION compose.yml compose.private.yml \
    compose.domain.yml Caddyfile
  do
    slabctl_copy_backup_file \
      "$SLABCTL_INSTALL_DIRECTORY/$metadata_name" \
      "metadata/$metadata_name" "$stage_directory" || exit 1
  done
  for config_name in access-mode install.env install-state.json; do
    slabctl_copy_backup_file \
      "$SLABCTL_INSTALL_DIRECTORY/config/$config_name" \
      "metadata/config-$config_name" "$stage_directory" || exit 1
  done
  for secret_path in "$SLABCTL_INSTALL_DIRECTORY"/secrets/*; do
    [ -e "$secret_path" ] || continue
    secret_name=$(basename -- "$secret_path")
    slabctl_copy_backup_file "$secret_path" "secrets/$secret_name" \
      "$stage_directory" || exit 1
  done

  running_containers=$(slabctl_compose ps --status running -q 2>/dev/null) || {
    slabctl_error "could not inspect running services before backup"
    exit 1
  }
  if [ -n "$running_containers" ]; then
    was_running=1
    echo "Stopping Slab briefly for a consistent backup..."
    slabctl_compose stop >/dev/null || exit 1
  fi
  running_containers=$(slabctl_compose ps --status running -q 2>/dev/null) || {
    slabctl_error "could not verify that services stopped before backup"
    exit 1
  }
  [ -z "$running_containers" ] || {
    slabctl_error "could not stop every service for a consistent backup"
    exit 1
  }

  runtime_image=$(slabctl_backup_runtime_image) || exit 1
  files_jsonl=$stage_directory/files.jsonl
  volumes_jsonl=$stage_directory/volumes.jsonl
  external_auth_json=$stage_directory/external-auth.json
  : > "$files_jsonl"
  : > "$volumes_jsonl"
  printf '%s\n' '[]' > "$external_auth_json"

  for archive_path in $(
    cd "$stage_directory" &&
      find metadata secrets -type f -print | LC_ALL=C sort
  ); do
    slabctl_record_backup_file "$stage_directory" "$archive_path" \
      "$files_jsonl" || exit 1
  done

  for logical_name in $(slabctl_product_volume_names); do
    docker_volume=$(slabctl_resolve_volume "$logical_name") || exit 1
    volume_archive=volumes/$logical_name.tar.gz
    schema=$(slabctl_database_schema "$logical_name" "$docker_volume") || {
      slabctl_error "could not inspect schema metadata for $logical_name"
      exit 1
    }
    if ! slabctl_schema_matches_release "$schema"; then
      slabctl_error "database schema for $logical_name does not match the installed release manifest"
      exit 1
    fi
    if [ "$logical_name" = email_data ]; then
      slabctl_external_auth_metadata "$docker_volume" > "$external_auth_json" || {
        slabctl_error "could not inspect external authentication portability"
        exit 1
      }
    fi
    slabctl_archive_volume "$runtime_image" "$docker_volume" \
      "$stage_directory/volumes" "$logical_name.tar.gz" || exit 1
    checksum=$(sha256sum "$stage_directory/$volume_archive" | awk '{print $1}') || exit 1
    bytes=$(stat -c '%s' "$stage_directory/$volume_archive") || exit 1
    jq -nc --arg logicalName "$logical_name" \
      --arg dockerVolume "$docker_volume" --arg archivePath "$volume_archive" \
      --arg sha256 "$checksum" --argjson bytes "$bytes" \
      --arg scope product --argjson schema "$schema" \
      '{logicalName:$logicalName,scope:$scope,dockerVolume:$dockerVolume,archivePath:$archivePath,sha256:$sha256,bytes:$bytes,schema:$schema}' \
      >> "$volumes_jsonl"
  done

  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  stack_version=$(sed -n '1p' "$SLABCTL_INSTALL_DIRECTORY/VERSION")
  access_mode=$(sed -n '1p' "$SLABCTL_INSTALL_DIRECTORY/config/access-mode")
  jq -n \
    --arg format "$SLABCTL_BACKUP_FORMAT" \
    --arg createdAt "$created_at" \
    --arg stackVersion "$stack_version" \
    --arg projectName "$SLABCTL_PROJECT_NAME" \
    --arg accessMode "$access_mode" \
    --slurpfile release "$SLABCTL_INSTALL_DIRECTORY/release-manifest.json" \
    --slurpfile files "$files_jsonl" \
    --slurpfile volumes "$volumes_jsonl" \
    --slurpfile externalAuth "$external_auth_json" \
    '{schemaVersion:2,format:$format,createdAt:$createdAt,stackVersion:$stackVersion,source:{projectName:$projectName,accessMode:$accessMode},images:$release[0].images,files:$files,volumes:$volumes,externalAuth:$externalAuth[0]}' \
    > "$stage_directory/manifest.json" || exit 1
  chmod 0600 "$stage_directory/manifest.json"

  plain_archive=$partial_archive
  [ "$encrypted" -eq 0 ] || plain_archive=$stage_directory/backup.tar.gz
  (
    cd "$stage_directory"
    {
      echo manifest.json
      jq -r '.files[].path, .volumes[].archivePath' manifest.json | LC_ALL=C sort
    } > archive-members.txt
    tar -czf "$plain_archive" -T archive-members.txt
  ) || exit 1
  chmod 0600 "$plain_archive"
  slabctl_backup_verify "$plain_archive" >/dev/null || exit 1
  if [ "$encrypted" -eq 1 ]; then
    recipient=$(age-keygen -y "$encryption_identity") || exit 1
    age --encrypt --recipient "$recipient" --output "$partial_archive" \
      "$plain_archive" || exit 1
    chmod 0600 "$partial_archive"
    slabctl_backup_verify "$partial_archive" "$encryption_identity" \
      >/dev/null || exit 1
  fi
  mv "$partial_archive" "$destination"
  archive_sha256=$(sha256sum "$destination" | awk '{print $1}') || exit 1
  slabctl_write_backup_state "$destination" "$archive_sha256" "$created_at" || exit 1

  if [ "$was_running" -eq 1 ]; then
    slabctl_stack_start >/dev/null || exit 1
    was_running=0
  fi
  trap - EXIT HUP INT TERM
  rm -rf "$stage_directory"
  echo "Backup created and verified: $destination"
  echo "SHA-256: $archive_sha256"
)

slabctl_backup_validate_manifest() {
  manifest_path=$1
  required_files=$(slabctl_backup_required_files)
  jq -e --arg format "$SLABCTL_BACKUP_FORMAT" \
    --arg legacyFormat "$SLABCTL_BACKUP_LEGACY_FORMAT" \
    --arg requiredFiles "$required_files" '
    . as $manifest |
    ((.schemaVersion == 1 and .format == $legacyFormat) or
      (.schemaVersion == 2 and .format == $format)) and
    (.createdAt | type == "string" and length > 0) and
    (.stackVersion | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")) and
    (.source.projectName | type == "string" and length > 0) and
    (.source.accessMode | IN("private", "domain")) and
    (.images | type == "object") and
    (.files | type == "array") and
    (([.files[].path] | sort) == ($requiredFiles | split("\n") | sort)) and
    (.volumes | type == "array" and length > 0) and
    ([.volumes[].logicalName] | length == (unique | length)) and
    ([.files[].path, .volumes[].archivePath] | length == (unique | length)) and
    ([.files[] |
      (.path | test("^(metadata|secrets)/[A-Za-z0-9._-]+$")) and
      (.sha256 | test("^[a-f0-9]{64}$")) and
      (.bytes | type == "number" and . >= 0)] | all) and
    ([.volumes[] |
      (.logicalName | test("^[A-Za-z0-9_.-]+$")) and
      (.dockerVolume | type == "string" and length > 0) and
      (.archivePath | test("^volumes/[A-Za-z0-9_.-]+\\.tar\\.gz$")) and
      (.sha256 | test("^[a-f0-9]{64}$")) and
      (.bytes | type == "number" and . >= 0) and
      (.schema | type == "object") and
      (if $manifest.schemaVersion == 2 then
        .scope == "product" and
        (if .schema.kind == "sqlite" then
          (.logicalName | IN("agents_data", "work_data", "docs_data", "email_data")) and
          (.schema.appliedMigrations | type == "array" and all(type == "string")) and
          (.schema.expectedMigrations | type == "array" and all(type == "string")) and
          .schema.appliedMigrations == .schema.expectedMigrations and
          .schema.matchesRelease == true
        else .schema.kind == "opaque" end)
      else true end)] | all) and
    (if .schemaVersion == 2 then
      (.externalAuth | type == "array") and
      ([.externalAuth[] |
        .provider == "proton_bridge" and
        (.configuredAccounts | type == "number" and . >= 1) and
        .portability == "reauthentication_required"] | all)
    else true end)
  ' "$manifest_path" >/dev/null 2>&1
}

slabctl_backup_extract_verified() {
  archive=$1
  output_directory=$2
  identity_file=${3:-}
  if [ ! -f "$archive" ] || [ -L "$archive" ]; then
    slabctl_error "backup archive is missing or unsafe: $archive"
    return 1
  fi
  [ -s "$archive" ] || {
    slabctl_error "backup archive is empty: $archive"
    return 1
  }
  mkdir -p "$output_directory"
  chmod 0700 "$output_directory"

  source_archive=$archive
  if slabctl_archive_is_age_encrypted "$archive"; then
    [ -n "$identity_file" ] || {
      slabctl_error "encrypted backup requires --identity FILE"
      return 1
    }
    slabctl_require_age || return 1
    slabctl_validate_age_identity "$identity_file" || return 1
    source_archive=$output_directory/decrypted-backup.tar.gz
    age --decrypt --identity "$identity_file" --output "$source_archive" \
      "$archive" >/dev/null || {
      slabctl_error "backup decryption failed"
      return 1
    }
    chmod 0600 "$source_archive"
  fi

  manifest_path=$output_directory/manifest.json
  tar -xOzf "$source_archive" manifest.json > "$manifest_path" 2>/dev/null || {
    slabctl_error "backup has no readable manifest.json"
    return 1
  }
  chmod 0600 "$manifest_path"
  slabctl_backup_validate_manifest "$manifest_path" || {
    slabctl_error "backup manifest is invalid or unsupported"
    return 1
  }

  actual_members=$output_directory/actual-members.txt
  expected_members=$output_directory/expected-members.txt
  tar -tzf "$source_archive" | LC_ALL=C sort > "$actual_members" || return 1
  {
    echo manifest.json
    jq -r '.files[].path, .volumes[].archivePath' "$manifest_path"
  } | LC_ALL=C sort > "$expected_members"
  cmp -s "$actual_members" "$expected_members" || {
    slabctl_error "backup archive members do not match its manifest"
    return 1
  }
  tar -tvzf "$source_archive" | awk '$1 !~ /^-/ { exit 1 }' || {
    slabctl_error "backup archive contains unsupported entry types"
    return 1
  }
  tar -xzf "$source_archive" --no-same-owner --no-same-permissions \
    -C "$output_directory" || return 1

  checksum_rows=$output_directory/checksums.tsv
  jq -r '.files[], .volumes[] | [.sha256, (.path // .archivePath), (.bytes|tostring)] | @tsv' \
    "$manifest_path" > "$checksum_rows"
  tab=$(printf '\t')
  while IFS="$tab" read -r expected_sha archive_path expected_bytes; do
    payload_path=$output_directory/$archive_path
    if [ ! -f "$payload_path" ] || [ -L "$payload_path" ]; then
      slabctl_error "backup payload is missing or unsafe: $archive_path"
      return 1
    fi
    actual_sha=$(sha256sum "$payload_path" | awk '{print $1}') || return 1
    actual_bytes=$(stat -c '%s' "$payload_path") || return 1
    if [ "$actual_sha" != "$expected_sha" ] || [ "$actual_bytes" != "$expected_bytes" ]; then
      slabctl_error "backup payload checksum mismatch: $archive_path"
      return 1
    fi
  done < "$checksum_rows"

  for volume_archive in "$output_directory"/volumes/*.tar.gz; do
    tar -tzf "$volume_archive" >/dev/null || {
      slabctl_error "volume payload is not a readable tar archive: $(basename -- "$volume_archive")"
      return 1
    }
    if tar -tzf "$volume_archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
      slabctl_error "volume payload contains an unsafe path: $(basename -- "$volume_archive")"
      return 1
    fi
  done
}

slabctl_backup_verify() (
  archive=$1
  identity_file=${2:-}
  temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/slab-backup-verify.XXXXXX") || exit 1
  trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
  slabctl_backup_extract_verified "$archive" "$temporary_directory" \
    "$identity_file" || exit 1
  jq -r '
    "Backup verified: " + .stackVersion,
    "Created: " + .createdAt,
    "Volumes: " + (.volumes | length | tostring),
    "Payload bytes: " + ([.files[].bytes, .volumes[].bytes] | add | tostring)
  ' "$temporary_directory/manifest.json"
)

slabctl_restore_archive_product_volumes() {
  manifest_path=$1
  jq -r '
    .volumes[] |
    select((.scope // (if (.logicalName | startswith("caddy_")) then "infrastructure" else "product" end)) == "product") |
    .logicalName
  ' "$manifest_path" | LC_ALL=C sort -u
}

slabctl_restore_schema_compatible() {
  manifest_path=$1
  backup_version=$2
  installed_version=$3
  schema_version=$(jq -r '.schemaVersion' "$manifest_path")
  if [ "$schema_version" -eq 1 ]; then
    [ "$backup_version" = "$installed_version" ] || {
      slabctl_error "legacy backup stack version $backup_version is not compatible with installed version $installed_version"
      return 1
    }
    return 0
  fi

  tab=$(printf '\t')
  while IFS="$tab" read -r logical_name applied_migrations; do
    [ -n "$logical_name" ] || continue
    target_migrations=$(slabctl_expected_migrations "$logical_name") || {
      slabctl_error "installed release has no data compatibility contract for $logical_name"
      return 1
    }
    if ! jq -en --argjson applied "$applied_migrations" \
      --argjson target "$target_migrations" '
        ($applied | length) <= ($target | length) and
        $target[0:($applied | length)] == $applied
      ' >/dev/null
    then
      slabctl_error "backup database schema for $logical_name is not supported by installed version $installed_version"
      return 1
    fi
  done <<EOF
$(jq -r '.volumes[] | select(.schema.kind == "sqlite") | [.logicalName, (.schema.appliedMigrations | @json)] | @tsv' "$manifest_path")
EOF
}

slabctl_restore_write_state() {
  status=$1
  archive_sha256=$2
  message=$3
  reauthentication_required=${4:-[]}
  state_path=$SLABCTL_INSTALL_DIRECTORY/config/restore-state.json
  temporary_state=$SLABCTL_INSTALL_DIRECTORY/config/.restore-state.$$
  jq -n --arg status "$status" --arg archiveSha256 "$archive_sha256" \
    --arg message "$message" --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson reauthenticationRequired "$reauthentication_required" \
    '{schemaVersion:1,status:$status,archiveSha256:$archiveSha256,updatedAt:$updatedAt,message:$message,reauthenticationRequired:$reauthenticationRequired}' \
    > "$temporary_state"
  chmod 0600 "$temporary_state"
  mv "$temporary_state" "$state_path"
}

slabctl_restore_archive() (
  archive=$1
  dry_run=${2:-0}
  confirmed=${3:-0}
  identity_file=${4:-}
  temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/slab-restore.XXXXXX") || exit 1
  trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
  slabctl_backup_extract_verified "$archive" "$temporary_directory" \
    "$identity_file" || exit 1

  backup_version=$(jq -r '.stackVersion' "$temporary_directory/manifest.json")
  installed_version=$(sed -n '1p' "$SLABCTL_INSTALL_DIRECTORY/VERSION")
  slabctl_restore_schema_compatible "$temporary_directory/manifest.json" \
    "$backup_version" "$installed_version" || exit 1

  archive_volumes=$temporary_directory/archive-volumes.txt
  current_volumes=$temporary_directory/current-volumes.txt
  slabctl_restore_archive_product_volumes "$temporary_directory/manifest.json" \
    > "$archive_volumes"
  slabctl_product_volume_names > "$current_volumes"
  cmp -s "$archive_volumes" "$current_volumes" || {
    slabctl_error "backup product volume set does not match this installation"
    exit 1
  }
  while IFS= read -r logical_name; do
    slabctl_resolve_volume "$logical_name" >/dev/null || exit 1
  done < "$current_volumes"

  if [ "$dry_run" -eq 1 ]; then
    echo "Restore dry run passed."
    echo "Backup stack version: $backup_version"
    echo "Installed stack version: $installed_version"
    echo "Volumes: $(wc -l < "$current_volumes" | tr -d ' ')"
    echo "No data was changed."
    exit 0
  fi

  running_containers=$(slabctl_compose ps --status running -q 2>/dev/null) || {
    slabctl_error "could not inspect running services before restore"
    exit 1
  }
  [ -z "$running_containers" ] || {
    slabctl_error "restore requires a stopped stack; run 'sudo slabctl stack stop' first"
    exit 1
  }
  if [ "$confirmed" -ne 1 ]; then
    [ -r /dev/tty ] || {
      slabctl_error "restore requires interactive confirmation or --yes"
      exit 1
    }
    printf 'Type RESTORE to replace all workspace data: ' > /dev/tty
    IFS= read -r confirmation < /dev/tty
    [ "$confirmation" = RESTORE ] || {
      slabctl_error "restore cancelled"
      exit 1
    }
  fi

  archive_sha256=$(sha256sum "$archive" | awk '{print $1}') || exit 1
  reauthentication_required=$(jq -c '[.externalAuth[]? | select(.portability == "reauthentication_required")]' \
    "$temporary_directory/manifest.json") || exit 1
  slabctl_restore_write_state RESTORING "$archive_sha256" \
    "Replacing workspace volumes from a verified backup." \
    "$reauthentication_required" || exit 1
  runtime_image=$(slabctl_backup_runtime_image) || exit 1

  restore_failed=0
  tab=$(printf '\t')
  while IFS="$tab" read -r logical_name archive_path; do
    docker_volume=$(slabctl_resolve_volume "$logical_name") || {
      restore_failed=1
      break
    }
    if ! docker run --rm --user 0 --entrypoint sh \
      --mount "type=volume,src=$docker_volume,dst=/target" \
      --mount "type=bind,src=$temporary_directory,dst=/backup,readonly" \
      "$runtime_image" -c \
      'find /target -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && tar -xzf "/backup/$1" -C /target' \
      restore-volume "$archive_path"
    then
      restore_failed=1
      break
    fi
  done <<EOF
$(jq -r '.volumes[] | select((.scope // (if (.logicalName | startswith("caddy_")) then "infrastructure" else "product" end)) == "product") | [.logicalName,.archivePath] | @tsv' "$temporary_directory/manifest.json")
EOF

  if [ "$restore_failed" -eq 0 ]; then
    for restored_secret in "$temporary_directory"/secrets/*; do
      secret_name=$(basename -- "$restored_secret")
      target_secret=$SLABCTL_INSTALL_DIRECTORY/secrets/$secret_name
      temporary_secret=$SLABCTL_INSTALL_DIRECTORY/secrets/.$secret_name.restore.$$
      if ! install -m 0444 "$restored_secret" "$temporary_secret" ||
        ! mv "$temporary_secret" "$target_secret"
      then
        rm -f "$temporary_secret"
        restore_failed=1
        break
      fi
    done
  fi

  if [ "$restore_failed" -ne 0 ]; then
    slabctl_restore_write_state RECOVERY_REQUIRED "$archive_sha256" \
      "Restore stopped after workspace mutation; rerun the same verified restore before starting Slab." \
      "$reauthentication_required" || true
    slabctl_error "restore did not finish; the stack remains stopped and requires recovery"
    exit 1
  fi

  if ! slabctl_stack_start || ! slabctl_wait_for_healthy_stack; then
    if slabctl_stack_stop >/dev/null 2>&1 &&
      running_containers=$(slabctl_compose ps --status running -q 2>/dev/null) &&
      [ -z "$running_containers" ]
    then
      restore_message="Data was restored, but services did not reach health after migrations. The stack is stopped."
    else
      restore_message="Data was restored, but services did not reach health after migrations and running services could not be ruled out. Stop the stack before recovery."
    fi
    slabctl_restore_write_state RECOVERY_REQUIRED "$archive_sha256" \
      "$restore_message" "$reauthentication_required" || true
    slabctl_error "data restored but services are not healthy; recovery is required"
    exit 1
  fi
  if command -v slabctl_update_exit_maintenance >/dev/null 2>&1 &&
    ! slabctl_update_exit_maintenance
  then
    slabctl_restore_write_state RECOVERY_REQUIRED "$archive_sha256" \
      "Data was restored and services are healthy, but agent dispatch remains in maintenance mode. Run: sudo slabctl update recover-maintenance" \
      "$reauthentication_required" || true
    slabctl_error "data restored, but agent dispatch maintenance could not be cleared"
    exit 1
  fi
  if ! slabctl_restore_write_state RESTORED "$archive_sha256" \
    "Backup restored and services reached health after migrations." \
    "$reauthentication_required"
  then
    if command -v slabctl_update_enter_maintenance >/dev/null 2>&1; then
      slabctl_update_enter_maintenance >/dev/null 2>&1 || true
    fi
    slabctl_error "restore succeeded, but its terminal state could not be persisted; agent dispatch was paused again"
    exit 1
  fi
  echo "Restore completed and verified: $archive"
  if [ "$(printf '%s\n' "$reauthentication_required" | jq 'length')" -gt 0 ]; then
    echo "External account action required:"
    printf '%s\n' "$reauthentication_required" | jq -r \
      '.[] | "- " + .provider + ": authenticate again on this host (" + (.configuredAccounts | tostring) + " configured account(s))"'
  fi
)
