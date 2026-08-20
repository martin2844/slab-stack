import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const validator = path.join(root, "scripts", "validate-manifest.mjs");
const imageEnvironmentRenderer = path.join(
  root,
  "scripts",
  "render-image-env.mjs",
);
const candidatePath = path.join(
  root,
  "releases",
  "v0.1.0-candidate.1.json",
);
const example = JSON.parse(
  fs.readFileSync(path.join(root, "releases", "example-manifest.json"), "utf8"),
);
const candidate = JSON.parse(
  fs.readFileSync(
    candidatePath,
    "utf8",
  ),
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

test("accepts the immutable candidate release manifest", () => {
  const result = validate(structuredClone(candidate));
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

test("rejects mutable image tags", () => {
  const manifest = structuredClone(candidate);
  manifest.images.runner.ref = "ghcr.io/martin2844/slab-runner:latest";
  const result = validate(manifest);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /runner image ref is invalid/);
});

test("renders every candidate image as an immutable tag and digest pair", () => {
  const result = spawnSync(
    process.execPath,
    [imageEnvironmentRenderer, candidatePath],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stderr);

  const lines = result.stdout.trim().split("\n");
  assert.equal(lines.length, 5);
  assert.deepEqual(
    lines.map((line) => line.split("=", 1)[0]),
    [
      "SLAB_AGENTS_IMAGE",
      "SLAB_WORK_IMAGE",
      "SLAB_DOCS_IMAGE",
      "SLAB_EMAIL_IMAGE",
      "SLAB_RUNNER_IMAGE",
    ],
  );
  for (const line of lines) {
    assert.match(line, /:candidate-[a-f0-9]{40}@sha256:[a-f0-9]{64}$/);
  }
});
