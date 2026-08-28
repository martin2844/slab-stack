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
  "v0.1.2-candidate.38.json",
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

function validateAtRuntime(manifest) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-runtime-manifest-"));
  const filename = path.join(directory, "manifest.json");
  fs.writeFileSync(filename, JSON.stringify(manifest));
  try {
    return spawnSync(
      "sh",
      [
        "-c",
        '. "$1"; slab_validate_release_manifest "$2"',
        "runtime-manifest-test",
        path.join(root, "installer/lib/render.sh"),
        filename,
      ],
      { encoding: "utf8" },
    );
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
  const runtimeResult = validateAtRuntime(structuredClone(candidate));
  assert.equal(runtimeResult.status, 0, runtimeResult.stderr);
  assert.equal(candidate.codexVersion, "0.148.0");
  assert.equal(candidate.geminiCliVersion, "0.56.0");
  assert.deepEqual(
    candidate.dataCompatibility.volumes.email_data.migrations,
    ["1", "2", "3", "4"],
  );
});

test("rejects a malformed optional Gemini CLI version", () => {
  const manifest = structuredClone(candidate);
  manifest.geminiCliVersion = "latest";
  const result = validate(manifest);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /geminiCliVersion must be semver/);
});

test("machine schema declares every release property accepted by validation", () => {
  const schema = JSON.parse(
    fs.readFileSync(
      path.join(root, "contracts/release-manifest.schema.json"),
      "utf8",
    ),
  );
  assert.deepEqual(
    Object.keys(candidate).sort(),
    Object.keys(schema.properties)
      .filter((key) => candidate[key] !== undefined)
      .sort(),
  );
  assert.ok(schema.properties.channel.enum.includes("drill"));
  assert.equal(
    schema.properties.dataCompatibility.properties.volumes.additionalProperties,
    false,
  );
});

test("rejects unknown release and image properties", () => {
  const release = structuredClone(candidate);
  release.command = "docker system prune";
  const rejectedRelease = validate(release);
  assert.notEqual(rejectedRelease.status, 0);
  assert.match(rejectedRelease.stderr, /unsupported property/);
  assert.notEqual(validateAtRuntime(release).status, 0);

  const image = structuredClone(candidate);
  image.images.runner.mutableTag = "latest";
  const rejectedImage = validate(image);
  assert.notEqual(rejectedImage.status, 0);
  assert.match(rejectedImage.stderr, /runner image contains an unsupported property/);
  assert.notEqual(validateAtRuntime(image).status, 0);
});

test("packaging and runtime validators reject unknown nested properties", () => {
  const mutations = [
    (manifest) => {
      manifest.migrationCompatibility.command = "unsafe";
    },
    (manifest) => {
      manifest.dataCompatibility.command = "unsafe";
    },
    (manifest) => {
      manifest.dataCompatibility.volumes.agents_data.command = "unsafe";
    },
    (manifest) => {
      manifest.drill = {
        expectedOutcome: "automatic_rollback",
        fault: "agents_image_substituted_with_runner",
        command: "unsafe",
      };
    },
  ];
  for (const mutate of mutations) {
    const manifest = structuredClone(candidate);
    mutate(manifest);
    assert.notEqual(validate(manifest).status, 0);
    assert.notEqual(validateAtRuntime(manifest).status, 0);
  }
});

test("packaging and runtime validators enforce the exact platform set", () => {
  for (const platforms of [
    ["linux/amd64", "linux/arm64", "linux/s390x"],
    ["linux/amd64", "linux/amd64", "linux/arm64"],
  ]) {
    const manifest = structuredClone(candidate);
    manifest.images.agents.platforms = platforms;
    assert.notEqual(validate(manifest).status, 0);
    assert.notEqual(validateAtRuntime(manifest).status, 0);
  }
});

test("validates optional release presentation metadata", () => {
  const manifest = structuredClone(candidate);
  manifest.releaseNotesUrl = "https://github.com/martin2844/slab-stack/releases/tag/v0.1.2";
  manifest.severity = "security";
  assert.equal(validate(manifest).status, 0);

  manifest.releaseNotesUrl = "http://internal.invalid/release";
  assert.match(validate(manifest).stderr, /bounded HTTPS URL/);
  for (const invalidUrl of [
    "https://",
    "https://user:password@example.invalid/release",
    "https://example.invalid/release notes",
    "https://%",
    "https://[invalid",
    "https://example.invalid:bad/release",
    "https://example.invalid:99999/release",
    "https://example.invalid/%ZZ",
    "https://999.999.999.999/release",
    "https://256.1.1.1/release",
    "https://example.123/release",
  ]) {
    manifest.releaseNotesUrl = invalidUrl;
    assert.match(validate(manifest).stderr, /bounded HTTPS URL/);
    assert.notEqual(validateAtRuntime(manifest).status, 0);
  }
  manifest.releaseNotesUrl = "https://example.invalid/release";
  manifest.severity = "urgent";
  assert.match(validate(manifest).stderr, /severity is invalid/);
});

test("accepts a release-engineering drill manifest", () => {
  const manifest = structuredClone(candidate);
  manifest.stackVersion = "0.1.0-drill.1";
  manifest.channel = "drill";
  const result = validate(manifest);
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
  assert.match(result.stderr, /images must describe exactly/);
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
  assert.notEqual(validateAtRuntime(manifest).status, 0);
});

test("packaging and runtime validators enforce timestamp and version bounds", () => {
  const impossibleDate = structuredClone(candidate);
  impossibleDate.releasedAt = "2026-99-99T99:99:99Z";
  assert.notEqual(validate(impossibleDate).status, 0);
  assert.notEqual(validateAtRuntime(impossibleDate).status, 0);

  const longCodexVersion = structuredClone(candidate);
  longCodexVersion.codexVersion = "x".repeat(101);
  assert.notEqual(validate(longCodexVersion).status, 0);
  assert.notEqual(validateAtRuntime(longCodexVersion).status, 0);
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
  for (const [filename, expectedPointer] of [
    [".github/workflows/host-matrix.yml", candidate.stackVersion],
    ["README.md", candidateName],
    ["installer/install.sh", candidateName],
    ["scripts/check.sh", candidateName],
    ["scripts/full-stack-smoke.sh", candidateName],
    ["scripts/render-image-env.mjs", candidateName],
  ]) {
    assert.match(
      fs.readFileSync(path.join(root, filename), "utf8"),
      new RegExp(expectedPointer.replaceAll(".", "\\.")),
      `${filename} does not point to ${expectedPointer}`,
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

test("stable channel points to the exact reviewed manifest", () => {
  const stablePath = path.join(root, "releases/v0.1.1.json");
  const stable = JSON.parse(fs.readFileSync(stablePath, "utf8"));
  const channel = JSON.parse(
    fs.readFileSync(path.join(root, "channels/stable.json"), "utf8"),
  );
  const manifestSha256 = crypto
    .createHash("sha256")
    .update(fs.readFileSync(stablePath))
    .digest("hex");
  assert.equal(channel.schemaVersion, 1);
  assert.equal(channel.channel, "stable");
  assert.equal(channel.stackVersion, stable.stackVersion);
  assert.equal(channel.manifestSha256, manifestSha256);
  assert.equal(
    channel.manifestUrl,
    `https://github.com/martin2844/slab-stack/releases/download/v${stable.stackVersion}/v${stable.stackVersion}.json`,
  );
});
