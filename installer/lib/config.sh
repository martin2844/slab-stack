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

slab_validate_memory_mode() {
  case "$1" in
    disabled | managed | self_hosted) return 0 ;;
    *) slab_config_error "Memory mode must be disabled, managed, or self_hosted." ;;
  esac
}

slab_validate_honcho_url() {
  value=$1
  printf '%s\n' "$value" |
    grep -Eq '^https?://(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+)(:[0-9]{1,5})?(/[^?#[:space:]]*)?$' || {
      slab_config_error "Honcho URL must be an HTTP(S) URL with a fixed host."
      return 1
    }
  case "$value" in
    *'@'* | *'?'* | *'#'*)
      slab_config_error "Honcho URL cannot contain credentials, a query, or a fragment."
      return 1
      ;;
  esac
}

slab_validate_honcho_workspace() {
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_.-]{1,120}$' ||
    slab_config_error "Honcho workspace ID must use 1-120 letters, numbers, dots, dashes, or underscores."
}

slab_validate_memory_context_tokens() {
  value=$1
  case "$value" in
    '' | *[!0-9]*)
      slab_config_error "Memory context tokens must be a number."
      return 1
      ;;
  esac
  if [ "$value" -lt 200 ] || [ "$value" -gt 4000 ]; then
    slab_config_error "Memory context tokens must be between 200 and 4000."
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

slab_validate_one_line_secret_file() {
  filename=$1
  label=$2
  slab_validate_root_private_file "$filename" "$label" || return 1
  [ -s "$filename" ] || {
    slab_config_error "$label cannot be empty: $filename"
    return 1
  }
  awk 'NR > 1 { exit 1 }' "$filename" >/dev/null || {
    slab_config_error "$label must contain exactly one line: $filename"
    return 1
  }
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
      SLAB_MEMORY_MODE) SLAB_MEMORY_MODE=$config_value ;;
      SLAB_HONCHO_URL) SLAB_HONCHO_URL=$config_value ;;
      SLAB_HONCHO_WORKSPACE_ID) SLAB_HONCHO_WORKSPACE_ID=$config_value ;;
      SLAB_MEMORY_MAX_CONTEXT_TOKENS) SLAB_MEMORY_MAX_CONTEXT_TOKENS=$config_value ;;
      SLAB_HONCHO_API_KEY_FILE) SLAB_HONCHO_API_KEY_FILE=$config_value ;;
      SLAB_HONCHO_OPENAI_API_KEY_FILE) SLAB_HONCHO_OPENAI_API_KEY_FILE=$config_value ;;
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
  : "${SLAB_MEMORY_MODE:=disabled}"
  : "${SLAB_HONCHO_URL:=https://api.honcho.dev}"
  : "${SLAB_HONCHO_WORKSPACE_ID:=slab}"
  : "${SLAB_MEMORY_MAX_CONTEXT_TOKENS:=900}"
  : "${SLAB_HONCHO_API_KEY_FILE:=}"
  : "${SLAB_HONCHO_OPENAI_API_KEY_FILE:=}"

  slab_validate_install_directory "$SLAB_INSTALL_DIRECTORY" || return 1
  slab_validate_access_mode "$SLAB_ACCESS_MODE" || return 1
  slab_validate_private_port "$SLAB_PRIVATE_PORT" || return 1
  slab_validate_memory_mode "$SLAB_MEMORY_MODE" || return 1
  slab_validate_honcho_workspace "$SLAB_HONCHO_WORKSPACE_ID" || return 1
  slab_validate_memory_context_tokens "$SLAB_MEMORY_MAX_CONTEXT_TOKENS" || return 1
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

  case "$SLAB_MEMORY_MODE" in
    disabled)
      SLAB_HONCHO_API_KEY_FILE=
      SLAB_HONCHO_OPENAI_API_KEY_FILE=
      ;;
    managed)
      slab_validate_honcho_url "$SLAB_HONCHO_URL" || return 1
      [ -n "$SLAB_HONCHO_API_KEY_FILE" ] || {
        slab_config_error "SLAB_HONCHO_API_KEY_FILE is required for managed memory."
        return 1
      }
      slab_validate_one_line_secret_file "$SLAB_HONCHO_API_KEY_FILE" \
        "Honcho API key file" || return 1
      SLAB_HONCHO_OPENAI_API_KEY_FILE=
      ;;
    self_hosted)
      SLAB_HONCHO_URL=http://honcho-api:8000
      [ -n "$SLAB_HONCHO_OPENAI_API_KEY_FILE" ] || {
        slab_config_error "SLAB_HONCHO_OPENAI_API_KEY_FILE is required for self-hosted memory."
        return 1
      }
      slab_validate_one_line_secret_file "$SLAB_HONCHO_OPENAI_API_KEY_FILE" \
        "Honcho OpenAI API key file" || return 1
      SLAB_HONCHO_API_KEY_FILE=
      ;;
  esac
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
