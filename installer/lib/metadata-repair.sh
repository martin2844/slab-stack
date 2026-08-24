#!/bin/sh

SLAB_EMAIL_METADATA_REPAIR_TARGET_VERSION=0.1.2-candidate.23
SLAB_EMAIL_METADATA_REPAIR_IMAGE_REF=ghcr.io/martin2844/slab-email:candidate-58816f1d708c97953ed5c4f87b81170c6a9ba1e0
SLAB_EMAIL_METADATA_REPAIR_IMAGE_DIGEST=sha256:95e165cf4be802ce8bf5266d4573d7328f721aee77bca300c20d37cd0cb82d6f

slab_metadata_repair_error() {
  echo "Slab metadata repair failed: $*" >&2
  return 1
}

slab_metadata_repair_manifest_is_affected() {
  installed_version=$1
  manifest_sha256=$2
  case "$installed_version:$manifest_sha256" in
    0.1.0-candidate.16:c25e237a8fb2a80a98ebf99177af3679b0113e7c9cb2b7efc8bc5c049c338b94 | \
      0.1.0-candidate.17:48c9065b917d2e6c955bd124e4e2927f93206b859cfe8eaac827691d67f20e82 | \
      0.1.0-candidate.18:4140f33496ecccc9039cbddfacbf5fa2a404e8505160b550503ec199a27c498d | \
      0.1.0-candidate.19:44a322ca3861ddcec02e2f0f23601c100c00545b7587c779c861d583c1838685 | \
      0.1.0-drill.1:f2c83785f417f712239dbbbc15661c9ad3343a1db85655507549daccdeb64136 | \
      0.1.0:1ecbce24607572060589cbed83a5a06aea927b2f337226c7b4a71ccda8914732 | \
      0.1.1:baa3d277efebbe7e4ced22ea408311a00a9d54a3fdd7c3933c7d74a4fc00a924 | \
      0.1.2-candidate.20:2a3d749d652b6f02bf00611ddfade3fc814aef3b59a394a6e6dac2e6e2b1f73b)
      return 0
      ;;
    *) return 1 ;;
  esac
}

slab_metadata_repair_validate_file() {
  managed_file=$1
  expected_uid=${SLABCTL_EXPECTED_OWNER_UID:-0}
  if [ ! -f "$managed_file" ] || [ -L "$managed_file" ]; then
    slab_metadata_repair_error "managed metadata is missing or unsafe: $managed_file"
    return 1
  fi
  [ "$(stat -c '%u' "$managed_file")" -eq "$expected_uid" ] || {
    slab_metadata_repair_error "managed metadata has an unexpected owner: $managed_file"
    return 1
  }
  managed_mode=$(stat -c '%a' "$managed_file")
  if printf '%s\n' "$managed_mode" | grep -Eq '([2367][0-7]|[0-7][2367])$'; then
    slab_metadata_repair_error "managed metadata is group/world writable: $managed_file"
    return 1
  fi
}

slab_metadata_repair_read_live_email_migrations() {
  slabctl_compose exec -T slab-email node -e '
    const Database = require("better-sqlite3");
    const database = new Database("/data/slab-email.db", {
      readonly: true,
      fileMustExist: true,
    });
    const migrations = database
      .prepare("SELECT version AS migration FROM schema_migrations ORDER BY version")
      .all()
      .map((row) => String(row.migration));
    process.stdout.write(JSON.stringify(migrations));
    database.close();
  '
}

