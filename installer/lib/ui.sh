#!/bin/sh

SLAB_UI_RESET=
SLAB_UI_HEADING=
SLAB_UI_STEP=
SLAB_UI_SUCCESS=
SLAB_UI_WARNING=
SLAB_UI_ERROR=
SLAB_UI_PROMPT=
SLAB_UI_MUTED=

if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ "${NO_COLOR+x}" != x ]; then
  SLAB_UI_RESET=$(printf '\033[0m')
  SLAB_UI_HEADING=$(printf '\033[1;36m')
  SLAB_UI_STEP=$(printf '\033[1;32m')
  SLAB_UI_SUCCESS=$(printf '\033[1;32m')
  SLAB_UI_WARNING=$(printf '\033[1;33m')
  SLAB_UI_ERROR=$(printf '\033[1;31m')
  SLAB_UI_PROMPT=$(printf '\033[1m')
  SLAB_UI_MUTED=$(printf '\033[2m')
fi

slab_ui_banner() {
  printf '\n%sSlab self-hosted setup%s\n' "$SLAB_UI_HEADING" "$SLAB_UI_RESET"
  cat <<'EOF'
======================

This installer prepares one Slab workspace on this server. It will:

  - validate the selected versioned release manifest;
  - install Docker Engine and Docker Compose V2 when they are missing;
  - create root-private configuration and persistent Docker volumes;
  - start Slab Agents, Work, Docs, Email, Runner, and Caddy;
  - register Slab with systemd so it starts after a reboot;
  - create the first password-protected administrator account.

Existing Docker installations are reused when healthy. The installer never
removes existing Docker packages, application data, or named volumes.
EOF
}

slab_ui_section() {
  section_title=$1
  printf '\n%s%s%s\n' "$SLAB_UI_HEADING" "$section_title" "$SLAB_UI_RESET"
  printf '%s%s%s\n' "$SLAB_UI_MUTED" "----------------------------------------" "$SLAB_UI_RESET"
}

slab_ui_step() {
  step_number=$1
  step_total=$2
  step_title=$3
  printf '\n%s[%s/%s] %s%s\n' \
    "$SLAB_UI_STEP" "$step_number" "$step_total" "$step_title" "$SLAB_UI_RESET"
}

slab_ui_success() {
  printf '%s%s%s\n' "$SLAB_UI_SUCCESS" "$1" "$SLAB_UI_RESET"
}

slab_ui_warning() {
  printf '%s%s%s\n' "$SLAB_UI_WARNING" "$1" "$SLAB_UI_RESET"
}

slab_ui_docker_plan() {
  if slab_docker_is_ready; then
    printf '%s\n' "Reuse the installed Docker Engine and Compose V2."
  else
    printf '%s\n' "Install Docker CE, containerd, Buildx, and Compose V2 from Docker's official apt repository."
  fi
}

slab_ui_print_install_plan() {
  platform=$1
  requested_version=$2
  cat <<EOF

Installation plan
=================

  Host:       $platform
  Release:    $requested_version
  Slab files: $SLAB_INSTALL_DIRECTORY
  Open in:    $SLAB_ACCESS_MODE mode
  Address:    $SLAB_PUBLIC_URL
  Memory:     $SLAB_MEMORY_MODE
  Docker:     $(slab_ui_docker_plan)
  Restarts:   automatic after a server reboot

Slab may install required server packages and Docker. It keeps its settings in
$SLAB_INSTALL_DIRECTORY. Your workspace data is stored separately and is not
removed by normal restarts or updates.

Private mode does not expose Slab publicly. Domain mode makes Slab available at
the address above and automatically configures HTTPS after your domain points
to this server.
EOF
}

slab_ui_print_success() {
  cat <<EOF

${SLAB_UI_SUCCESS}Core installation complete${SLAB_UI_RESET}
==========================

Slab's services are healthy and the administrator account is configured.
Persistent product data is stored in Docker volumes and survives service
restarts, host reboots, and signed stack updates.
EOF
}
