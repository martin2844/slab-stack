#!/bin/sh
set -eu

# The public bootstrap is intentionally small. It only resolves a version,
# verifies a signed release bundle, and invokes the versioned installer inside.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SLAB_BOOTSTRAP_CHANNEL_BASE_URL=${SLAB_BOOTSTRAP_CHANNEL_BASE_URL:-}
SLAB_BOOTSTRAP_RELEASE_BASE_URL=${SLAB_BOOTSTRAP_RELEASE_BASE_URL:-https://github.com/martin2844/slab-stack/releases/download}
SLAB_BOOTSTRAP_PUBLIC_KEY_SHA256=2865983ef11b8070415642e0ebdcde17468f48392ee517a63f991f29e80c5293
SLAB_BOOTSTRAP_ALLOW_INSECURE_TEST_SOURCE=${SLAB_BOOTSTRAP_ALLOW_INSECURE_TEST_SOURCE:-0}
SLAB_BOOTSTRAP_TEMPORARY_DIRECTORY=

slab_bootstrap_usage() {
  cat <<'EOF'
Usage: sudo sh install.sh [bootstrap options] [installer options]

Bootstrap options:
  --version VERSION     Install one exact signed stack version.
  --channel CHANNEL     Resolve stable or candidate (default: stable).
  --                    Stop parsing bootstrap options.
  --help                Show this help.

Installer options such as --dry-run, --non-interactive, and --config are
forwarded unchanged. Passwords are never accepted as command-line values.
EOF
}

slab_bootstrap_fail() {
  echo "Slab bootstrap failed: $*" >&2
  exit 1
}

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2317
slab_bootstrap_cleanup() {
  if [ -n "$SLAB_BOOTSTRAP_TEMPORARY_DIRECTORY" ] &&
    [ -d "$SLAB_BOOTSTRAP_TEMPORARY_DIRECTORY" ]
  then
    case "$SLAB_BOOTSTRAP_TEMPORARY_DIRECTORY" in
      /tmp/slab-bootstrap.*)
        find "$SLAB_BOOTSTRAP_TEMPORARY_DIRECTORY" -depth -delete
        ;;
      *)
        echo "Refusing to clean unexpected bootstrap path." >&2
        ;;
    esac
  fi
}

trap slab_bootstrap_cleanup EXIT
trap 'exit 130' HUP INT TERM

slab_bootstrap_require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    slab_bootstrap_fail "required command is unavailable: $1"
}

slab_bootstrap_validate_version() {
  printf '%s\n' "$1" |
    grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z][0-9A-Za-z.-]*)?$' ||
    slab_bootstrap_fail "invalid release version: $1"
}

slab_bootstrap_download() {
  source_url=$1
  destination=$2
  maximum_seconds=${3:-300}
  case "$source_url" in
    https://*)
      curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --location --fail --silent --show-error \
        --connect-timeout 10 --max-time "$maximum_seconds" \
        --output "$destination" "$source_url"
      ;;
    http://* | file://*)
      [ "$SLAB_BOOTSTRAP_ALLOW_INSECURE_TEST_SOURCE" = 1 ] ||
        slab_bootstrap_fail "release downloads require HTTPS"
      protocol=${source_url%%:*}
      curl --proto "=$protocol" --proto-redir "=$protocol" \
        --location --fail --silent --show-error \
        --connect-timeout 10 --max-time "$maximum_seconds" \
        --output "$destination" "$source_url"
      ;;
    *) slab_bootstrap_fail "unsupported release URL" ;;
  esac
}

