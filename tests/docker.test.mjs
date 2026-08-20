import assert from "node:assert/strict";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helper = path.join(root, "installer", "lib", "docker.sh");

function run(script) {
  return spawnSync("sh", ["-c", `. "$1"; ${script}`, "docker", helper], {
    encoding: "utf8",
  });
}

test("bounded service diagnostics redact credential-shaped content", () => {
  const result = run(`
    slab_compose() {
      printf '%s\n' \
        'Authorization: Bearer should-not-escape' \
        'RUNNER_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
        '{"token":"opaque-secret-value","apiKey":"opaque-key-value"}' \
        'ordinary diagnostic'
    }
    slab_print_bounded_service_logs slab-agents
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stderr, /ordinary diagnostic/);
  assert.match(result.stderr, /\[REDACTED\]/);
  assert.doesNotMatch(result.stderr, /should-not-escape/);
  assert.doesNotMatch(result.stderr, /0123456789abcdef/);
  assert.doesNotMatch(result.stderr, /opaque-secret-value|opaque-key-value/);
});

test("service diagnostics are capped even when the source is large", () => {
  const result = run(`
    slab_compose() {
      awk 'BEGIN { for (i = 0; i < 20000; i++) printf "x" }'
    }
    slab_print_bounded_service_logs slab-agents
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(Buffer.byteLength(result.stderr) <= 8300, result.stderr.length);
});

test("terminal migration failure is preferred over a merely pending service", () => {
  const result = run(`
    slab_compose_service_container() {
      case "$1" in
        slab-api) printf '%s\\n' api-container ;;
        work-migrate) printf '%s\\n' migration-container ;;
      esac
    }
    docker() {
      case "$2" in
        api-container) printf '%s\\n' 'created ' ;;
        migration-container) printf '%s\\n' 'exited 1' ;;
      esac
    }
    slab_detect_first_failing_service
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), "work-migrate");
});
