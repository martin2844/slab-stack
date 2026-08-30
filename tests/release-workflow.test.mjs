import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const releaseWorkflow = fs.readFileSync(
  path.join(root, ".github/workflows/release.yml"),
  "utf8",
);
const hostMatrixWorkflow = fs.readFileSync(
  path.join(root, ".github/workflows/host-matrix.yml"),
  "utf8",
);
const metadataRepairContract = fs.readFileSync(
  path.join(root, "installer/lib/metadata-repair.sh"),
  "utf8",
);

test("stable publication verifies the signed channel before changing GitHub latest", () => {
  const unlistRelease = releaseWorkflow.indexOf(
    "-F prerelease=false -f make_latest=false",
  );
  const uploadChannel = releaseWorkflow.indexOf(
    'gh release upload "$channel_tag"',
  );
  const verifyChannel = releaseWorkflow.indexOf(
    'cmp -s "dist/$CHANNEL.json" "verified/$CHANNEL.json"',
  );
  const promoteLatest = releaseWorkflow.indexOf(
    "-F prerelease=false -f make_latest=true",
  );

  assert.ok(unlistRelease >= 0, "stable release must first remain non-latest");
  assert.ok(uploadChannel > unlistRelease, "channel upload must follow unlisting");
  assert.ok(verifyChannel > uploadChannel, "published channel must be verified");
  assert.ok(promoteLatest > verifyChannel, "GitHub latest must change last");
});

test("stable gate upgrades the previous signed release with durable state", () => {
  assert.match(releaseWorkflow, /upgrade_from_version: 0\.1\.1/);
  assert.match(releaseWorkflow, /upgrade_channel: stable/);
  assert.match(hostMatrixWorkflow, /stable-upgrade:/);
  const repairContractVersion = metadataRepairContract.match(
    /^SLAB_EMAIL_METADATA_REPAIR_TARGET_VERSION=(\S+)$/m,
  )?.[1];
  const workflowRepairVersion = hostMatrixWorkflow.match(
    /^\s+SLAB_METADATA_REPAIR_VERSION: (\S+)$/m,
  )?.[1];
  assert.ok(repairContractVersion, "metadata repair contract must declare a target");
  assert.equal(workflowRepairVersion, repairContractVersion);

  const installPrevious = hostMatrixWorkflow.indexOf(
    "--version \"$SLAB_UPGRADE_FROM_VERSION\"",
  );
  const seedState = hostMatrixWorkflow.indexOf(
    "Seed durable cross-service state",
  );
  const repairMetadata = hostMatrixWorkflow.indexOf(
    '--version "$SLAB_METADATA_REPAIR_VERSION" -- --repair-known-metadata',
  );
  const stagedChannel = hostMatrixWorkflow.indexOf(
    'SLAB_RELEASE_CHANNEL_BASE_URL="$channel_base"',
  );
  const applyUpdate = hostMatrixWorkflow.indexOf(
    'slabctl update apply --channel "$SLAB_UPGRADE_CHANNEL"',
  );
  const verifyBackup = hostMatrixWorkflow.indexOf(
    'slabctl backup verify "$backup_path"',
  );

  assert.ok(installPrevious >= 0, "upgrade lane must install the previous stable");
  assert.ok(seedState > installPrevious, "state must be seeded before the update");
  assert.ok(repairMetadata > seedState, "known legacy metadata is repaired after seeding");
  assert.ok(stagedChannel > repairMetadata, "update must resolve the staged signed channel");
  assert.ok(applyUpdate > stagedChannel, "signed target must be applied through slabctl");
  assert.ok(verifyBackup > applyUpdate, "mandatory update backup must be verified");

  for (const durableApi of [
    "/api/agents",
    "/api/work/issues",
    "/api/docs",
    "/api/integrations/email/accounts",
  ]) {
    assert.match(hostMatrixWorkflow, new RegExp(durableApi.replaceAll("/", "\\/")));
  }
});
