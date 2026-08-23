#!/bin/sh

slabctl_update_state_path() {
  printf '%s/config/update-state.json\n' "$SLABCTL_INSTALL_DIRECTORY"
}

slabctl_update_write_state() {
  status=$1
  from_version=$2
  to_version=$3
  channel=$4
  message=$5
  backup_path=${6:-}
  recovery_directory=${7:-}
  rollback_compatible=${8:-false}
  state_path=$(slabctl_update_state_path)
  temporary_state=$SLABCTL_INSTALL_DIRECTORY/config/.update-state.$$
  jq -n \
    --arg status "$status" --arg fromVersion "$from_version" \
    --arg toVersion "$to_version" --arg channel "$channel" \
    --arg message "$message" --arg backupPath "$backup_path" \
    --arg recoveryDirectory "$recovery_directory" \
    --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson rollbackCompatible "$rollback_compatible" \
    '{schemaVersion:1,status:$status,fromVersion:$fromVersion,toVersion:$toVersion,
      channel:$channel,message:$message,
      backupPath:($backupPath | if length > 0 then . else null end),
      recoveryDirectory:($recoveryDirectory | if length > 0 then . else null end),
      rollbackCompatible:$rollbackCompatible,updatedAt:$updatedAt}' \
    > "$temporary_state" || return 1
  chmod 0600 "$temporary_state"
  mv "$temporary_state" "$state_path"
}

slabctl_update_version_at_least() {
  actual=$1
  minimum=$2
  [ "$actual" = "$minimum" ] && return 0
  first=$(printf '%s\n%s\n' "$actual" "$minimum" | LC_ALL=C sort -V | head -n 1)
  [ "$first" = "$minimum" ]
}

slabctl_update_is_newer() {
  current=$1
  candidate=$2
  [ "$current" != "$candidate" ] || return 1
  slabctl_update_version_at_least "$candidate" "$current"
}

slabctl_update_agents_database() {
  action=$1
  slabctl_compose exec -T slab-agents node -e '
    const Database = require("better-sqlite3");
    const database = new Database(process.env.SLAB_WORKSPACE_DB || "/data/slab-workspace.db");
    database.pragma("busy_timeout = 5000");
    const action = process.argv[1];
    if (action === "maintenance-on" || action === "maintenance-off") {
      const value = action === "maintenance-on" ? "on" : "off";
      database.prepare(`INSERT INTO settings (key,value,updated_at) VALUES (?,?,?)
        ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at`)
        .run("system_maintenance_mode", value, new Date().toISOString());
      process.exit(0);
    }
    if (action === "active-count") {
      const row = database.prepare(`SELECT COUNT(*) AS count FROM runs
        WHERE status IN ("running","waiting_approval")`).get();
      process.stdout.write(String(row.count));
      process.exit(0);
    }
    process.exit(2);
  ' "$action"
}

slabctl_update_enter_maintenance() {
  slabctl_update_agents_database maintenance-on >/dev/null || {
    slabctl_error "could not place agent dispatch into maintenance mode"
    return 1
  }
}

slabctl_update_exit_maintenance() {
  slabctl_update_agents_database maintenance-off >/dev/null
}

slabctl_update_wait_for_idle() {
  attempts=${SLABCTL_UPDATE_DRAIN_ATTEMPTS:-120}
  interval=${SLABCTL_UPDATE_DRAIN_INTERVAL_SECONDS:-2}
  attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    active=$(slabctl_update_agents_database active-count 2>/dev/null || printf error)
    case "$active" in
      0) return 0 ;;
      *[!0-9]* | '')
        slabctl_error "could not inspect active agent runs"
        return 1
        ;;
    esac
    printf 'Waiting for %s active agent run(s) to finish...\n' "$active"
    sleep "$interval"
    attempt=$((attempt + 1))
  done
  slabctl_error "active agent runs did not drain before the update timeout"
}

