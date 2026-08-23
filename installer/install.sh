#!/bin/sh
set -eu

BUNDLE_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DEFAULT_MANIFEST=$BUNDLE_ROOT/releases/v0.1.0-candidate.16.json

# shellcheck source=installer/lib/preflight.sh
. "$BUNDLE_ROOT/installer/lib/preflight.sh"
# shellcheck source=installer/lib/host-bootstrap.sh
. "$BUNDLE_ROOT/installer/lib/host-bootstrap.sh"
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
# shellcheck source=installer/lib/codex.sh
. "$BUNDLE_ROOT/installer/lib/codex.sh"
# shellcheck source=installer/lib/slabctl-install.sh
. "$BUNDLE_ROOT/installer/lib/slabctl-install.sh"
# shellcheck source=installer/lib/systemd.sh
. "$BUNDLE_ROOT/installer/lib/systemd.sh"
# shellcheck source=installer/lib/domain.sh
. "$BUNDLE_ROOT/installer/lib/domain.sh"
# shellcheck source=installer/lib/proton.sh
. "$BUNDLE_ROOT/installer/lib/proton.sh"

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

slab_run_bootstrap_preflight "$SLAB_INSTALL_DIRECTORY"
slab_validate_compose_project_name "$SLAB_COMPOSE_PROJECT_NAME"
requested_version=$(slab_extract_stack_version "$SLAB_MANIFEST")
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
  if command -v jq >/dev/null 2>&1; then
    slab_validate_release_manifest "$SLAB_MANIFEST"
  else
    echo "Dry run note: jq would be installed before full manifest validation."
  fi
  if slab_docker_is_ready; then
    echo "Docker Engine and Compose V2 are available."
  else
    echo "Docker Engine and Compose V2 would be installed from Docker's official apt repository."
  fi
  echo "Dry run complete. No packages, files, secrets, containers, or data were changed."
  exit 0
fi

slab_acquire_install_lock "$SLAB_INSTALL_DIRECTORY"
# Close the read/check-to-write race after acquiring the per-install lock.
slab_validate_install_target_state
slab_prepare_host
slab_run_preflight "$SLAB_INSTALL_DIRECTORY"
slab_validate_release_manifest "$SLAB_MANIFEST"
validated_version=$(jq -r '.stackVersion' "$SLAB_MANIFEST")
[ "$validated_version" = "$requested_version" ] || {
  echo "Release manifest version changed during installation." >&2
  exit 1
}

SLAB_INSTALL_STARTED=1
SLAB_INSTALL_ATTEMPT_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
slab_prepare_state_directory "$SLAB_INSTALL_DIRECTORY"
slab_acquire_management_lock "$SLAB_INSTALL_DIRECTORY"
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
  "$SLAB_PRIVATE_PORT" \
  1
slab_install_management_cli "$BUNDLE_ROOT" "$SLAB_INSTALL_DIRECTORY"
slab_install_systemd_unit "$BUNDLE_ROOT"
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
slab_activate_systemd_unit "$SLAB_INSTALL_DIRECTORY"
SLAB_INSTALL_PHASE=lifecycle_configured
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

codex_authenticated=0
domain_tls_ready=0
# Consumed by the sourced Codex management helper.
# shellcheck disable=SC2034
SLABCTL_EXPECTED_OWNER_UID=${SLAB_MANAGEMENT_OWNER_UID:-0}
slabctl_load_installation "$SLAB_INSTALL_DIRECTORY"
if slabctl_codex_status >/dev/null 2>&1; then
  codex_authenticated=1
fi
if [ "$SLAB_ACCESS_MODE" = domain ] && slabctl_wait_for_domain_tls; then
  domain_tls_ready=1
fi
completion_state=READY_NO_RUNTIME
[ "$codex_authenticated" -eq 1 ] && completion_state=READY
if [ "$SLAB_ACCESS_MODE" = domain ] && [ "$domain_tls_ready" -eq 0 ]; then
  completion_state=TLS_PENDING
fi
SLAB_INSTALL_PHASE=admin_configured
slab_write_install_state \
  "$SLAB_INSTALL_DIRECTORY" "$requested_version" "$SLAB_ACCESS_MODE" \
  "$SLAB_PUBLIC_URL" "$SLAB_COMPOSE_PROJECT_NAME" \
  "$SLAB_INSTALL_ATTEMPT_STARTED_AT" "$SLAB_INSTALL_PHASE" "$completion_state"
# The product installation is complete at this point. Optional interactive
# runtime onboarding must never rewrite a healthy stack as FAILED.
SLAB_INSTALL_STARTED=0

echo
echo "Slab services are healthy and the administrator is configured."
if [ "$SLAB_ACCESS_MODE" = private ]; then
  echo "Open an SSH tunnel from your computer:"
  echo "  ssh -L $SLAB_PRIVATE_PORT:127.0.0.1:$SLAB_PRIVATE_PORT user@server"
  echo "Then open: $SLAB_PUBLIC_URL"
else
  echo "Caddy is running for: $SLAB_PUBLIC_URL"
  if [ "$completion_state" = TLS_PENDING ]; then
    echo "DNS or TLS is still pending. After fixing it, run: sudo slabctl domain verify"
  else
    echo "HTTPS is verified with a trusted certificate."
  fi
fi
if [ "$codex_authenticated" -eq 1 ]; then
  echo "Codex authentication is active."
else
  echo "Codex authentication is the next setup step."
  echo "Run: sudo slabctl codex login"
fi

if [ "$SLAB_NON_INTERACTIVE" -eq 0 ] &&
  slabctl_proton_available &&
  ! slabctl_proton_configured
then
  printf 'Connect a Proton mailbox now? [y/N]: ' > /dev/tty
  IFS= read -r configure_proton < /dev/tty
  case "$configure_proton" in
    y | Y | yes | YES)
      if ! slabctl_proton_setup; then
        echo "Proton setup was not completed. The healthy installation remains available." >&2
        echo "Retry later with: sudo slabctl proton setup" >&2
      fi
      ;;
  esac
fi

if [ "$SLAB_NON_INTERACTIVE" -eq 0 ] && [ "$codex_authenticated" -eq 0 ]; then
  printf 'Authenticate Codex now? [Y/n]: ' > /dev/tty
  IFS= read -r authenticate_codex < /dev/tty
  case "$authenticate_codex" in
    n | N | no | NO) ;;
    *)
      if slabctl_codex_login_device; then
        codex_authenticated=1
        completion_state=$(jq -r '.status' \
          "$SLAB_INSTALL_DIRECTORY/config/install-state.json")
      else
        echo "Codex authentication was not completed. The healthy installation remains available." >&2
      fi
      ;;
  esac
fi
echo "Installation status: $completion_state"
