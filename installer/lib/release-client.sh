#!/bin/sh
# shellcheck disable=SC2015,SC2034

SLAB_RELEASE_PUBLIC_KEY_SHA256=2865983ef11b8070415642e0ebdcde17468f48392ee517a63f991f29e80c5293
SLAB_RELEASE_TEMPORARY_DIRECTORY=
SLAB_RELEASE_VERSION=
SLAB_RELEASE_BUNDLE_ROOT=
SLAB_RELEASE_MANIFEST=
SLAB_RELEASE_CHANNEL_FILE=
SLAB_RELEASE_MANIFEST_SHA256=

slabctl_release_download() {
  source_url=$1
  destination=$2
  maximum_seconds=${3:-${SLAB_RELEASE_DOWNLOAD_MAX_SECONDS:-300}}
  case "$source_url" in
    https://*)
      curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --location --fail --silent --show-error \
        --connect-timeout 10 --max-time "$maximum_seconds" \
        --output "$destination" "$source_url"
      ;;
    http://* | file://*)
      [ "${SLAB_RELEASE_ALLOW_INSECURE_TEST_SOURCE:-0}" = 1 ] || {
        slabctl_error "release downloads require HTTPS"
        return 1
      }
      protocol=${source_url%%:*}
      curl --proto "=$protocol" --proto-redir "=$protocol" \
        --location --fail --silent --show-error \
        --connect-timeout 10 --max-time "$maximum_seconds" \
        --output "$destination" "$source_url"
      ;;
    *) slabctl_error "unsupported release URL"; return 1 ;;
  esac
}

slabctl_release_validate_version() {
  printf '%s\n' "$1" |
    grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$' || {
      slabctl_error "invalid release version: $1"
      return 1
    }
}

slabctl_release_validate_public_key() {
  public_key=$1
  slabctl_validate_managed_file "$public_key" || return 1
  public_key_der=$SLAB_RELEASE_TEMPORARY_DIRECTORY/release-signing-public.der
  openssl pkey -pubin -in "$public_key" -outform DER -out "$public_key_der" \
    >/dev/null 2>&1 || {
      slabctl_error "installed release signing key is invalid"
      return 1
    }
  fingerprint=$(sha256sum "$public_key_der" | awk '{print $1}') || return 1
  [ "$fingerprint" = "$SLAB_RELEASE_PUBLIC_KEY_SHA256" ] || {
    slabctl_error "installed release signing key fingerprint does not match"
    return 1
  }
}

slabctl_release_validate_channel() {
  channel_file=$1
  requested_channel=$2
  jq -e --arg channel "$requested_channel" '
    .schemaVersion == 1 and
    .channel == $channel and
    (.stackVersion | type == "string" and
      test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$")) and
    (.manifestUrl | type == "string" and test("^https://")) and
    (.manifestSha256 | type == "string" and test("^[a-f0-9]{64}$"))
  ' "$channel_file" >/dev/null 2>&1 || {
    slabctl_error "signed channel metadata is invalid"
    return 1
  }
}

slabctl_release_validate_requested_channel() {
  requested_channel=$1
  case "$requested_channel" in
    stable | candidate) ;;
    drill)
      [ "${SLAB_RELEASE_ALLOW_DRILL_CHANNEL:-0}" = 1 ] || {
        slabctl_error "the drill release channel is restricted to explicit disposable-host tests"
        return 1
      }
      ;;
    *) slabctl_error "unsupported release channel: $requested_channel"; return 1 ;;
  esac
}