slabctl_update_stage_recovery() {
  destination=$1
  mkdir -p "$destination/config"
  chmod 0700 "$destination" "$destination/config"
  for relative_path in \
    compose.yml compose.private.yml compose.domain.yml Caddyfile \
    release-manifest.json VERSION config/install.env config/access-mode \
    config/install-state.json
  do
    source_path=$SLABCTL_INSTALL_DIRECTORY/$relative_path
    [ -f "$source_path" ] || continue
    cp "$source_path" "$destination/$relative_path" || return 1
  done
  find "$destination" -type f -exec chmod 0600 {} \;
}

slabctl_update_restore_recovery() {
  recovery_directory=$1
  for relative_path in \
    compose.yml compose.private.yml compose.domain.yml Caddyfile \
    release-manifest.json VERSION config/install.env config/access-mode \
    config/install-state.json
  do
    source_path=$recovery_directory/$relative_path
    [ -f "$source_path" ] || continue
    target_path=$SLABCTL_INSTALL_DIRECTORY/$relative_path
    temporary_path=$(dirname -- "$target_path")/.$(basename -- "$target_path").rollback.$$
    cp "$source_path" "$temporary_path" || return 1
    chmod 0644 "$temporary_path"
    case "$relative_path" in config/install-state.json) chmod 0600 "$temporary_path" ;; esac
    mv "$temporary_path" "$target_path" || return 1
  done
}

slabctl_update_installed_identity() {
  version=$1
  state_path=$SLABCTL_INSTALL_DIRECTORY/config/install-state.json
  temporary_state=$SLABCTL_INSTALL_DIRECTORY/config/.install-state.update.$$
  updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg version "$version" --arg updatedAt "$updated_at" '
    .version = $version |
    .updatedAt = $updatedAt |
    .lastKnownGood = {
      status, version: $version, accessMode, publicUrl, projectName,
      completedAt: $updatedAt
    }
  ' "$state_path" > "$temporary_state" || return 1
  chmod 0600 "$temporary_state"
  mv "$temporary_state" "$state_path"
}

slabctl_update_functional_smoke() {
  slabctl_compose exec -T slab-agents node -e '
    fetch("http://127.0.0.1:3009/ready")
      .then(async (response) => {
        if (!response.ok) process.exit(1);
        const payload = await response.json();
        process.exit(payload?.status === "ready" ? 0 : 1);
      })
      .catch(() => process.exit(1));
  '
}

slabctl_update_render_release() {
  bundle_root=$1
  manifest=$2
  public_url=$(jq -er '.publicUrl' "$SLABCTL_STATE_FILE") || return 1
  access_mode=$SLABCTL_ACCESS_MODE
  domain=$(sed -n 's/^SLAB_DOMAIN=//p' "$SLABCTL_ENVIRONMENT_FILE")
  acme_email=$(sed -n 's/^ACME_EMAIL=//p' "$SLABCTL_ENVIRONMENT_FILE")
  private_bind_ip=$(sed -n 's/^SLAB_PRIVATE_BIND_IP=//p' "$SLABCTL_ENVIRONMENT_FILE")
  private_port=$(sed -n 's/^SLAB_PRIVATE_PORT=//p' "$SLABCTL_ENVIRONMENT_FILE")
  # shellcheck source=installer/lib/render.sh
  . "$bundle_root/installer/lib/render.sh"
  slab_render_installation "$bundle_root" "$SLABCTL_INSTALL_DIRECTORY" \
    "$manifest" "$access_mode" "$public_url" "$domain" "$acme_email" \
    "$private_bind_ip" "$private_port"
}

slabctl_update_install_management() {
  bundle_root=$1
  # shellcheck source=installer/lib/prompts.sh
  . "$bundle_root/installer/lib/prompts.sh"
  # shellcheck source=installer/lib/slabctl-install.sh
  . "$bundle_root/installer/lib/slabctl-install.sh"
  slab_install_management_cli "$bundle_root" "$SLABCTL_INSTALL_DIRECTORY"
}

