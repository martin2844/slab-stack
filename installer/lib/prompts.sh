#!/bin/sh

slab_prompt_error() {
  printf '%s%s%s\n' "${SLAB_UI_ERROR:-}" "$*" "${SLAB_UI_RESET:-}" >&2
  return 1
}

slab_prompt_heading() {
  printf '\n%s%s%s\n' "${SLAB_UI_HEADING:-}" "$1" "${SLAB_UI_RESET:-}" > /dev/tty
  printf '%s%s%s\n' "${SLAB_UI_MUTED:-}" "----------------------------------------" "${SLAB_UI_RESET:-}" > /dev/tty
}

slab_prompt_note() {
  printf '%s\n' "$@" > /dev/tty
}

slab_validate_trusted_directory_chain() {
  slab_trust_target=$1
  slab_trust_uid=$2
  slab_trust_root=$3

  case "$slab_trust_root" in
    /*) ;;
    *) slab_prompt_error "Trusted path root must be absolute."; return 1 ;;
  esac
  if [ "$slab_trust_root" != / ]; then
    case "$slab_trust_target/" in
      "$slab_trust_root"/ | "$slab_trust_root"/*) ;;
      *) slab_prompt_error "Path must be inside the trusted root: $slab_trust_root"; return 1 ;;
    esac
  fi

  slab_trust_current=$slab_trust_root
  if [ -L "$slab_trust_current" ] || [ ! -d "$slab_trust_current" ]; then
    slab_prompt_error "Trusted path root must be a real directory: $slab_trust_current"
    return 1
  fi
  slab_trust_relative=${slab_trust_target#"$slab_trust_root"}
  slab_trust_relative=${slab_trust_relative#/}
  slab_trust_old_ifs=$IFS
  IFS=/
  # The explicitly supplied trust root is a test seam. Production always
  # starts at /, so every existing ancestor is checked.
  for slab_trust_component in __root__ $slab_trust_relative; do
    if [ "$slab_trust_component" != __root__ ]; then
      [ -n "$slab_trust_component" ] || continue
      if [ "$slab_trust_current" = / ]; then
        slab_trust_current=/$slab_trust_component
      else
        slab_trust_current=$slab_trust_current/$slab_trust_component
      fi
      if [ -L "$slab_trust_current" ]; then
        IFS=$slab_trust_old_ifs
        slab_prompt_error "Trusted path cannot contain symbolic links: $slab_trust_current"
        return 1
      fi
      [ -e "$slab_trust_current" ] || break
      [ -d "$slab_trust_current" ] || {
        IFS=$slab_trust_old_ifs
        slab_prompt_error "Trusted path component is not a directory: $slab_trust_current"
        return 1
      }
    fi
    slab_trust_owner=$(stat -c '%u' "$slab_trust_current") || { IFS=$slab_trust_old_ifs; return 1; }
    [ "$slab_trust_owner" -eq "$slab_trust_uid" ] || {
      IFS=$slab_trust_old_ifs
      slab_prompt_error "Trusted path must be owned by UID $slab_trust_uid: $slab_trust_current"
      return 1
    }
    slab_trust_permissions=$(stat -c '%a' "$slab_trust_current") || { IFS=$slab_trust_old_ifs; return 1; }
    if printf '%s\n' "$slab_trust_permissions" | grep -Eq '([2367][0-7]|[0-7][2367])$'; then
      IFS=$slab_trust_old_ifs
      slab_prompt_error "Trusted path cannot be group/world writable: $slab_trust_current"
      return 1
    fi
  done
  IFS=$slab_trust_old_ifs
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
    *//* | */)
      slab_prompt_error "Installation directory must use a canonical path without repeated or trailing slashes."
      return 1
      ;;
  esac
  case "$install_directory" in
    / | /bin | /boot | /dev | /etc | /home | /opt | /root | /run | /srv | /usr | /var)
      slab_prompt_error "Installation directory is too broad: $install_directory"
      return 1
      ;;
  esac
  if [ -L "$install_directory" ]; then
    slab_prompt_error "Installation directory cannot be a symbolic link."
    return 1
  fi
  if [ -e "$install_directory" ] && [ ! -d "$install_directory" ]; then
    slab_prompt_error "Installation target exists and is not a directory."
    return 1
  fi

  slab_validate_trusted_directory_chain \
    "$install_directory" "${SLAB_INSTALL_OWNER_UID:-0}" \
    "${SLAB_INSTALL_TRUST_ROOT:-/}"
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
  printf '\n%s%s%s [%s]: ' \
    "${SLAB_UI_PROMPT:-}" "$prompt" "${SLAB_UI_RESET:-}" "$default_value" > /dev/tty
  IFS= read -r entered_value < /dev/tty
  if [ -n "$entered_value" ]; then
    SLAB_PROMPT_VALUE=$entered_value
  else
    SLAB_PROMPT_VALUE=$default_value
  fi
}

