#!/bin/sh
# shellcheck disable=SC2015,SC2154,SC2317

slabctl_doctor_sanitize_stream() {
  LC_ALL=C sed -E \
    -e 's/^([[:space:]]*((Proxy-)?Authorization|Cookie|Set-Cookie)[[:space:]]*:[[:space:]]*).*/\1[REDACTED]/Ig' \
    -e 's/("((Proxy-)?Authorization|Cookie|Set-Cookie)"[[:space:]]*:[[:space:]]*")[^"]*/\1[REDACTED]/Ig' \
    -e 's/((Proxy-)?Authorization[[:space:]]*:[[:space:]]*(Bearer|Basic)[[:space:]]+)[^,;[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/((Cookie|Set-Cookie)[[:space:]]*:[[:space:]]*).*/\1[REDACTED]/Ig' \
    -e 's#([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]]+@#\1[REDACTED]@#g' \
    -e 's/("[A-Za-z0-9_-]*(password|token|secret|api[_-]?key)[A-Za-z0-9_-]*"[[:space:]]*:[[:space:]]*")[^"]*/\1[REDACTED]/Ig' \
    -e 's/([A-Za-z0-9_-]*(password|token|secret|api[_-]?key)[A-Za-z0-9_-]*[=:][[:space:]]*)"[^"]*"/\1"[REDACTED]"/Ig' \
    -e "s/([A-Za-z0-9_-]*(password|token|secret|api[_-]?key)[A-Za-z0-9_-]*[=:][[:space:]]*)'[^']*'/\1'[REDACTED]'/Ig" \
    -e 's/([A-Za-z0-9_-]*(password|token|secret|api[_-]?key)[A-Za-z0-9_-]*[=:][[:space:]]*)[^,[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/[A-Za-z0-9_+\/-]{32,}={0,2}/[REDACTED]/g'
}

slabctl_doctor_append() {
  output=$1
  check_id=$2
  status=$3
  message=$4
  jq -nc --arg id "$check_id" --arg status "$status" --arg message "$message" \
    '{id:$id,status:$status,message:$message}' >> "$output"
}

slabctl_doctor_service_checks() {
  output=$1
  for service_name in slab-api slab-mcp slab-docs slab-email slab-runner slab-agents; do
    health=$(slabctl_service_health_status "$service_name" 2>/dev/null || true)
    if [ "$health" = healthy ]; then
      slabctl_doctor_append "$output" "service.$service_name" pass "healthy"
    else
      slabctl_doctor_append "$output" "service.$service_name" fail \
        "expected healthy, observed ${health:-missing}"
    fi
  done
  if [ "$SLABCTL_ACCESS_MODE" = domain ]; then
    health=$(slabctl_service_health_status caddy 2>/dev/null || true)
    case "$health" in
      running | healthy) slabctl_doctor_append "$output" service.caddy pass "$health" ;;
      *) slabctl_doctor_append "$output" service.caddy fail "expected running, observed ${health:-missing}" ;;
    esac
  fi
}

slabctl_doctor_schema_checks() {
  output=$1
  for logical_name in agents_data work_data docs_data email_data; do
    docker_volume=$(slabctl_resolve_volume "$logical_name" 2>/dev/null || true)
    if [ -z "$docker_volume" ]; then
      slabctl_doctor_append "$output" "database.$logical_name" fail \
        "managed volume is missing or ambiguous"
      continue
    fi
    schema=$(slabctl_database_schema "$logical_name" "$docker_volume" 2>/dev/null || true)
    if printf '%s' "$schema" | jq -e '.kind == "sqlite" and (.migrationCount | type == "number")' \
      >/dev/null 2>&1
    then
      migration_count=$(printf '%s' "$schema" | jq -r '.migrationCount')
      latest=$(printf '%s' "$schema" | jq -r '.latestMigration // "none"')
      slabctl_doctor_append "$output" "database.$logical_name" pass \
        "$migration_count migrations; latest $latest"
    else
      slabctl_doctor_append "$output" "database.$logical_name" fail \
        "schema metadata could not be read"
    fi
  done
}

