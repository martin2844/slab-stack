#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const manifestPath = path.resolve(
  process.argv[2] ?? "releases/example-manifest.json",
);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));

const semver = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
const isoDateTime = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/;
const digest = /^sha256:[a-f0-9]{64}$/;
const imageRef = /^ghcr\.io\/[a-z0-9_.-]+\/[a-z0-9_.-]+:(?:v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?|candidate-[a-f0-9]{40})$/;
const serviceNames = ["agents", "work", "docs", "email", "runner"];
const databaseVolumes = ["agents_data", "work_data", "docs_data", "email_data"];
const topLevelKeys = new Set([
  "schemaVersion",
  "stackVersion",
  "channel",
  "releasedAt",
  "minimumSlabctlVersion",
  "images",
  "codexVersion",
  "geminiCliVersion",
  "releaseNotesUrl",
  "severity",
  "drill",
  "migrationCompatibility",
  "dataCompatibility",
]);

function invariant(condition, message) {
  if (!condition) throw new Error(`${manifestPath}: ${message}`);
}

function hasExactlyKeys(value, keys) {
  return (
    value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    Object.keys(value).sort().join(",") === [...keys].sort().join(",")
  );
}

function isHttpsUrl(value) {
  if (
    typeof value !== "string" ||
    value.length > 500 ||
    /[\u0000-\u0020\u007f]/.test(value)
  ) {
    return false;
  }
  const policyMatch = value.match(
    /^https:\/\/(?<host>[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.[A-Za-z](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?::(?<port>[0-9]{1,5}))?(?:[/?#][^\s]*)?$/,
  );
  if (
    !policyMatch ||
    (policyMatch.groups.port !== undefined &&
      Number(policyMatch.groups.port) > 65535) ||
    /%(?![0-9A-Fa-f]{2})/.test(value)
  ) {
    return false;
  }
  try {
    const url = new URL(value);
    return (
      url.protocol === "https:" &&
      url.hostname.length > 0 &&
      url.username.length === 0 &&
      url.password.length === 0
    );
  } catch {
    return false;
  }
}

invariant(manifest.schemaVersion === 1, "schemaVersion must be 1");
invariant(
  Object.keys(manifest).every((key) => topLevelKeys.has(key)),
  "release manifest contains an unsupported property",
);
invariant(semver.test(manifest.stackVersion), "stackVersion must be semver");
invariant(
  ["development", "candidate", "stable", "drill"].includes(manifest.channel),
  "channel is invalid",
);
invariant(
  typeof manifest.releasedAt === "string" &&
    isoDateTime.test(manifest.releasedAt) &&
    new Date(manifest.releasedAt).toISOString() ===
      manifest.releasedAt.replace(/Z$/, ".000Z"),
  "releasedAt must be an ISO date",
);
invariant(
  semver.test(manifest.minimumSlabctlVersion),
  "minimumSlabctlVersion must be semver",
);
invariant(
  typeof manifest.codexVersion === "string" &&
    manifest.codexVersion.length > 0 &&
    manifest.codexVersion.length <= 100,
  "codexVersion is required",
);
if (manifest.geminiCliVersion !== undefined) {
  invariant(
    semver.test(manifest.geminiCliVersion),
    "geminiCliVersion must be semver when provided",
  );
}
if (manifest.releaseNotesUrl !== undefined) {
  invariant(
    isHttpsUrl(manifest.releaseNotesUrl),
    "releaseNotesUrl must be a bounded HTTPS URL",
  );
}
if (manifest.severity !== undefined) {
  invariant(
    ["routine", "security", "critical"].includes(manifest.severity),
    "severity is invalid",
  );
}
if (manifest.drill !== undefined) {
  invariant(
    hasExactlyKeys(manifest.drill, ["expectedOutcome", "fault"]) &&
      manifest.drill.expectedOutcome === "automatic_rollback" &&
      manifest.drill.fault === "agents_image_substituted_with_runner",
    "drill metadata is invalid",
  );
}

invariant(
  manifest.images &&
    Object.keys(manifest.images).sort().join(",") ===
      serviceNames.toSorted().join(","),
  "images must describe exactly the five product services",
);

for (const service of serviceNames) {
  const image = manifest.images?.[service];
  invariant(image, `missing image: ${service}`);
  invariant(
    Object.keys(image).sort().join(",") === "digest,platforms,ref",
    `${service} image contains an unsupported property`,
  );
  invariant(imageRef.test(image.ref), `${service} image ref is invalid`);
  invariant(digest.test(image.digest), `${service} digest is invalid`);
  invariant(
    Array.isArray(image.platforms) &&
      image.platforms.length === 2 &&
      new Set(image.platforms).size === 2 &&
      image.platforms.every((platform) =>
        ["linux/amd64", "linux/arm64"].includes(platform),
      ),
    `${service} must support linux/amd64 and linux/arm64`,
  );
}

invariant(
  hasExactlyKeys(manifest.migrationCompatibility, [
    "minimumUpgradeStack",
    "minimumRollbackStack",
  ]),
  "migrationCompatibility contains an unsupported property",
);

for (const key of ["minimumUpgradeStack", "minimumRollbackStack"]) {
  invariant(
    semver.test(manifest.migrationCompatibility?.[key] ?? ""),
    `migrationCompatibility.${key} must be semver`,
  );
}

if (manifest.dataCompatibility !== undefined) {
  invariant(
    hasExactlyKeys(manifest.dataCompatibility, ["schemaVersion", "volumes"]),
    "dataCompatibility contains an unsupported property",
  );
  invariant(
    manifest.dataCompatibility.schemaVersion === 1,
    "dataCompatibility.schemaVersion must be 1",
  );
  invariant(
    Object.keys(manifest.dataCompatibility.volumes ?? {}).sort().join(",") ===
      databaseVolumes.sort().join(","),
    "dataCompatibility.volumes must describe every product database",
  );
  for (const volume of databaseVolumes) {
    const volumeContract = manifest.dataCompatibility.volumes[volume];
    invariant(
      hasExactlyKeys(volumeContract, ["migrations"]),
      `dataCompatibility.volumes.${volume} contains an unsupported property`,
    );
    const migrations = volumeContract.migrations;
    invariant(
      Array.isArray(migrations) &&
        migrations.length > 0 &&
        migrations.every(
          (migration) =>
            typeof migration === "string" && migration.length > 0,
        ),
      `dataCompatibility.volumes.${volume}.migrations must be non-empty strings`,
    );
    invariant(
      new Set(migrations).size === migrations.length,
      `dataCompatibility.volumes.${volume}.migrations must be unique`,
    );
  }
}

console.log(`Valid release manifest: ${manifest.stackVersion}`);
