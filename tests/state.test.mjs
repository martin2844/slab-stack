import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helper = path.join(root, "installer", "lib", "state.sh");

function write(directory, phase, status, attempt = "2026-08-20T10:00:00Z") {
  return spawnSync(
    "sh",
    [
      "-c",
      '. "$1"; slab_write_install_state "$2" 0.1.0-candidate.2 private http://127.0.0.1:3009 slab "$3" "$4" "$5"',
      "state",
      helper,
      directory,
      attempt,
      phase,
      status,
    ],
    { encoding: "utf8" },
  );
}

test("persists atomic non-secret progress through final readiness", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-state-"));
  fs.mkdirSync(path.join(directory, "config"));
  try {
    const intermediate = write(directory, "services_healthy", "INSTALLING");
    assert.equal(intermediate.status, 0, intermediate.stderr);
    const current = JSON.parse(
      fs.readFileSync(path.join(directory, "config", "install-state.json"), "utf8"),
    );
    assert.equal(current.status, "INSTALLING");
    assert.equal(current.phase, "services_healthy");
    assert.deepEqual(current.completedSteps, [
      "rendered",
      "compose_validated",
      "compose_reconciled",
      "services_healthy",
    ]);
    assert.equal(JSON.stringify(current).includes("password"), false);

    const final = write(directory, "admin_configured", "READY_NO_RUNTIME");
    assert.equal(final.status, 0, final.stderr);
    const completed = JSON.parse(
      fs.readFileSync(path.join(directory, "config", "install-state.json"), "utf8"),
    );
    assert.equal(completed.status, "READY_NO_RUNTIME");
    assert.equal(completed.completedSteps.at(-1), "admin_configured");
    assert.equal(fs.statSync(path.join(directory, "config", "install-state.json")).mode & 0o777, 0o600);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("a failed rerun retains the previous successful state as last-known-good", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-state-good-"));
  fs.mkdirSync(path.join(directory, "config"));
  try {
    assert.equal(write(directory, "admin_configured", "READY_NO_RUNTIME").status, 0);
    assert.equal(
      write(directory, "compose_reconciled", "INSTALLING", "2026-08-20T11:00:00Z").status,
      0,
    );
    assert.equal(
      write(directory, "compose_reconciled", "FAILED", "2026-08-20T11:00:00Z").status,
      0,
    );
    const failed = JSON.parse(
      fs.readFileSync(path.join(directory, "config", "install-state.json"), "utf8"),
    );
    assert.equal(failed.status, "FAILED");
    assert.equal(failed.lastKnownGood.status, "READY_NO_RUNTIME");
    assert.equal(failed.lastKnownGood.projectName, "slab");
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
