#!/bin/sh

slab_install_management_cli() (
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
  doctor_path=$library_directory/doctor.sh
  manager_version_path=$library_directory/VERSION
  pointer_path=$registry_directory/install-directory
  transaction_path=$registry_directory/management-transaction

  for directory in "$binary_directory" "$library_directory" "$registry_directory"; do
    slab_validate_trusted_directory_chain \
      "$directory" "$owner_uid" "$trust_root" || return 1
  done

  for path in "$binary_path" "$library_path" "$lifecycle_path" "$domain_path" \
    "$proton_path" "$backup_path" "$release_client_path" \
    "$release_public_key_path" "$update_path" "$doctor_path" "$pointer_path" \
    "$manager_version_path" "$transaction_path"
  do
    [ ! -L "$path" ] || {
      echo "Refusing symbolic-link management path: $path" >&2
      return 1
    }
    if [ -e "$path" ] && [ ! -f "$path" ]; then
      echo "Refusing non-file management path: $path" >&2
      return 1
    fi
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
  temporary_doctor=$library_directory/.doctor.sh.$$
  temporary_manager_version=$library_directory/.VERSION.$$
  temporary_pointer=$registry_directory/.install-directory.$$
  temporary_transaction=$registry_directory/.management-transaction.$$
  rollback_directory=
  preparation_complete=0
  cleanup_management_preparation() {
    cleanup_status=$?
    trap - EXIT HUP INT TERM
    if [ "$preparation_complete" -eq 0 ]; then
      rm -f "$temporary_binary" "$temporary_library" "$temporary_lifecycle" \
        "$temporary_domain" "$temporary_proton" "$temporary_backup" \
        "$temporary_release_client" "$temporary_release_public_key" \
        "$temporary_update" "$temporary_doctor" "$temporary_manager_version" \
        "$temporary_pointer" "$temporary_transaction"
      [ -z "$rollback_directory" ] || rm -rf "$rollback_directory"
    fi
    exit "$cleanup_status"
  }
  trap cleanup_management_preparation EXIT
  trap 'exit 130' HUP INT TERM
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
  cp "$bundle_root/installer/lib/doctor.sh" "$temporary_doctor"
  release_manifest=$install_directory/release-manifest.json
  if [ -f "$release_manifest" ] && [ ! -L "$release_manifest" ]; then
    jq -er '.stackVersion' "$release_manifest" > "$temporary_manager_version"
  else
    cp "$install_directory/VERSION" "$temporary_manager_version"
  fi
  printf '%s\n' "$install_directory" > "$temporary_pointer"
  chmod 0755 "$temporary_binary"
  chmod 0644 "$temporary_library" "$temporary_lifecycle" "$temporary_domain" \
    "$temporary_proton" "$temporary_backup" "$temporary_release_client" \
    "$temporary_release_public_key" "$temporary_pointer"
  chmod 0644 "$temporary_update"
  chmod 0644 "$temporary_doctor"
  chmod 0644 "$temporary_manager_version"

  rollback_directory=$(mktemp -d "$registry_directory/.management-rollback.XXXXXX") || return 1
  chmod 0700 "$rollback_directory"
  backup_managed_file() {
    backup_target=$1
    backup_name=$2
    [ -e "$backup_target" ] || return 0
    cp -p "$backup_target" "$rollback_directory/$backup_name" || return 1
    : > "$rollback_directory/$backup_name.present"
  }
  restore_managed_file() {
    restore_target=$1
    restore_name=$2
    if [ -f "$rollback_directory/$restore_name.present" ]; then
      restore_temporary=$(dirname -- "$restore_target")/.$(basename -- "$restore_target").restore.$$
      cp -p "$rollback_directory/$restore_name" "$restore_temporary" &&
        mv "$restore_temporary" "$restore_target"
    else
      rm -f "$restore_target"
    fi
  }
  backup_managed_file "$binary_path" binary || return 1
  backup_managed_file "$library_path" codex || return 1
  backup_managed_file "$lifecycle_path" lifecycle || return 1
  backup_managed_file "$domain_path" domain || return 1
  backup_managed_file "$proton_path" proton || return 1
  backup_managed_file "$backup_path" backup || return 1
  backup_managed_file "$release_client_path" release-client || return 1
  backup_managed_file "$release_public_key_path" release-public-key || return 1
  backup_managed_file "$update_path" update || return 1
  backup_managed_file "$doctor_path" doctor || return 1
  backup_managed_file "$manager_version_path" manager-version || return 1
  backup_managed_file "$pointer_path" pointer || return 1
  cp -p "$bundle_root/bin/slabctl" "$rollback_directory/recovery-launcher" || return 1
  cp -p "$temporary_update" "$rollback_directory/recovery-update.sh" || return 1
  cp -p "$temporary_manager_version" \
    "$rollback_directory/recovery-manager-version" || return 1
  chmod 0700 "$rollback_directory/recovery-launcher"
  chmod 0600 "$rollback_directory/recovery-update.sh" \
    "$rollback_directory/recovery-manager-version"
  preparation_complete=1
  trap - EXIT HUP INT TERM

  mutation_started=0
  install_complete=0
  install_recovery_wrapper() {
    wrapper=$binary_directory/.slabctl.journal-wrapper.$$
    cat > "$wrapper" <<'EOF'
#!/bin/sh
# slab-stack-managed: slabctl
if [ -n "${SLABCTL_TEST_ROOT:-}" ] && [ "$(id -u)" -ne 0 ]; then
  slabctl_wrapper_root=$SLABCTL_TEST_ROOT
else
  slabctl_wrapper_root=
fi
slabctl_wrapper_transaction=$slabctl_wrapper_root/etc/slab/management-transaction
if [ -f "$slabctl_wrapper_transaction" ]; then
  slabctl_wrapper_recovery=$(sed -n '1p' "$slabctl_wrapper_transaction")/recovery-launcher
  [ -x "$slabctl_wrapper_recovery" ] || {
    echo "slabctl: management recovery launcher is unavailable" >&2
    exit 1
  }
  exec "$slabctl_wrapper_recovery" "$@"
fi
EOF
    if [ -f "$rollback_directory/binary.present" ]; then
      cat "$rollback_directory/binary" >> "$wrapper"
    else
      cat >> "$wrapper" <<'EOF'
echo "slabctl: management installation is incomplete; rerun the installer" >&2
exit 1
EOF
    fi
    chmod 0755 "$wrapper"
    mv "$wrapper" "$binary_path"
  }
  cleanup_management_install() {
    cleanup_status=$?
    trap - EXIT HUP INT TERM
    preserve_rollback=0
    if [ "$mutation_started" -eq 1 ] && [ "$install_complete" -eq 0 ]; then
      restore_failed=0
      restore_managed_file "$library_path" codex || restore_failed=1
      restore_managed_file "$lifecycle_path" lifecycle || restore_failed=1
      restore_managed_file "$domain_path" domain || restore_failed=1
      restore_managed_file "$proton_path" proton || restore_failed=1
      restore_managed_file "$backup_path" backup || restore_failed=1
      restore_managed_file "$release_client_path" release-client || restore_failed=1
      restore_managed_file "$release_public_key_path" release-public-key || restore_failed=1
      restore_managed_file "$update_path" update || restore_failed=1
      restore_managed_file "$doctor_path" doctor || restore_failed=1
      restore_managed_file "$manager_version_path" manager-version || restore_failed=1
      restore_managed_file "$pointer_path" pointer || restore_failed=1
      install_recovery_wrapper || restore_failed=1
      if [ "$restore_failed" -ne 0 ]; then
        preserve_rollback=1
        echo "Management CLI installation failed and its previous files could not be fully restored. Recovery files remain at: $rollback_directory" >&2
      else
        rm -f "$transaction_path"
      fi
    fi
    rm -f "$temporary_binary" "$temporary_library" "$temporary_lifecycle" \
      "$temporary_domain" "$temporary_proton" "$temporary_backup" \
      "$temporary_release_client" "$temporary_release_public_key" \
      "$temporary_update" "$temporary_doctor" "$temporary_manager_version" \
      "$temporary_pointer" "$temporary_transaction"
    [ "$preserve_rollback" -eq 1 ] || rm -rf "$rollback_directory"
    exit "$cleanup_status"
  }
  trap cleanup_management_install EXIT
  trap 'exit 130' HUP INT TERM

  printf '%s\n' "$rollback_directory" > "$temporary_transaction"
  chmod 0600 "$temporary_transaction"
  mutation_started=1
  mv "$temporary_transaction" "$transaction_path" || exit 1
  mv "$temporary_binary" "$binary_path" || exit 1
  mv "$temporary_library" "$library_path" || exit 1
  mv "$temporary_lifecycle" "$lifecycle_path" || exit 1
  mv "$temporary_domain" "$domain_path" || exit 1
  mv "$temporary_proton" "$proton_path" || exit 1
  mv "$temporary_backup" "$backup_path" || exit 1
  mv "$temporary_release_client" "$release_client_path" || exit 1
  mv "$temporary_release_public_key" "$release_public_key_path" || exit 1
  mv "$temporary_update" "$update_path" || exit 1
  mv "$temporary_doctor" "$doctor_path" || exit 1
  mv "$temporary_manager_version" "$manager_version_path" || exit 1
  mv "$temporary_pointer" "$pointer_path" || exit 1
  rm -f "$transaction_path"
  install_complete=1
  trap - EXIT HUP INT TERM
  rm -rf "$rollback_directory"

  # Publish the stack identity only after the complete management generation
  # is durable. This also keeps updates started by an older slabctl retryable
  # if the process dies during its own management replacement.
  if [ -f "$release_manifest" ] && [ ! -L "$release_manifest" ]; then
    release_version=$(jq -er '.stackVersion' "$release_manifest") || return 1
    temporary_install_version=$install_directory/.VERSION.management.$$
    printf '%s\n' "$release_version" > "$temporary_install_version" || return 1
    chmod 0644 "$temporary_install_version"
    mv "$temporary_install_version" "$install_directory/VERSION"
  fi
)
