#!/bin/sh

slab_validate_compose_project_name() {
  project_name=$1
  printf '%s\n' "$project_name" | grep -Eq '^[a-z0-9][a-z0-9_-]*$' || {
    echo "Compose project name must use lowercase letters, numbers, dashes, or underscores." >&2
    return 1
  }
}

slab_configure_compose() {
  install_directory=$1
  access_mode=$2
  project_name=$3
  slab_validate_compose_project_name "$project_name" || return 1

  SLAB_COMPOSE_INSTALL_DIRECTORY=$install_directory
  SLAB_COMPOSE_PROJECT_NAME=$project_name
  case "$access_mode" in
    private) SLAB_COMPOSE_OVERLAY=$install_directory/compose.private.yml ;;
    domain) SLAB_COMPOSE_OVERLAY=$install_directory/compose.domain.yml ;;
    *) echo "Unsupported access mode: $access_mode" >&2; return 1 ;;
  esac
}

slab_compose() {
  docker compose \
    --project-name "$SLAB_COMPOSE_PROJECT_NAME" \
    --env-file "$SLAB_COMPOSE_INSTALL_DIRECTORY/config/install.env" \
    -f "$SLAB_COMPOSE_INSTALL_DIRECTORY/compose.yml" \
    -f "$SLAB_COMPOSE_OVERLAY" \
    "$@"
}

slab_validate_compose_configuration() {
  slab_compose config --quiet
}

slab_pull_and_start() {
  slab_run_compose_step pull pull || return 1
  slab_run_compose_step reconcile up -d --remove-orphans
}

slab_run_compose_step() {
  step_name=$1
  shift
  SLAB_COMPOSE_DIAGNOSTIC=$(mktemp "${TMPDIR:-/tmp}/slab-compose-${step_name}.XXXXXX") || return 1
  chmod 0600 "$SLAB_COMPOSE_DIAGNOSTIC"
  if ! slab_compose "$@" >"$SLAB_COMPOSE_DIAGNOSTIC" 2>&1; then
    echo "Docker Compose $step_name failed:" >&2
    slab_sanitize_diagnostic_stream < "$SLAB_COMPOSE_DIAGNOSTIC" | head -c 8192 >&2
    echo >&2
    rm -f "$SLAB_COMPOSE_DIAGNOSTIC"
    SLAB_COMPOSE_DIAGNOSTIC=
    return 1
  fi
  rm -f "$SLAB_COMPOSE_DIAGNOSTIC"
  SLAB_COMPOSE_DIAGNOSTIC=
}

slab_compose_service_container() {
  service_name=$1
  slab_compose ps -q "$service_name"
}

slab_print_compose_status() {
  slab_compose ps >&2 || true
}

slab_sanitize_diagnostic_stream() {
  LC_ALL=C sed -E \
    -e "s/(Bearer[[:space:]]+)[^[:space:]\"']+/\\1[REDACTED]/g" \
    -e 's/("[A-Za-z0-9_]*(password|token|secret|api[_-]?key)[A-Za-z0-9_]*"[[:space:]]*:[[:space:]]*")[^"]*/\1[REDACTED]/Ig' \
    -e 's/([A-Za-z0-9_]*(password|token|secret|api[_-]?key)[A-Za-z0-9_]*[=:][[:space:]]*)[^,[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/[a-f0-9]{32,}/[REDACTED]/g'
}

slab_detect_first_failing_service() {
  for service_name in slab-api slab-mcp slab-docs slab-email slab-runner slab-agents caddy; do
    container_id=$(slab_compose_service_container "$service_name" 2>/dev/null || true)
    [ -n "$container_id" ] || continue
    container_state=$(docker inspect "$container_id" \
      --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
      2>/dev/null || true)
    case "$container_state" in
      *unhealthy* | exited* | dead*) printf '%s\n' "$service_name"; return 0 ;;
    esac
  done

  for service_name in work-migrate docs-migrate email-migrate; do
    container_id=$(slab_compose_service_container "$service_name" 2>/dev/null || true)
    [ -n "$container_id" ] || continue
    container_state=$(docker inspect "$container_id" \
      --format '{{.State.Status}} {{.State.ExitCode}}' 2>/dev/null || true)
    case "$container_state" in
      'exited 0') ;;
      exited\ * | dead\ *) printf '%s\n' "$service_name"; return 0 ;;
    esac
  done
  return 1
}

slab_print_bounded_service_logs() {
  service_name=$1
  [ -n "$service_name" ] || return 0
  echo "Bounded sanitized logs for $service_name:" >&2
  slab_compose logs --no-color --tail 40 "$service_name" 2>&1 |
    slab_sanitize_diagnostic_stream |
    head -c 8192 >&2 || true
  echo >&2
}
