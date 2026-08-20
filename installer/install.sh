#!/bin/sh
set -eu

BUNDLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DEFAULT_MANIFEST=$BUNDLE_ROOT/releases/v0.1.0-candidate.2.json

# shellcheck source=installer/lib/preflight.sh
. "$BUNDLE_ROOT/installer/lib/preflight.sh"
# shellcheck source=installer/lib/prompts.sh
. "$BUNDLE_ROOT/installer/lib/prompts.sh"
# shellcheck source=installer/lib/config.sh
. "$BUNDLE_ROOT/installer/lib/config.sh"
# shellcheck source=installer/lib/lock.sh
. "$BUNDLE_ROOT/installer/lib/lock.sh"
# shellcheck source=installer/lib/secrets.sh
. "$BUNDLE_ROOT/installer/lib/secrets.sh"
# shellcheck source=installer/lib/render.sh
. "$BUNDLE_ROOT/installer/lib/render.sh"
# shellcheck source=installer/lib/docker.sh
. "$BUNDLE_ROOT/installer/lib/docker.sh"
# shellcheck source=installer/lib/health.sh
. "$BUNDLE_ROOT/installer/lib/health.sh"
# shellcheck source=installer/lib/state.sh
. "$BUNDLE_ROOT/installer/lib/state.sh"

SLAB_NON_INTERACTIVE=0
SLAB_DRY_RUN=0
SLAB_CONFIG_FILE=
SLAB_MANIFEST=$DEFAULT_MANIFEST
SLAB_INSTALL_STARTED=0
SLAB_ADMIN_PASSWORD=
SLAB_COMPOSE_CONFIGURED=0
SLAB_STATE_WRITABLE=0
SLAB_INSTALL_PHASE=not_started
SLAB_INSTALL_ATTEMPT_STARTED_AT=
SLAB_FAILED_SERVICE=
SLAB_COMPOSE_DIAGNOSTIC=
SLAB_REQUESTED_VERSION=
SLAB_INSTALL_DIRECTORY=
SLAB_ACCESS_MODE=
SLAB_DOMAIN=
SLAB_ACME_EMAIL=
SLAB_PRIVATE_BIND_IP=
SLAB_PRIVATE_PORT=
SLAB_COMPOSE_PROJECT_NAME=
SLAB_ADMIN_PASSWORD_FILE=

slab_usage() {
  cat <<'EOF'
Usage: sudo ./installer/install.sh [options]

Options:
  --non-interactive       Read declarative configuration instead of /dev/tty.
  --config FILE           Root-private configuration file for non-interactive mode.
  --manifest FILE         Release manifest from this verified installer bundle.
  --dry-run               Validate host, configuration, and release inputs without changes.
  --help                  Show this help.

Passwords are never accepted as command-line arguments. In non-interactive
mode, set SLAB_ADMIN_PASSWORD_FILE to a root-owned 0400/0600 file.
EOF
}

slab_installer_exit() {
  exit_status=$1
  SLAB_ADMIN_PASSWORD=
  if [ -n "$SLAB_COMPOSE_DIAGNOSTIC" ]; then
    rm -f "$SLAB_COMPOSE_DIAGNOSTIC"
    SLAB_COMPOSE_DIAGNOSTIC=
  fi
  if [ "$exit_status" -ne 0 ] && [ "$SLAB_INSTALL_STARTED" -eq 1 ]; then
    if [ "$SLAB_STATE_WRITABLE" -eq 1 ]; then
      slab_write_install_state \
        "$SLAB_INSTALL_DIRECTORY" \
        "$SLAB_REQUESTED_VERSION" \
        "$SLAB_ACCESS_MODE" \
        "$SLAB_PUBLIC_URL" \
        "$SLAB_COMPOSE_PROJECT_NAME" \
        "$SLAB_INSTALL_ATTEMPT_STARTED_AT" \
        "$SLAB_INSTALL_PHASE" \
        FAILED || true
    fi
    echo "Installation did not reach readiness." >&2
    if [ "$SLAB_COMPOSE_CONFIGURED" -eq 1 ]; then
      echo "Current service status:" >&2
      slab_print_compose_status
      detected_failure=$(slab_detect_first_failing_service 2>/dev/null || true)
      failing_service=${detected_failure:-$SLAB_FAILED_SERVICE}
      slab_print_bounded_service_logs "$failing_service"
    fi
    echo "No application data or generated secrets were deleted." >&2
  fi
}

