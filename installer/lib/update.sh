#!/bin/sh
# shellcheck disable=SC2015,SC2031,SC2154,SC2317

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
  LC_ALL=C awk -v actual="$actual" -v minimum="$minimum" '
    function numeric_compare(left, right, left_value, right_value) {
      left_value = left; right_value = right
      sub(/^0+/, "", left_value); sub(/^0+/, "", right_value)
      if (left_value == "") left_value = "0"
      if (right_value == "") right_value = "0"
      if (length(left_value) != length(right_value))
        return length(left_value) < length(right_value) ? -1 : 1
      if (left_value == right_value) return 0
      return left_value < right_value ? -1 : 1
    }
    function compare(left, right, left_dash, right_dash, left_core, right_core,
      left_pre, right_pre, left_parts, right_parts, left_count, right_count,
      index_value, left_numeric, right_numeric, result) {
      sub(/\+.*/, "", left); sub(/\+.*/, "", right)
      left_dash = index(left, "-"); right_dash = index(right, "-")
      left_core = left_dash ? substr(left, 1, left_dash - 1) : left
      right_core = right_dash ? substr(right, 1, right_dash - 1) : right
      split(left_core, left_parts, "."); split(right_core, right_parts, ".")
      for (index_value = 1; index_value <= 3; index_value++) {
        result = numeric_compare(left_parts[index_value], right_parts[index_value])
        if (result != 0) return result
      }
      left_pre = left_dash ? substr(left, left_dash + 1) : ""
      right_pre = right_dash ? substr(right, right_dash + 1) : ""
      if (left_pre == "" || right_pre == "") {
        if (left_pre == right_pre) return 0
        return left_pre == "" ? 1 : -1
      }
      left_count = split(left_pre, left_parts, ".")
      right_count = split(right_pre, right_parts, ".")
      for (index_value = 1; index_value <= left_count && index_value <= right_count; index_value++) {
        left_numeric = left_parts[index_value] ~ /^[0-9]+$/
        right_numeric = right_parts[index_value] ~ /^[0-9]+$/
        if (left_numeric && right_numeric) {
          result = numeric_compare(left_parts[index_value], right_parts[index_value])
        } else if (left_numeric != right_numeric) {
          result = left_numeric ? -1 : 1
        } else if (left_parts[index_value] == right_parts[index_value]) {
          result = 0
        } else {
          result = left_parts[index_value] < right_parts[index_value] ? -1 : 1
        }
        if (result != 0) return result
      }
      if (left_count == right_count) return 0
      return left_count < right_count ? -1 : 1
    }
    BEGIN { exit(compare(actual, minimum) >= 0 ? 0 : 1) }
  '
}

slabctl_update_is_newer() {
  current=$1
  candidate=$2
  slabctl_update_version_at_least "$candidate" "$current" &&
    ! slabctl_update_version_at_least "$current" "$candidate"
}

slabctl_update_has_equal_precedence() {
  first_version=$1
  second_version=$2
  slabctl_update_version_at_least "$first_version" "$second_version" &&
    slabctl_update_version_at_least "$second_version" "$first_version"
}

slabctl_update_write_attempt() {
  attempt_action=$1
  attempt_channel=$2
  attempt_expected=$3
  attempt_observed=$4
  attempt_message=$5
  attempt_path=$SLABCTL_INSTALL_DIRECTORY/config/update-attempt.json
  attempt_temporary=$SLABCTL_INSTALL_DIRECTORY/config/.update-attempt.$$
  if ! jq -n \
    --arg action "$attempt_action" \
    --arg channel "$attempt_channel" \
    --arg expectedTarget "$attempt_expected" \
    --arg observedTarget "$attempt_observed" \
    --arg message "$attempt_message" \
    --arg attemptedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schemaVersion:1,status:"TARGET_MISMATCH",action:$action,
      channel:$channel,expectedTarget:$expectedTarget,
      observedTarget:$observedTarget,message:$message,attemptedAt:$attemptedAt}' \
    > "$attempt_temporary"
  then
    rm -f "$attempt_temporary"
    return 1
  fi
  chmod 0600 "$attempt_temporary" || {
    rm -f "$attempt_temporary"
    return 1
  }
  mv "$attempt_temporary" "$attempt_path" || {
    rm -f "$attempt_temporary"
    return 1
  }
}

slabctl_update_assert_expected_target() {
  expected_target=${1:-}
  target_action=${2:-check}
  target_channel=${3:-candidate}
  [ -z "$expected_target" ] || [ "$SLAB_RELEASE_VERSION" = "$expected_target" ] || {
    mismatch_message="Signed channel target changed: expected $expected_target, observed $SLAB_RELEASE_VERSION."
    slabctl_update_write_attempt "$target_action" "$target_channel" \
      "$expected_target" "$SLAB_RELEASE_VERSION" "$mismatch_message" || {
        slabctl_error "could not persist the rejected exact-target update attempt"
        return 1
      }
    slabctl_error "signed channel target changed: expected $expected_target, observed $SLAB_RELEASE_VERSION"
    return 1
  }
}

slabctl_update_validate_cli_options() {
  cli_action=$1
  cli_channel_explicit=$2
  cli_confirmed=$3
  cli_output_format=$4
  cli_target=$5
  case "$cli_action" in
    check)
      [ "$cli_confirmed" -eq 0 ]
      ;;
    apply)
      [ "$cli_output_format" = text ]
      ;;
    rollback)
      [ "$cli_channel_explicit" -eq 0 ] &&
        [ "$cli_output_format" = text ] &&
        [ -z "$cli_target" ]
      ;;
    recover-maintenance)
      [ "$cli_channel_explicit" -eq 0 ] &&
        [ "$cli_confirmed" -eq 0 ] &&
        [ "$cli_output_format" = text ] &&
        [ -z "$cli_target" ]
      ;;
    *) return 1 ;;
  esac
}

slabctl_update_classify_status() {
  case "$1" in
    UPDATED | ROLLED_BACK | CANCELLED) printf '%s\n' safe ;;
    DRAINING | BACKING_UP | APPLYING | FAILED | RECOVERY_REQUIRED | ROLLBACK_FAILED)
      printf '%s\n' recovery
      ;;
    *)
      printf '%s\n' invalid
      return 1
      ;;
  esac
}

