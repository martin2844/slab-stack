import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const targetManifest = path.join(root, "releases", "v0.1.2-candidate.21.json");
const affectedManifests = [
  "v0.1.0-candidate.16.json",
  "v0.1.0-candidate.17.json",
  "v0.1.0-candidate.18.json",
  "v0.1.0-candidate.19.json",
  "v0.1.0-drill.1.json",
  "v0.1.0.json",
  "v0.1.1.json",
  "v0.1.2-candidate.20.json",
];
const libraries = [
  path.join(root, "installer", "lib", "codex.sh"),
  path.join(root, "installer", "lib", "lock.sh"),
  path.join(root, "installer", "lib", "backup.sh"),
  path.join(root, "installer", "lib", "metadata-repair.sh"),
];

function createFixture(sourceManifestName = "v0.1.1.json") {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-metadata-repair-"));
  const hostRoot = path.join(directory, "host");
  const installation = path.join(directory, "installation");
  const registry = path.join(hostRoot, "etc", "slab");
  const config = path.join(installation, "config");
  fs.mkdirSync(registry, { recursive: true });
  fs.mkdirSync(config, { recursive: true });
  fs.writeFileSync(path.join(registry, "install-directory"), `${installation}\n`, { mode: 0o600 });
  const sourceManifest = path.join(root, "releases", sourceManifestName);
  const sourceVersion = JSON.parse(fs.readFileSync(sourceManifest, "utf8")).stackVersion;
  fs.copyFileSync(sourceManifest, path.join(installation, "release-manifest.json"));
  fs.writeFileSync(path.join(installation, "VERSION"), `${sourceVersion}\n`, { mode: 0o600 });
  fs.writeFileSync(
    path.join(config, "install-state.json"),
    `${JSON.stringify({ projectName: "slab-test", status: "READY", accessMode: "private" })}\n`,
    { mode: 0o600 },
  );
  fs.writeFileSync(path.join(config, "access-mode"), "private\n", { mode: 0o600 });
  fs.writeFileSync(path.join(config, "install.env"), "COMPOSE_PROJECT_NAME=slab-test\n", { mode: 0o600 });
  fs.writeFileSync(path.join(installation, "compose.yml"), "services: {}\n", { mode: 0o600 });
  fs.writeFileSync(path.join(installation, "compose.private.yml"), "services: {}\n", { mode: 0o600 });
  return { directory, hostRoot, installation, sourceVersion };
}

function runRepair(fixture, liveMigrations = ["1", "2"], environment = {}) {
  const script = `
    set -eu
    . "$1"
    . "$2"
    . "$3"
    . "$4"
    if [ "\${SLAB_TEST_FAIL_CP:-0}" = 1 ]; then
      cp() { printf 'partial' > "$2"; return 74; }
    fi
    slab_metadata_repair_read_live_email_migrations() { printf '%s\\n' "$SLAB_TEST_LIVE_MIGRATIONS"; }
    slab_repair_known_email_migration_metadata "$5"
    SLABCTL_INSTALL_DIRECTORY=$(cat "$6/etc/slab/install-directory")
    slabctl_expected_migrations email_data
  `;
  return spawnSync(
    "sh",
    [
      "-c",
      script,
      "metadata-repair-test",
      ...libraries,
      targetManifest,
      fixture.hostRoot,
    ],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        SLAB_METADATA_REPAIR_ROOT: fixture.hostRoot,
        SLAB_MANAGEMENT_OWNER_UID: String(process.getuid()),
        SLABCTL_EXPECTED_OWNER_UID: String(process.getuid()),
        SLAB_TEST_LIVE_MIGRATIONS: JSON.stringify(liveMigrations),
        ...environment,
      },
    },
  );
}

function readManifest(fixture) {
  return JSON.parse(fs.readFileSync(path.join(fixture.installation, "release-manifest.json"), "utf8"));
}

