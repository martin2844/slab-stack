#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const manifestPath = path.resolve(
  process.argv[2] ?? "releases/v0.1.2-candidate.32.json",
);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));

const images = [
  ["SLAB_AGENTS_IMAGE", "agents"],
  ["SLAB_WORK_IMAGE", "work"],
  ["SLAB_DOCS_IMAGE", "docs"],
  ["SLAB_EMAIL_IMAGE", "email"],
  ["SLAB_RUNNER_IMAGE", "runner"],
];

for (const [environmentName, service] of images) {
  const image = manifest.images?.[service];
  if (!image?.ref || !image?.digest) {
    throw new Error(`${manifestPath}: missing image: ${service}`);
  }
  process.stdout.write(`${environmentName}=${image.ref}@${image.digest}\n`);
}