slabctl_update_check_recovery_reason() {
  check_current=$1
  check_installed_manifest=$SLABCTL_INSTALL_DIRECTORY/release-manifest.json
  [ -f "$check_installed_manifest" ] && [ ! -L "$check_installed_manifest" ] || {
    printf '%s\n' "Installed release manifest is missing or unsafe."
    return 1
  }
  check_manifest_version=$(jq -er '.stackVersion' "$check_installed_manifest" \
    2>/dev/null) || {
      printf '%s\n' "Installed release manifest has no valid stack identity."
      return 1
    }
  [ "$check_current" = "$check_manifest_version" ] || {
    printf '%s\n' \
      "Installed version and release manifest disagree; recover the interrupted update."
    return 1
  }
  check_state_path=$(slabctl_update_state_path)
  [ ! -e "$check_state_path" ] || [ -f "$check_state_path" ] &&
    [ ! -L "$check_state_path" ] || {
      printf '%s\n' "Update recovery state is unsafe."
      return 1
    }
  [ -f "$check_state_path" ] || return 0
  check_previous_status=$(jq -er '.status' "$check_state_path" 2>/dev/null) || {
    printf '%s\n' "Update recovery state is invalid."
    return 1
  }
  if ! check_classification=$(slabctl_update_classify_status \
    "$check_previous_status"); then
    printf '%s\n' "Update recovery state has an unsupported status."
    return 1
  fi
  [ "$check_classification" = safe ] || {
    printf '%s\n' \
      "The previous update is in $check_previous_status state and requires recovery."
    return 1
  }
}

slabctl_update_check_json() {
  current=$1
  channel=$2
  installed_manifest=$SLABCTL_INSTALL_DIRECTORY/release-manifest.json
  [ -f "$installed_manifest" ] && [ ! -L "$installed_manifest" ] || {
    slabctl_error "installed release manifest is missing or unsafe"
    return 1
  }
  recovery_reason=
  recovery_required=false
  if ! recovery_reason=$(slabctl_update_check_recovery_reason "$current"); then
    recovery_required=true
  fi
  checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ "$recovery_required" = true ]; then
    update_status=recovery_required
  elif [ "$current" = "$SLAB_RELEASE_VERSION" ]; then
    update_status=up_to_date
  elif slabctl_update_is_newer "$current" "$SLAB_RELEASE_VERSION"; then
    update_status=update_available
  elif slabctl_update_has_equal_precedence "$current" "$SLAB_RELEASE_VERSION"; then
    update_status=channel_equivalent
  else
    update_status=channel_older
  fi
  minimum_rollback=$(jq -er '.migrationCompatibility.minimumRollbackStack' \
    "$SLAB_RELEASE_MANIFEST") || return 1
  if slabctl_update_version_at_least "$current" "$minimum_rollback"; then
    check_rollback_compatible=true
  else
    check_rollback_compatible=false
  fi
  jq -n \
    --slurpfile installed "$installed_manifest" \
    --slurpfile available "$SLAB_RELEASE_MANIFEST" \
    --arg installedVersion "$current" \
    --arg availableVersion "$SLAB_RELEASE_VERSION" \
    --arg channel "$channel" \
    --arg status "$update_status" \
    --arg checkedAt "$checked_at" \
    --arg recoveryReason "$recovery_reason" \
    --argjson recoveryRequired "$recovery_required" \
    --argjson rollbackCompatible "$check_rollback_compatible" '
      def revision:
        if . == null then null
        else (.ref | capture("(?:candidate-|sha-)(?<revision>[a-f0-9]{7,40})$").revision? // null)
        end;
      def component($id; $name; $services; $recoveryRequired):
        ($installed[0].images[$id] // null) as $current |
        ($available[0].images[$id] // null) as $target |
        {
          id: $id,
          name: $name,
          services: $services,
          installed: ($current | if . == null then null else
            {ref, digest, revision: revision} end),
          available: ($target | if . == null then null else
            {ref, digest, revision: revision} end),
          status: (if $recoveryRequired then "recovery_required"
            elif $current.digest == $target.digest then
            "up_to_date" else "update_available" end)
        };
      {
        schemaVersion: 1,
        status: $status,
        channel: $channel,
        installedStackVersion: $installedVersion,
        availableStackVersion: $availableVersion,
        checkedAt: $checkedAt,
        recoveryReason: ($recoveryReason | if length > 0 then . else null end),
        release: {
          releasedAt: ($available[0].releasedAt // null),
          severity: ($available[0].severity // "routine"),
          releaseNotesUrl: ($available[0].releaseNotesUrl // null),
          rollbackCompatibleFromInstalled: $rollbackCompatible
        },
        components: [
          component("agents"; "Agents"; ["slab-agents"]; $recoveryRequired),
          component("work"; "Work"; ["work-migrate", "slab-api", "slab-mcp"]; $recoveryRequired),
          component("docs"; "Docs"; ["docs-migrate", "slab-docs"]; $recoveryRequired),
          component("email"; "Email"; ["email-migrate", "slab-email"]; $recoveryRequired),
          component("runner"; "Runner"; ["slab-runner"]; $recoveryRequired)
        ]
      }
    '
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
      const now = new Date().toISOString();
      const columns = new Set(
        database.prepare("PRAGMA table_info(runs)").all().map((row) => row.name),
      );
      const hasDurableLease = columns.has("lease_owner") &&
        columns.has("lease_expires_at");
      const row = hasDurableLease
        ? database.prepare(`SELECT COUNT(*) AS count FROM runs
            WHERE status IN (?,?)
              OR (status=? AND lease_owner IS NOT NULL AND lease_expires_at > ?)`)
            .get("running", "waiting_approval", "queued", now)
        : database.prepare(`SELECT COUNT(*) AS count FROM runs
            WHERE status IN (?,?)`)
            .get("running", "waiting_approval");
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

slabctl_update_assert_recoverable_state() {
  state_path=$(slabctl_update_state_path)
  [ ! -e "$state_path" ] || [ -f "$state_path" ] && [ ! -L "$state_path" ] || {
    slabctl_error "the previous update state is unsafe"
    return 1
  }
  [ -f "$state_path" ] || return 0
  previous_status=$(jq -er '.status' "$state_path" 2>/dev/null) || {
    slabctl_error "the previous update state is invalid"
    return 1
  }
  if ! previous_classification=$(slabctl_update_classify_status \
    "$previous_status"); then
    slabctl_error "the previous update state has an unsupported status"
    return 1
  fi
  [ "$previous_classification" = safe ] || {
    slabctl_error "the previous update requires recovery before another update can run"
    return 1
  }
}

slabctl_update_recover_maintenance() (
  state_path=$(slabctl_update_state_path)
  [ -f "$state_path" ] && [ ! -L "$state_path" ] || {
    slabctl_error "no update recovery state is available"
    exit 1
  }
  status=$(jq -er '.status' "$state_path") || exit 1
  from_version=$(jq -er '.fromVersion' "$state_path") || exit 1
  to_version=$(jq -er '.toVersion' "$state_path") || exit 1
  channel=$(jq -er '.channel' "$state_path") || exit 1
  backup_path=$(jq -r '.backupPath // ""' "$state_path") || exit 1
  recovery_directory=$(jq -r '.recoveryDirectory // ""' "$state_path") || exit 1
  rollback_compatible=$(jq -r '.rollbackCompatible // false' "$state_path") || exit 1
  installed_version=$(sed -n '1p' "$SLABCTL_INSTALL_DIRECTORY/VERSION")
  manifest_version=$(jq -r '.stackVersion // ""' \
    "$SLABCTL_INSTALL_DIRECTORY/release-manifest.json" 2>/dev/null || true)
  reconcile_stack=0
  restore_previous=0

  case "$status:$installed_version" in
    DRAINING:"$from_version" | BACKING_UP:"$from_version" | FAILED:"$from_version")
      [ "$manifest_version" = "$from_version" ] || {
        slabctl_error "pre-update recovery state disagrees with installed release files"
        exit 1
      }
      terminal_status=CANCELLED
      terminal_from=$from_version
      terminal_to=$to_version
      terminal_message="The interrupted pre-update attempt was cancelled and agent dispatch maintenance was cleared."
      ;;
    APPLYING:"$from_version" | APPLYING:"$to_version" | \
      RECOVERY_REQUIRED:"$from_version" | RECOVERY_REQUIRED:"$to_version")
      if [ "$status" = RECOVERY_REQUIRED ] && [ -z "$recovery_directory" ]; then
        [ "$installed_version" = "$from_version" ] &&
          [ "$manifest_version" = "$from_version" ] || {
            slabctl_error "pre-update recovery state disagrees with installed release files"
            exit 1
          }
        terminal_status=CANCELLED
        terminal_from=$from_version
        terminal_to=$to_version
        terminal_message="The pre-update attempt was cancelled and agent dispatch maintenance was cleared."
      else
        [ "$rollback_compatible" = true ] || {
          slabctl_error "the interrupted update crossed a non-rollback-compatible boundary; restore the verified backup"
          exit 1
        }
        [ -n "$recovery_directory" ] && [ -d "$recovery_directory" ] &&
          [ ! -L "$recovery_directory" ] || {
            slabctl_error "staged previous release is unavailable for recovery"
            exit 1
          }
        staged_version=$(sed -n '1p' "$recovery_directory/VERSION" \
          2>/dev/null || true)
        staged_manifest_version=$(jq -r '.stackVersion // ""' \
          "$recovery_directory/release-manifest.json" 2>/dev/null || true)
        [ -n "$staged_version" ] &&
          [ "$staged_version" = "$staged_manifest_version" ] || {
            slabctl_error "staged previous release has an inconsistent identity"
            exit 1
          }
        case "$staged_version" in
          "$from_version") terminal_from=$to_version ;;
          "$to_version") terminal_from=$from_version ;;
          *)
            slabctl_error "staged previous release does not match the update ledger"
            exit 1
            ;;
        esac
        terminal_status=ROLLED_BACK
        terminal_to=$staged_version
        terminal_message="The staged previous release was restored and is healthy; agent dispatch maintenance was cleared."
        restore_previous=1
        reconcile_stack=1
      fi
      ;;
    ROLLBACK_FAILED:"$from_version")
      [ "$manifest_version" = "$from_version" ] || {
        slabctl_error "failed rollback state disagrees with installed release files"
        exit 1
      }
      terminal_status=UPDATED
      terminal_from=$to_version
      terminal_to=$from_version
      terminal_message="The installed release remains healthy after the failed rollback and agent dispatch maintenance was cleared."
      ;;
    UPDATED:"$to_version")
      [ "$manifest_version" = "$to_version" ] || {
        slabctl_error "updated state disagrees with installed release files"
        exit 1
      }
      terminal_status=UPDATED
      terminal_from=$from_version
      terminal_to=$to_version
      terminal_message="The target release is healthy and agent dispatch maintenance was cleared."
      ;;
    ROLLED_BACK:"$to_version")
      [ "$manifest_version" = "$to_version" ] || {
        slabctl_error "rolled-back state disagrees with installed release files"
        exit 1
      }
      terminal_status=ROLLED_BACK
      terminal_from=$from_version
      terminal_to=$to_version
      terminal_message="The rolled-back release is healthy and agent dispatch maintenance was cleared."
      ;;
    *)
      slabctl_error "update state and installed release do not describe a maintenance-only recovery"
      exit 1
      ;;
  esac

  if [ "$restore_previous" -eq 1 ]; then
    [ -n "$recovery_directory" ] && [ -d "$recovery_directory" ] &&
      [ ! -L "$recovery_directory" ] || {
        slabctl_error "staged previous release is unavailable for recovery"
        exit 1
      }
    slabctl_update_restore_recovery "$recovery_directory" || exit 1
  fi
  slabctl_compose config --quiet >/dev/null || exit 1
  if [ "$reconcile_stack" -eq 1 ]; then
    slabctl_compose pull >/dev/null || exit 1
    slabctl_compose up -d --remove-orphans >/dev/null || exit 1
  fi
  slabctl_wait_for_healthy_stack >/dev/null || exit 1
  slabctl_update_functional_smoke >/dev/null || exit 1
  slabctl_update_exit_maintenance || {
    slabctl_error "could not clear agent dispatch maintenance mode"
    exit 1
  }
  if ! slabctl_update_write_state "$terminal_status" "$terminal_from" "$terminal_to" \
    "$channel" "$terminal_message" "$backup_path" "$recovery_directory" \
    "$rollback_compatible"
  then
    slabctl_update_enter_maintenance >/dev/null 2>&1 || true
    slabctl_error "maintenance was cleared, but recovery state could not be persisted; dispatch was paused again"
    exit 1
  fi
  echo "Agent dispatch maintenance cleared."
)