slab_prompt_password() {
  # Command substitution isolates temporary TTY traps from the installer's
  # outer failure/signal handlers. Only the entered password reaches stdout.
  # Consumed by the versioned installer after this sourced helper returns.
  # shellcheck disable=SC2034
  SLAB_ADMIN_PASSWORD=$(
    restore_tty() {
      stty echo < /dev/tty 2>/dev/null || true
    }
    trap restore_tty EXIT
    trap 'restore_tty; exit 130' HUP INT TERM
    cat > /dev/tty <<'EOF'
Slab currently uses one workspace administrator. Choose at least 12 characters.
The raw password is never stored or logged; Slab stores only its password hash.
EOF
    printf '\n%sAdministrator password%s: ' \
      "${SLAB_UI_PROMPT:-}" "${SLAB_UI_RESET:-}" > /dev/tty
    stty -echo < /dev/tty
    IFS= read -r password < /dev/tty
    printf '\nConfirm administrator password: ' > /dev/tty
    IFS= read -r confirmation < /dev/tty
    restore_tty
    printf '\n' > /dev/tty
    slab_validate_passwords "$password" "$confirmation" || exit 1
    trap - EXIT HUP INT TERM
    printf '%s' "$password"
  ) || return 1
}

slab_prompt_hidden_value() {
  prompt=$1
  SLAB_PROMPT_SECRET=$(
    restore_tty() {
      stty echo < /dev/tty 2>/dev/null || true
    }
    trap restore_tty EXIT
    trap 'restore_tty; exit 130' HUP INT TERM
    printf '\n%s%s%s: ' \
      "${SLAB_UI_PROMPT:-}" "$prompt" "${SLAB_UI_RESET:-}" > /dev/tty
    stty -echo < /dev/tty
    IFS= read -r secret < /dev/tty
    restore_tty
    printf '\n' > /dev/tty
    [ -n "$secret" ] || exit 1
    trap - EXIT HUP INT TERM
    printf '%s' "$secret"
  ) || {
    slab_prompt_error "$prompt cannot be empty."
    return 1
  }
}

