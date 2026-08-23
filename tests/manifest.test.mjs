import assert from "node:assert/strict";
import crypto from "node:crypto";
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
  "v0.1.0-candidate.18.json",
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

test("rejects an incomplete database compatibility contract", () => {
  const manifest = structuredClone(candidate);
  delete manifest.dataCompatibility.volumes.email_data;
  const result = validate(manifest);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /must describe every product database/);
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

test("uses the current candidate when the renderer receives no manifest", () => {
  const explicit = spawnSync(
    process.execPath,
    [imageEnvironmentRenderer, candidatePath],
    { encoding: "utf8", cwd: root },
  );
  const implicit = spawnSync(process.execPath, [imageEnvironmentRenderer], {
    encoding: "utf8",
    cwd: root,
  });
  assert.equal(explicit.status, 0, explicit.stderr);
  assert.equal(implicit.status, 0, implicit.stderr);
  assert.equal(implicit.stdout, explicit.stdout);
});

test("keeps every current-candidate pointer on the same manifest", () => {
  const candidateName = path.basename(candidatePath);
  for (const filename of [
    "README.md",
    "installer/install.sh",
    "scripts/check.sh",
    "scripts/full-stack-smoke.sh",
    "scripts/render-image-env.mjs",
  ]) {
    assert.match(
      fs.readFileSync(path.join(root, filename), "utf8"),
      new RegExp(candidateName.replaceAll(".", "\\.")),
      `${filename} does not point to ${candidateName}`,
    );
  }
});

test("candidate channel points to the exact reviewed manifest", () => {
  const channel = JSON.parse(
    fs.readFileSync(path.join(root, "channels/candidate.json"), "utf8"),
  );
  const manifestBytes = fs.readFileSync(candidatePath);
  const manifestSha256 = crypto
    .createHash("sha256")
    .update(manifestBytes)
    .digest("hex");
  assert.equal(channel.schemaVersion, 1);
  assert.equal(channel.channel, "candidate");
  assert.equal(channel.stackVersion, candidate.stackVersion);
  assert.equal(channel.manifestSha256, manifestSha256);
  assert.equal(
    channel.manifestUrl,
    `https://github.com/martin2844/slab-stack/releases/download/v${candidate.stackVersion}/v${candidate.stackVersion}.json`,
  );
});
