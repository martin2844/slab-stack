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
    session-secret
  do
    slab_ensure_secret_file "$secret_directory" "$secret_name" || {
      umask "$old_umask"
      return 1
    }
  done

  umask "$old_umask"
}