slabctl_update_check() (
  channel=${1:-$(jq -r '.channel' "$SLABCTL_INSTALL_DIRECTORY/release-manifest.json")}
  trap slabctl_release_cleanup EXIT
  trap 'exit 130' HUP INT TERM
  slabctl_release_prepare "$channel" "$release_public_key_file" || exit 1
  current=$(sed -n '1p' "$SLABCTL_INSTALL_DIRECTORY/VERSION")
  echo "Installed: $current"
  echo "Channel: $channel"
  echo "Available: $SLAB_RELEASE_VERSION"
  if [ "$current" = "$SLAB_RELEASE_VERSION" ]; then
    echo "Status: up to date"
  elif slabctl_update_is_newer "$current" "$SLAB_RELEASE_VERSION"; then
    echo "Status: update available"
  else
    echo "Status: channel points to an older release; no downgrade will be applied"
  fi
)

slabctl_update_apply() (
  channel=$1
  confirmed=$2
  update_succeeded=0
  mutation_started=0
  maintenance_entered=0
  backup_path=
  recovery_directory=
  current=$(sed -n '1p' "$SLABCTL_INSTALL_DIRECTORY/VERSION")
  target=
  rollback_compatible=false

  cleanup_update() {
    cleanup_status=$?
    trap - EXIT HUP INT TERM
    if [ "$cleanup_status" -ne 0 ] && [ "$update_succeeded" -eq 0 ]; then
      if [ "$mutation_started" -eq 1 ] &&
        [ "$rollback_compatible" = true ] && [ -n "$recovery_directory" ]
      then
        echo "Update failed after mutation. Restoring the previous release..." >&2
        if slabctl_update_restore_recovery "$recovery_directory" &&
          slabctl_compose config --quiet >/dev/null 2>&1 &&
          slabctl_compose up -d --remove-orphans >/dev/null 2>&1 &&
          slabctl_wait_for_healthy_stack >/dev/null 2>&1 &&
          slabctl_update_functional_smoke >/dev/null 2>&1
        then
          slabctl_update_exit_maintenance >/dev/null 2>&1 || true
          slabctl_update_write_state ROLLED_BACK "$current" "$target" "$channel" \
            "Update failed; the previous release was restored and is healthy." \
            "$backup_path" "$recovery_directory" "$rollback_compatible" || true
          echo "Previous release restored successfully." >&2
        else
          slabctl_update_write_state RECOVERY_REQUIRED "$current" "$target" "$channel" \
            "Automatic rollback failed. Keep the stack stopped and restore the pre-update backup." \
            "$backup_path" "$recovery_directory" "$rollback_compatible" || true
          slabctl_error "automatic rollback failed; recovery from the verified backup is required"
        fi
      elif [ "$mutation_started" -eq 1 ]; then
        slabctl_update_write_state RECOVERY_REQUIRED "$current" "$target" "$channel" \
          "The update crossed a non-rollback-compatible migration boundary. Keep the stack stopped and restore the verified pre-update backup." \
          "$backup_path" "$recovery_directory" "$rollback_compatible" || true
        slabctl_error "automatic image rollback is unsafe; recovery from the verified backup is required"
      else
        [ "$maintenance_entered" -eq 0 ] ||
          slabctl_update_exit_maintenance >/dev/null 2>&1 || true
        slabctl_update_write_state FAILED "$current" "$target" "$channel" \
          "Update stopped before changing the installed release." \
          "$backup_path" "$recovery_directory" "$rollback_compatible" || true
      fi
    fi
    slabctl_release_cleanup
    exit "$cleanup_status"
  }
  trap cleanup_update EXIT
  trap 'exit 130' HUP INT TERM

  slabctl_release_prepare "$channel" "$release_public_key_file" || exit 1
  target=$SLAB_RELEASE_VERSION
  if [ "$current" = "$target" ]; then
    echo "Slab is already up to date at $current."
    update_succeeded=1
    exit 0
  fi
  slabctl_update_is_newer "$current" "$target" || {
    slabctl_error "refusing channel downgrade from $current to $target"
    exit 1
  }
  minimum_manager=$(jq -er '.minimumSlabctlVersion' \
    "$SLAB_RELEASE_MANIFEST") || exit 1
  slabctl_update_version_at_least "$current" "$minimum_manager" || {
    slabctl_error "release $target requires slabctl $minimum_manager or newer; installed manager is $current"
    exit 1
  }
  minimum_upgrade=$(jq -er '.migrationCompatibility.minimumUpgradeStack' \
    "$SLAB_RELEASE_MANIFEST") || exit 1
  slabctl_update_version_at_least "$current" "$minimum_upgrade" || {
    slabctl_error "release $target requires at least $minimum_upgrade; installed is $current"
    exit 1
  }
  minimum_rollback=$(jq -er '.migrationCompatibility.minimumRollbackStack' \
    "$SLAB_RELEASE_MANIFEST") || exit 1
  if slabctl_update_version_at_least "$current" "$minimum_rollback"; then
    rollback_compatible=true
  fi

  if [ "$confirmed" -ne 1 ]; then
    [ -r /dev/tty ] || {
      slabctl_error "update requires interactive confirmation or --yes"
      exit 1
    }
    printf 'Update Slab from %s to %s? Type UPDATE: ' "$current" "$target" > /dev/tty
    IFS= read -r confirmation < /dev/tty
    [ "$confirmation" = UPDATE ] || {
      slabctl_error "update cancelled"
      exit 1
    }
  fi

  slabctl_update_write_state DRAINING "$current" "$target" "$channel" \
    "Waiting for active agent runs before update." "" "" "$rollback_compatible"
  slabctl_update_enter_maintenance || exit 1
  maintenance_entered=1
  slabctl_update_wait_for_idle || exit 1

  backup_directory=${SLABCTL_UPDATE_BACKUP_DIRECTORY:-/var/backups/slab}
  mkdir -p "$backup_directory"
  chmod 0700 "$backup_directory"
  backup_path=$backup_directory/pre-update-$current-to-$target-$(date -u +%Y%m%dT%H%M%SZ).tar.gz
  slabctl_update_write_state BACKING_UP "$current" "$target" "$channel" \
    "Creating and verifying the mandatory pre-update backup." \
    "$backup_path" "" "$rollback_compatible"
  slabctl_backup_create "$backup_path" || exit 1

  recovery_directory=$SLABCTL_INSTALL_DIRECTORY/config/update-recovery/$current-$(date -u +%Y%m%dT%H%M%SZ)
  slabctl_update_stage_recovery "$recovery_directory" || exit 1
  slabctl_update_write_state APPLYING "$current" "$target" "$channel" \
    "Applying digest-pinned images and migrations." \
    "$backup_path" "$recovery_directory" "$rollback_compatible"
  mutation_started=1
  slabctl_update_render_release "$SLAB_RELEASE_BUNDLE_ROOT" \
    "$SLAB_RELEASE_MANIFEST" || exit 1
  slabctl_compose config --quiet || exit 1
  slabctl_compose pull || exit 1
  slabctl_compose up -d --remove-orphans || exit 1
  slabctl_wait_for_healthy_stack || exit 1
  slabctl_update_functional_smoke || exit 1
  slabctl_update_installed_identity "$target" || exit 1
  slabctl_update_exit_maintenance || exit 1
  maintenance_entered=0
  slabctl_update_install_management "$SLAB_RELEASE_BUNDLE_ROOT" || exit 1
  slabctl_update_write_state UPDATED "$current" "$target" "$channel" \
    "Release applied; services and application readiness passed." \
    "$backup_path" "$recovery_directory" "$rollback_compatible"
  update_succeeded=1
  echo "Slab updated successfully: $current -> $target"
  echo "Verified backup: $backup_path"
)

