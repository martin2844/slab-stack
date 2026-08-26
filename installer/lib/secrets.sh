#!/bin/sh

# Docker Compose implements file-backed secrets as bind mounts. The source
# directory remains root-only on the host, while each mounted file must be
# readable by the unprivileged UID used inside a service container.

slab_ensure_secret_file() {
  secret_directory=$1
  secret_name=$2
  secret_path=$secret_directory/$secret_name

  if [ -L "$secret_path" ]; then
    echo "Refusing symbolic-link secret: $secret_path" >&2
    return 1
  fi
  if [ -e "$secret_path" ]; then
    if [ ! -f "$secret_path" ] || [ ! -s "$secret_path" ]; then
      echo "Existing secret must be a non-empty regular file: $secret_path" >&2
      return 1
    fi
  else
    temporary_secret=$(mktemp "$secret_directory/.${secret_name}.XXXXXX")
    if ! openssl rand -hex 32 > "$temporary_secret"; then
      rm -f "$temporary_secret"
      return 1
    fi
    chmod 0444 "$temporary_secret"
    mv "$temporary_secret" "$secret_path"
  fi

  chmod 0444 "$secret_path"
}

slab_prepare_secrets() {
  secret_directory=$1
  if [ -L "$secret_directory" ]; then
    echo "Refusing symbolic-link secret directory: $secret_directory" >&2
    return 1
  fi
  if [ -e "$secret_directory" ] && [ ! -d "$secret_directory" ]; then
    echo "Secret target exists and is not a directory: $secret_directory" >&2
    return 1
  fi
  old_umask=$(umask)
  umask 077
  mkdir -p "$secret_directory"
  chmod 0700 "$secret_directory"

  for secret_name in \
    work-api-key \
    docs-api-key \
    runner-token \
    email-admin-key \
    email-master-key \
    session-secret \
    honcho-api-key \
    honcho-openai-api-key \
    honcho-db-password
  do
    slab_ensure_secret_file "$secret_directory" "$secret_name" || {
      umask "$old_umask"
      return 1
    }
  done

  umask "$old_umask"
}

slab_replace_secret() {
  secret_directory=$1
  secret_name=$2
  value=$3
  [ -n "$value" ] || return 0
  target=$secret_directory/$secret_name
  temporary=$(mktemp "$secret_directory/.${secret_name}.replace.XXXXXX") || return 1
  if ! printf '%s\n' "$value" > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  chmod 0444 "$temporary"
  mv "$temporary" "$target"
}

slab_replace_secret_from_file() {
  secret_directory=$1
  secret_name=$2
  source_file=$3
  [ -n "$source_file" ] || return 0
  target=$secret_directory/$secret_name
  temporary=$(mktemp "$secret_directory/.${secret_name}.replace.XXXXXX") || return 1
  if ! awk 'NR > 1 { exit 1 }' "$source_file" >/dev/null; then
    rm -f "$temporary"
    echo "Secret input must contain exactly one line: $source_file" >&2
    return 1
  fi
  if ! cp "$source_file" "$temporary" || [ ! -s "$temporary" ]; then
    rm -f "$temporary"
    return 1
  fi
  chmod 0444 "$temporary"
  mv "$temporary" "$target"
}