slabctl_update_stop_for_recovery() {
  slabctl_compose stop >/dev/null 2>&1 || return 1
  running_containers=$(slabctl_compose ps --status running -q 2>/dev/null) || return 1
  [ -z "$running_containers" ]
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
  temporary_version=$SLABCTL_INSTALL_DIRECTORY/.VERSION.update.$$
  updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg version "$version" --arg updatedAt "$updated_at" '
    .version = $version |
    .updatedAt = $updatedAt |
    .lastKnownGood = {
      status, version: $version, accessMode, publicUrl, projectName,
      completedAt: $updatedAt
    }
  ' "$state_path" > "$temporary_state" || return 1
  printf '%s\n' "$version" > "$temporary_version" || return 1
  chmod 0600 "$temporary_state"
  chmod 0644 "$temporary_version"
  mv "$temporary_version" "$SLABCTL_INSTALL_DIRECTORY/VERSION" || return 1
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
  SLAB_MEMORY_MODE=$(sed -n 's/^SLAB_MEMORY_MODE=//p' "$SLABCTL_ENVIRONMENT_FILE")
  SLAB_HONCHO_URL=$(sed -n 's/^SLAB_HONCHO_URL=//p' "$SLABCTL_ENVIRONMENT_FILE")
  SLAB_HONCHO_WORKSPACE_ID=$(sed -n 's/^SLAB_HONCHO_WORKSPACE_ID=//p' "$SLABCTL_ENVIRONMENT_FILE")
  SLAB_MEMORY_MAX_CONTEXT_TOKENS=$(sed -n 's/^SLAB_MEMORY_MAX_CONTEXT_TOKENS=//p' "$SLABCTL_ENVIRONMENT_FILE")
  : "${SLAB_MEMORY_MODE:=disabled}"
  : "${SLAB_HONCHO_URL:=https://api.honcho.dev}"
  : "${SLAB_HONCHO_WORKSPACE_ID:=slab}"
  : "${SLAB_MEMORY_MAX_CONTEXT_TOKENS:=900}"
  # Legacy installations do not have memory secret files. Create the new
  # root-private placeholders before Compose validates the target release;
  # configured values are preserved because secret preparation is idempotent.
  # shellcheck source=installer/lib/secrets.sh
  . "$bundle_root/installer/lib/secrets.sh"
  slab_prepare_secrets "$SLABCTL_INSTALL_DIRECTORY/secrets" || return 1
  # shellcheck source=installer/lib/render.sh
  . "$bundle_root/installer/lib/render.sh"
  slab_render_installation "$bundle_root" "$SLABCTL_INSTALL_DIRECTORY" \
    "$manifest" "$access_mode" "$public_url" "$domain" "$acme_email" \
    "$private_bind_ip" "$private_port" 0
}