slabctl_doctor_collect() {
  output=$1
  : > "$output"
  installed_version=$(sed -n '1p' "$SLABCTL_INSTALL_DIRECTORY/VERSION" 2>/dev/null || true)
  manifest_version=$(jq -r '.stackVersion // empty' \
    "$SLABCTL_INSTALL_DIRECTORY/release-manifest.json" 2>/dev/null || true)
  if [ -n "$installed_version" ] && [ "$installed_version" = "$manifest_version" ]; then
    slabctl_doctor_append "$output" release.identity pass "$installed_version"
  else
    slabctl_doctor_append "$output" release.identity fail \
      "VERSION and release manifest do not match"
  fi

  managed_ok=1
  for managed_file in "$SLABCTL_STATE_FILE" "$SLABCTL_ENVIRONMENT_FILE" \
    "$SLABCTL_INSTALL_DIRECTORY/release-manifest.json" \
    "$SLABCTL_INSTALL_DIRECTORY/VERSION"
  do
    slabctl_validate_managed_file "$managed_file" >/dev/null 2>&1 || managed_ok=0
  done
  if [ "$managed_ok" -eq 1 ]; then
    slabctl_doctor_append "$output" host.permissions pass \
      "managed metadata is root-owned and not writable by group/other"
  else
    slabctl_doctor_append "$output" host.permissions fail \
      "one or more managed files have unsafe ownership or mode"
  fi

  docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
  compose_version=$(docker compose version --short 2>/dev/null || true)
  if [ -n "$docker_version" ] && [ -n "$compose_version" ]; then
    slabctl_doctor_append "$output" host.docker pass \
      "Docker $docker_version; Compose $compose_version"
  else
    slabctl_doctor_append "$output" host.docker fail \
      "Docker Engine or Compose is unavailable"
  fi

  disk_use=$(df -P "$SLABCTL_INSTALL_DIRECTORY" 2>/dev/null | awk 'NR == 2 {gsub(/%/,"",$5); print $5}')
  inode_use=$(df -Pi "$SLABCTL_INSTALL_DIRECTORY" 2>/dev/null | awk 'NR == 2 {gsub(/%/,"",$5); print $5}')
  case "$disk_use:$inode_use" in
    *[!0-9:]* | :*)
      slabctl_doctor_append "$output" host.capacity warn \
        "disk or inode utilization could not be measured"
      ;;
    *)
      if [ "$disk_use" -ge 90 ] || [ "$inode_use" -ge 90 ]; then
        slabctl_doctor_append "$output" host.capacity fail \
          "disk ${disk_use}% used; inodes ${inode_use}% used"
      elif [ "$disk_use" -ge 80 ] || [ "$inode_use" -ge 80 ]; then
        slabctl_doctor_append "$output" host.capacity warn \
          "disk ${disk_use}% used; inodes ${inode_use}% used"
      else
        slabctl_doctor_append "$output" host.capacity pass \
          "disk ${disk_use}% used; inodes ${inode_use}% used"
      fi
      ;;
  esac

  slabctl_doctor_service_checks "$output"
  slabctl_doctor_schema_checks "$output"

  if slabctl_runner_codex_available >/dev/null 2>&1; then
    slabctl_doctor_append "$output" runtime.codex pass "available"
  else
    slabctl_doctor_append "$output" runtime.codex warn \
      "not authenticated or unavailable"
  fi

  backup_state=$SLABCTL_INSTALL_DIRECTORY/config/backup-state.json
  if [ -f "$backup_state" ] && [ ! -L "$backup_state" ]; then
    backup_archive=$(jq -r '.lastSuccessfulBackup.archive // empty' "$backup_state" 2>/dev/null || true)
    backup_verified=$(jq -r '.lastSuccessfulBackup.verifiedAt // empty' "$backup_state" 2>/dev/null || true)
    if [ -n "$backup_archive" ] && [ -f "$backup_archive" ] && [ -n "$backup_verified" ]; then
      slabctl_doctor_append "$output" backup.latest pass \
        "verified at $backup_verified; archive is present"
    else
      slabctl_doctor_append "$output" backup.latest warn \
        "backup state exists but its archive is unavailable"
    fi
  else
    slabctl_doctor_append "$output" backup.latest warn \
      "no successful backup is recorded"
  fi

  channel=$(jq -r '.channel // "stable"' \
    "$SLABCTL_INSTALL_DIRECTORY/release-manifest.json" 2>/dev/null || printf stable)
  if slabctl_release_prepare_channel "$channel" "$release_public_key_file" \
    >/dev/null 2>&1
  then
    slabctl_doctor_append "$output" update.channel pass \
      "signed $channel channel is reachable at $SLAB_RELEASE_VERSION"
  else
    slabctl_doctor_append "$output" update.channel warn \
      "signed $channel channel could not be verified"
  fi
  slabctl_release_cleanup

  public_url=$(jq -r '.publicUrl // empty' "$SLABCTL_STATE_FILE" 2>/dev/null || true)
  if [ -n "$public_url" ] && curl --proto '=https,http' --max-time 10 \
    --fail --silent --show-error "$public_url/health" >/dev/null 2>&1
  then
    slabctl_doctor_append "$output" access.endpoint pass "$public_url/health"
  else
    slabctl_doctor_append "$output" access.endpoint fail \
      "configured health endpoint is unreachable"
  fi
}

