import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const validator = path.join(root, "scripts", "validate-manifest.mjs");
const example = JSON.parse(
  fs.readFileSync(path.join(root, "releases", "example-manifest.json"), "utf8"),
);

function validate(manifest) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-manifest-"));
  const filename = path.join(directory, "manifest.json");
  fs.writeFileSync(filename, JSON.stringify(manifest));
  try {
    return spawnSync(process.execPath, [validator, filename], {
      encoding: "utf8",
    });
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

test("accepts the complete development release fixture", () => {
  const result = validate(structuredClone(example));
  assert.equal(result.status, 0, result.stderr);
});

test("rejects a release missing one service image", () => {
  const manifest = structuredClone(example);
  delete manifest.images.runner;
  const result = validate(manifest);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /missing image: runner/);
});

test("rejects a mutable or malformed image digest", () => {
  const manifest = structuredClone(example);
  manifest.images.agents.digest = "latest";
  const result = validate(manifest);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /agents digest is invalid/);
});

test("requires both supported architectures", () => {
  const manifest = structuredClone(example);
  manifest.images.docs.platforms = ["linux/amd64"];
  const result = validate(manifest);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /docs must support linux\/amd64 and linux\/arm64/);
});

