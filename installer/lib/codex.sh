#!/bin/sh

slabctl_error() {
  echo "slabctl: $*" >&2
  return 1
}

slabctl_validate_managed_file() {
  managed_file=$1
  if [ ! -f "$managed_file" ] || [ -L "$managed_file" ]; then
    slabctl_error "installed stack metadata is missing or unsafe: $managed_file"
    return 1
  fi
  expected_uid=${SLABCTL_EXPECTED_OWNER_UID:-0}
  [ "$(stat -c '%u' "$managed_file")" -eq "$expected_uid" ] || {
    slabctl_error "installed stack metadata has an unexpected owner: $managed_file"
    return 1
  }
  managed_mode=$(stat -c '%a' "$managed_file")
  if printf '%s\n' "$managed_mode" | grep -Eq '([2367][0-7]|[0-7][2367])$'; then
    slabctl_error "installed stack metadata is group/world writable: $managed_file"
    return 1
  fi
}

slab_acquire_management_lock() {
  install_directory=$1
  lock_file=$install_directory/config/management.lock
  [ ! -L "$lock_file" ] || {
    slabctl_error "management lock cannot be a symbolic link"
    return 1
  }
  exec 8>"$lock_file"
  chmod 0600 "$lock_file"
  if ! flock -n 8; then
    slabctl_error "another installer or slabctl command is already operating on this installation"
    return 1
  fi
}