for (const sourceManifestName of affectedManifests) {
  test(`repairs only known Email metadata for ${sourceManifestName}`, () => {
    const fixture = createFixture(sourceManifestName);
    try {
      const before = readManifest(fixture);
      const originalBytes = fs.readFileSync(path.join(fixture.installation, "release-manifest.json"));
      const result = runRepair(fixture);
      assert.equal(result.status, 0, result.stderr);
      assert.match(result.stdout, /Corrected the known Email migration metadata defect/);
      assert.match(result.stdout, /\["1","2"\]/);

      const after = readManifest(fixture);
      const expected = structuredClone(before);
      expected.dataCompatibility.volumes.email_data.migrations = ["1", "2"];
      assert.deepEqual(after, expected);
      const backup = path.join(
        fixture.installation,
        `release-manifest.json.pre-email-metadata-repair.${fixture.sourceVersion}`,
      );
      assert.deepEqual(fs.readFileSync(backup), originalBytes);
      assert.equal(fs.statSync(backup).mode & 0o777, 0o600);
    } finally {
      fs.rmSync(fixture.directory, { recursive: true, force: true });
    }
  });
}

test("refuses modified release metadata outside the exact affected allowlist", () => {
  const fixture = createFixture();
  try {
    const manifestPath = path.join(fixture.installation, "release-manifest.json");
    const modified = readManifest(fixture);
    modified.releasedAt = "2026-08-24T00:00:00Z";
    fs.writeFileSync(manifestPath, `${JSON.stringify(modified, null, 2)}\n`, { mode: 0o600 });
    const before = fs.readFileSync(manifestPath);
    const result = runRepair(fixture);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /does not exactly match an affected official release/);
    assert.deepEqual(fs.readFileSync(manifestPath), before);
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});

test("refuses repair when live Email migrations differ from the exact known state", () => {
  const fixture = createFixture();
  try {
    const manifestPath = path.join(fixture.installation, "release-manifest.json");
    const before = fs.readFileSync(manifestPath);
    const result = runRepair(fixture, ["1", "2", "3"]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /live Email migrations are not the exact known/);
    assert.deepEqual(fs.readFileSync(manifestPath), before);
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});

test("repair is idempotent after the metadata is corrected", () => {
  const fixture = createFixture();
  try {
    const first = runRepair(fixture);
    assert.equal(first.status, 0, first.stderr);
    const repairedBytes = fs.readFileSync(path.join(fixture.installation, "release-manifest.json"));
    const second = runRepair(fixture);
    assert.equal(second.status, 0, second.stderr);
    assert.match(second.stdout, /already correct/);
    assert.deepEqual(fs.readFileSync(path.join(fixture.installation, "release-manifest.json")), repairedBytes);
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});

test("an interrupted backup publication leaves no final artifact and retry succeeds", () => {
  const fixture = createFixture();
  try {
    const interrupted = runRepair(fixture, ["1", "2"], {
      SLAB_TEST_FAIL_CP: "1",
    });
    assert.notEqual(
      interrupted.status,
      0,
      `stdout=${interrupted.stdout}\nstderr=${interrupted.stderr}`,
    );
    assert.equal(
      fs.existsSync(path.join(fixture.installation, "release-manifest.json.pre-email-metadata-repair.0.1.1")),
      false,
    );
    assert.deepEqual(
      fs.readdirSync(fixture.installation).filter((name) => name.includes("email-repair-backup")),
      [],
    );

    const retry = runRepair(fixture);
    assert.equal(retry.status, 0, retry.stderr);
    assert.deepEqual(readManifest(fixture).dataCompatibility.volumes.email_data.migrations, ["1", "2"]);
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});

test("a termination signal during backup staging aborts without manifest mutation", () => {
  const fixture = createFixture();
  try {
    const binaries = path.join(fixture.directory, "signal-bin");
    fs.mkdirSync(binaries);
    fs.writeFileSync(
      path.join(binaries, "cp"),
      `#!/bin/sh
kill -TERM "$PPID"
exit 143
`,
      { mode: 0o755 },
    );
    const manifestPath = path.join(fixture.installation, "release-manifest.json");
    const before = fs.readFileSync(manifestPath);
    const interrupted = runRepair(fixture, ["1", "2"], {
      PATH: `${binaries}:${process.env.PATH}`,
    });
    assert.notEqual(interrupted.status, 0);
    assert.deepEqual(fs.readFileSync(manifestPath), before);
    assert.equal(
      fs.existsSync(path.join(fixture.installation, "release-manifest.json.pre-email-metadata-repair.0.1.1")),
      false,
    );
    assert.deepEqual(
      fs.readdirSync(fixture.installation).filter((name) => name.includes("email-repair")),
      [],
    );
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});
