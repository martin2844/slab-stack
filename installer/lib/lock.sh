#!/bin/sh

slab_acquire_install_lock() {
  install_directory=$1
  lock_root=${SLAB_LOCK_ROOT:-/run/slab-installer-locks}
  lock_owner_uid=${SLAB_LOCK_OWNER_UID:-0}

  [ ! -L "$lock_root" ] || {
    echo "Installer lock root cannot be a symbolic link: $lock_root" >&2
    return 1
  }
  lock_parent=$(dirname -- "$lock_root")
  slab_validate_trusted_directory_chain \
    "$lock_parent" "$lock_owner_uid" "${SLAB_LOCK_TRUST_ROOT:-/}" || return 1
  old_umask=$(umask)
  umask 077
  mkdir -p "$lock_root"
  chmod 0700 "$lock_root"
  umask "$old_umask"
  slab_validate_trusted_directory_chain \
    "$lock_root" "$lock_owner_uid" "${SLAB_LOCK_TRUST_ROOT:-/}" || return 1

  lock_probe=$install_directory
  lock_suffix=
  while [ ! -e "$lock_probe" ]; do
    lock_component=${lock_probe##*/}
    lock_suffix=/$lock_component$lock_suffix
    lock_probe=$(dirname -- "$lock_probe")
  done
  # Device/inode identity also makes two root-owned bind-mount aliases contend
  # on the same lock. For a not-yet-created target, append the remaining path
  # below the nearest existing ancestor.
  lock_identity="$(stat -Lc '%d:%i' "$lock_probe")"$lock_suffix || return 1
  install_hash=$(printf '%s' "$lock_identity" | sha256sum | awk '{print $1}') || return 1
  lock_file=$lock_root/slab-installer-$install_hash.lock
  [ ! -L "$lock_file" ] || {
    echo "Installer lock cannot be a symbolic link: $lock_file" >&2
    return 1
  }

  # FD 9 remains open for the lifetime of install.sh. The stable lock file is
  # intentionally retained so no second inode can bypass an active lock.
  exec 9>"$lock_file"
  chmod 0600 "$lock_file"
  if ! flock -n 9; then
    echo "Another installer is already operating on: $install_directory" >&2
    return 1
  fi
}
