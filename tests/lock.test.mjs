import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const prompts = path.join(root, "installer", "lib", "prompts.sh");
const lock = path.join(root, "installer", "lib", "lock.sh");

test("only one installer can hold the lock for an installation directory", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-lock-"));
  const lockRoot = path.join(directory, "locks");
  const marker = path.join(directory, "locked");
  const environment = {
    ...process.env,
    SLAB_LOCK_ROOT: lockRoot,
    SLAB_LOCK_TRUST_ROOT: directory,
    SLAB_LOCK_OWNER_UID: String(process.getuid()),
  };
  const first = spawn(
    "sh",
    [
      "-c",
      '. "$1"; . "$2"; slab_acquire_install_lock /opt/slab; : > "$3"; sleep 5',
      "lock",
      prompts,
      lock,
      marker,
    ],
    { encoding: "utf8", env: environment },
  );
  try {
    for (let attempt = 0; attempt < 100 && !fs.existsSync(marker); attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.equal(fs.existsSync(marker), true, "first process never acquired lock");
    const second = spawnSync(
      "sh",
      [
        "-c",
        '. "$1"; . "$2"; slab_acquire_install_lock /opt/slab',
        "lock",
        prompts,
        lock,
      ],
      { encoding: "utf8", env: environment },
    );
    assert.notEqual(second.status, 0);
    assert.match(second.stderr, /already operating/);
  } finally {
    first.kill("SIGTERM");
    await new Promise((resolve) => first.once("exit", resolve));
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
