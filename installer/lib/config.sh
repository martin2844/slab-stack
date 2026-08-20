#!/bin/sh

slab_config_error() {
  echo "$*" >&2
  return 1
}

slab_validate_private_port() {
  port=$1
  case "$port" in
    '' | *[!0-9]*) slab_config_error "Private port must be a number."; return 1 ;;
  esac
  if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
    slab_config_error "Private port must be between 1024 and 65535."
  fi
}

slab_validate_root_private_file() {
  filename=$1
  label=$2
  [ -L "$filename" ] && {
    slab_config_error "$label cannot be a symbolic link: $filename"
    return 1
  }
  if [ ! -f "$filename" ] || [ ! -r "$filename" ]; then
    slab_config_error "$label must be a readable regular file: $filename"
    return 1
  fi
  owner_uid=$(stat -c '%u' "$filename") || return 1
  expected_uid=${SLAB_CONFIG_OWNER_UID:-0}
  slab_validate_trusted_directory_chain \
    "$(dirname -- "$filename")" "$expected_uid" \
    "${SLAB_CONFIG_TRUST_ROOT:-/}" || return 1
  [ "$owner_uid" -eq "$expected_uid" ] || {
    slab_config_error "$label must be owned by UID $expected_uid: $filename"
    return 1
  }
  permissions=$(stat -c '%a' "$filename") || return 1
  case "$permissions" in
    400 | 600) ;;
    *) slab_config_error "$label must use mode 0400 or 0600: $filename"; return 1 ;;
  esac
}

slab_load_noninteractive_config() {
  config_file=$1
  slab_validate_root_private_file "$config_file" "Installer config" || return 1

  while IFS= read -r config_line || [ -n "$config_line" ]; do
    case "$config_line" in
      '' | \#*) continue ;;
      *=*) ;;
      *) slab_config_error "Invalid config line (expected KEY=value)."; return 1 ;;
    esac
    config_key=${config_line%%=*}
    config_value=${config_line#*=}
    # These assignments are consumed by the versioned installer after this
    # sourced helper returns.
    # shellcheck disable=SC2034
    case "$config_key" in
      SLAB_INSTALL_DIRECTORY) SLAB_INSTALL_DIRECTORY=$config_value ;;
      SLAB_ACCESS_MODE) SLAB_ACCESS_MODE=$config_value ;;
      SLAB_DOMAIN) SLAB_DOMAIN=$config_value ;;
      SLAB_ACME_EMAIL) SLAB_ACME_EMAIL=$config_value ;;
      SLAB_PRIVATE_BIND_IP) SLAB_PRIVATE_BIND_IP=$config_value ;;
      SLAB_PRIVATE_PORT) SLAB_PRIVATE_PORT=$config_value ;;
      SLAB_COMPOSE_PROJECT_NAME) SLAB_COMPOSE_PROJECT_NAME=$config_value ;;
      SLAB_ADMIN_PASSWORD_FILE) SLAB_ADMIN_PASSWORD_FILE=$config_value ;;
      *) slab_config_error "Unknown installer config key: $config_key"; return 1 ;;
    esac
  done < "$config_file"
}

slab_finalize_noninteractive_config() {
  : "${SLAB_INSTALL_DIRECTORY:=/opt/slab}"
  : "${SLAB_ACCESS_MODE:=private}"
  : "${SLAB_DOMAIN:=}"
  : "${SLAB_ACME_EMAIL:=}"
  : "${SLAB_PRIVATE_BIND_IP:=127.0.0.1}"
  : "${SLAB_PRIVATE_PORT:=3009}"
  : "${SLAB_COMPOSE_PROJECT_NAME:=slab}"

  slab_validate_install_directory "$SLAB_INSTALL_DIRECTORY" || return 1
  slab_validate_access_mode "$SLAB_ACCESS_MODE" || return 1
  slab_validate_private_port "$SLAB_PRIVATE_PORT" || return 1
  [ "$SLAB_PRIVATE_BIND_IP" = 127.0.0.1 ] || {
    slab_config_error "The first installer release only permits loopback private binding (127.0.0.1)."
    return 1
  }

  if [ "$SLAB_ACCESS_MODE" = domain ]; then
    [ -n "$SLAB_DOMAIN" ] || {
      slab_config_error "SLAB_DOMAIN is required in domain mode."
      return 1
    }
    slab_validate_domain "$SLAB_DOMAIN" || return 1
    slab_validate_email "$SLAB_ACME_EMAIL" || return 1
    # Consumed by the versioned installer after this sourced helper returns.
    # shellcheck disable=SC2034
    SLAB_PUBLIC_URL=https://$SLAB_DOMAIN
  else
    SLAB_DOMAIN=
    SLAB_ACME_EMAIL=
    # Consumed by the versioned installer after this sourced helper returns.
    # shellcheck disable=SC2034
    SLAB_PUBLIC_URL=http://127.0.0.1:$SLAB_PRIVATE_PORT
  fi
}

slab_read_admin_password_file() {
  password_file=$1
  slab_validate_root_private_file "$password_file" "Administrator password file" || return 1
  if ! awk 'NR > 1 { exit 1 }' "$password_file" >/dev/null; then
    slab_config_error "Administrator password file must contain exactly one line."
    return 1
  fi
  IFS= read -r SLAB_ADMIN_PASSWORD < "$password_file" ||
    [ -n "${SLAB_ADMIN_PASSWORD:-}" ] || return 1
  slab_validate_passwords "$SLAB_ADMIN_PASSWORD" "$SLAB_ADMIN_PASSWORD"
}
