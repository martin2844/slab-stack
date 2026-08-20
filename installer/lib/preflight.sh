#!/bin/sh

slab_preflight_error() {
  echo "Preflight failed: $*" >&2
  return 1
}

slab_require_root() {
  effective_uid=${SLAB_PREFLIGHT_UID:-$(id -u)}
  [ "$effective_uid" -eq 0 ] ||
    slab_preflight_error "run the installer as root (for example, with sudo)."
}

slab_normalize_architecture() {
  case ${1:-$(uname -m)} in
    x86_64 | amd64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) slab_preflight_error "unsupported architecture: ${1:-unknown}." ;;
  esac
}

slab_validate_platform() {
  distribution=$1
  version=$2
  architecture=$3

  slab_normalize_architecture "$architecture" >/dev/null || return 1
  case "$distribution:$version" in
    ubuntu:22.04 | ubuntu:24.04 | ubuntu:26.04 | debian:12 | debian:12.*) return 0 ;;
    *)
      slab_preflight_error \
        "unsupported host: $distribution $version (supported: Ubuntu 22.04/24.04/26.04 and Debian 12)."
      ;;
  esac
}

slab_detect_platform() {
  os_release_file=${SLAB_OS_RELEASE_FILE:-/etc/os-release}
  [ -r "$os_release_file" ] ||
    slab_preflight_error "cannot read $os_release_file."

  # The supported distributions provide ID and VERSION_ID in os-release.
  # shellcheck disable=SC1090
  . "$os_release_file"
  distribution=${ID:-}
  version=${VERSION_ID:-}
  architecture=$(slab_normalize_architecture) || return 1
  slab_validate_platform "$distribution" "$version" "$architecture" || return 1
  printf '%s %s %s\n' "$distribution" "$version" "$architecture"
}

slab_require_commands() {
  missing_commands=
  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing_commands="$missing_commands $command_name"
    fi
  done
  [ -z "$missing_commands" ] ||
    slab_preflight_error "missing required commands:$missing_commands."
}

slab_require_docker() {
  docker info >/dev/null 2>&1 ||
    slab_preflight_error "Docker Engine is not installed or the daemon is unavailable."
  docker compose version >/dev/null 2>&1 ||
    slab_preflight_error "Docker Compose V2 is required."
}

slab_check_capacity() {
  install_directory=$1
  capacity_path=$install_directory
  while [ ! -e "$capacity_path" ]; do
    parent_path=$(dirname -- "$capacity_path")
    [ "$parent_path" != "$capacity_path" ] || break
    capacity_path=$parent_path
  done

  memory_kib=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
  disk_kib=$(df -Pk "$capacity_path" | awk 'NR == 2 { print $4 }')
  [ "${memory_kib:-0}" -ge 4194304 ] ||
    echo "Warning: less than 4 GiB RAM is available." >&2
  [ "${disk_kib:-0}" -ge 26214400 ] ||
    echo "Warning: less than 25 GiB disk space is available." >&2
}

slab_run_preflight() {
  install_directory=$1
  slab_require_root
  slab_detect_platform >/dev/null
  slab_require_commands curl openssl tar jq awk df flock sha256sum systemctl
  slab_require_docker
  slab_check_capacity "$install_directory"
}

slab_run_bootstrap_preflight() {
  install_directory=$1
  slab_require_root
  slab_detect_platform >/dev/null
  slab_require_commands awk df flock sha256sum sed find dirname apt-get dpkg
  slab_check_capacity "$install_directory"
}

slab_extract_stack_version() {
  manifest=$1
  version=$(sed -n \
    's/^[[:space:]]*"stackVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' \
    "$manifest")
  if [ -z "$version" ] || [ "$(printf '%s\n' "$version" | wc -l)" -ne 1 ]; then
    slab_preflight_error "cannot read one stackVersion from release manifest: $manifest."
    return 1
  fi
  printf '%s\n' "$version"
}