slab_collect_interactive_configuration() {
  slab_prompt_heading "Where should Slab keep its files?"
  slab_prompt_note \
    "Slab uses two places on this same server:" \
    "  - a private folder for program settings and secrets;" \
    "  - Docker storage for your agents, documents, tickets, and email settings." \
    "Both survive normal restarts and updates." \
    "Keep the default unless you have a specific reason to change it."
  slab_prompt_value "Slab folder" "/opt/slab"
  SLAB_INSTALL_DIRECTORY=$SLAB_PROMPT_VALUE
  slab_validate_install_directory "$SLAB_INSTALL_DIRECTORY"

  slab_prompt_heading "How do you want to open Slab?"
  slab_prompt_note \
    "1) Private — Best for testing. Only you can open it through SSH." \
    "2) Domain  — Best for regular use. Open it at an HTTPS address such as" \
    "             agents.example.com. You need a domain or subdomain." \
    "Choose 1 if you are unsure."
  slab_prompt_value "Choose 1 or 2" "1"
  case "$SLAB_PROMPT_VALUE" in
    1 | private) SLAB_ACCESS_MODE=private ;;
    2 | domain) SLAB_ACCESS_MODE=domain ;;
    *) slab_prompt_error "Enter 1 for private access or 2 for domain access." ;;
  esac
  slab_validate_access_mode "$SLAB_ACCESS_MODE"

  SLAB_DOMAIN=
  SLAB_ACME_EMAIL=
  if [ "$SLAB_ACCESS_MODE" = domain ]; then
    slab_prompt_note \
      "Enter the address you want to use, without https:// or a port." \
      "Before Slab can open there, create a DNS A record that points this" \
      "address to the public IP of this server. Slab will set up HTTPS for you."
    slab_prompt_value "Domain or subdomain" "agents.example.com"
    SLAB_DOMAIN=$SLAB_PROMPT_VALUE
    slab_validate_domain "$SLAB_DOMAIN"
    slab_prompt_note \
      "You may provide an email address for important HTTPS certificate notices." \
      "Leave it empty if you do not want those notices."
    slab_prompt_value "Certificate contact email (optional)" ""
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

  slab_prompt_heading "Persistent agent memory"
  slab_prompt_note \
    "disabled: no cross-conversation memory; enable it later from Settings." \
    "managed: use Honcho's hosted API; requires a Honcho API key." \
    "self_hosted: keep Honcho storage on this VPS, with extra containers." \
    "Self-hosted Honcho still uses OpenAI for derivation and embeddings, so it" \
    "requires an OpenAI API key and may incur OpenAI usage charges."
  slab_prompt_value "Memory mode (disabled/managed/self_hosted)" "disabled"
  SLAB_MEMORY_MODE=$SLAB_PROMPT_VALUE
  slab_validate_memory_mode "$SLAB_MEMORY_MODE"
  SLAB_HONCHO_URL=https://api.honcho.dev
  SLAB_HONCHO_WORKSPACE_ID=slab
  # Read by the versioned installer after this sourced helper returns.
  # shellcheck disable=SC2034
  SLAB_MEMORY_MAX_CONTEXT_TOKENS=900
  SLAB_HONCHO_API_KEY=
  SLAB_HONCHO_OPENAI_API_KEY=
  case "$SLAB_MEMORY_MODE" in
    managed)
      slab_prompt_note \
        "Managed Honcho receives the selected memory context. Its API key is" \
        "written only to a root-private Docker secret file."
      slab_prompt_value "Honcho URL" "https://api.honcho.dev"
      SLAB_HONCHO_URL=$SLAB_PROMPT_VALUE
      slab_validate_honcho_url "$SLAB_HONCHO_URL"
      slab_prompt_value "Honcho workspace ID" "slab"
      SLAB_HONCHO_WORKSPACE_ID=$SLAB_PROMPT_VALUE
      slab_validate_honcho_workspace "$SLAB_HONCHO_WORKSPACE_ID"
      slab_prompt_hidden_value "Honcho API key"
      # Read by the versioned installer after this sourced helper returns.
      # shellcheck disable=SC2034
      SLAB_HONCHO_API_KEY=$SLAB_PROMPT_SECRET
      SLAB_PROMPT_SECRET=
      ;;
    self_hosted)
      slab_prompt_note \
        "Self-hosted Honcho keeps PostgreSQL/pgvector and Redis data here." \
        "Its derivation and embedding workers send relevant memory input to OpenAI."
      slab_prompt_value "Honcho workspace ID" "slab"
      SLAB_HONCHO_WORKSPACE_ID=$SLAB_PROMPT_VALUE
      slab_validate_honcho_workspace "$SLAB_HONCHO_WORKSPACE_ID"
      slab_prompt_hidden_value "OpenAI API key for Honcho derivation and embeddings"
      # Read by the versioned installer after this sourced helper returns.
      # shellcheck disable=SC2034
      SLAB_HONCHO_OPENAI_API_KEY=$SLAB_PROMPT_SECRET
      SLAB_PROMPT_SECRET=
      SLAB_HONCHO_URL=http://honcho-api:8000
      ;;
  esac

}
