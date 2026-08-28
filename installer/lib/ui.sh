#!/bin/sh

slab_ui_banner() {
  cat <<'EOF'

Slab self-hosted setup
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
  printf '\n%s\n' "$section_title"
  printf '%s\n' "----------------------------------------"
}

slab_ui_step() {
  step_number=$1
  step_total=$2
  step_title=$3
  printf '\n[%s/%s] %s\n' "$step_number" "$step_total" "$step_title"
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
  Directory:  $SLAB_INSTALL_DIRECTORY
  Access:     $SLAB_ACCESS_MODE
  URL:        $SLAB_PUBLIC_URL
  Memory:     $SLAB_MEMORY_MODE
  Docker:     $(slab_ui_docker_plan)
  Lifecycle:  systemd-managed; persistent data stays in named Docker volumes

The installation may add apt packages, Docker's signed apt repository, Docker
Engine, systemd units, and files below $SLAB_INSTALL_DIRECTORY. It will not
open a public application port in private mode. Domain mode uses Caddy on ports
80 and 443 and requests a TLS certificate after DNS resolves to this server.
EOF
}

slab_ui_print_success() {
  cat <<EOF

Core installation complete
==========================

Slab's services are healthy and the administrator account is configured.
Persistent product data is stored in Docker volumes and survives service
restarts, host reboots, and signed stack updates.
EOF
}
