#!/bin/sh

SLAB_DOCKER_GPG_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
SLAB_HOST_PACKAGES_PREPARED=${SLAB_HOST_PACKAGES_PREPARED:-0}

slab_host_path() {
  host_root=${SLAB_HOST_ROOT:-}
  printf '%s%s\n' "$host_root" "$1"
}

slab_apt_get() {
  DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 "$@"
}

slab_install_host_packages() {
  [ "$SLAB_HOST_PACKAGES_PREPARED" -eq 0 ] || return 0
  slab_apt_get update
  slab_apt_get install -y ca-certificates curl gnupg jq openssl tar
  SLAB_HOST_PACKAGES_PREPARED=1
}

slab_acquire_host_bootstrap_lock() {
  host_lock=${SLAB_HOST_LOCK_FILE:-/run/slab-installer-host-bootstrap.lock}
  [ ! -L "$host_lock" ] || {
    echo "Host bootstrap lock cannot be a symbolic link: $host_lock" >&2
    return 1
  }
  old_umask=$(umask)
  umask 077
  : >> "$host_lock"
  umask "$old_umask"
  chmod 0600 "$host_lock"
  exec 7>"$host_lock"
  if ! flock -w "${SLAB_HOST_LOCK_TIMEOUT_SECONDS:-300}" 7; then
    echo "Another Slab installer is preparing host packages or Docker." >&2
    return 1
  fi
}

slab_docker_is_ready() {
  command -v docker >/dev/null 2>&1 &&
    docker info >/dev/null 2>&1 &&
    docker compose version >/dev/null 2>&1
}

slab_detect_conflicting_docker_packages() {
  conflicts=
  for package_name in \
    docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc
  do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$package_name" 2>/dev/null |
      grep -q '^ii '
    then
      conflicts="$conflicts $package_name"
    fi
  done
  [ -z "$conflicts" ] || {
    echo "Conflicting Docker packages are installed:$conflicts" >&2
    echo "Remove them explicitly before installing Docker CE; Slab will not remove host packages automatically." >&2
    return 1
  }
}

slab_write_docker_repository() (
  distribution=$1
  codename=$2
  architecture=$3
  keyrings_directory=$(slab_host_path /etc/apt/keyrings)
  sources_directory=$(slab_host_path /etc/apt/sources.list.d)
  key_path=$keyrings_directory/docker.asc
  source_path=$sources_directory/docker.sources
  staged_key=$keyrings_directory/.docker.asc.$$
  staged_source=$sources_directory/.docker.sources.$$
  download_url="https://download.docker.com/linux/$distribution/gpg"
  repository_url="https://download.docker.com/linux/$distribution"

  install -d -m 0755 "$keyrings_directory" "$sources_directory"
  temporary_key=$(mktemp "${TMPDIR:-/tmp}/slab-docker-key.XXXXXX")
  trap 'rm -f "$temporary_key" "$staged_key" "$staged_source"' EXIT HUP INT TERM
  curl -fsSL "$download_url" -o "$temporary_key"
  if ! gpg --batch --show-keys --with-colons "$temporary_key" 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10 }' |
    grep -Fxq "$SLAB_DOCKER_GPG_FINGERPRINT"
  then
    echo "Docker repository signing key fingerprint did not match the pinned release key." >&2
    return 1
  fi
  install -m 0644 "$temporary_key" "$staged_key"
  mv "$staged_key" "$key_path"
  rm -f "$temporary_key"

  temporary_source=$(mktemp "${TMPDIR:-/tmp}/slab-docker-source.XXXXXX")
  trap 'rm -f "$temporary_source" "$staged_key" "$staged_source"' EXIT HUP INT TERM
  {
    echo "Types: deb"
    echo "URIs: $repository_url"
    echo "Suites: $codename"
    echo "Components: stable"
    echo "Architectures: $architecture"
    echo "Signed-By: /etc/apt/keyrings/docker.asc"
  } > "$temporary_source"
  install -m 0644 "$temporary_source" "$staged_source"
  mv "$staged_source" "$source_path"
  rm -f "$temporary_source"
  trap - EXIT HUP INT TERM
)

slab_install_docker_engine() {
  slab_docker_is_ready && return 0
  slab_require_commands apt-get dpkg dpkg-query curl gpg grep install mktemp
  slab_detect_conflicting_docker_packages

  # shellcheck disable=SC1090
  . "${SLAB_OS_RELEASE_FILE:-/etc/os-release}"
  distribution=${ID:-}
  version=${VERSION_ID:-}
  codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
  architecture=$(dpkg --print-architecture)
  slab_validate_platform "$distribution" "$version" "$architecture"
  [ -n "$codename" ] || {
    echo "Cannot determine the distribution codename for Docker's apt repository." >&2
    return 1
  }

  echo "Docker Engine is not installed; configuring Docker's official apt repository."
  slab_install_host_packages
  slab_write_docker_repository "$distribution" "$codename" "$architecture"
  slab_apt_get update
  slab_apt_get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  slab_docker_is_ready || {
    echo "Docker Engine installation completed, but the daemon or Compose V2 is unavailable." >&2
    return 1
  }
}

slab_prepare_host() {
  slab_require_commands apt-get dpkg dpkg-query awk grep install mktemp mv systemctl
  slab_acquire_host_bootstrap_lock
  if ! command -v jq >/dev/null 2>&1 ||
    ! command -v openssl >/dev/null 2>&1 ||
    ! command -v tar >/dev/null 2>&1 ||
    ! command -v gpg >/dev/null 2>&1 ||
    ! command -v curl >/dev/null 2>&1
  then
    echo "Installing required host packages from the distribution repository."
    slab_install_host_packages
  fi
  slab_install_docker_engine
}