slabctl_doctor_json() {
  checks_file=$1
  jq -s \
    --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg version "$(sed -n '1p' "$SLABCTL_INSTALL_DIRECTORY/VERSION" 2>/dev/null || true)" \
    '{schemaVersion:1,generatedAt:$generatedAt,installedVersion:$version,
      overall:(if any(.[]; .status == "fail") then "fail"
        elif any(.[]; .status == "warn") then "warn" else "pass" end),
      checks:.}' "$checks_file"
}

slabctl_doctor() (
  output_format=${1:-text}
  temporary_directory=$(mktemp -d /tmp/slab-doctor.XXXXXX) || exit 1
  trap 'rm -rf "$temporary_directory"' EXIT
  trap 'exit 130' HUP INT TERM
  checks_file=$temporary_directory/checks.jsonl
  slabctl_doctor_collect "$checks_file"
  result=$(slabctl_doctor_json "$checks_file") || exit 1
  if [ "$output_format" = json ]; then
    printf '%s\n' "$result"
  else
    printf 'Slab doctor — %s\n\n' "$(printf '%s' "$result" | jq -r '.overall')"
    printf '%s' "$result" | jq -r '.checks[] | "[\(.status | ascii_upcase)] \(.id): \(.message)"'
  fi
  [ "$(printf '%s' "$result" | jq -r '.overall')" != fail ]
)