slabctl_update_install_management() {
  bundle_root=$1
  # shellcheck source=installer/lib/prompts.sh
  . "$bundle_root/installer/lib/prompts.sh"
  # shellcheck source=installer/lib/slabctl-install.sh
  . "$bundle_root/installer/lib/slabctl-install.sh"
  slab_install_management_cli "$bundle_root" "$SLABCTL_INSTALL_DIRECTORY"
}

slabctl_update_bridge_root() {
  printf '%s\n' "${SLAB_UPDATE_BRIDGE_ROOT:-/var/lib/slab-update-bridge}"
}

slabctl_update_bridge_stat() {
  "${SLABCTL_STAT_BIN:-stat}" -c "$1" "$2"
}

slabctl_update_bridge_sync() {
  "${SLABCTL_SYNC_BIN:-sync}" -f "$1"
}

slabctl_update_bridge_remove_claim() {
  bridge_root=$1
  claimed=$2
  rm -f "$claimed" || return 1
  slabctl_update_bridge_sync "$bridge_root/processing"
}

slabctl_update_bridge_remove_inbox_file() {
  inbox_directory=$1
  inbox_file=$2
  rm -f "$inbox_file" || return 1
  slabctl_update_bridge_sync "$inbox_directory"
}

slabctl_update_bridge_validate_directories() {
  bridge_root=$1
  expected_root_uid=${SLABCTL_EXPECTED_OWNER_UID:-0}
  for directory_spec in \
    "$bridge_root:$expected_root_uid:755" \
    "$bridge_root/requests:$expected_root_uid:1733" \
    "$bridge_root/requests/.claimed:$expected_root_uid:700" \
    "$bridge_root/requests/.uploads:${SLAB_UPDATE_BRIDGE_REQUEST_UID:-10001}:700" \
    "$bridge_root/processing:$expected_root_uid:700" \
    "$bridge_root/status:$expected_root_uid:755" \
    "$bridge_root/status/requests:$expected_root_uid:755"
  do
    directory=${directory_spec%%:*}
    remainder=${directory_spec#*:}
    expected_uid=${remainder%%:*}
    expected_mode=${remainder#*:}
    [ -d "$directory" ] && [ ! -L "$directory" ] || {
      slabctl_error "update bridge directory is missing or unsafe: $directory"
      return 1
    }
    actual_uid=$(slabctl_update_bridge_stat '%u' "$directory") || return 1
    actual_mode=$(slabctl_update_bridge_stat '%a' "$directory") || return 1
    [ "$actual_uid" -eq "$expected_uid" ] && [ "$actual_mode" = "$expected_mode" ] || {
      slabctl_error "update bridge directory has unsafe ownership or permissions: $directory"
      return 1
    }
  done
}

slabctl_update_bridge_sweep() {
  bridge_root=$1
  inbox=$bridge_root/requests
  uploads=$inbox/.uploads
  status_requests=$bridge_root/status/requests
  status_directory=$bridge_root/status
  retention_minutes=${SLAB_UPDATE_BRIDGE_STATUS_RETENTION_MINUTES:-1440}
  printf '%s\n' "$retention_minutes" | grep -Eq '^[1-9][0-9]*$' || return 1

  for entry in "$inbox"/* "$inbox"/.[!.]* "$inbox"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    entry_name=${entry##*/}
    case "$entry_name" in
      .claimed | .uploads | *.json) continue ;;
    esac
    find "$entry" -xdev -depth -delete || return 1
  done
  find "$uploads" -xdev -mindepth 1 -mmin +1 -delete || return 1
  for temporary_status in "$status_directory"/.status.* \
    "$status_directory"/.latest.*
  do
    [ -e "$temporary_status" ] || [ -L "$temporary_status" ] || continue
    rm -f "$temporary_status" || return 1
  done

  for status_file in "$status_requests"/*.json; do
    [ -f "$status_file" ] && [ ! -L "$status_file" ] || continue
    [ -n "$(find "$status_file" -prune -mmin "+$retention_minutes" -print)" ] ||
      continue
    status_state=$(jq -r '.state // empty' "$status_file" 2>/dev/null || true)
    [ "$status_state" = running ] || rm -f "$status_file" || return 1
  done
  slabctl_update_bridge_sync "$inbox" || return 1
  slabctl_update_bridge_sync "$uploads" || return 1
  slabctl_update_bridge_sync "$status_requests" || return 1
  slabctl_update_bridge_sync "$status_directory" || return 1
  slabctl_update_bridge_compact_replay_ledger "$bridge_root" "$(date -u +%s)"
}

slabctl_update_bridge_evict_terminal_statuses() {
  bridge_root=$1
  request_id=$2
  status_requests=$bridge_root/status/requests
  maximum=${SLAB_UPDATE_BRIDGE_STATUS_MAXIMUM:-2048}
  maximum_bytes=${SLAB_UPDATE_BRIDGE_STATUS_MAXIMUM_BYTES:-4194304}
  publication_reserve_bytes=1048576
  printf '%s\n' "$maximum" | grep -Eq '^[1-9][0-9]*$' || return 1
  printf '%s\n' "$maximum_bytes" | grep -Eq '^[1-9][0-9]*$' || return 1
  [ "$maximum" -le 3000 ] || {
    slabctl_error "update bridge status maximum exceeds the safe transport reserve"
    return 1
  }
  [ "$maximum_bytes" -le 6291456 ] || {
    slabctl_error "update bridge status byte limit exceeds the safe transport reserve"
    return 1
  }

  status_count=0
  status_bytes=0
  request_present=0
  for status_file in "$status_requests"/*.json; do
    [ -e "$status_file" ] || [ -L "$status_file" ] || continue
    [ -f "$status_file" ] && [ ! -L "$status_file" ] || {
      slabctl_error "update bridge status is unsafe: $status_file"
      return 1
    }
    status_count=$((status_count + 1))
    status_size=$(slabctl_update_bridge_stat '%s' "$status_file") || return 1
    status_bytes=$((status_bytes + status_size))
    [ "${status_file##*/}" != "$request_id.json" ] || request_present=1
  done

  while [ $((status_count + 1 - request_present)) -gt "$maximum" ] ||
    [ $((status_bytes + publication_reserve_bytes)) -gt "$maximum_bytes" ]
  do
    oldest=
    oldest_mtime=
    for status_file in "$status_requests"/*.json; do
      [ -f "$status_file" ] && [ ! -L "$status_file" ] || continue
      [ "${status_file##*/}" != "$request_id.json" ] || continue
      status_state=$(jq -r '.state // empty' "$status_file" 2>/dev/null || true)
      [ "$status_state" != running ] || continue
      status_mtime=$(slabctl_update_bridge_stat '%Y' "$status_file") || return 1
      if [ -z "$oldest" ] || [ "$status_mtime" -lt "$oldest_mtime" ]; then
        oldest=$status_file
        oldest_mtime=$status_mtime
      fi
    done
    [ -n "$oldest" ] || {
      slabctl_error "update bridge status transport has no evictable terminal entries"
      return 1
    }
    oldest_size=$(slabctl_update_bridge_stat '%s' "$oldest") || return 1
    rm -f "$oldest" || return 1
    status_count=$((status_count - 1))
    status_bytes=$((status_bytes - oldest_size))
  done
  slabctl_update_bridge_sync "$status_requests"
}

