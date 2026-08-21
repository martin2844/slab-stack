#!/bin/sh

slabctl_proton_command() {
  if [ "${1:-}" = -T ]; then
    shift
    slabctl_compose exec -T slab-email node dist/proton/setup-cli.js "$@"
  else
    slabctl_compose exec slab-email node dist/proton/setup-cli.js "$@"
  fi
}

slabctl_proton_available() {
  slabctl_proton_command -T --status >/dev/null 2>&1
}

slabctl_proton_configured() {
  slabctl_proton_command -T --configured >/dev/null 2>&1
}

slabctl_proton_setup() {
  slabctl_proton_command
}
