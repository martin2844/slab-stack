#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST=${SLAB_STACK_MANIFEST:-$ROOT/releases/v0.1.0-candidate.19.json}
PRIVATE_PORT=${SLAB_STACK_SMOKE_PORT:-39009}
PROJECT_NAME=${SLAB_STACK_SMOKE_PROJECT:-slab-stack-smoke-$$}
FIXTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/slab-stack-smoke.XXXXXX")
PASSWORD=testing-only-stack-admin-password
COOKIES=$FIXTURE_DIR/cookies

compose() {
  docker compose --project-name "$PROJECT_NAME" \
    --env-file "$FIXTURE_DIR/install.env" \
    -f "$FIXTURE_DIR/compose.yml" \
    -f "$FIXTURE_DIR/compose.private.yml" "$@"
}

cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT HUP INT TERM

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing full-stack smoke dependency: $1" >&2
    exit 1
  fi
}

assert_equal() {
  actual=$1
  expected=$2
  label=$3
  if [ "$actual" != "$expected" ]; then
    printf '%s: expected %s, got %s.\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

wait_http() {
  url=$1
  attempts=${2:-60}
  count=0
  until curl -fsS "$url" >/dev/null 2>&1; do
    count=$((count + 1))
    if [ "$count" -ge "$attempts" ]; then
      echo "Timed out waiting for $url" >&2
      return 1
    fi
    sleep 1
  done
}

wait_healthy() {
  attempts=60
  count=0
  while :; do
    pending=0
    for service in slab-api slab-mcp slab-docs slab-email slab-runner slab-agents; do
      container_id=$(compose ps -q "$service")
      status=$(docker inspect "$container_id" --format '{{.State.Health.Status}}')
      [ "$status" = healthy ] || pending=1
    done
    [ "$pending" -eq 0 ] && return 0
    count=$((count + 1))
    if [ "$count" -ge "$attempts" ]; then
      echo "Timed out waiting for healthy stack." >&2
      compose ps >&2
      return 1
    fi
    sleep 1
  done
}

for dependency in curl docker jq node openssl; do
  require "$dependency"
done

. "$ROOT/installer/lib/secrets.sh"
# shellcheck disable=SC1091
. "$ROOT/installer/lib/runtime.sh"
slab_prepare_secrets "$FIXTURE_DIR/secrets"
cp "$ROOT/templates/compose.yml" "$FIXTURE_DIR/compose.yml"
cp "$ROOT/templates/compose.private.yml" "$FIXTURE_DIR/compose.private.yml"

{
  printf 'SLAB_PUBLIC_URL=http://127.0.0.1:%s\n' "$PRIVATE_PORT"
  printf 'SLAB_DOMAIN=\nACME_EMAIL=\n'
  printf 'SLAB_PRIVATE_BIND_IP=127.0.0.1\n'
  printf 'SLAB_PRIVATE_PORT=%s\n' "$PRIVATE_PORT"
  node "$ROOT/scripts/render-image-env.mjs" "$MANIFEST"
} > "$FIXTURE_DIR/install.env"
chmod 0600 "$FIXTURE_DIR/install.env"

compose config --quiet
compose up -d --pull always

wait_http "http://127.0.0.1:$PRIVATE_PORT/health"
ready_before=$(curl -sS -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:$PRIVATE_PORT/ready")
[ "$ready_before" = 503 ]

agents_container=$(compose ps -q slab-agents)
printf '%s\n' "$PASSWORD" |
  docker exec -i "$agents_container" node scripts/admin-bootstrap.mjs >/dev/null
wait_http "http://127.0.0.1:$PRIVATE_PORT/ready"

curl -fsS -c "$COOKIES" \
  -H "Origin: http://127.0.0.1:$PRIVATE_PORT" \
  -H 'Content-Type: application/json' \
  --data "{\"password\":\"$PASSWORD\"}" \
  "http://127.0.0.1:$PRIVATE_PORT/api/auth/login" >/dev/null

setup_payload=$(curl -fsS -b "$COOKIES" \
  -H "Origin: http://127.0.0.1:$PRIVATE_PORT" \
  -X POST "http://127.0.0.1:$PRIVATE_PORT/api/setup/check")
echo "$setup_payload" | jq -e '
  .data.ready == false and
  ([.data.checks[] | select(.service != "codex") | .state] | all(. == "connected")) and
  ([.data.checks[] | select(.service == "codex") | .state] == ["failed"])
' >/dev/null

# Codex accepts API-key credentials without making a model request. This proves
# that the persistent Runner home and auth-aware /runtimes contract work without
# consuming quota or placing the test credential in argv/environment.
printf '%s\n' 'testing-only-codex-api-key' |
  compose exec -T -e CODEX_HOME=/var/lib/slab-runner/codex \
    slab-runner /usr/local/bin/codex login --with-api-key >/dev/null
compose restart slab-runner >/dev/null
wait_healthy
setup_ready=$(curl -fsS -b "$COOKIES" \
  -H "Origin: http://127.0.0.1:$PRIVATE_PORT" \
  -X POST "http://127.0.0.1:$PRIVATE_PORT/api/setup/check" |
  jq -r '.data.ready')
[ "$setup_ready" = true ]

email_url=$(curl -fsS -b "$COOKIES" \
  "http://127.0.0.1:$PRIVATE_PORT/api/integrations/email" |
  jq -r '.data.serviceUrl')
[ "$email_url" = http://slab-email:6981 ]
email_status=$(curl -fsS -b "$COOKIES" \
  -H "Origin: http://127.0.0.1:$PRIVATE_PORT" \
  -X POST "http://127.0.0.1:$PRIVATE_PORT/api/integrations/email/test" |
  jq -r '.data.status')
[ "$email_status" = connected ]

work_container=$(compose ps -q slab-api)
docker exec "$work_container" node -e '
  const fs = require("node:fs");
  const token = fs.readFileSync("/run/secrets/work_api_key", "utf8").trim();
  fetch("http://127.0.0.1:6970/api/projects", {
    method: "POST",
    headers: { "X-API-Key": token, "Content-Type": "application/json" },
    body: JSON.stringify({ key: "SMOKE", name: "Stack smoke" }),
  }).then(async (response) => {
    if (!response.ok) throw new Error(`${response.status} ${await response.text()}`);
  });
'

curl -fsS -b "$COOKIES" \
  -H "Origin: http://127.0.0.1:$PRIVATE_PORT" \
  -H 'Content-Type: application/json' \
  --data '{"project_key":"SMOKE","title":"Verify unified stack persistence","type":"task","priority":"medium","labels":["smoke"]}' \
  "http://127.0.0.1:$PRIVATE_PORT/api/work/issues" >/dev/null
curl -fsS -b "$COOKIES" \
  -H "Origin: http://127.0.0.1:$PRIVATE_PORT" \
  -H 'Content-Type: application/json' \
  --data '{"title":"Unified stack smoke","body":"Created through Slab Agents and Docs MCP.","tags":["smoke"],"author":"Installer QA"}' \
  "http://127.0.0.1:$PRIVATE_PORT/api/docs" >/dev/null

compose restart slab-api slab-mcp slab-docs slab-email slab-runner slab-agents >/dev/null
wait_healthy

for service in slab-api slab-mcp slab-docs slab-email slab-runner slab-agents; do
  container_id=$(compose ps -q "$service")
  slab_assert_non_root_workload "$service" "$container_id"
done

issue_count=$(curl -fsS -b "$COOKIES" \
  "http://127.0.0.1:$PRIVATE_PORT/api/work/issues?project=SMOKE" |
  jq -r '.data | length')
doc_count=$(curl -fsS -b "$COOKIES" \
  "http://127.0.0.1:$PRIVATE_PORT/api/docs" |
  jq -r '.data | length')
assert_equal "$issue_count" 1 "Persisted Work issue count"
assert_equal "$doc_count" 1 "Persisted Docs document count"

published_bindings=$(compose ps --format json |
  jq -r '
    select(.Publishers != null)
    | .Publishers[]?
    | select(.PublishedPort > 0)
    | "\(.URL):\(.PublishedPort)"
  ' |
  sort -u)
assert_equal \
  "$published_bindings" \
  "127.0.0.1:$PRIVATE_PORT" \
  "Published host bindings"

echo "Slab full-stack private smoke passed."