slab_repair_known_email_migration_metadata() {
  target_manifest=$1
  repair_root=${SLAB_METADATA_REPAIR_ROOT:-}
  pointer_file=$repair_root/etc/slab/install-directory

  command -v jq >/dev/null 2>&1 || {
    slab_metadata_repair_error "jq is required"
    return 1
  }
  command -v sha256sum >/dev/null 2>&1 || {
    slab_metadata_repair_error "sha256sum is required"
    return 1
  }
  slab_metadata_repair_validate_file "$pointer_file" || return 1

  install_directory=$(sed -n '1p' "$pointer_file")
  case "$install_directory" in
    /*) ;;
    *) slab_metadata_repair_error "installation registry is not absolute"; return 1 ;;
  esac
  case "$install_directory" in
    *//* | */ | */./* | */../*)
      slab_metadata_repair_error "installation registry is not canonical"
      return 1
      ;;
  esac

  target_version=$(jq -er '.stackVersion' "$target_manifest") || return 1
  [ "$target_version" = "$SLAB_EMAIL_METADATA_REPAIR_TARGET_VERSION" ] || {
    slab_metadata_repair_error "this repair requires signed release $SLAB_EMAIL_METADATA_REPAIR_TARGET_VERSION"
    return 1
  }
  target_email_ref=$(jq -er '.images.email.ref' "$target_manifest") || return 1
  target_email_digest=$(jq -er '.images.email.digest' "$target_manifest") || return 1
  target_email_migrations=$(jq -cer '.dataCompatibility.volumes.email_data.migrations | map(tostring)' "$target_manifest") || return 1
  if [ "$target_email_ref" != "$SLAB_EMAIL_METADATA_REPAIR_IMAGE_REF" ] ||
    [ "$target_email_digest" != "$SLAB_EMAIL_METADATA_REPAIR_IMAGE_DIGEST" ] ||
    [ "$target_email_migrations" != '["1","2"]' ]
  then
    slab_metadata_repair_error "signed target does not contain the expected Email correction"
    return 1
  fi

  SLABCTL_EXPECTED_OWNER_UID=${SLAB_MANAGEMENT_OWNER_UID:-0}
  slabctl_load_installation "$install_directory" || return 1
  slab_acquire_management_lock "$install_directory" || return 1
  # The first load resolves the trusted Compose identity needed to locate the
  # lock. Reload under that lock so every file used below is revalidated after
  # any updater/installer that was already in flight has finished.
  slabctl_load_installation "$install_directory" || return 1

  installed_version_file=$install_directory/VERSION
  installed_manifest=$install_directory/release-manifest.json
  slab_metadata_repair_validate_file "$installed_version_file" || return 1
  slab_metadata_repair_validate_file "$installed_manifest" || return 1
  installed_version=$(sed -n '1p' "$installed_version_file")
  installed_email_ref=$(jq -er '.images.email.ref' "$installed_manifest") || return 1
  installed_email_digest=$(jq -er '.images.email.digest' "$installed_manifest") || return 1
  installed_email_migrations=$(jq -cer '.dataCompatibility.volumes.email_data.migrations | map(tostring)' "$installed_manifest") || return 1

  if [ "$installed_email_ref" != "$SLAB_EMAIL_METADATA_REPAIR_IMAGE_REF" ] ||
    [ "$installed_email_digest" != "$SLAB_EMAIL_METADATA_REPAIR_IMAGE_DIGEST" ]
  then
    slab_metadata_repair_error "installed Email image is outside the known affected set"
    return 1
  fi

  if [ "$installed_email_migrations" = '["1","2"]' ]; then
    echo "Email migration metadata is already correct. No repair was needed."
    return 0
  fi
  [ "$installed_email_migrations" = '["1","2","3"]' ] || {
    slab_metadata_repair_error "installed Email migration metadata is outside the known affected set"
    return 1
  }
  installed_manifest_sha256=$(sha256sum "$installed_manifest" | awk '{print $1}')
  slab_metadata_repair_manifest_is_affected \
    "$installed_version" "$installed_manifest_sha256" || {
      slab_metadata_repair_error "installed release metadata does not exactly match an affected official release"
      return 1
    }

  live_email_migrations=$(slab_metadata_repair_read_live_email_migrations) || {
    slab_metadata_repair_error "could not inspect the running Email database"
    return 1
  }
  live_email_migrations=$(printf '%s' "$live_email_migrations" | jq -cer 'map(tostring)') || {
    slab_metadata_repair_error "Email returned invalid migration metadata"
    return 1
  }
  [ "$live_email_migrations" = '["1","2"]' ] || {
    slab_metadata_repair_error "live Email migrations are not the exact known [1,2] state; no metadata was changed"
    return 1
  }

  backup_manifest=$installed_manifest.pre-email-metadata-repair.$installed_version
  backup_temporary=$install_directory/.release-manifest.email-repair-backup.$$
  temporary_manifest=$install_directory/.release-manifest.email-repair.$$
  if [ -e "$backup_manifest" ] || [ -L "$backup_manifest" ]; then
    if [ ! -f "$backup_manifest" ] || [ -L "$backup_manifest" ] ||
      ! cmp -s "$backup_manifest" "$installed_manifest"
    then
      slab_metadata_repair_error "repair backup already exists with unexpected content: $backup_manifest"
      return 1
    fi
  else
    (
      trap 'rm -f "$backup_temporary"' EXIT
      trap 'exit 130' HUP INT TERM
      umask 077
      cp "$installed_manifest" "$backup_temporary" || exit 1
      cmp -s "$backup_temporary" "$installed_manifest" || exit 1
      chmod 0600 "$backup_temporary" || exit 1
      mv "$backup_temporary" "$backup_manifest" || exit 1
      trap - EXIT HUP INT TERM
    ) || {
      rm -f "$backup_temporary"
      return 1
    }
  fi

  (
    trap 'rm -f "$temporary_manifest"' EXIT
    trap 'exit 130' HUP INT TERM
    umask 077
    jq '.dataCompatibility.volumes.email_data.migrations = ["1", "2"]' \
      "$installed_manifest" > "$temporary_manifest" || exit 1
    chmod "$(stat -c '%a' "$installed_manifest")" "$temporary_manifest" || exit 1
    mv "$temporary_manifest" "$installed_manifest" || exit 1
    trap - EXIT HUP INT TERM
  ) || {
    rm -f "$temporary_manifest"
    return 1
  }

  repaired_migrations=$(jq -cer '.dataCompatibility.volumes.email_data.migrations | map(tostring)' "$installed_manifest") || return 1
  [ "$repaired_migrations" = '["1","2"]' ] || {
    slab_metadata_repair_error "repaired manifest did not validate"
    return 1
  }
  echo "Corrected the known Email migration metadata defect for Slab $installed_version."
  echo "Original manifest preserved at $backup_manifest"
  echo "Run 'sudo slabctl update apply --channel candidate --yes' to continue the update."
}
