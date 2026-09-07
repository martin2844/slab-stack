#!/bin/sh

slabctl_changepass() (
  # Keep secrets and terminal cleanup local; preserve the caller's traps.
  set +x
  if ! ( : <> /dev/tty ) 2>/dev/null; then
    slabctl_error "changing the administrator password requires an interactive terminal"
    exit 1
  fi
  exec 3<> /dev/tty
  terminal_state=$(stty -g <&3) || exit 1
  trap 'stty "$terminal_state" <&3 2>/dev/null || true' EXIT
  trap 'exit 130' HUP INT TERM
  printf '\nChange Slab administrator password\n' >&3
  printf 'Use 12 to 256 characters. Existing browser sessions will be signed out.\n' >&3
  stty -echo <&3 || exit 1
  printf '\nNew password: ' >&3
  IFS= read -r new_password <&3 || exit 1
  printf '\nConfirm new password: ' >&3
  IFS= read -r confirmation <&3 || exit 1
  stty "$terminal_state" <&3 || exit 1
  printf '\n' >&3
  [ "$new_password" = "$confirmation" ] || {
    slabctl_error "passwords do not match; password was not changed"
    exit 1
  }
  if [ "${#new_password}" -lt 12 ] || [ "${#new_password}" -gt 256 ]; then
    slabctl_error "administrator password must contain 12 to 256 characters; password was not changed"
    exit 1
  fi
  if ! printf '%s\n' "$new_password" |
    slabctl_compose exec -T slab-agents node scripts/admin-bootstrap.mjs --rotate
  then
    slabctl_error "password change failed; check Slab Agents with sudo slabctl doctor before retrying"
    exit 1
  fi
  printf '\nAdministrator password changed. Sign in with your new password.\n'
)

slabctl_stack_start() {
  slabctl_compose config --quiet || {
    slabctl_error "installed Compose configuration is invalid"
    return 1
  }
  slabctl_compose up -d --remove-orphans
}

slabctl_stack_stop() {
  # `down` removes only containers and networks. Named volumes and all product
  # data remain intact, while the next boot reruns the idempotent migrations.
  slabctl_compose down --remove-orphans
}

slabctl_stack_restart() {
  slabctl_stack_stop || return 1
  slabctl_stack_start
}

slabctl_stack_status() {
  slabctl_compose ps
}

slabctl_service_health_status() {
  service_name=$1
  container_id=$(slabctl_compose ps -q "$service_name" 2>/dev/null || true)
  [ -n "$container_id" ] || return 1
  docker inspect "$container_id" \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}'
}

slabctl_memory_mode() {
  sed -n 's/^SLAB_MEMORY_MODE=//p' "$SLABCTL_ENVIRONMENT_FILE" | head -n 1
}

slabctl_wait_for_healthy_stack() {
  attempts=${SLABCTL_HEALTH_ATTEMPTS:-90}
  interval=${SLABCTL_HEALTH_INTERVAL_SECONDS:-2}
  attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    pending=
    services="slab-api slab-mcp slab-docs slab-email slab-runner slab-agents"
    if [ "$(slabctl_memory_mode)" = self_hosted ]; then
      services="$services honcho-database honcho-redis honcho-api honcho-deriver"
    fi
    for service_name in $services; do
      health=$(slabctl_service_health_status "$service_name" 2>/dev/null || true)
      [ "$health" = healthy ] || pending="$pending $service_name"
    done
    if [ "$SLABCTL_ACCESS_MODE" = domain ]; then
      caddy_status=$(slabctl_service_health_status caddy 2>/dev/null || true)
      [ "$caddy_status" = running ] || pending="$pending caddy"
    fi
    [ -z "$pending" ] && return 0
    sleep "$interval"
    attempt=$((attempt + 1))
  done
  slabctl_error "timed out waiting for healthy services:$pending"
}
