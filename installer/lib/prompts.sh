#!/bin/sh

slab_prompt_error() {
  echo "$*" >&2
  return 1
}

slab_validate_install_directory() {
  install_directory=$1
  case "$install_directory" in
    /*) ;;
    *)
      slab_prompt_error "Installation directory must be an absolute path."
      return 1
      ;;
  esac
  case "/$install_directory/" in
    */../* | */./*)
      slab_prompt_error "Installation directory cannot contain . or .. segments."
      return 1
      ;;
  esac
  case "$install_directory" in
    / | /bin | /boot | /dev | /etc | /home | /opt | /root | /run | /srv | /usr | /var)
      slab_prompt_error "Installation directory is too broad: $install_directory"
      return 1
      ;;
  esac
}

slab_validate_access_mode() {
  case "$1" in
    private | domain) return 0 ;;
    *) slab_prompt_error "Access mode must be private or domain." ;;
  esac
}

slab_validate_domain() {
  domain=$1
  if [ "${#domain}" -gt 253 ]; then
    slab_prompt_error "Domain is too long."
    return 1
  fi
  printf '%s\n' "$domain" |
    grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$' ||
    slab_prompt_error "Enter a hostname such as agents.example.com (without scheme or port)."
}

slab_validate_email() {
  email=$1
  [ -z "$email" ] && return 0
  printf '%s\n' "$email" | grep -Eq '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' ||
    slab_prompt_error "Enter a valid email address or leave it empty."
}

slab_validate_passwords() {
  password=$1
  confirmation=$2
  if [ "$password" != "$confirmation" ]; then
    slab_prompt_error "Administrator passwords do not match."
    return 1
  fi
  if [ "${#password}" -lt 12 ]; then
    slab_prompt_error "Administrator password must contain at least 12 characters."
    return 1
  fi
  if [ "${#password}" -gt 256 ]; then
    slab_prompt_error "Administrator password cannot exceed 256 characters."
    return 1
  fi
}

slab_prompt_value() {
  prompt=$1
  default_value=$2
  printf '%s [%s]: ' "$prompt" "$default_value" > /dev/tty
  IFS= read -r entered_value < /dev/tty
  if [ -n "$entered_value" ]; then
    SLAB_PROMPT_VALUE=$entered_value
  else
    SLAB_PROMPT_VALUE=$default_value
  fi
}

slab_prompt_password() {
  restore_tty() {
    stty echo < /dev/tty 2>/dev/null || true
  }
  trap restore_tty EXIT HUP INT TERM
  printf 'Administrator password: ' > /dev/tty
  stty -echo < /dev/tty
  IFS= read -r password < /dev/tty
  printf '\nConfirm administrator password: ' > /dev/tty
  IFS= read -r confirmation < /dev/tty
  restore_tty
  trap - EXIT HUP INT TERM
  printf '\n' > /dev/tty
  slab_validate_passwords "$password" "$confirmation"
  # Read by the versioned installer after this sourced helper returns.
  # shellcheck disable=SC2034
  SLAB_ADMIN_PASSWORD=$password
  confirmation=
}

slab_collect_interactive_configuration() {
  slab_prompt_value "Installation directory" "/opt/slab"
  SLAB_INSTALL_DIRECTORY=$SLAB_PROMPT_VALUE
  slab_validate_install_directory "$SLAB_INSTALL_DIRECTORY"

  slab_prompt_value "Access mode (private/domain)" "private"
  SLAB_ACCESS_MODE=$SLAB_PROMPT_VALUE
  slab_validate_access_mode "$SLAB_ACCESS_MODE"

  SLAB_DOMAIN=
  SLAB_ACME_EMAIL=
  if [ "$SLAB_ACCESS_MODE" = domain ]; then
    slab_prompt_value "Domain" "agents.example.com"
    SLAB_DOMAIN=$SLAB_PROMPT_VALUE
    slab_validate_domain "$SLAB_DOMAIN"
    slab_prompt_value "ACME email (optional)" ""
    SLAB_ACME_EMAIL=$SLAB_PROMPT_VALUE
    slab_validate_email "$SLAB_ACME_EMAIL"
    # Read by the versioned installer after this sourced helper returns.
    # shellcheck disable=SC2034
    SLAB_PUBLIC_URL=https://$SLAB_DOMAIN
  else
    # Read by the versioned installer after this sourced helper returns.
    # shellcheck disable=SC2034
    SLAB_PUBLIC_URL=http://127.0.0.1:3009
  fi

  slab_prompt_password
}
