#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/slab-honcho-smoke.XXXXXX")
PROJECT_NAME=slab-honcho-smoke-$$

cleanup() {
  docker compose \
    --project-name "$PROJECT_NAME" \
    --env-file "$FIXTURE_DIR/install.env" \
    -f "$FIXTURE_DIR/compose.yml" \
    --profile memory \
    down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$FIXTURE_DIR/secrets"
for secret in \
  work-api-key \
  docs-api-key \
  runner-token \
  email-admin-key \
  email-master-key \
  session-secret \
  honcho-api-key
do
  printf '%s\n' test-only-secret > "$FIXTURE_DIR/secrets/$secret"
done
printf '%s\n' test-only-openai-key > \
  "$FIXTURE_DIR/secrets/honcho-openai-api-key"
printf '%s\n' test-only-database-password > \
  "$FIXTURE_DIR/secrets/honcho-db-password"
chmod 0700 "$FIXTURE_DIR/secrets"
# Compose file-backed secrets are bind mounts. The directory remains
# root-private while files must be readable by unprivileged container users.
chmod 0444 "$FIXTURE_DIR"/secrets/*

cp "$ROOT/templates/compose.yml" "$FIXTURE_DIR/compose.yml"
cp "$ROOT/templates/install.env.example" "$FIXTURE_DIR/install.env"

compose() {
  docker compose \
    --project-name "$PROJECT_NAME" \
    --env-file "$FIXTURE_DIR/install.env" \
    -f "$FIXTURE_DIR/compose.yml" \
    --profile memory \
    "$@"
}

if ! compose up -d --wait --wait-timeout 180 \
  honcho-database honcho-redis honcho-api honcho-deriver; then
  compose ps >&2 || true
  compose logs --tail 200 honcho-api honcho-deriver >&2 || true
  exit 1
fi

health_response=$(compose exec -T honcho-api \
  /app/.venv/bin/python -c \
  "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).read().decode())")

printf '%s\n' "$health_response"
printf '%s\n' "$health_response" | jq -e '.status == "ok"' >/dev/null

contract_response=$(compose exec -T honcho-api /app/.venv/bin/python - <<'PY'
import json
import urllib.request

base_url = "http://127.0.0.1:8000/v3"

def post(path, body):
    request = urllib.request.Request(
        base_url + path,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    return json.loads(urllib.request.urlopen(request, timeout=3).read())

workspace = post("/workspaces", {"id": "slab-smoke"})
peer = post(
    "/workspaces/slab-smoke/peers",
    {"id": "operator", "metadata": {"source": "slab-stack-smoke"}},
)
print(json.dumps({"workspaceId": workspace["id"], "peerId": peer["id"]}))
PY
)
printf '%s\n' "$contract_response"
printf '%s\n' "$contract_response" | jq -e \
  '.workspaceId == "slab-smoke" and .peerId == "operator"' >/dev/null
echo "Honcho self-hosted profile reached health."
