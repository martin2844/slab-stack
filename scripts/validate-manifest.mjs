#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const manifestPath = path.resolve(
  process.argv[2] ?? "releases/example-manifest.json",
);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));

const semver = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;
const digest = /^sha256:[a-f0-9]{64}$/;
const imageRef = /^ghcr\.io\/[a-z0-9_.-]+\/[a-z0-9_.-]+:v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/;
const serviceNames = ["agents", "work", "docs", "email", "runner"];

function invariant(condition, message) {
  if (!condition) throw new Error(`${manifestPath}: ${message}`);
}

invariant(manifest.schemaVersion === 1, "schemaVersion must be 1");
invariant(semver.test(manifest.stackVersion), "stackVersion must be semver");
invariant(
  ["development", "candidate", "stable"].includes(manifest.channel),
  "channel is invalid",
);
invariant(
  !Number.isNaN(Date.parse(manifest.releasedAt)),
  "releasedAt must be an ISO date",
);
invariant(
  semver.test(manifest.minimumSlabctlVersion),
  "minimumSlabctlVersion must be semver",
);
invariant(
  typeof manifest.codexVersion === "string" && manifest.codexVersion.length > 0,
  "codexVersion is required",
);

for (const service of serviceNames) {
  const image = manifest.images?.[service];
  invariant(image, `missing image: ${service}`);
  invariant(imageRef.test(image.ref), `${service} image ref is invalid`);
  invariant(digest.test(image.digest), `${service} digest is invalid`);
  invariant(
    Array.isArray(image.platforms) &&
      image.platforms.includes("linux/amd64") &&
      image.platforms.includes("linux/arm64"),
    `${service} must support linux/amd64 and linux/arm64`,
  );
}

for (const key of ["minimumUpgradeStack", "minimumRollbackStack"]) {
  invariant(
    semver.test(manifest.migrationCompatibility?.[key] ?? ""),
    `migrationCompatibility.${key} must be semver`,
  );
}

console.log(`Valid release manifest: ${manifest.stackVersion}`);

