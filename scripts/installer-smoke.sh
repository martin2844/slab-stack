#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/.tmp"
FIXTURE_DIR=$(mktemp -d "$ROOT/.tmp/slab-installer-smoke.XXXXXX")
INSTALL_DIR=$FIXTURE_DIR/installation
CONFIG_FILE=$FIXTURE_DIR/install.conf
PASSWORD_FILE=$FIXTURE_DIR/admin-password
PRIVATE_PORT=${SLAB_INSTALLER_SMOKE_PORT:-39109}
PROJECT_NAME=${SLAB_INSTALLER_SMOKE_PROJECT:-slab-installer-smoke-$$}
PASSWORD=testing-only-installer-admin-password
SYSTEMCTL_CALLS=$FIXTURE_DIR/systemctl-calls

cat > "$FIXTURE_DIR/systemctl-test" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$SLAB_TEST_SYSTEMCTL_CALLS"
case "$*" in
  "daemon-reload") ;;
  "enable --now var-lib-slab\\x2dupdate\\x2dbridge-requests.mount var-lib-slab\\x2dupdate\\x2dbridge-status.mount") ;;
  "enable --now slab-update-bridge-prepare.service") ;;
  "enable --now slab.service slab-update-bridge.path slab-update-bridge-sweep.timer")
    SLABCTL_TEST_ROOT=$SLAB_MANAGEMENT_HOST_ROOT \
      "$SLAB_MANAGEMENT_HOST_ROOT/usr/local/bin/slabctl" stack start >/dev/null
    ;;
  *) echo "unexpected systemctl command: $*" >&2; exit 91 ;;
esac
EOF
chmod 0755 "$FIXTURE_DIR/systemctl-test"

compose() {
  docker compose --project-name "$PROJECT_NAME" \
    --env-file "$INSTALL_DIR/config/install.env" \
    -f "$INSTALL_DIR/compose.yml" \
    -f "$INSTALL_DIR/compose.private.yml" "$@"
}

