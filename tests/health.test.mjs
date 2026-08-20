import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helper = path.join(root, "installer", "lib", "health.sh");

function run(script, environment = {}) {
  return spawnSync("sh", ["-c", `. "$1"; ${script}`, "health", helper], {
    encoding: "utf8",
    env: { ...process.env, ...environment },
  });
}

test("waits until every long-running service is healthy", () => {
  const result = run(`
    slab_service_health_status() { echo healthy; }
    slab_wait_for_healthy_stack
  `);
  assert.equal(result.status, 0, result.stderr);
});

test("domain mode also requires the Caddy process to be running", () => {
  const healthy = run(
    `
      slab_service_health_status() { echo healthy; }
      slab_service_runtime_status() { echo running; }
      slab_wait_for_healthy_stack
    `,
    { SLAB_ACCESS_MODE: "domain" },
  );
  assert.equal(healthy.status, 0, healthy.stderr);

  const stopped = run(
    `
      slab_service_health_status() { echo healthy; }
      slab_service_runtime_status() { echo exited; }
      slab_wait_for_healthy_stack
    `,
    {
      SLAB_ACCESS_MODE: "domain",
      SLAB_HEALTH_ATTEMPTS: "1",
      SLAB_HEALTH_INTERVAL_SECONDS: "0",
    },
  );
  assert.notEqual(stopped.status, 0);
  assert.match(stopped.stderr, /caddy/);
});

test("reports bounded health timeout with pending services", () => {
  const result = run(
    `slab_service_health_status() { echo starting; }; slab_wait_for_healthy_stack`,
    { SLAB_HEALTH_ATTEMPTS: "1", SLAB_HEALTH_INTERVAL_SECONDS: "0" },
  );
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Timed out waiting for healthy services/);
  assert.match(result.stderr, /slab-agents/);
});

test("preserves an existing administrator and never invokes bootstrap", () => {
  const result = run(`
    slab_agents_http_status() { echo 200; }
    docker() { echo unexpected-docker-call >&2; return 99; }
    slab_bootstrap_admin_if_needed test-only-password
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /keeping the current password/);
  assert.doesNotMatch(result.stderr, /unexpected-docker-call/);
});

test("rejects unexpected readiness without invoking administrator bootstrap", () => {
  const result = run(`
    slab_agents_http_status() { echo 500; }
    docker() { echo unexpected-docker-call >&2; return 99; }
    slab_bootstrap_admin_if_needed test-only-password
  `);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /unexpected readiness status: 500/);
  assert.doesNotMatch(result.stderr, /unexpected-docker-call/);
});

test("pipes a new administrator password and reaches readiness", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-bootstrap-"));
  const marker = path.join(directory, "bootstrapped");
  try {
    const result = run(
      `
        slab_agents_http_status() {
          if [ -f "$SLAB_TEST_MARKER" ]; then echo 200; else echo 503; fi
        }
        slab_compose_service_container() { echo agents-container; }
        docker() {
          [ "$1" = exec ] || return 98
          shift
          if [ "$1" = -i ]; then
            IFS= read -r supplied_password
            [ "$supplied_password" = test-only-password ] || return 97
            : > "$SLAB_TEST_MARKER"
            return 0
          fi
          return 96
        }
        slab_bootstrap_admin_if_needed test-only-password
      `,
      {
        SLAB_TEST_MARKER: marker,
        SLAB_HEALTH_ATTEMPTS: "1",
        SLAB_HEALTH_INTERVAL_SECONDS: "0",
      },
    );
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.existsSync(marker), true);
    assert.doesNotMatch(result.stdout + result.stderr, /test-only-password/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
