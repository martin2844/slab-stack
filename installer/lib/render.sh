#!/bin/sh

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

  case "$access_mode" in
    private | domain) ;;
    *) echo "Unsupported access mode: $access_mode" >&2; return 1 ;;
  esac

  mkdir -p "$install_directory/config"
  chmod 0755 "$install_directory" "$install_directory/config"

  cp "$bundle_root/templates/compose.yml" "$install_directory/compose.yml"
  cp "$bundle_root/templates/compose.domain.yml" \
    "$install_directory/compose.domain.yml"
  cp "$bundle_root/templates/compose.private.yml" \
    "$install_directory/compose.private.yml"
  cp "$bundle_root/templates/Caddyfile.domain" "$install_directory/Caddyfile"
  cp "$manifest_path" "$install_directory/release-manifest.json"

  environment_file=$install_directory/config/install.env
  temporary_environment=$install_directory/config/.install.env.tmp.$$
  {
    printf 'SLAB_PUBLIC_URL=%s\n' "$public_url"
    printf 'SLAB_DOMAIN=%s\n' "$domain"
    printf 'ACME_EMAIL=%s\n' "$acme_email"
    printf 'SLAB_PRIVATE_BIND_IP=%s\n' "$private_bind_ip"
    printf 'SLAB_PRIVATE_PORT=%s\n' "$private_port"
    node "$bundle_root/scripts/render-image-env.mjs" "$manifest_path"
  } > "$temporary_environment"
  chmod 0644 "$temporary_environment"
  mv "$temporary_environment" "$environment_file"

  jq -r '.stackVersion' "$manifest_path" > "$install_directory/VERSION"
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