cleanup() {
  if [ -f "$INSTALL_DIR/config/install.env" ]; then
    compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT HUP INT TERM

printf '%s\n' "$PASSWORD" > "$PASSWORD_FILE"
chmod 0600 "$PASSWORD_FILE"
cat > "$CONFIG_FILE" <<EOF
SLAB_INSTALL_DIRECTORY=$INSTALL_DIR
SLAB_ACCESS_MODE=private
SLAB_PRIVATE_BIND_IP=127.0.0.1
SLAB_PRIVATE_PORT=$PRIVATE_PORT
SLAB_COMPOSE_PROJECT_NAME=$PROJECT_NAME
SLAB_ADMIN_PASSWORD_FILE=$PASSWORD_FILE
EOF
chmod 0600 "$CONFIG_FILE"

SLAB_PREFLIGHT_UID=0 \
SLAB_CONFIG_OWNER_UID=$(id -u) \
SLAB_CONFIG_TRUST_ROOT=$FIXTURE_DIR \
SLAB_INSTALL_OWNER_UID=$(id -u) \
SLAB_INSTALL_TRUST_ROOT=$FIXTURE_DIR \
SLAB_LOCK_OWNER_UID=$(id -u) \
SLAB_LOCK_ROOT=$FIXTURE_DIR/locks \
SLAB_LOCK_TRUST_ROOT=$FIXTURE_DIR \
SLAB_HOST_LOCK_FILE=$FIXTURE_DIR/host-bootstrap.lock \
SLAB_MANAGEMENT_HOST_ROOT=$FIXTURE_DIR/host \
SLAB_MANAGEMENT_OWNER_UID=$(id -u) \
SLAB_MANAGEMENT_TRUST_ROOT=$FIXTURE_DIR \
SLAB_SYSTEMCTL_BIN=$FIXTURE_DIR/systemctl-test \
SLAB_TEST_SYSTEMCTL_CALLS=$SYSTEMCTL_CALLS \
  "$ROOT/installer/install.sh" --non-interactive --config "$CONFIG_FILE"

curl -fsS "http://127.0.0.1:$PRIVATE_PORT/ready" >/dev/null
first_secret_hash=$(sha256sum "$INSTALL_DIR/secrets/session-secret" | awk '{print $1}')
installed_slabctl=$FIXTURE_DIR/host/usr/local/bin/slabctl
if SLABCTL_TEST_ROOT=$FIXTURE_DIR/host "$installed_slabctl" codex status \
  >/dev/null 2>&1
then
  echo "Fresh installer smoke unexpectedly started with Codex authenticated." >&2
  exit 1
fi
printf '%s\n' 'testing-only-installer-codex-key' |
  SLABCTL_TEST_ROOT=$FIXTURE_DIR/host "$installed_slabctl" \
    codex login --api-key >/dev/null
SLABCTL_TEST_ROOT=$FIXTURE_DIR/host "$installed_slabctl" codex status \
  >/dev/null

# A rerun reconciles the same installation without requiring or rotating the
# one-time bootstrap credential.
rm -f "$PASSWORD_FILE"
SLAB_PREFLIGHT_UID=0 \
SLAB_CONFIG_OWNER_UID=$(id -u) \
SLAB_CONFIG_TRUST_ROOT=$FIXTURE_DIR \
SLAB_INSTALL_OWNER_UID=$(id -u) \
SLAB_INSTALL_TRUST_ROOT=$FIXTURE_DIR \
SLAB_LOCK_OWNER_UID=$(id -u) \
SLAB_LOCK_ROOT=$FIXTURE_DIR/locks \
SLAB_LOCK_TRUST_ROOT=$FIXTURE_DIR \
SLAB_HOST_LOCK_FILE=$FIXTURE_DIR/host-bootstrap.lock \
SLAB_MANAGEMENT_HOST_ROOT=$FIXTURE_DIR/host \
SLAB_MANAGEMENT_OWNER_UID=$(id -u) \
SLAB_MANAGEMENT_TRUST_ROOT=$FIXTURE_DIR \
SLAB_SYSTEMCTL_BIN=$FIXTURE_DIR/systemctl-test \
SLAB_TEST_SYSTEMCTL_CALLS=$SYSTEMCTL_CALLS \
  "$ROOT/installer/install.sh" --non-interactive --config "$CONFIG_FILE"

second_secret_hash=$(sha256sum "$INSTALL_DIR/secrets/session-secret" | awk '{print $1}')
[ "$first_secret_hash" = "$second_secret_hash" ]
test "$(grep -c '^enable --now slab.service slab-update-bridge.path slab-update-bridge-sweep.timer$' "$SYSTEMCTL_CALLS")" -eq 2
test "$(grep -c '^enable --now slab-update-bridge-prepare.service$' "$SYSTEMCTL_CALLS")" -eq 2
test "$(grep -c '^enable --now var-lib-slab\\x2dupdate\\x2dbridge-requests.mount var-lib-slab\\x2dupdate\\x2dbridge-status.mount$' "$SYSTEMCTL_CALLS")" -eq 2

cookies=$FIXTURE_DIR/cookies
curl -fsS -c "$cookies" \
  -H "Origin: http://127.0.0.1:$PRIVATE_PORT" \
  -H 'Content-Type: application/json' \
  --data "{\"password\":\"$PASSWORD\"}" \
  "http://127.0.0.1:$PRIVATE_PORT/api/auth/login" >/dev/null

jq -e '
  .status == "READY" and
  .phase == "admin_configured" and
  (.completedSteps | index("lifecycle_configured") != null) and
  (.completedSteps | index("admin_configured") != null) and
  .lastKnownGood.status == "READY"
' \
  "$INSTALL_DIR/config/install-state.json" >/dev/null

echo "Slab versioned installer smoke passed."
