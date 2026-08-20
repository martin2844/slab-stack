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
  chmod 0444 "$FIXTURE_DIR/secrets/$secret"
done
chmod 0700 "$FIXTURE_DIR/secrets"

cp "$ROOT/templates/compose.yml" "$FIXTURE_DIR/compose.yml"
cp "$ROOT/templates/compose.domain.yml" "$FIXTURE_DIR/compose.domain.yml"
cp "$ROOT/templates/compose.private.yml" "$FIXTURE_DIR/compose.private.yml"
cp "$ROOT/templates/Caddyfile.domain" "$FIXTURE_DIR/Caddyfile"
cp "$ROOT/templates/install.env.example" "$FIXTURE_DIR/install.env"

jq -e '.schemaVersion == 1 and .channel == "development"' \
  "$ROOT/releases/example-manifest.json" >/dev/null

for manifest in "$ROOT"/releases/*.json; do
  node "$ROOT/scripts/validate-manifest.mjs" "$manifest" >/dev/null
done

node "$ROOT/scripts/render-image-env.mjs" \
  "$ROOT/releases/v0.1.0-candidate.2.json" >/dev/null

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

for migration_service in work-migrate docs-migrate email-migrate; do
  if ! grep -q "^  ${migration_service}:" "$ROOT/templates/compose.yml"; then
    echo "Missing one-shot migration service: $migration_service" >&2
    exit 1
  fi
done

migration_uid_guards=$(grep -F -c 'test \"$$(id -u)\" -ne 0' \
  "$ROOT/templates/compose.yml")
if [ "$migration_uid_guards" -ne 3 ]; then
  echo "Every migration service must reject root execution." >&2
  exit 1
fi

for readiness_port in 6969 6970 6980 6981; do
  if ! grep -q "127.0.0.1:${readiness_port}/ready" "$ROOT/templates/compose.yml"; then
    echo "Service on port $readiness_port does not use schema readiness." >&2
    exit 1
  fi
done

sh -n "$ROOT/scripts/check.sh"
sh -n "$ROOT/scripts/full-stack-smoke.sh"
sh -n "$ROOT/installer/lib/preflight.sh"
sh -n "$ROOT/installer/lib/prompts.sh"
sh -n "$ROOT/installer/lib/render.sh"
sh -n "$ROOT/installer/lib/secrets.sh"
node --check "$ROOT/scripts/validate-manifest.mjs"
node --check "$ROOT/scripts/render-image-env.mjs"

echo "Slab stack contracts are valid."
