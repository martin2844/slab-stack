#!/bin/sh

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
