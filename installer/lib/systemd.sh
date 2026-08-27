#!/bin/sh

slab_install_systemd_unit() {
  bundle_root=$1
  host_root=${SLAB_SYSTEMD_HOST_ROOT:-${SLAB_MANAGEMENT_HOST_ROOT:-}}
  owner_uid=${SLAB_SYSTEMD_OWNER_UID:-${SLAB_MANAGEMENT_OWNER_UID:-0}}
  request_uid=${SLAB_UPDATE_BRIDGE_REQUEST_UID:-10001}
  trust_root=${SLAB_SYSTEMD_TRUST_ROOT:-${SLAB_MANAGEMENT_TRUST_ROOT:-/}}
  unit_directory=$host_root/etc/systemd/system
  bridge_root=$host_root/var/lib/slab-update-bridge

  slab_validate_trusted_directory_chain \
    "$unit_directory" "$owner_uid" "$trust_root" || return 1
  mkdir -p "$unit_directory"
  chmod 0755 "$unit_directory"
  if [ "$(id -u)" -eq 0 ]; then
    chown "$owner_uid" "$unit_directory"
  fi
  slab_validate_trusted_directory_chain \
    "$unit_directory" "$owner_uid" "$trust_root" || return 1

  for unit_name in slab.service slab-update-bridge.service \
    slab-update-bridge-prepare.service slab-update-bridge.path \
    slab-update-bridge-sweep.timer \
    'var-lib-slab\x2dupdate\x2dbridge-requests.mount' \
    'var-lib-slab\x2dupdate\x2dbridge-status.mount'
  do
    unit_path=$unit_directory/$unit_name
    [ ! -L "$unit_path" ] || {
      echo "Refusing symbolic-link systemd unit: $unit_path" >&2
      return 1
    }
    if [ -e "$unit_path" ] &&
      ! grep -Fqx "# slab-stack-managed: $unit_name" "$unit_path"
    then
      echo "Refusing to replace an unmanaged systemd unit: $unit_path" >&2
      return 1
    fi
  done

  slab_validate_trusted_directory_chain \
    "$bridge_root" "$owner_uid" "$trust_root" || return 1
  for bridge_directory in "$bridge_root" "$bridge_root/requests" \
    "$bridge_root/requests/.claimed" "$bridge_root/requests/.uploads" \
    "$bridge_root/processing" "$bridge_root/status" \
    "$bridge_root/status/requests"
  do
    [ ! -L "$bridge_directory" ] || {
      echo "Refusing symbolic-link update bridge directory: $bridge_directory" >&2
      return 1
    }
    if [ -e "$bridge_directory" ] && [ ! -d "$bridge_directory" ]; then
      echo "Refusing non-directory update bridge path: $bridge_directory" >&2
      return 1
    fi
  done
  mkdir -p "$bridge_root/requests/.claimed" "$bridge_root/requests/.uploads" \
    "$bridge_root/processing" \
    "$bridge_root/status/requests"
  chmod 0755 "$bridge_root" "$bridge_root/status" \
    "$bridge_root/status/requests"
  chmod 1733 "$bridge_root/requests"
  chmod 0700 "$bridge_root/requests/.claimed" \
    "$bridge_root/requests/.uploads" "$bridge_root/processing"
  if [ "$(id -u)" -eq 0 ]; then
    chown "$owner_uid" "$bridge_root" "$bridge_root/requests" \
      "$bridge_root/requests/.claimed" "$bridge_root/processing" \
      "$bridge_root/status" "$bridge_root/status/requests"
    chown "$request_uid" "$bridge_root/requests/.uploads"
  fi

  for unit_name in slab.service slab-update-bridge.service \
    slab-update-bridge-prepare.service slab-update-bridge.path \
    slab-update-bridge-sweep.timer \
    'var-lib-slab\x2dupdate\x2dbridge-requests.mount' \
    'var-lib-slab\x2dupdate\x2dbridge-status.mount'
  do
    unit_path=$unit_directory/$unit_name
    temporary_unit=$unit_directory/.$unit_name.$$
    cp "$bundle_root/templates/$unit_name" "$temporary_unit" || return 1
    chmod 0644 "$temporary_unit" || return 1
    mv "$temporary_unit" "$unit_path" || return 1
  done
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
  if ! "$systemctl_command" enable --now \
    'var-lib-slab\x2dupdate\x2dbridge-requests.mount' \
    'var-lib-slab\x2dupdate\x2dbridge-status.mount'; then
    activation_status=1
  elif ! "$systemctl_command" enable --now slab-update-bridge-prepare.service; then
    activation_status=1
  elif ! "$systemctl_command" enable --now slab.service \
    slab-update-bridge.path slab-update-bridge-sweep.timer; then
    activation_status=1
  fi
  slab_acquire_management_lock "$install_directory" || return 1
  [ "$activation_status" -eq 0 ] || {
    echo "Could not enable and start slab.service." >&2
    return 1
  }
}

slab_activate_update_bridge_path() {
  systemctl_command=${SLAB_SYSTEMCTL_BIN:-systemctl}
  "$systemctl_command" daemon-reload || return 1
  "$systemctl_command" enable --now \
    'var-lib-slab\x2dupdate\x2dbridge-requests.mount' \
    'var-lib-slab\x2dupdate\x2dbridge-status.mount' || {
      echo "Could not mount the bounded Slab update bridge transport." >&2
      return 1
    }
  "$systemctl_command" enable --now slab-update-bridge-prepare.service || {
    echo "Could not prepare the Slab update request claim directory." >&2
    return 1
  }
  "$systemctl_command" enable --now slab-update-bridge.path \
    slab-update-bridge-sweep.timer || {
    echo "Could not enable the Slab update request watcher." >&2
    return 1
  }
}