trap 'slab_installer_exit $?' EXIT
trap 'exit 130' HUP INT TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --non-interactive) SLAB_NON_INTERACTIVE=1 ;;
    --config)
      [ "$#" -ge 2 ] || { echo "--config requires a file." >&2; exit 2; }
      SLAB_CONFIG_FILE=$2
      shift
      ;;
    --manifest)
      [ "$#" -ge 2 ] || { echo "--manifest requires a file." >&2; exit 2; }
      SLAB_MANIFEST=$2
      shift
      ;;
    --dry-run) SLAB_DRY_RUN=1 ;;
    --help) slab_usage; exit 0 ;;
    *) echo "Unknown installer option: $1" >&2; slab_usage >&2; exit 2 ;;
  esac
  shift
done

slab_require_root

if [ "$SLAB_NON_INTERACTIVE" -eq 1 ]; then
  [ -n "$SLAB_CONFIG_FILE" ] || {
    echo "--non-interactive requires --config FILE." >&2
    exit 2
  }
  slab_load_noninteractive_config "$SLAB_CONFIG_FILE"
  slab_finalize_noninteractive_config
else
  [ -r /dev/tty ] || {
    echo "Interactive installation requires /dev/tty; use --non-interactive explicitly." >&2
    exit 2
  }
  slab_collect_interactive_configuration
  SLAB_PRIVATE_BIND_IP=127.0.0.1
  SLAB_PRIVATE_PORT=3009
  SLAB_COMPOSE_PROJECT_NAME=slab
fi

slab_run_preflight "$SLAB_INSTALL_DIRECTORY"
slab_validate_release_manifest "$SLAB_MANIFEST"
slab_validate_compose_project_name "$SLAB_COMPOSE_PROJECT_NAME"
requested_version=$(jq -r '.stackVersion' "$SLAB_MANIFEST")
SLAB_REQUESTED_VERSION=$requested_version

slab_validate_install_target_state() {
  existing_state=$SLAB_INSTALL_DIRECTORY/config/install-state.json
  if [ -f "$SLAB_INSTALL_DIRECTORY/VERSION" ]; then
    installed_version=$(sed -n '1p' "$SLAB_INSTALL_DIRECTORY/VERSION")
    [ "$installed_version" = "$requested_version" ] || {
      echo "Slab $installed_version is already installed. Use the future slabctl update workflow instead of changing versions in-place." >&2
      return 1
    }
    slab_validate_existing_install_identity \
      "$SLAB_INSTALL_DIRECTORY" "$requested_version" "$SLAB_ACCESS_MODE" \
      "$SLAB_PUBLIC_URL" "$SLAB_COMPOSE_PROJECT_NAME"
  elif [ -f "$existing_state" ]; then
    slab_validate_existing_install_identity \
      "$SLAB_INSTALL_DIRECTORY" "$requested_version" "$SLAB_ACCESS_MODE" \
      "$SLAB_PUBLIC_URL" "$SLAB_COMPOSE_PROJECT_NAME"
  elif [ -d "$SLAB_INSTALL_DIRECTORY" ] &&
    [ -n "$(find "$SLAB_INSTALL_DIRECTORY" -mindepth 1 -maxdepth 1 -print -quit)" ]
  then
    echo "Installation directory is not empty and has no Slab VERSION marker: $SLAB_INSTALL_DIRECTORY" >&2
    return 1
  fi
}

slab_validate_install_target_state

echo
echo "Slab installation"
echo "  Directory: $SLAB_INSTALL_DIRECTORY"
echo "  Access:    $SLAB_ACCESS_MODE"
echo "  URL:       $SLAB_PUBLIC_URL"
echo "  Version:   $requested_version"
echo

if [ "$SLAB_NON_INTERACTIVE" -eq 0 ]; then
  printf 'Continue? [y/N]: ' > /dev/tty
  IFS= read -r confirmation < /dev/tty
  case "$confirmation" in y | Y | yes | YES) ;; *) echo "Installation cancelled."; exit 0 ;; esac
fi

if [ "$SLAB_DRY_RUN" -eq 1 ]; then
  echo "Dry run complete. No files, secrets, containers, or data were changed."
  exit 0
fi

slab_acquire_install_lock "$SLAB_INSTALL_DIRECTORY"
# Close the read/check-to-write race after acquiring the per-install lock.
slab_validate_install_target_state

SLAB_INSTALL_STARTED=1
SLAB_INSTALL_ATTEMPT_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
slab_prepare_state_directory "$SLAB_INSTALL_DIRECTORY"
SLAB_STATE_WRITABLE=1
SLAB_INSTALL_PHASE=not_started
slab_write_install_state \
  "$SLAB_INSTALL_DIRECTORY" "$requested_version" "$SLAB_ACCESS_MODE" \
  "$SLAB_PUBLIC_URL" "$SLAB_COMPOSE_PROJECT_NAME" \
  "$SLAB_INSTALL_ATTEMPT_STARTED_AT" "$SLAB_INSTALL_PHASE" INSTALLING