slabctl_release_validate_archive() {
  archive=$1
  expected_root=$2
  listing=$SLAB_RELEASE_TEMPORARY_DIRECTORY/archive.list
  verbose_listing=$SLAB_RELEASE_TEMPORARY_DIRECTORY/archive.verbose.list
  tar -tzf "$archive" > "$listing" || return 1
  [ -s "$listing" ] || {
    slabctl_error "release bundle is empty"
    return 1
  }
  while IFS= read -r member; do
    case "$member" in
      "$expected_root" | "$expected_root/" | "$expected_root/"*) ;;
      *) slabctl_error "release bundle contains a path outside its root"; return 1 ;;
    esac
    case "/$member/" in
      */../* | */./*) slabctl_error "release bundle contains an unsafe path"; return 1 ;;
    esac
  done < "$listing"
  tar -tvzf "$archive" > "$verbose_listing" || return 1
  while IFS= read -r entry; do
    entry_type=${entry%"${entry#?}"}
    case "$entry_type" in
      - | d) ;;
      *) slabctl_error "release bundle contains a non-regular entry"; return 1 ;;
    esac
  done < "$verbose_listing"
}

slabctl_release_cleanup() {
  case "$SLAB_RELEASE_TEMPORARY_DIRECTORY" in
    /tmp/slab-release.*)
      [ ! -d "$SLAB_RELEASE_TEMPORARY_DIRECTORY" ] ||
        find "$SLAB_RELEASE_TEMPORARY_DIRECTORY" -depth -delete
      ;;
  esac
  SLAB_RELEASE_TEMPORARY_DIRECTORY=
  SLAB_RELEASE_VERSION=
  SLAB_RELEASE_BUNDLE_ROOT=
  SLAB_RELEASE_MANIFEST=
  SLAB_RELEASE_CHANNEL_FILE=
  SLAB_RELEASE_MANIFEST_SHA256=
}

slabctl_release_prepare_channel() {
  requested_channel=$1
  public_key=$2
  slabctl_release_validate_requested_channel "$requested_channel" || return 1
  slabctl_release_cleanup
  SLAB_RELEASE_TEMPORARY_DIRECTORY=$(mktemp -d /tmp/slab-release.XXXXXX) || return 1
  chmod 0700 "$SLAB_RELEASE_TEMPORARY_DIRECTORY"
  slabctl_release_validate_public_key "$public_key" || return 1

  channel_base=${SLAB_RELEASE_CHANNEL_BASE_URL:-https://github.com/martin2844/slab-stack/releases/download/channel-$requested_channel}
  channel_file=$SLAB_RELEASE_TEMPORARY_DIRECTORY/$requested_channel.json
  channel_signature=$channel_file.sig
  slabctl_release_download "$channel_base/$requested_channel.json" \
    "$channel_file" "${SLAB_RELEASE_CHANNEL_MAX_SECONDS:-30}" || return 1
  slabctl_release_download "$channel_base/$requested_channel.json.sig" \
    "$channel_signature" "${SLAB_RELEASE_CHANNEL_MAX_SECONDS:-30}" || return 1
  openssl pkeyutl -verify -rawin -pubin -inkey "$public_key" \
    -in "$channel_file" -sigfile "$channel_signature" >/dev/null 2>&1 || {
      slabctl_error "channel signature verification failed"
      return 1
    }
  slabctl_release_validate_channel "$channel_file" "$requested_channel" || return 1

  version=$(jq -er '.stackVersion' "$channel_file") || return 1
  slabctl_release_validate_version "$version" || return 1
  expected_manifest_sha256=$(jq -er '.manifestSha256' "$channel_file") || return 1
  SLAB_RELEASE_VERSION=$version
  SLAB_RELEASE_CHANNEL_FILE=$channel_file
  SLAB_RELEASE_MANIFEST_SHA256=$expected_manifest_sha256
}

slabctl_release_prepare() {
  requested_channel=$1
  public_key=$2
  slabctl_release_prepare_channel "$requested_channel" "$public_key" || return 1
  version=$SLAB_RELEASE_VERSION
  expected_manifest_sha256=$SLAB_RELEASE_MANIFEST_SHA256
  release_base=${SLAB_RELEASE_BUNDLE_BASE_URL:-https://github.com/martin2844/slab-stack/releases/download}
  asset_name=slab-stack-$version.tar.gz
  version_base=$release_base/v$version
  archive=$SLAB_RELEASE_TEMPORARY_DIRECTORY/$asset_name
  checksum=$archive.sha256
  signature=$checksum.sig
  slabctl_release_download "$version_base/$asset_name" "$archive" || return 1
  slabctl_release_download "$version_base/$asset_name.sha256" "$checksum" || return 1
  slabctl_release_download "$version_base/$asset_name.sha256.sig" "$signature" || return 1
  openssl pkeyutl -verify -rawin -pubin -inkey "$public_key" \
    -in "$checksum" -sigfile "$signature" >/dev/null 2>&1 || {
      slabctl_error "release signature verification failed"
      return 1
    }
  [ "$(awk 'END { print NR }' "$checksum")" -eq 1 ] || {
    slabctl_error "release checksum file must contain exactly one entry"
    return 1
  }
  expected_archive_sha256=$(awk 'NR == 1 { print $1 }' "$checksum")
  expected_archive_name=$(awk 'NR == 1 { print $2 }' "$checksum")
  printf '%s\n' "$expected_archive_sha256" | grep -Eq '^[a-f0-9]{64}$' || {
    slabctl_error "release checksum is malformed"
    return 1
  }
  [ "$expected_archive_name" = "$asset_name" ] || {
    slabctl_error "release checksum names an unexpected artifact"
    return 1
  }
  actual_archive_sha256=$(sha256sum "$archive" | awk '{print $1}') || return 1
  [ "$actual_archive_sha256" = "$expected_archive_sha256" ] || {
    slabctl_error "release bundle checksum does not match"
    return 1
  }

  bundle_root=slab-stack-$version
  slabctl_release_validate_archive "$archive" "$bundle_root" || return 1
  extracted=$SLAB_RELEASE_TEMPORARY_DIRECTORY/extracted
  mkdir -m 0700 "$extracted"
  tar -xzf "$archive" -C "$extracted" --no-same-owner --no-same-permissions || return 1
  versioned_root=$extracted/$bundle_root
  manifest=$versioned_root/releases/v$version.json
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || {
    slabctl_error "verified bundle has no matching release manifest"
    return 1
  }
  [ "$(jq -er '.stackVersion' "$manifest")" = "$version" ] || {
    slabctl_error "bundle manifest version does not match"
    return 1
  }
  actual_manifest_sha256=$(sha256sum "$manifest" | awk '{print $1}') || return 1
  [ "$actual_manifest_sha256" = "$expected_manifest_sha256" ] || {
    slabctl_error "bundle manifest does not match the signed channel"
    return 1
  }
  SLAB_RELEASE_BUNDLE_ROOT=$versioned_root
  SLAB_RELEASE_MANIFEST=$manifest
}
