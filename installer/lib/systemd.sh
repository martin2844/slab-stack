#!/bin/sh

slab_install_systemd_unit() {
  bundle_root=$1
  host_root=${SLAB_SYSTEMD_HOST_ROOT:-${SLAB_MANAGEMENT_HOST_ROOT:-}}
  owner_uid=${SLAB_SYSTEMD_OWNER_UID:-${SLAB_MANAGEMENT_OWNER_UID:-0}}
  trust_root=${SLAB_SYSTEMD_TRUST_ROOT:-${SLAB_MANAGEMENT_TRUST_ROOT:-/}}
  unit_directory=$host_root/etc/systemd/system
  unit_path=$unit_directory/slab.service

  slab_validate_trusted_directory_chain \
    "$unit_directory" "$owner_uid" "$trust_root" || return 1
  [ ! -L "$unit_path" ] || {
    echo "Refusing symbolic-link systemd unit: $unit_path" >&2
    return 1
  }
  if [ -e "$unit_path" ] && \
    ! grep -q '^# slab-stack-managed: slab.service$' "$unit_path"
  then
    echo "Refusing to replace an unmanaged systemd unit: $unit_path" >&2
    return 1
  fi

  mkdir -p "$unit_directory"
  chmod 0755 "$unit_directory"
  if [ "$(id -u)" -eq 0 ]; then
    chown "$owner_uid" "$unit_directory"
  fi
  slab_validate_trusted_directory_chain \
    "$unit_directory" "$owner_uid" "$trust_root" || return 1

  temporary_unit=$unit_directory/.slab.service.$$
  cp "$bundle_root/templates/slab.service" "$temporary_unit"
  chmod 0644 "$temporary_unit"
  mv "$temporary_unit" "$unit_path"
}

slab_activate_systemd_unit() {
  install_directory=$1
  systemctl_command=${SLAB_SYSTEMCTL_BIN:-systemctl}

  "$systemctl_command" daemon-reload || return 1

  # The systemd unit enters through slabctl and therefore takes the same
  # management lock. Release the installer's lock around activation, then
  # reacquire it before continuing the installation/state transaction.
  exec 8>&-
  activation_status=0
  if ! "$systemctl_command" enable --now slab.service; then
    activation_status=1
  fi
  slab_acquire_management_lock "$install_directory" || return 1
  [ "$activation_status" -eq 0 ] || {
    echo "Could not enable and start slab.service." >&2
    return 1
  }
}