slab_prepare_secrets "$SLAB_INSTALL_DIRECTORY/secrets"
slab_render_installation \
  "$BUNDLE_ROOT" \
  "$SLAB_INSTALL_DIRECTORY" \
  "$SLAB_MANIFEST" \
  "$SLAB_ACCESS_MODE" \
  "$SLAB_PUBLIC_URL" \
  "$SLAB_DOMAIN" \
  "$SLAB_ACME_EMAIL" \
  "$SLAB_PRIVATE_BIND_IP" \
  "$SLAB_PRIVATE_PORT"
slab_configure_compose \
  "$SLAB_INSTALL_DIRECTORY" \
  "$SLAB_ACCESS_MODE" \
  "$SLAB_COMPOSE_PROJECT_NAME"
SLAB_COMPOSE_CONFIGURED=1
SLAB_INSTALL_PHASE=rendered
slab_write_install_state \
  "$SLAB_INSTALL_DIRECTORY" "$requested_version" "$SLAB_ACCESS_MODE" \
  "$SLAB_PUBLIC_URL" "$SLAB_COMPOSE_PROJECT_NAME" \
  "$SLAB_INSTALL_ATTEMPT_STARTED_AT" "$SLAB_INSTALL_PHASE" INSTALLING

slab_validate_compose_configuration
SLAB_INSTALL_PHASE=compose_validated
slab_write_install_state \
  "$SLAB_INSTALL_DIRECTORY" "$requested_version" "$SLAB_ACCESS_MODE" \
  "$SLAB_PUBLIC_URL" "$SLAB_COMPOSE_PROJECT_NAME" \
  "$SLAB_INSTALL_ATTEMPT_STARTED_AT" "$SLAB_INSTALL_PHASE" INSTALLING
slab_pull_and_start
SLAB_INSTALL_PHASE=compose_reconciled
slab_write_install_state \
  "$SLAB_INSTALL_DIRECTORY" "$requested_version" "$SLAB_ACCESS_MODE" \
  "$SLAB_PUBLIC_URL" "$SLAB_COMPOSE_PROJECT_NAME" \
  "$SLAB_INSTALL_ATTEMPT_STARTED_AT" "$SLAB_INSTALL_PHASE" INSTALLING
slab_wait_for_healthy_stack
SLAB_INSTALL_PHASE=services_healthy
slab_write_install_state \
  "$SLAB_INSTALL_DIRECTORY" "$requested_version" "$SLAB_ACCESS_MODE" \
  "$SLAB_PUBLIC_URL" "$SLAB_COMPOSE_PROJECT_NAME" \
  "$SLAB_INSTALL_ATTEMPT_STARTED_AT" "$SLAB_INSTALL_PHASE" INSTALLING

admin_readiness=$(slab_agents_http_status /ready 2>/dev/null || true)
if [ "$admin_readiness" = 503 ]; then
  if [ "$SLAB_NON_INTERACTIVE" -eq 1 ]; then
    [ -n "$SLAB_ADMIN_PASSWORD_FILE" ] || {
      echo "SLAB_ADMIN_PASSWORD_FILE is required for initial administrator bootstrap." >&2
      exit 2
    }
    slab_read_admin_password_file "$SLAB_ADMIN_PASSWORD_FILE"
  else
    slab_prompt_password
  fi
fi
slab_bootstrap_admin_if_needed "$SLAB_ADMIN_PASSWORD"
SLAB_ADMIN_PASSWORD=

completion_state=READY_NO_RUNTIME
[ "$SLAB_ACCESS_MODE" = domain ] && completion_state=TLS_PENDING
SLAB_INSTALL_PHASE=admin_configured
slab_write_install_state \
  "$SLAB_INSTALL_DIRECTORY" "$requested_version" "$SLAB_ACCESS_MODE" \
  "$SLAB_PUBLIC_URL" "$SLAB_COMPOSE_PROJECT_NAME" \
  "$SLAB_INSTALL_ATTEMPT_STARTED_AT" "$SLAB_INSTALL_PHASE" "$completion_state"

echo
echo "Slab services are healthy and the administrator is configured."
if [ "$SLAB_ACCESS_MODE" = private ]; then
  echo "Open an SSH tunnel from your computer:"
  echo "  ssh -L $SLAB_PRIVATE_PORT:127.0.0.1:$SLAB_PRIVATE_PORT user@server"
  echo "Then open: $SLAB_PUBLIC_URL"
else
  echo "Caddy is running for: $SLAB_PUBLIC_URL"
  echo "DNS and TLS verification are still pending in this installer milestone."
fi
echo "Codex authentication is the next setup step."
echo "Installation status: $completion_state"
