#!/bin/sh

slab_install_management_cli() {
  bundle_root=$1
  install_directory=$2
  host_root=${SLAB_MANAGEMENT_HOST_ROOT:-}
  owner_uid=${SLAB_MANAGEMENT_OWNER_UID:-0}
  trust_root=${SLAB_MANAGEMENT_TRUST_ROOT:-/}

  binary_directory=$host_root/usr/local/bin
  library_directory=$host_root/usr/local/lib/slab-stack
  registry_directory=$host_root/etc/slab
  binary_path=$binary_directory/slabctl
  library_path=$library_directory/codex.sh
  lifecycle_path=$library_directory/lifecycle.sh
  domain_path=$library_directory/domain.sh
  proton_path=$library_directory/proton.sh
  backup_path=$library_directory/backup.sh
  release_client_path=$library_directory/release-client.sh
  release_public_key_path=$library_directory/release-signing-public.pem
  update_path=$library_directory/update.sh
  pointer_path=$registry_directory/install-directory

  for directory in "$binary_directory" "$library_directory" "$registry_directory"; do
    slab_validate_trusted_directory_chain \
      "$directory" "$owner_uid" "$trust_root" || return 1
  done

  for path in "$binary_path" "$library_path" "$lifecycle_path" "$domain_path" \
    "$proton_path" "$backup_path" "$release_client_path" \
    "$release_public_key_path" "$update_path" "$pointer_path"
  do
    [ ! -L "$path" ] || {
      echo "Refusing symbolic-link management path: $path" >&2
      return 1
    }
  done
  if [ -f "$pointer_path" ]; then
    registered_directory=$(sed -n '1p' "$pointer_path")
    [ "$registered_directory" = "$install_directory" ] || {
      echo "Another Slab installation is already registered at: $registered_directory" >&2
      return 1
    }
  fi
  if [ -e "$binary_path" ] && ! grep -q '^# slab-stack-managed: slabctl$' "$binary_path"; then
    echo "Refusing to replace an unmanaged slabctl: $binary_path" >&2
    return 1
  fi

  mkdir -p "$binary_directory" "$library_directory" "$registry_directory"
  chmod 0755 "$binary_directory" "$library_directory" "$registry_directory"
  if [ "$(id -u)" -eq 0 ]; then
    chown "$owner_uid" "$library_directory" "$registry_directory"
  fi
  for directory in "$binary_directory" "$library_directory" "$registry_directory"; do
    slab_validate_trusted_directory_chain \
      "$directory" "$owner_uid" "$trust_root" || return 1
  done

  temporary_binary=$binary_directory/.slabctl.$$
  temporary_library=$library_directory/.codex.sh.$$
  temporary_lifecycle=$library_directory/.lifecycle.sh.$$
  temporary_domain=$library_directory/.domain.sh.$$
  temporary_proton=$library_directory/.proton.sh.$$
  temporary_backup=$library_directory/.backup.sh.$$
  temporary_release_client=$library_directory/.release-client.sh.$$
  temporary_release_public_key=$library_directory/.release-signing-public.pem.$$
  temporary_update=$library_directory/.update.sh.$$
  temporary_pointer=$registry_directory/.install-directory.$$
  cp "$bundle_root/bin/slabctl" "$temporary_binary"
  cp "$bundle_root/installer/lib/codex.sh" "$temporary_library"
  cp "$bundle_root/installer/lib/lifecycle.sh" "$temporary_lifecycle"
  cp "$bundle_root/installer/lib/domain.sh" "$temporary_domain"
  cp "$bundle_root/installer/lib/proton.sh" "$temporary_proton"
  cp "$bundle_root/installer/lib/backup.sh" "$temporary_backup"
  cp "$bundle_root/installer/lib/release-client.sh" "$temporary_release_client"
  cp "$bundle_root/contracts/release-signing-public.pem" \
    "$temporary_release_public_key"
  cp "$bundle_root/installer/lib/update.sh" "$temporary_update"
  printf '%s\n' "$install_directory" > "$temporary_pointer"
  chmod 0755 "$temporary_binary"
  chmod 0644 "$temporary_library" "$temporary_lifecycle" "$temporary_domain" \
    "$temporary_proton" "$temporary_backup" "$temporary_release_client" \
    "$temporary_release_public_key" "$temporary_pointer"
  chmod 0644 "$temporary_update"
  mv "$temporary_binary" "$binary_path"
  mv "$temporary_library" "$library_path"
  mv "$temporary_lifecycle" "$lifecycle_path"
  mv "$temporary_domain" "$domain_path"
  mv "$temporary_proton" "$proton_path"
  mv "$temporary_backup" "$backup_path"
  mv "$temporary_release_client" "$release_client_path"
  mv "$temporary_release_public_key" "$release_public_key_path"
  mv "$temporary_update" "$update_path"
  mv "$temporary_pointer" "$pointer_path"
}
