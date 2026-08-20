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
