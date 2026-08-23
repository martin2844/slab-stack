#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
manifest=${1:-}
output_directory=${2:-$ROOT/dist}
PACKAGER_IMAGE=docker.io/library/debian:12.11-slim@sha256:b1a741487078b369e78119849663d7f1a5341ef2768798f7b7406c4240f86aef
archive_temporary=
checksum_temporary=

[ -n "$manifest" ] || {
  echo "Usage: $0 RELEASE_MANIFEST [OUTPUT_DIRECTORY]" >&2
  exit 2
}
case "$manifest" in
  /*) ;;
  *) manifest=$ROOT/$manifest ;;
esac
if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
  echo "Release manifest must be a regular file: $manifest" >&2
  exit 1
fi

for command_name in node jq docker sha256sum mktemp find cp chmod mkdir mv date id; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing release packaging dependency: $command_name" >&2
    exit 1
  }
done

node "$ROOT/scripts/validate-manifest.mjs" "$manifest" >/dev/null
version=$(jq -r '.stackVersion' "$manifest")
channel=$(jq -r '.channel' "$manifest")
case "$channel" in
  candidate | stable) ;;
  *) echo "Only candidate or stable manifests can be packaged." >&2; exit 1 ;;
esac

bundle_name=slab-stack-$version
asset_name=$bundle_name.tar.gz
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/slab-release-package.XXXXXX")
staging_root=$temporary_directory/$bundle_name

cleanup_release_package() {
  [ -z "$archive_temporary" ] || rm -f "$archive_temporary"
  [ -z "$checksum_temporary" ] || rm -f "$checksum_temporary"
  case "$temporary_directory" in
    /tmp/slab-release-package.* | "${TMPDIR:-/tmp}"/slab-release-package.*)
      [ ! -d "$temporary_directory" ] || find "$temporary_directory" -depth -delete
      ;;
  esac
}
trap cleanup_release_package EXIT
trap 'exit 130' HUP INT TERM

mkdir -p "$staging_root/releases" "$staging_root/contracts" "$output_directory"
output_directory=$(CDPATH='' cd -- "$output_directory" && pwd)
cp -R "$ROOT/installer" "$staging_root/installer"
cp -R "$ROOT/templates" "$staging_root/templates"
cp -R "$ROOT/bin" "$staging_root/bin"
cp "$manifest" "$staging_root/releases/v$version.json"
cp "$ROOT/contracts/release-signing-public.pem" "$staging_root/contracts/"
cp "$ROOT/README.md" "$staging_root/README.md"

find "$staging_root" -type d -exec chmod 0755 {} \;
find "$staging_root" -type f -exec chmod 0644 {} \;
chmod 0755 "$staging_root/installer/install.sh" "$staging_root/bin/slabctl"

released_at=$(jq -r '.releasedAt' "$manifest")
source_date_epoch=${SOURCE_DATE_EPOCH:-$(date -u -d "$released_at" +%s)}
archive_temporary=$output_directory/.$asset_name.tmp.$$
archive=$output_directory/$asset_name
checksum_temporary=$output_directory/.$asset_name.sha256.tmp.$$
checksum=$output_directory/$asset_name.sha256

docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges \
  --user "$(id -u):$(id -g)" \
  -e BUNDLE_NAME="$bundle_name" \
  -e SOURCE_DATE_EPOCH="$source_date_epoch" \
  -e ASSET_TEMPORARY=".$asset_name.tmp.$$" \
  -v "$temporary_directory:/input:ro" \
  -v "$output_directory:/output" \
  "$PACKAGER_IMAGE" \
  sh -eu -c 'tar --sort=name --format=ustar --mtime="@$SOURCE_DATE_EPOCH" \
    --owner=0 --group=0 --numeric-owner -C /input \
    -cf - "$BUNDLE_NAME" | gzip -n > "/output/$ASSET_TEMPORARY"'
chmod 0644 "$archive_temporary"
mv "$archive_temporary" "$archive"

archive_sha256=$(sha256sum "$archive" | awk '{print $1}')
printf '%s  %s\n' "$archive_sha256" "$asset_name" > "$checksum_temporary"
chmod 0644 "$checksum_temporary"
mv "$checksum_temporary" "$checksum"
cp "$manifest" "$output_directory/v$version.json"
chmod 0644 "$output_directory/v$version.json"

echo "$archive"
echo "$checksum"
echo "$output_directory/v$version.json"
