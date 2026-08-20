#!/bin/sh

slab_completed_steps_for_phase() {
  case "$1" in
    rendered) printf '%s\n' '["rendered"]' ;;
    compose_validated) printf '%s\n' '["rendered","compose_validated"]' ;;
    compose_reconciled) printf '%s\n' '["rendered","compose_validated","compose_reconciled"]' ;;
    services_healthy) printf '%s\n' '["rendered","compose_validated","compose_reconciled","services_healthy"]' ;;
    admin_configured) printf '%s\n' '["rendered","compose_validated","compose_reconciled","services_healthy","admin_configured"]' ;;
    *) printf '%s\n' '[]' ;;
  esac
}

slab_prepare_state_directory() {
  install_directory=$1
  config_directory=$install_directory/config
  state_file=$config_directory/install-state.json
  [ ! -L "$config_directory" ] || {
    echo "Refusing symbolic-link config directory: $config_directory" >&2
    return 1
  }
  [ ! -e "$config_directory" ] || [ -d "$config_directory" ] || {
    echo "Installation config path is not a directory: $config_directory" >&2
    return 1
  }
  [ ! -L "$state_file" ] || {
    echo "Refusing symbolic-link install state: $state_file" >&2
    return 1
  }
  mkdir -p "$config_directory"
  chmod 0755 "$install_directory" "$config_directory"
}

slab_validate_existing_install_identity() {
  install_directory=$1
  version=$2
  access_mode=$3
  public_url=$4
  project_name=$5
  state_file=$install_directory/config/install-state.json

  [ -e "$state_file" ] || {
    echo "Existing installation has no state ledger; refusing an ambiguous in-place rerun." >&2
    return 1
  }
  if [ -L "$state_file" ] || [ ! -f "$state_file" ]; then
    echo "Existing install state must be a regular, non-symbolic-link file." >&2
    return 1
  fi
  jq -e \
    --arg version "$version" \
    --arg accessMode "$access_mode" \
    --arg publicUrl "$public_url" \
    --arg projectName "$project_name" \
    '.version == $version and
     .accessMode == $accessMode and
     .publicUrl == $publicUrl and
     .projectName == $projectName' \
    "$state_file" >/dev/null 2>&1 || {
      echo "Installer identity differs from the existing installation; project, access mode, and URL are immutable during reruns." >&2
      return 1
    }
}

slab_write_install_state() {
  install_directory=$1
  version=$2
  access_mode=$3
  public_url=$4
  project_name=$5
  attempt_started_at=$6
  phase=$7
  status=$8

  state_file=$install_directory/config/install-state.json
  temporary_state=$install_directory/config/.install-state.tmp.$$
  updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  completed_steps=$(slab_completed_steps_for_phase "$phase") || return 1
  previous_state=null
  if [ -f "$state_file" ]; then
    previous_state=$(jq -c '
      if (.status == "READY" or .status == "READY_NO_RUNTIME" or .status == "TLS_PENDING") then
        {
          status,
          version,
          accessMode,
          publicUrl,
          projectName,
          completedAt: (.updatedAt // .installedAt // null)
        }
      else
        (.lastKnownGood // null)
      end
    ' "$state_file") || return 1
  fi

  jq -n \
    --arg version "$version" \
    --arg accessMode "$access_mode" \
    --arg publicUrl "$public_url" \
    --arg projectName "$project_name" \
    --arg status "$status" \
    --arg phase "$phase" \
    --arg attemptStartedAt "$attempt_started_at" \
    --arg updatedAt "$updated_at" \
    --argjson completedSteps "$completed_steps" \
    --argjson lastKnownGood "$previous_state" \
    '{
      version: $version,
      accessMode: $accessMode,
      publicUrl: $publicUrl,
      projectName: $projectName,
      status: $status,
      phase: $phase,
      completedSteps: $completedSteps,
      attemptStartedAt: $attemptStartedAt,
      updatedAt: $updatedAt,
      lastKnownGood: $lastKnownGood
    }' > "$temporary_state" || return 1
  chmod 0600 "$temporary_state"
  mv "$temporary_state" "$state_file"
}
