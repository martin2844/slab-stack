#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
manifest=${1:-}
output_directory=${2:-$ROOT/dist}

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

for command_name in node jq tar gzip sha256sum mktemp find cp chmod mkdir mv date; do
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
  case "$temporary_directory" in
    /tmp/slab-release-package.* | "${TMPDIR:-/tmp}"/slab-release-package.*)
      [ ! -d "$temporary_directory" ] || find "$temporary_directory" -depth -delete
      ;;
  esac
}
trap cleanup_release_package EXIT HUP INT TERM

mkdir -p "$staging_root/releases" "$output_directory"
cp -R "$ROOT/installer" "$staging_root/installer"
cp -R "$ROOT/templates" "$staging_root/templates"
cp -R "$ROOT/bin" "$staging_root/bin"
cp "$manifest" "$staging_root/releases/v$version.json"
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

tar --sort=name --format=ustar --mtime="@$source_date_epoch" \
  --owner=0 --group=0 --numeric-owner -C "$temporary_directory" \
  -cf - "$bundle_name" | gzip -n > "$archive_temporary"
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