slabctl_update_bridge_compact_replay_ledger() {
  bridge_root=$1
  now_epoch=$2
  processing=$bridge_root/processing
  ledger=$processing/replay-ledger
  temporary=$(mktemp "$processing/.replay-ledger.XXXXXX") || return 1
  if [ -e "$ledger" ] || [ -L "$ledger" ]; then
    [ -f "$ledger" ] && [ ! -L "$ledger" ] || {
      rm -f "$temporary"
      slabctl_error "update bridge replay ledger is unsafe"
      return 1
    }
    ledger_uid=$(slabctl_update_bridge_stat '%u' "$ledger") || return 1
    ledger_mode=$(slabctl_update_bridge_stat '%a' "$ledger") || return 1
    ledger_size=$(slabctl_update_bridge_stat '%s' "$ledger") || return 1
    [ "$ledger_uid" -eq "${SLABCTL_EXPECTED_OWNER_UID:-0}" ] &&
      [ "$ledger_mode" = 600 ] && [ "$ledger_size" -le 131072 ] || {
        rm -f "$temporary"
        slabctl_error "update bridge replay ledger has unsafe metadata"
        return 1
      }
    jq -e --argjson now "$now_epoch" '
      if (type == "object" and
        ((keys | sort) == (["entries", "schemaVersion"] | sort)) and
        .schemaVersion == 1 and
        (.entries | type == "array" and length <= 1024 and all(
          type == "object" and
          ((keys | sort) == (["expiresAt", "requestId"] | sort)) and
          (.requestId | type == "string" and
            test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
          (.expiresAt | type == "number" and . == floor)
        )))
      then .entries |= map(select(.expiresAt > $now))
      else error("invalid replay ledger")
      end
    ' "$ledger" > "$temporary" || {
      rm -f "$temporary"
      slabctl_error "update bridge replay ledger is invalid"
      return 1
    }
  else
    jq -n '{schemaVersion: 1, entries: []}' > "$temporary" || return 1
  fi
  chmod 0600 "$temporary"
  slabctl_update_bridge_sync "$temporary" || {
    rm -f "$temporary"
    return 1
  }
  mv "$temporary" "$ledger" || return 1
  slabctl_update_bridge_sync "$processing"
}

slabctl_update_bridge_replay_seen() {
  bridge_root=$1
  request_id=$2
  jq -e --arg requestId "$request_id" \
    'any(.entries[]; .requestId == $requestId)' \
    "$bridge_root/processing/replay-ledger" >/dev/null 2>&1
}

slabctl_update_bridge_record_replay() {
  bridge_root=$1
  request_id=$2
  expires_at=$3
  processing=$bridge_root/processing
  ledger=$processing/replay-ledger
  temporary=$(mktemp "$processing/.replay-ledger.XXXXXX") || return 1
  jq -e --arg requestId "$request_id" --argjson expiresAt "$expires_at" '
    if any(.entries[]; .requestId == $requestId) then
      error("duplicate request")
    elif (.entries | length) >= 1024 then
      error("replay ledger is full")
    else
      .entries += [{requestId: $requestId, expiresAt: $expiresAt}]
    end
  ' "$ledger" > "$temporary" || {
    rm -f "$temporary"
    return 1
  }
  chmod 0600 "$temporary"
  slabctl_update_bridge_sync "$temporary" || {
    rm -f "$temporary"
    return 1
  }
  mv "$temporary" "$ledger" || return 1
  slabctl_update_bridge_sync "$processing"
}

slabctl_update_bridge_publish_status() {
  bridge_root=$1
  request_id=$2
  action=$3
  state=$4
  channel=$5
  target=$6
  requested_at=$7
  started_at=$8
  completed_at=$9
  result_path=${10}
  error_code=${11}
  error_message=${12}
  status_directory=$bridge_root/status
  request_status=$status_directory/requests/$request_id.json
  result_json=null
  if [ -n "$result_path" ]; then
    result_size=$(slabctl_update_bridge_stat '%s' "$result_path") || return 1
    [ "$result_size" -le 262144 ] || {
      slabctl_error "update bridge result exceeds the safe status limit"
      return 1
    }
    result_json=$(jq -ec 'if type == "object" then . else error("not an object") end' \
      "$result_path") || return 1
  fi
  slabctl_update_bridge_evict_terminal_statuses "$bridge_root" "$request_id" ||
    return 1
  temporary_status=$(mktemp "$status_directory/.status.XXXXXX") || return 1
  temporary_latest=$(mktemp "$status_directory/.latest.XXXXXX") || {
    rm -f "$temporary_status"
    return 1
  }
  jq -n --argjson result "$result_json" \
    --arg requestId "$request_id" \
    --arg action "$action" \
    --arg state "$state" \
    --arg channel "$channel" \
    --arg target "$target" \
    --arg requestedAt "$requested_at" \
    --arg startedAt "$started_at" \
    --arg completedAt "$completed_at" \
    --arg errorCode "$error_code" \
    --arg errorMessage "$error_message" '
      {
        schemaVersion: 1,
        requestId: $requestId,
        action: ($action | if length == 0 then null else . end),
        state: $state,
        channel: ($channel | if length == 0 then null else . end),
        target: ($target | if length == 0 then null else . end),
        requestedAt: ($requestedAt | if length == 0 then null else . end),
        startedAt: $startedAt,
        completedAt: ($completedAt | if length == 0 then null else . end),
        result: $result,
        error: (if $errorCode | length == 0 then null else
          {code: $errorCode, message: $errorMessage} end)
      }
    ' > "$temporary_status" || {
      rm -f "$temporary_status" "$temporary_latest"
      return 1
    }
  chmod 0644 "$temporary_status"
  slabctl_update_bridge_sync "$temporary_status" || {
    rm -f "$temporary_status" "$temporary_latest"
    return 1
  }
  cp "$temporary_status" "$temporary_latest" || {
    rm -f "$temporary_status" "$temporary_latest"
    return 1
  }
  chmod 0644 "$temporary_latest"
  slabctl_update_bridge_sync "$temporary_latest" || {
    rm -f "$temporary_status" "$temporary_latest"
    return 1
  }
  mv "$temporary_status" "$request_status" || {
    rm -f "$temporary_status" "$temporary_latest"
    return 1
  }
  slabctl_update_bridge_sync "$status_directory/requests" || return 1
  mv "$temporary_latest" "$status_directory/latest.json" || return 1
  slabctl_update_bridge_sync "$status_directory"
}