slabctl_update_rollback() (
  confirmed=$1
  rollback_succeeded=0
  rollback_mutated=0
  rollback_maintenance=0
  rollback_backup=
  state_path=$(slabctl_update_state_path)
  [ -f "$state_path" ] && [ ! -L "$state_path" ] || {
    slabctl_error "no auditable update state is available for rollback"
    exit 1
  }
  [ "$(jq -r '.status' "$state_path")" = UPDATED ] || {
    slabctl_error "only the latest successfully updated release can be rolled back"
    exit 1
  }
  [ "$(jq -r '.rollbackCompatible' "$state_path")" = true ] || {
    slabctl_error "this migration boundary requires restore from the pre-update backup"
    exit 1
  }
  from_version=$(jq -er '.toVersion' "$state_path") || exit 1
  to_version=$(jq -er '.fromVersion' "$state_path") || exit 1
  channel=$(jq -er '.channel' "$state_path") || exit 1
  recovery_directory=$(jq -er '.recoveryDirectory' "$state_path") || exit 1
  previous_backup=$(jq -er '.backupPath' "$state_path") || exit 1
  [ -d "$recovery_directory" ] && [ ! -L "$recovery_directory" ] || {
    slabctl_error "rollback recovery files are unavailable"
    exit 1
  }
  if [ "$confirmed" -ne 1 ]; then
    [ -r /dev/tty ] || {
      slabctl_error "rollback requires interactive confirmation or --yes"
      exit 1
    }
    printf 'Rollback Slab from %s to %s? Type ROLLBACK: ' \
      "$from_version" "$to_version" > /dev/tty
    IFS= read -r confirmation < /dev/tty
    [ "$confirmation" = ROLLBACK ] || exit 1
  fi

  cleanup_rollback() {
    cleanup_status=$?
    trap - EXIT HUP INT TERM
    if [ "$cleanup_status" -ne 0 ] && [ "$rollback_succeeded" -eq 0 ]; then
      if [ "$rollback_mutated" -eq 1 ]; then
        slabctl_update_write_state RECOVERY_REQUIRED "$from_version" "$to_version" "$channel" \
          "Rollback stopped after release files changed. Keep the stack stopped and restore a verified backup." \
          "${rollback_backup:-$previous_backup}" "$recovery_directory" true || true
      else
        [ "$rollback_maintenance" -eq 0 ] ||
          slabctl_update_exit_maintenance >/dev/null 2>&1 || true
        slabctl_update_write_state ROLLBACK_FAILED "$from_version" "$to_version" "$channel" \
          "Rollback stopped before changing the installed release." \
          "${rollback_backup:-$previous_backup}" "$recovery_directory" true || true
      fi
    fi
    exit "$cleanup_status"
  }
  trap cleanup_rollback EXIT
  trap 'exit 130' HUP INT TERM

  slabctl_update_enter_maintenance || exit 1
  rollback_maintenance=1
  slabctl_update_wait_for_idle || exit 1
  backup_directory=${SLABCTL_UPDATE_BACKUP_DIRECTORY:-/var/backups/slab}
  mkdir -p "$backup_directory"
  chmod 0700 "$backup_directory"
  rollback_backup=$backup_directory/pre-rollback-$from_version-$(date -u +%Y%m%dT%H%M%SZ).tar.gz
  slabctl_backup_create "$rollback_backup" || exit 1
  rollback_mutated=1
  slabctl_update_restore_recovery "$recovery_directory" || exit 1
  slabctl_compose config --quiet || exit 1
  slabctl_compose up -d --remove-orphans || exit 1
  slabctl_wait_for_healthy_stack || exit 1
  slabctl_update_functional_smoke || exit 1
  slabctl_update_exit_maintenance || exit 1
  rollback_maintenance=0
  slabctl_update_write_state ROLLED_BACK "$from_version" "$to_version" "$channel" \
    "Operator rollback completed and the previous release is healthy." \
    "$previous_backup" "$recovery_directory" true
  rollback_succeeded=1
  echo "Slab rolled back successfully: $from_version -> $to_version"
  echo "Pre-rollback backup: $rollback_backup"
)
