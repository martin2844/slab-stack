import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helper = path.join(root, "installer", "lib", "secrets.sh");
const secretNames = [
  "work-api-key",
  "docs-api-key",
  "runner-token",
  "email-admin-key",
  "email-master-key",
  "session-secret",
];

function prepare(directory) {
  return spawnSync(
    "sh",
    ["-c", '. "$1"; slab_prepare_secrets "$2"', "slab-secrets", helper, directory],
    { encoding: "utf8" },
  );
}

test("creates idempotent Compose-readable secrets under a host-private directory", () => {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-secrets-"),
  );
  const secretsDirectory = path.join(temporaryDirectory, "secrets");
  try {
    const first = prepare(secretsDirectory);
    assert.equal(first.status, 0, first.stderr);
    assert.equal(first.stdout, "");
    assert.equal(fs.statSync(secretsDirectory).mode & 0o777, 0o700);

    const initialValues = new Map();
    for (const name of secretNames) {
      const filename = path.join(secretsDirectory, name);
      const value = fs.readFileSync(filename, "utf8").trim();
      assert.match(value, /^[a-f0-9]{64}$/);
      assert.equal(fs.statSync(filename).mode & 0o777, 0o444);
      initialValues.set(name, value);
    }

    const second = prepare(secretsDirectory);
    assert.equal(second.status, 0, second.stderr);
    for (const name of secretNames) {
      assert.equal(
        fs.readFileSync(path.join(secretsDirectory, name), "utf8").trim(),
        initialValues.get(name),
      );
    }
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("refuses a symbolic-link secret target", () => {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-secrets-link-"),
  );
  const secretsDirectory = path.join(temporaryDirectory, "secrets");
  fs.mkdirSync(secretsDirectory);
  fs.symlinkSync(
    path.join(temporaryDirectory, "outside"),
    path.join(secretsDirectory, "runner-token"),
  );
  try {
    const result = prepare(secretsDirectory);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Refusing symbolic-link secret/);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});