slabctl_update_bridge_reconcile_latest() {
  bridge_root=$1
  request_status=$2
  status_directory=$bridge_root/status
  temporary_latest=$(mktemp "$status_directory/.latest.XXXXXX") || return 1
  cp "$request_status" "$temporary_latest" || {
    rm -f "$temporary_latest"
    return 1
  }
  chmod 0644 "$temporary_latest"
  slabctl_update_bridge_sync "$temporary_latest" || {
    rm -f "$temporary_latest"
    return 1
  }
  mv "$temporary_latest" "$status_directory/latest.json" || {
    rm -f "$temporary_latest"
    return 1
  }
  slabctl_update_bridge_sync "$status_directory"
}

slabctl_update_bridge_failure_message() {
  error_path=$1
  fallback=$2
  # Only expose bounded slabctl-owned diagnostics. Third-party tools may echo
  # credential-bearing URLs or host details to stderr.
  message=$(sed -n 's/^slabctl: //p' "$error_path" | tail -n 1 |
    tr '\n\r\t' '   ' | sed 's/[[:cntrl:]]/ /g' | cut -c1-500)
  [ -n "$message" ] || message=$fallback
  printf '%s\n' "$message"
}

slabctl_update_bridge_recover_abandoned() {
  bridge_root=$1
  processing=$bridge_root/processing
  for abandoned in "$processing"/*.json; do
    [ -e "$abandoned" ] || [ -L "$abandoned" ] || continue
    request_id=${abandoned##*/}
    request_id=${request_id%.json}
    if ! printf '%s\n' "$request_id" |
      grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then
      rm -f "$abandoned"
      continue
    fi
    existing_status=$bridge_root/status/requests/$request_id.json
    action=
    channel=
    target=
    requested_at=
    started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ -e "$existing_status" ] || [ -L "$existing_status" ]; then
      [ -f "$existing_status" ] && [ ! -L "$existing_status" ] || {
        slabctl_error "update bridge status is unsafe: $existing_status"
        return 1
      }
      existing_state=$(jq -er '.state' "$existing_status" 2>/dev/null) || {
        slabctl_error "update bridge status is invalid: $existing_status"
        return 1
      }
      if [ "$existing_state" != running ]; then
        slabctl_update_bridge_reconcile_latest "$bridge_root" \
          "$existing_status" || return 1
        slabctl_update_bridge_remove_claim "$bridge_root" "$abandoned" || return 1
        continue
      fi
      action=$(jq -r '.action // empty' "$existing_status") || return 1
      channel=$(jq -r '.channel // empty' "$existing_status") || return 1
      target=$(jq -r '.target // empty' "$existing_status") || return 1
      requested_at=$(jq -r '.requestedAt // empty' "$existing_status") || return 1
      started_at=$(jq -r '.startedAt // empty' "$existing_status" 2>/dev/null || true)
      [ -n "$started_at" ] || started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    fi
    completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    slabctl_update_bridge_publish_status "$bridge_root" "$request_id" \
      "$action" failed "$channel" "$target" "$requested_at" "$started_at" \
      "$completed_at" "" bridge_interrupted \
      "The host update worker stopped before it could confirm the result; refresh status before retrying." || return 1
    slabctl_update_bridge_remove_claim "$bridge_root" "$abandoned" || return 1
  done
  rm -f "$processing"/.snapshot.* "$processing"/.claim.* "$processing"/.result.* \
    "$processing"/.error.*
}

slabctl_update_bridge_validate_request() {
  request_path=$1
  request_id=$2
  now_epoch=$3
  jq -er --arg requestId "$request_id" --argjson now "$now_epoch" '
    def exact_keys($expected):
      type == "object" and ((keys | sort) == ($expected | sort));
    def semver:
      type == "string" and
      test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$");
    (try (.requestedAt | fromdateiso8601) catch null) as $requested |
    (try (.expiresAt | fromdateiso8601) catch null) as $expires |
    exact_keys(["schemaVersion", "requestId", "action", "channel", "target", "requestedAt", "expiresAt"]) and
    .schemaVersion == 1 and
    .requestId == $requestId and
    (.action | IN("check", "apply")) and
    (.channel | IN("stable", "candidate")) and
    ((.action == "check" and (.target == null or (.target | semver))) or
      (.action == "apply" and (.target | semver))) and
    (.requestedAt | type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      $requested != null) and
    (.expiresAt | type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      $expires != null) and
    $requested <= ($now + 60) and
    $expires > $now and
    $expires > $requested and
    ($expires - $requested) <= 900 and
    ($requested | todateiso8601) == .requestedAt and
    ($expires | todateiso8601) == .expiresAt
  ' "$request_path" >/dev/null 2>&1
}