slab_bootstrap_json_string() {
  json_file=$1
  json_key=$2
  values=$(sed -n \
    's/^[[:space:]]*"'"$json_key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' \
    "$json_file")
  if [ -z "$values" ] || [ "$(printf '%s\n' "$values" | wc -l)" -ne 1 ]; then
    slab_bootstrap_fail "channel metadata has no unique $json_key"
  fi
  printf '%s\n' "$values"
}

slab_bootstrap_write_public_key() {
  destination=$1
  cat > "$destination" <<'EOF'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAUcgrRzXN38EmLiEZfZM06BwhyLZTgwIjZSaLgFkPvMQ=
-----END PUBLIC KEY-----
EOF
}

slab_bootstrap_validate_archive() {
  archive=$1
  expected_root=$2
  listing=$3
  verbose_listing=$4

  tar -tzf "$archive" > "$listing"
  [ -s "$listing" ] || slab_bootstrap_fail "release bundle is empty"
  while IFS= read -r member; do
    case "$member" in
      "$expected_root" | "$expected_root/" | "$expected_root/"*) ;;
      *) slab_bootstrap_fail "release bundle contains a path outside its root" ;;
    esac
    case "/$member/" in
      */../* | */./*) slab_bootstrap_fail "release bundle contains an unsafe path" ;;
    esac
  done < "$listing"

  tar -tvzf "$archive" > "$verbose_listing"
  while IFS= read -r entry; do
    entry_type=${entry%"${entry#?}"}
    case "$entry_type" in
      - | d) ;;
      *) slab_bootstrap_fail "release bundle contains a non-regular entry" ;;
    esac
  done < "$verbose_listing"
}

requested_version=
requested_channel=stable
selection_count=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || slab_bootstrap_fail "--version requires a value"
      requested_version=$2
      selection_count=$((selection_count + 1))
      shift 2
      ;;
    --channel)
      [ "$#" -ge 2 ] || slab_bootstrap_fail "--channel requires a value"
      requested_channel=$2
      selection_count=$((selection_count + 1))
      shift 2
      ;;
    --help) slab_bootstrap_usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

[ "$selection_count" -le 1 ] ||
  slab_bootstrap_fail "choose either --version or --channel, not both"
case "$requested_channel" in
  stable | candidate) ;;
  *) slab_bootstrap_fail "unsupported release channel: $requested_channel" ;;
esac

for required_command in curl openssl sha256sum tar sed awk grep wc mktemp find chmod mkdir; do
  slab_bootstrap_require_command "$required_command"
done

SLAB_BOOTSTRAP_TEMPORARY_DIRECTORY=$(mktemp -d /tmp/slab-bootstrap.XXXXXX)
chmod 0700 "$SLAB_BOOTSTRAP_TEMPORARY_DIRECTORY"
channel_manifest_sha256=
public_key=$SLAB_BOOTSTRAP_TEMPORARY_DIRECTORY/release-signing-public.pem
public_key_der=$SLAB_BOOTSTRAP_TEMPORARY_DIRECTORY/release-signing-public.der
slab_bootstrap_write_public_key "$public_key"
openssl pkey -pubin -in "$public_key" -outform DER -out "$public_key_der" \
  >/dev/null 2>&1 || slab_bootstrap_fail "embedded release key is invalid"
public_key_sha256=$(sha256sum "$public_key_der" | awk '{print $1}')
[ "$public_key_sha256" = "$SLAB_BOOTSTRAP_PUBLIC_KEY_SHA256" ] ||
  slab_bootstrap_fail "embedded release key fingerprint does not match"

if [ -z "$requested_version" ]; then
  channel_base_url=${SLAB_BOOTSTRAP_CHANNEL_BASE_URL:-https://github.com/martin2844/slab-stack/releases/download/channel-$requested_channel}
  channel_file=$SLAB_BOOTSTRAP_TEMPORARY_DIRECTORY/channel.json
  channel_signature=$SLAB_BOOTSTRAP_TEMPORARY_DIRECTORY/channel.json.sig
  slab_bootstrap_download \
    "$channel_base_url/$requested_channel.json" "$channel_file" 30
  slab_bootstrap_download \
    "$channel_base_url/$requested_channel.json.sig" "$channel_signature" 30
  openssl pkeyutl -verify -rawin -pubin -inkey "$public_key" \
    -in "$channel_file" -sigfile "$channel_signature" >/dev/null 2>&1 ||
    slab_bootstrap_fail "channel signature verification failed"
  requested_version=$(slab_bootstrap_json_string "$channel_file" stackVersion)
  channel_manifest_sha256=$(
    slab_bootstrap_json_string "$channel_file" manifestSha256
  )
  printf '%s\n' "$channel_manifest_sha256" |
    grep -Eq '^[a-f0-9]{64}$' ||
    slab_bootstrap_fail "channel manifest checksum is invalid"
fi
slab_bootstrap_validate_version "$requested_version"

asset_name=slab-stack-$requested_version.tar.gz
release_url=$SLAB_BOOTSTRAP_RELEASE_BASE_URL/v$requested_version
archive=$SLAB_BOOTSTRAP_TEMPORARY_DIRECTORY/$asset_name
checksum=$archive.sha256
signature=$checksum.sig

echo "Downloading signed Slab release $requested_version..."
slab_bootstrap_download "$release_url/$asset_name" "$archive"
slab_bootstrap_download "$release_url/$asset_name.sha256" "$checksum"
slab_bootstrap_download "$release_url/$asset_name.sha256.sig" "$signature"

openssl pkeyutl -verify -rawin -pubin -inkey "$public_key" \
  -in "$checksum" -sigfile "$signature" >/dev/null 2>&1 ||
  slab_bootstrap_fail "release signature verification failed"

[ "$(awk 'END { print NR }' "$checksum")" -eq 1 ] ||
  slab_bootstrap_fail "release checksum file must contain exactly one entry"
expected_archive_sha256=$(awk 'NR == 1 { print $1 }' "$checksum")
expected_archive_name=$(awk 'NR == 1 { print $2 }' "$checksum")
printf '%s\n' "$expected_archive_sha256" | grep -Eq '^[a-f0-9]{64}$' ||
  slab_bootstrap_fail "release checksum is malformed"
[ "$expected_archive_name" = "$asset_name" ] ||
  slab_bootstrap_fail "release checksum names an unexpected artifact"
actual_archive_sha256=$(sha256sum "$archive" | awk '{print $1}')
[ "$actual_archive_sha256" = "$expected_archive_sha256" ] ||
  slab_bootstrap_fail "release bundle checksum does not match"

bundle_root=slab-stack-$requested_version
archive_listing=$SLAB_BOOTSTRAP_TEMPORARY_DIRECTORY/archive.list
archive_verbose_listing=$SLAB_BOOTSTRAP_TEMPORARY_DIRECTORY/archive.verbose.list
slab_bootstrap_validate_archive \
  "$archive" "$bundle_root" "$archive_listing" "$archive_verbose_listing"

extracted=$SLAB_BOOTSTRAP_TEMPORARY_DIRECTORY/extracted
mkdir -m 0700 "$extracted"
tar -xzf "$archive" -C "$extracted" --no-same-owner --no-same-permissions
versioned_root=$extracted/$bundle_root
installer=$versioned_root/installer/install.sh
manifest=$versioned_root/releases/v$requested_version.json
if [ ! -f "$installer" ] || [ -L "$installer" ]; then
  slab_bootstrap_fail "verified bundle has no regular installer entry point"
fi
if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
  slab_bootstrap_fail "verified bundle has no matching release manifest"
fi

included_version=$(slab_bootstrap_json_string "$manifest" stackVersion)
[ "$included_version" = "$requested_version" ] ||
  slab_bootstrap_fail "bundle manifest version does not match the release"
if [ -n "$channel_manifest_sha256" ]; then
  actual_manifest_sha256=$(sha256sum "$manifest" | awk '{print $1}')
  [ "$actual_manifest_sha256" = "$channel_manifest_sha256" ] ||
    slab_bootstrap_fail "bundle manifest does not match the selected channel"
fi

echo "Release signature and checksum verified. Starting the versioned installer."
set +e
sh "$installer" --manifest "$manifest" "$@"
installer_status=$?
set -e
exit "$installer_status"
