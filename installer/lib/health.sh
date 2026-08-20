#!/bin/sh

slab_health_error() {
  echo "$*" >&2
  return 1
}

slab_service_health_status() {
  service_name=$1
  container_id=$(slab_compose_service_container "$service_name") || return 1
  [ -n "$container_id" ] || return 1
  docker inspect "$container_id" --format '{{.State.Health.Status}}'
}

slab_service_runtime_status() {
  service_name=$1
  container_id=$(slab_compose_service_container "$service_name") || return 1
  [ -n "$container_id" ] || return 1
  docker inspect "$container_id" --format '{{.State.Status}}'
}

slab_wait_for_healthy_stack() {
  attempts=${SLAB_HEALTH_ATTEMPTS:-90}
  interval=${SLAB_HEALTH_INTERVAL_SECONDS:-2}
  count=0
  while :; do
    pending=
    for service_name in slab-api slab-mcp slab-docs slab-email slab-runner slab-agents; do
      health=$(slab_service_health_status "$service_name" 2>/dev/null || true)
      [ "$health" = healthy ] || pending="$pending $service_name"
    done
    if [ "${SLAB_ACCESS_MODE:-private}" = domain ]; then
      caddy_status=$(slab_service_runtime_status caddy 2>/dev/null || true)
      [ "$caddy_status" = running ] || pending="$pending caddy"
    fi
    [ -z "$pending" ] && return 0
    count=$((count + 1))
    if [ "$count" -ge "$attempts" ]; then
      SLAB_FAILED_SERVICE=$(printf '%s\n' "$pending" | awk '{print $1}')
      slab_health_error "Timed out waiting for healthy services:$pending"
      return 1
    fi
    sleep "$interval"
  done
}

slab_agents_http_status() {
  path=$1
  container_id=$(slab_compose_service_container slab-agents) || return 1
  [ -n "$container_id" ] || return 1
  docker exec "$container_id" node -e '
    fetch(`http://127.0.0.1:3009${process.argv[1]}`)
      .then((response) => process.stdout.write(String(response.status)))
      .catch(() => process.exit(1));
  ' "$path"
}

slab_wait_for_agents_ready() {
  attempts=${SLAB_HEALTH_ATTEMPTS:-90}
  interval=${SLAB_HEALTH_INTERVAL_SECONDS:-2}
  count=0
  while :; do
    status=$(slab_agents_http_status /ready 2>/dev/null || true)
    [ "$status" = 200 ] && return 0
    count=$((count + 1))
    if [ "$count" -ge "$attempts" ]; then
      slab_health_error "Timed out waiting for Slab Agents readiness."
      return 1
    fi
    sleep "$interval"
  done
}

slab_bootstrap_admin_if_needed() {
  administrator_password=$1
  readiness=$(slab_agents_http_status /ready 2>/dev/null || true)
  case "$readiness" in
    200)
      echo "Administrator credentials already exist; keeping the current password."
      return 0
      ;;
    503) ;;
    *) slab_health_error "Slab Agents returned an unexpected readiness status: ${readiness:-unavailable}."; return 1 ;;
  esac

  container_id=$(slab_compose_service_container slab-agents) || return 1
  bootstrap_diagnostic=$(mktemp "${TMPDIR:-/tmp}/slab-admin-bootstrap.XXXXXX") || return 1
  chmod 0600 "$bootstrap_diagnostic"
  if ! printf '%s\n' "$administrator_password" |
    docker exec -i "$container_id" node scripts/admin-bootstrap.mjs \
      >/dev/null 2>"$bootstrap_diagnostic"
  then
    # Consumed by the installer's failure trap after this sourced helper exits.
    # shellcheck disable=SC2034
    SLAB_FAILED_SERVICE=slab-agents
    slab_health_error "Administrator bootstrap failed. The password was not stored by the installer."
    slab_sanitize_diagnostic_stream < "$bootstrap_diagnostic" | head -c 4096 >&2
    rm -f "$bootstrap_diagnostic"
    return 1
  fi
  rm -f "$bootstrap_diagnostic"
  slab_wait_for_agents_ready
}