slabctl_update_bridge_process() {
  bridge_root=$(slabctl_update_bridge_root)
  slabctl_update_bridge_validate_directories "$bridge_root" || return 1
  slabctl_update_bridge_sweep "$bridge_root" || return 1
  slabctl_update_bridge_recover_abandoned "$bridge_root" || return 1
  inbox=$bridge_root/requests
  staging=$inbox/.claimed
  processing=$bridge_root/processing
  expected_request_uid=${SLAB_UPDATE_BRIDGE_REQUEST_UID:-10001}

  for candidate in "$staging"/*.json "$inbox"/*.json; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    request_name=${candidate##*/}
    request_id=${request_name%.json}
    if ! printf '%s\n' "$request_id" |
      grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then
      case "$candidate" in
        "$staging"/*)
          slabctl_update_bridge_remove_inbox_file "$staging" "$candidate" || return 1
          ;;
        *)
          slabctl_update_bridge_remove_inbox_file "$inbox" "$candidate" || return 1
          ;;
      esac
      return 0
    fi
    status_path=$bridge_root/status/requests/$request_id.json
    if [ -e "$status_path" ] || [ -L "$status_path" ]; then
      case "$candidate" in
        "$staging"/*)
          slabctl_update_bridge_remove_inbox_file "$staging" "$candidate" || return 1
          ;;
        *)
          slabctl_update_bridge_remove_inbox_file "$inbox" "$candidate" || return 1
          ;;
      esac
      return 0
    fi
    if slabctl_update_bridge_replay_seen "$bridge_root" "$request_id"; then
      duplicate_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      publish_status=0
      slabctl_update_bridge_publish_status "$bridge_root" "$request_id" \
        "" failed "" "" "" "$duplicate_at" "$duplicate_at" "" \
        duplicate_request "This update request ID was already accepted." ||
        publish_status=$?
      case "$candidate" in
        "$staging"/*)
          slabctl_update_bridge_remove_inbox_file "$staging" "$candidate" || return 1
          ;;
        *)
          slabctl_update_bridge_remove_inbox_file "$inbox" "$candidate" || return 1
          ;;
      esac
      [ "$publish_status" -eq 0 ] || return "$publish_status"
      return 0
    fi
    case "$candidate" in
      "$staging"/*) staged=$candidate ;;
      *)
        staged=$staging/$request_name
        if [ -e "$staged" ] || [ -L "$staged" ]; then
          slabctl_update_bridge_remove_inbox_file "$inbox" "$candidate" || return 1
          return 0
        fi
        mv "$candidate" "$staged" || continue
        slabctl_update_bridge_sync "$staging" || return 1
        slabctl_update_bridge_sync "$inbox" || return 1
        ;;
    esac
    claimed=$processing/$request_id.json
    started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ -L "$staged" ] || [ ! -f "$staged" ] ||
      [ "$(slabctl_update_bridge_stat '%u' "$staged" 2>/dev/null || printf invalid)" != "$expected_request_uid" ] ||
      [ "$(slabctl_update_bridge_stat '%a' "$staged" 2>/dev/null || printf invalid)" != 600 ] ||
      [ "$(slabctl_update_bridge_stat '%h' "$staged" 2>/dev/null || printf invalid)" != 1 ] ||
      ! request_size=$(slabctl_update_bridge_stat '%s' "$staged" 2>/dev/null) ||
      ! printf '%s\n' "$request_size" | grep -Eq '^[0-9]+$' ||
      [ "$request_size" -lt 2 ] || [ "$request_size" -gt 16384 ]
    then
      publish_status=0
      slabctl_update_bridge_publish_status "$bridge_root" "$request_id" \
        "" failed "" "" "" "$started_at" "$started_at" "" \
        invalid_request "The update request file was unsafe or malformed." ||
        publish_status=$?
      slabctl_update_bridge_remove_inbox_file "$staging" "$staged" || return 1
      [ "$publish_status" -eq 0 ] || return "$publish_status"
      return 0
    fi
    claim_temporary=$(mktemp "$processing/.claim.XXXXXX") || return 1
    result=$(mktemp "$processing/.result.XXXXXX") || {
      rm -f "$claim_temporary"
      return 1
    }
    error=$(mktemp "$processing/.error.XXXXXX") || {
      rm -f "$claim_temporary" "$result"
      return 1
    }
    chmod 0600 "$claim_temporary" "$result" "$error"
    if ! dd if="$staged" of="$claim_temporary" bs=16385 count=1 status=none; then
      rm -f "$claim_temporary" "$result" "$error"
      return 1
    fi
    snapshot_size=$(slabctl_update_bridge_stat '%s' "$claim_temporary") || return 1
    now_epoch=$(date -u +%s)
    if [ "$snapshot_size" -lt 2 ] || [ "$snapshot_size" -gt 16384 ] ||
      ! slabctl_update_bridge_validate_request "$claim_temporary" "$request_id" "$now_epoch"
    then
      publish_status=0
      slabctl_update_bridge_publish_status "$bridge_root" "$request_id" \
        "" failed "" "" "" "$started_at" "$started_at" "" \
        invalid_request "The update request was invalid, expired, or exceeded its lifetime." ||
        publish_status=$?
      rm -f "$claim_temporary" "$result" "$error"
      slabctl_update_bridge_remove_inbox_file "$staging" "$staged" || return 1
      [ "$publish_status" -eq 0 ] || return "$publish_status"
      return 0
    fi
    action=$(jq -er '.action' "$claim_temporary") || return 1
    channel=$(jq -er '.channel' "$claim_temporary") || return 1
    target=$(jq -r '.target // empty' "$claim_temporary") || return 1
    requested_at=$(jq -er '.requestedAt' "$claim_temporary") || return 1
    expires_epoch=$(jq -er '.expiresAt | fromdateiso8601' "$claim_temporary") || return 1
    [ ! -e "$claimed" ] && [ ! -L "$claimed" ] || return 1
    mv "$claim_temporary" "$claimed" || return 1
    slabctl_update_bridge_sync "$claimed" || return 1
    slabctl_update_bridge_sync "$processing" || return 1
    slabctl_update_bridge_record_replay "$bridge_root" "$request_id" \
      "$expires_epoch" || return 1
    slabctl_update_bridge_remove_inbox_file "$staging" "$staged" || return 1
    slabctl_update_bridge_publish_status "$bridge_root" "$request_id" \
      "$action" running "$channel" "$target" "$requested_at" "$started_at" \
      "" "" "" "" || return 1

    operation_status=0
    result_for_status=
    case "$action" in
      check)
        slabctl_update_check "$channel" json "$target" > "$result" 2> "$error" ||
          operation_status=$?
        [ "$operation_status" -ne 0 ] || result_for_status=$result
        ;;
      apply)
        if slabctl_update_apply "$channel" 1 "$target" > "$result" 2> "$error"; then
          : > "$result"
          if slabctl_update_check "$channel" json "$target" > "$result" 2>> "$error"; then
            result_for_status=$result
          else
            : > "$result"
          fi
        else
          operation_status=$?
        fi
        ;;
    esac
    completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ "$operation_status" -eq 0 ]; then
      slabctl_update_bridge_publish_status "$bridge_root" "$request_id" \
        "$action" succeeded "$channel" "$target" "$requested_at" "$started_at" \
        "$completed_at" "$result_for_status" "" "" || return 1
    else
      error_message=$(slabctl_update_bridge_failure_message "$error" \
        "The signed update operation failed.")
      slabctl_update_bridge_publish_status "$bridge_root" "$request_id" \
        "$action" failed "$channel" "$target" "$requested_at" "$started_at" \
        "$completed_at" "" update_failed "$error_message" || return 1
    fi
    rm -f "$result" "$error"
    slabctl_update_bridge_remove_claim "$bridge_root" "$claimed" || return 1
    return "$operation_status"
  done
}

slabctl_update_check() (
  channel=${1:-$(jq -r '.channel' "$SLABCTL_INSTALL_DIRECTORY/release-manifest.json")}
  output_format=${2:-text}
  expected_target=${3:-}
  trap slabctl_release_cleanup EXIT
  trap 'exit 130' HUP INT TERM
  slabctl_release_prepare "$channel" "$release_public_key_file" || exit 1
  slabctl_update_assert_expected_target "$expected_target" check "$channel" || exit 1
  current=$(sed -n '1p' "$SLABCTL_INSTALL_DIRECTORY/VERSION")
  if [ "$output_format" = json ]; then
    slabctl_update_check_json "$current" "$channel"
    exit
  fi
  if recovery_reason=$(slabctl_update_check_recovery_reason "$current"); then
    :
  else
    slabctl_error "$recovery_reason"
    exit 1
  fi
  echo "Installed: $current"
  echo "Channel: $channel"
  echo "Available: $SLAB_RELEASE_VERSION"
  if [ "$current" = "$SLAB_RELEASE_VERSION" ]; then
    echo "Status: up to date"
  elif slabctl_update_is_newer "$current" "$SLAB_RELEASE_VERSION"; then
    echo "Status: update available"
  elif slabctl_update_has_equal_precedence "$current" "$SLAB_RELEASE_VERSION"; then
    echo "Status: channel target has equal SemVer precedence with different build metadata"
  else
    echo "Status: channel points to an older release; no downgrade will be applied"
  fi
)

slabctl_update_apply() (
  channel=$1
  confirmed=$2
  expected_target=${3:-}
  update_succeeded=0
  mutation_started=0
  maintenance_entered=0
  backup_path=
  recovery_directory=
  current=$(sed -n '1p' "$SLABCTL_INSTALL_DIRECTORY/VERSION")
  target=
  rollback_compatible=false

  slabctl_update_assert_recoverable_state || exit 1

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
          if slabctl_update_write_state ROLLED_BACK "$target" "$current" "$channel" \
            "Update failed; the previous release was restored and is healthy." \
            "$backup_path" "$recovery_directory" "$rollback_compatible"
          then
            if slabctl_update_exit_maintenance >/dev/null 2>&1; then
              maintenance_entered=0
              echo "Previous release restored successfully." >&2
            else
              slabctl_update_write_state RECOVERY_REQUIRED "$current" "$target" "$channel" \
                "The previous release is healthy, but agent dispatch remains in maintenance mode. Restore dispatch with: slabctl update recover-maintenance" \
                "$backup_path" "$recovery_directory" "$rollback_compatible" || true
              echo "slabctl: the previous release is healthy, but agent dispatch remains in maintenance mode" >&2
            fi
          else
            slabctl_error "the previous release is healthy, but its recovery ledger could not be persisted; maintenance remains enabled"
          fi
        else
          if slabctl_update_stop_for_recovery; then
            recovery_message="Automatic rollback failed. The stack is stopped; restore the verified pre-update backup."
          else
            recovery_message="Automatic rollback failed and running services could not be ruled out. Stop the stack, then restore the verified pre-update backup."
          fi
          slabctl_update_write_state RECOVERY_REQUIRED "$current" "$target" "$channel" \
            "$recovery_message" \
            "$backup_path" "$recovery_directory" "$rollback_compatible" || true
          slabctl_error "automatic rollback failed; recovery from the verified backup is required"
        fi
      elif [ "$mutation_started" -eq 1 ]; then
        if slabctl_update_stop_for_recovery; then
          recovery_message="The update crossed a non-rollback-compatible migration boundary. The stack is stopped; restore the verified pre-update backup."
        else
          recovery_message="The update crossed a non-rollback-compatible migration boundary and running services could not be ruled out. Stop the stack, then restore the verified pre-update backup."
        fi
        slabctl_update_write_state RECOVERY_REQUIRED "$current" "$target" "$channel" \
          "$recovery_message" \
          "$backup_path" "$recovery_directory" "$rollback_compatible" || true
        slabctl_error "automatic image rollback is unsafe; recovery from the verified backup is required"
      else
        if [ "$maintenance_entered" -eq 1 ]; then
          if slabctl_update_exit_maintenance >/dev/null 2>&1; then
            maintenance_entered=0
            slabctl_update_write_state CANCELLED "$current" "$target" "$channel" \
              "Update stopped before changing the installed release; agent dispatch maintenance was cleared." \
              "$backup_path" "$recovery_directory" "$rollback_compatible" || true
          else
            slabctl_update_write_state RECOVERY_REQUIRED "$current" "$target" "$channel" \
              "Update stopped before changing the installed release, but agent dispatch remains in maintenance mode. Restore dispatch with: slabctl update recover-maintenance" \
              "$backup_path" "" "$rollback_compatible" || true
          fi
        fi
      fi
    fi
    slabctl_release_cleanup
    exit "$cleanup_status"
  }
  trap slabctl_release_cleanup EXIT
  trap 'exit 130' HUP INT TERM

  slabctl_release_prepare "$channel" "$release_public_key_file" || exit 1
  target=$SLAB_RELEASE_VERSION
  slabctl_update_assert_expected_target "$expected_target" apply "$channel" || exit 1
  if [ "$current" = "$target" ]; then
    echo "Slab is already up to date at $current."
    update_succeeded=1
    exit 0
  fi
  if ! slabctl_update_is_newer "$current" "$target"; then
    if slabctl_update_has_equal_precedence "$current" "$target"; then
      slabctl_error "refusing release with equal SemVer precedence but different build metadata: $current -> $target"
    else
      slabctl_error "refusing channel downgrade from $current to $target"
    fi
    exit 1
  fi
  minimum_manager=$(jq -er '.minimumSlabctlVersion' \
    "$SLAB_RELEASE_MANIFEST") || exit 1
  manager_version=${SLABCTL_MANAGER_VERSION:-$current}
  slabctl_update_version_at_least "$manager_version" "$minimum_manager" || {
    slabctl_error "release $target requires slabctl $minimum_manager or newer; installed manager is $manager_version"
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
  trap cleanup_update EXIT
  maintenance_entered=1
  slabctl_update_enter_maintenance || exit 1
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
  slabctl_update_install_management "$SLAB_RELEASE_BUNDLE_ROOT" || exit 1
  slabctl_update_installed_identity "$target" || exit 1
  slabctl_update_write_state UPDATED "$current" "$target" "$channel" \
    "Release applied; services and application readiness passed." \
    "$backup_path" "$recovery_directory" "$rollback_compatible"
  slabctl_update_exit_maintenance || exit 1
  maintenance_entered=0
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
        if slabctl_update_stop_for_recovery; then
          rollback_message="Rollback stopped after release files changed. The stack is stopped; restore a verified backup."
        else
          rollback_message="Rollback stopped after release files changed and running services could not be ruled out. Stop the stack, then restore a verified backup."
        fi
        slabctl_update_write_state RECOVERY_REQUIRED "$from_version" "$to_version" "$channel" \
          "$rollback_message" \
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
  slabctl_update_write_state ROLLED_BACK "$from_version" "$to_version" "$channel" \
    "Operator rollback completed and the previous release is healthy." \
    "$previous_backup" "$recovery_directory" true
  slabctl_update_exit_maintenance || exit 1
  rollback_maintenance=0
  rollback_succeeded=1
  echo "Slab rolled back successfully: $from_version -> $to_version"
  echo "Pre-rollback backup: $rollback_backup"
)
