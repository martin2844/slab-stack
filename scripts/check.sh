#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURE_DIR="$ROOT/.tmp/check"

cleanup() {
  rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT HUP INT TERM

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required check dependency: $1" >&2
    exit 1
  fi
}

require jq
require docker
require node

mkdir -p "$FIXTURE_DIR/secrets"
for secret in work-api-key docs-api-key runner-token email-admin-key email-master-key session-secret; do
  printf 'test-only-secret\n' > "$FIXTURE_DIR/secrets/$secret"
done

cp "$ROOT/templates/compose.yml" "$FIXTURE_DIR/compose.yml"
cp "$ROOT/templates/compose.domain.yml" "$FIXTURE_DIR/compose.domain.yml"
cp "$ROOT/templates/compose.private.yml" "$FIXTURE_DIR/compose.private.yml"
cp "$ROOT/templates/Caddyfile.domain" "$FIXTURE_DIR/Caddyfile"
cp "$ROOT/templates/install.env.example" "$FIXTURE_DIR/install.env"

jq -e '.schemaVersion == 1 and .channel == "development"' \
  "$ROOT/releases/example-manifest.json" >/dev/null
node "$ROOT/scripts/validate-manifest.mjs" \
  "$ROOT/releases/example-manifest.json" >/dev/null

(
  cd "$FIXTURE_DIR"
  docker compose --env-file install.env -f compose.yml -f compose.domain.yml config --quiet
  docker compose --env-file install.env -f compose.yml -f compose.private.yml config --quiet
)

if grep -R -E '(Bearer |sk-[A-Za-z0-9]|password=|api[_-]?key=)' \
  "$ROOT/templates" "$ROOT/releases" >/dev/null 2>&1; then
  echo "Potential plaintext secret found in release templates." >&2
  exit 1
fi

if grep -E '^[[:space:]]+-[[:space:]]+"?([0-9.]+:)?(6969|6970|6980|6981|6990):' \
  "$ROOT/templates/compose.yml" >/dev/null 2>&1; then
  echo "A backend service publishes a host port." >&2
  exit 1
fi

for image_var in SLAB_AGENTS_IMAGE SLAB_WORK_IMAGE SLAB_DOCS_IMAGE SLAB_EMAIL_IMAGE SLAB_RUNNER_IMAGE; do
  if ! grep -q "^${image_var}=.*@sha256:" "$ROOT/templates/install.env.example"; then
    echo "$image_var is not digest pinned in the environment template." >&2
    exit 1
  fi
done

sh -n "$ROOT/scripts/check.sh"
node --check "$ROOT/scripts/validate-manifest.mjs"

echo "Slab stack contracts are valid."