slabctl_load_installation() {
  install_directory=$1
  case "$install_directory" in
    /*) ;;
    *) slabctl_error "installation directory must be absolute"; return 1 ;;
  esac
  case "$install_directory" in
    *//* | */ | */./* | */../*)
      slabctl_error "installation directory is not canonical"
      return 1
      ;;
  esac

  state_file=$install_directory/config/install-state.json
  access_file=$install_directory/config/access-mode
  environment_file=$install_directory/config/install.env
  for managed_file in "$state_file" "$access_file" "$environment_file" \
    "$install_directory/compose.yml"
  do
    slabctl_validate_managed_file "$managed_file" || return 1
  done

  project_name=$(jq -er '.projectName | select(test("^[a-z0-9][a-z0-9_-]*$"))' \
    "$state_file") || {
    slabctl_error "installed Compose project identity is invalid"
    return 1
  }
  access_mode=$(sed -n '1p' "$access_file")
  case "$access_mode" in
    private) overlay_file=$install_directory/compose.private.yml ;;
    domain) overlay_file=$install_directory/compose.domain.yml ;;
    *) slabctl_error "installed access mode is invalid"; return 1 ;;
  esac
  slabctl_validate_managed_file "$overlay_file" || return 1

  SLABCTL_INSTALL_DIRECTORY=$install_directory
  SLABCTL_STATE_FILE=$state_file
  SLABCTL_PROJECT_NAME=$project_name
  SLABCTL_ENVIRONMENT_FILE=$environment_file
  SLABCTL_OVERLAY_FILE=$overlay_file
}

slabctl_compose() {
  docker compose \
    --project-name "$SLABCTL_PROJECT_NAME" \
    --env-file "$SLABCTL_ENVIRONMENT_FILE" \
    -f "$SLABCTL_INSTALL_DIRECTORY/compose.yml" \
    -f "$SLABCTL_OVERLAY_FILE" \
    "$@"
}

slabctl_codex_command() {
  allocate_tty=$1
  shift
  if [ "$allocate_tty" -eq 1 ]; then
    slabctl_compose exec \
      -e CODEX_HOME=/var/lib/slab-runner/codex \
      slab-runner /usr/local/bin/codex "$@"
  else
    slabctl_compose exec -T \
      -e CODEX_HOME=/var/lib/slab-runner/codex \
      slab-runner /usr/local/bin/codex "$@"
  fi
}

slabctl_wait_for_runner() {
  attempts=${SLABCTL_RUNNER_HEALTH_ATTEMPTS:-30}
  delay=${SLABCTL_RUNNER_HEALTH_DELAY_SECONDS:-2}
  attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    container_id=$(slabctl_compose ps -q slab-runner 2>/dev/null || true)
    if [ -n "$container_id" ]; then
      health=$(docker inspect "$container_id" \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        2>/dev/null || true)
      [ "$health" = healthy ] && return 0
    fi
    sleep "$delay"
    attempt=$((attempt + 1))
  done
  slabctl_error "Runner did not become healthy after restart"
}

slabctl_update_runtime_state() {
  runtime_status=$1
  current_status=$(jq -r '.status // empty' "$SLABCTL_STATE_FILE") || return 1
  next_status=$current_status
  case "$runtime_status:$current_status" in
    authenticated:READY_NO_RUNTIME) next_status=READY ;;
    signed_out:READY) next_status=READY_NO_RUNTIME ;;
  esac
  [ "$next_status" != "$current_status" ] || return 0

  updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  temporary_state=$SLABCTL_INSTALL_DIRECTORY/config/.install-state.slabctl.$$
  jq \
    --arg status "$next_status" \
    --arg updatedAt "$updated_at" \
    '.status = $status |
     .updatedAt = $updatedAt |
     .lastKnownGood = {
       status: $status,
       version,
       accessMode,
       publicUrl,
       projectName,
       completedAt: $updatedAt
     }' "$SLABCTL_STATE_FILE" > "$temporary_state" || return 1
  chmod 0600 "$temporary_state"
  mv "$temporary_state" "$SLABCTL_STATE_FILE"
}

slabctl_restart_runner() {
  slabctl_compose restart slab-runner >/dev/null
  slabctl_wait_for_runner
}

slabctl_runner_codex_available() {
  slabctl_compose exec -T slab-runner node -e '
    const fs = require("node:fs");
    const token = fs.readFileSync("/run/secrets/runner_token", "utf8").trim();
    fetch("http://127.0.0.1:6990/runtimes", {
      headers: { "X-Runner-Token": token },
    }).then(async (response) => {
      if (!response.ok) process.exit(1);
      const payload = await response.json();
      const codex = payload.data?.find((runtime) => runtime.id === "codex");
      process.exit(codex?.available === true ? 0 : 1);
    }).catch(() => process.exit(1));
  '
}

slabctl_codex_login_device() {
  slabctl_codex_command 1 login --device-auth || return 1
  slabctl_restart_runner || return 1
  slabctl_codex_command 0 login status || return 1
  slabctl_runner_codex_available || {
    slabctl_error "Runner did not confirm that Codex is available"
    return 1
  }
  slabctl_update_runtime_state authenticated
  echo "Codex authentication is active. Slab Agents will use it for new runs."
}

slabctl_codex_login_api_key() {
  if [ -t 0 ]; then
    api_key=$(
      restore_tty() { stty echo < /dev/tty 2>/dev/null || true; }
      trap restore_tty EXIT
      trap 'restore_tty; exit 130' HUP INT TERM
      printf 'OpenAI API key: ' > /dev/tty
      stty -echo < /dev/tty
      IFS= read -r entered_key < /dev/tty
      restore_tty
      printf '\n' > /dev/tty
      [ -n "$entered_key" ] || exit 1
      trap - EXIT HUP INT TERM
      printf '%s' "$entered_key"
    ) || {
      slabctl_error "an API key is required"
      return 1
    }
    printf '%s' "$api_key" |
      slabctl_codex_command 0 login --with-api-key || {
        api_key=
        return 1
      }
    api_key=
  else
    slabctl_codex_command 0 login --with-api-key
  fi
  slabctl_restart_runner || return 1
  slabctl_codex_command 0 login status || return 1
  slabctl_runner_codex_available || {
    slabctl_error "Runner did not confirm that Codex is available"
    return 1
  }
  slabctl_update_runtime_state authenticated
  echo "Codex authentication is active. Slab Agents will use it for new runs."
}

slabctl_codex_status() {
  slabctl_codex_command 0 login status || return 1
  slabctl_runner_codex_available || {
    slabctl_error "Codex credentials exist, but Runner does not report the runtime available"
    return 1
  }
}

slabctl_codex_logout() {
  slabctl_codex_command 0 logout || return 1
  slabctl_restart_runner || return 1
  slabctl_update_runtime_state signed_out
  echo "Codex is signed out. Existing product data is unchanged."
}