slabctl_support_bundle() (
  umask 077
  destination=${1:-/var/backups/slab}
  confirmed=${2:-0}
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  case "$destination" in
    *.tar.gz) bundle_output=$destination ;;
    *) bundle_output=$destination/slab-support-$timestamp.tar.gz ;;
  esac
  output_directory=$(dirname -- "$bundle_output")
  [ ! -L "$output_directory" ] || {
    slabctl_error "support bundle destination cannot be a symbolic link"
    exit 1
  }
  mkdir -p "$output_directory"
  output_directory=$(CDPATH='' cd -- "$output_directory" && pwd) || exit 1
  bundle_output=$output_directory/$(basename -- "$bundle_output")
  [ ! -e "$bundle_output" ] && [ ! -L "$bundle_output" ] || {
    slabctl_error "support bundle already exists: $bundle_output"
    exit 1
  }
  work_directory=$(mktemp -d "$output_directory/.slab-support.XXXXXX") || exit 1
  chmod 0700 "$work_directory"
  temporary_directory=$work_directory/content
  partial=$work_directory/archive.tar.gz
  mkdir "$temporary_directory"
  chmod 0700 "$temporary_directory"
  cleanup_support() {
    cleanup_status=$?
    rm -rf "$work_directory"
    exit "$cleanup_status"
  }
  trap cleanup_support EXIT
  trap 'exit 130' HUP INT TERM

  checks_file=$temporary_directory/doctor-checks.jsonl
  slabctl_doctor_collect "$checks_file"
  slabctl_doctor_json "$checks_file" > "$temporary_directory/doctor.json"
  rm -f "$checks_file"
  slabctl_compose ps --all 2>&1 | slabctl_doctor_sanitize_stream |
    head -c 65536 > "$temporary_directory/compose-ps.txt" || true
  docker version 2>&1 | slabctl_doctor_sanitize_stream |
    head -c 32768 > "$temporary_directory/docker-version.txt" || true
  cp "$SLABCTL_INSTALL_DIRECTORY/release-manifest.json" \
    "$temporary_directory/release-manifest.json"
  jq -n \
    --argjson secretsPresent "$([ -d "$SLABCTL_INSTALL_DIRECTORY/secrets" ] && echo true || echo false)" \
    --argjson backupStatePresent "$([ -f "$SLABCTL_INSTALL_DIRECTORY/config/backup-state.json" ] && echo true || echo false)" \
    --argjson updateStatePresent "$([ -f "$SLABCTL_INSTALL_DIRECTORY/config/update-state.json" ] && echo true || echo false)" \
    '{secretsPresent:$secretsPresent,backupStatePresent:$backupStatePresent,
      updateStatePresent:$updateStatePresent,secretValuesIncluded:false}' \
    > "$temporary_directory/config-presence.json"
  slabctl_compose exec -T slab-agents node -e '
    const Database = require("better-sqlite3");
    const db = new Database(process.env.SLAB_WORKSPACE_DB || "/data/slab-workspace.db", { readonly: true });
    const rows = db.prepare(`SELECT id,status,trigger,mode,issue_key AS issueKey,
      created_at AS createdAt,completed_at AS completedAt FROM runs
      WHERE status IN ("failed","skipped","cancelled") ORDER BY rowid DESC LIMIT 25`).all();
    process.stdout.write(JSON.stringify({ promptsIncluded: false, runs: rows }, null, 2));
  ' 2>/dev/null > "$temporary_directory/recent-terminal-runs.json" ||
    printf '%s\n' '{"promptsIncluded":false,"runs":[],"collectionError":true}' \
      > "$temporary_directory/recent-terminal-runs.json"
  mkdir "$temporary_directory/logs"
  for service_name in slab-api slab-mcp slab-docs slab-email slab-runner slab-agents caddy; do
    slabctl_compose logs --no-color --tail 100 "$service_name" 2>&1 |
      slabctl_doctor_sanitize_stream | head -c 65536 \
      > "$temporary_directory/logs/$service_name.log" || true
  done
  (
    cd "$temporary_directory" || exit 1
    find . -type f -print | sed 's#^./##' | LC_ALL=C sort > included-files.txt
  )
  echo "Support bundle will include:"
  sed 's/^/  - /' "$temporary_directory/included-files.txt"
  echo "It excludes database files, prompts, messages, document bodies, and secret values."
  if [ "$confirmed" -ne 1 ]; then
    [ -r /dev/tty ] || {
      slabctl_error "support bundle requires review confirmation or --yes"
      exit 1
    }
    printf 'Type BUNDLE after reviewing the list: ' > /dev/tty
    IFS= read -r confirmation < /dev/tty
    [ "$confirmation" = BUNDLE ] || exit 1
  fi
  tar -czf "$partial" -C "$temporary_directory" .
  chmod 0600 "$partial"
  mv "$partial" "$bundle_output"
  trap - EXIT HUP INT TERM
  rm -rf "$work_directory"
  echo "Sanitized support bundle created: $bundle_output"
)
