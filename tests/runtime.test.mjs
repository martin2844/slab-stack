import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helper = path.join(root, "installer", "lib", "runtime.sh");

function inspect(processTable) {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-runtime-"),
  );
  const docker = path.join(temporaryDirectory, "docker");
  fs.writeFileSync(
    docker,
    `#!/bin/sh\nif [ "$1" = top ]; then\n  printf '%s\\n' '${processTable}'\n  exit 0\nfi\nexit 1\n`,
    { mode: 0o755 },
  );
  try {
    return spawnSync(
      "sh",
      [
        "-c",
        '. "$1"; slab_assert_non_root_workload slab-api container-id',
        "runtime-test",
        helper,
      ],
      {
        encoding: "utf8",
        env: { ...process.env, PATH: `${temporaryDirectory}:${process.env.PATH}` },
      },
    );
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

function failInspection(message) {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-runtime-failure-"),
  );
  const docker = path.join(temporaryDirectory, "docker");
  fs.writeFileSync(
    docker,
    `#!/bin/sh\nprintf '%s\\n' '${message}' >&2\nexit 1\n`,
    { mode: 0o755 },
  );
  try {
    return spawnSync(
      "sh",
      [
        "-c",
        '. "$1"; slab_assert_non_root_workload slab-api container-id',
        "runtime-test",
        helper,
      ],
      {
        encoding: "utf8",
        env: { ...process.env, PATH: `${temporaryDirectory}:${process.env.PATH}` },
      },
    );
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

test("accepts a non-root workload behind a root Docker init supervisor", () => {
  const result = inspect(
    "PID USER COMMAND\n101 root docker-init\n102 1000 node",
  );
  assert.equal(result.status, 0, result.stderr);
});

test("rejects a root workload even when Docker init is present", () => {
  const result = inspect(
    "PID USER COMMAND\n101 root docker-init\n102 root node",
  );
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /workload process node is running as root/);
});

test("accepts an image whose PID 1 workload is already non-root", () => {
  const result = inspect("PID USER COMMAND\n101 10001 node");
  assert.equal(result.status, 0, result.stderr);
});

test("rejects an init supervisor with no workload", () => {
  const result = inspect("PID USER COMMAND\n101 root docker-init");
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /no workload process/);
});

test("rejects numeric UID 0 and mixed-privilege workloads", () => {
  const result = inspect(
    "PID USER COMMAND\n101 root docker-init\n102 1000 node\n103 0 helper",
  );
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /workload process helper is running as root/);
});

test("reports Docker process inspection failures", () => {
  const result = failInspection("daemon unavailable");
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Could not inspect slab-api processes/);
  assert.match(result.stderr, /daemon unavailable/);
});
