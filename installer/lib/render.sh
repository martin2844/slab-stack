#!/bin/sh

slab_validate_release_manifest() {
  manifest_path=$1
  jq -e '
    . as $manifest |
    .schemaVersion == 1 and
    (.stackVersion | test("^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")) and
    (.channel | IN("development", "candidate", "stable")) and
    (.codexVersion | type == "string" and length > 0) and
    (.images | type == "object") and
    (["agents", "work", "docs", "email", "runner"] | all(
      . as $service |
      ($manifest.images[$service].ref | test("^ghcr\\.io/[a-z0-9_.-]+/[a-z0-9_.-]+:[A-Za-z0-9_.-]+$")) and
      ($manifest.images[$service].digest | test("^sha256:[a-f0-9]{64}$")) and
      ($manifest.images[$service].platforms | index("linux/amd64") != null) and
      ($manifest.images[$service].platforms | index("linux/arm64") != null)
    ))
  ' "$manifest_path" >/dev/null 2>&1 || {
    echo "Invalid release manifest: $manifest_path" >&2
    return 1
  }
}

slab_render_image_environment() {
  manifest_path=$1
  for image_mapping in \
    SLAB_AGENTS_IMAGE:agents \
    SLAB_WORK_IMAGE:work \
    SLAB_DOCS_IMAGE:docs \
    SLAB_EMAIL_IMAGE:email \
    SLAB_RUNNER_IMAGE:runner
  do
    environment_name=${image_mapping%%:*}
    service_name=${image_mapping#*:}
    image_reference=$(jq -r --arg service "$service_name" \
      '.images[$service].ref + "@" + .images[$service].digest' \
      "$manifest_path") || return 1
    printf '%s=%s\n' "$environment_name" "$image_reference"
  done
}

slab_render_installation() {
  bundle_root=$1
  install_directory=$2
  manifest_path=$3
  access_mode=$4
  public_url=$5
  domain=$6
  acme_email=$7
  private_bind_ip=$8
  private_port=$9
  # Older slabctl update clients call this target-release helper with nine
  # arguments. Defaulting to deferred identity keeps those clients from
  # claiming the target version before management replacement commits.
  write_identity=${10:-0}

  case "$access_mode" in
    private | domain) ;;
    *) echo "Unsupported access mode: $access_mode" >&2; return 1 ;;
  esac
  slab_validate_release_manifest "$manifest_path" || return 1

  if [ -L "$install_directory/config" ]; then
    echo "Refusing symbolic-link config directory: $install_directory/config" >&2
    return 1
  fi
  for managed_path in \
    "$install_directory/compose.yml" \
    "$install_directory/compose.domain.yml" \
    "$install_directory/compose.private.yml" \
    "$install_directory/Caddyfile" \
    "$install_directory/release-manifest.json" \
    "$install_directory/VERSION" \
    "$install_directory/config/install.env" \
    "$install_directory/config/access-mode" \
    "$install_directory/config/install-state.json"
  do
    if [ -L "$managed_path" ]; then
      echo "Refusing symbolic-link managed file: $managed_path" >&2
      return 1
    fi
  done

  mkdir -p "$install_directory/config"
  chmod 0755 "$install_directory" "$install_directory/config"

  cp "$bundle_root/templates/compose.yml" "$install_directory/compose.yml"
  cp "$bundle_root/templates/compose.domain.yml" \
    "$install_directory/compose.domain.yml"
  cp "$bundle_root/templates/compose.private.yml" \
    "$install_directory/compose.private.yml"
  if [ -n "$acme_email" ]; then
    cp "$bundle_root/templates/Caddyfile.domain" "$install_directory/Caddyfile"
  else
    # Match the literal Caddy environment placeholder.
    # shellcheck disable=SC2016
    sed '/^[[:space:]]*email {\$ACME_EMAIL}[[:space:]]*$/d' \
      "$bundle_root/templates/Caddyfile.domain" > "$install_directory/Caddyfile"
  fi
  cp "$manifest_path" "$install_directory/release-manifest.json"

  environment_file=$install_directory/config/install.env
  temporary_environment=$install_directory/config/.install.env.tmp.$$
  {
    printf 'SLAB_PUBLIC_URL=%s\n' "$public_url"
    printf 'SLAB_DOMAIN=%s\n' "$domain"
    printf 'ACME_EMAIL=%s\n' "$acme_email"
    printf 'SLAB_PRIVATE_BIND_IP=%s\n' "$private_bind_ip"
    printf 'SLAB_PRIVATE_PORT=%s\n' "$private_port"
    slab_render_image_environment "$manifest_path"
  } > "$temporary_environment"
  chmod 0644 "$temporary_environment"
  mv "$temporary_environment" "$environment_file"

  if [ "$write_identity" = 1 ]; then
    jq -r '.stackVersion' "$manifest_path" > "$install_directory/VERSION"
  fi
  chmod 0644 \
    "$install_directory/compose.yml" \
    "$install_directory/compose.domain.yml" \
    "$install_directory/compose.private.yml" \
    "$install_directory/Caddyfile" \
    "$install_directory/release-manifest.json" \
    "$install_directory/VERSION"

  printf '%s\n' "$access_mode" > "$install_directory/config/access-mode"
  chmod 0644 "$install_directory/config/access-mode"
}
