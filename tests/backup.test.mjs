import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const backupLibrary = path.join(root, "installer/lib/backup.sh");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: "utf8", ...options });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return result;
}

function checksum(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function backupFixture(t, { stackVersion = "0.1.0-candidate.10", extra = false } = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-backup-test-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const stage = path.join(directory, "stage");
  const volumeSource = path.join(directory, "volume-source");
  fs.mkdirSync(path.join(stage, "metadata"), { recursive: true });
  fs.mkdirSync(path.join(stage, "volumes"), { recursive: true });
  fs.mkdirSync(volumeSource);
  fs.writeFileSync(path.join(stage, "metadata/VERSION"), `${stackVersion}\n`);
  fs.writeFileSync(path.join(volumeSource, "slab-workspace.db"), "fixture-data\n");
  const volumeArchive = path.join(stage, "volumes/agents_data.tar.gz");
  run("tar", ["-czf", volumeArchive, "-C", volumeSource, "."]);

  const metadataPath = path.join(stage, "metadata/VERSION");
  const manifest = {
    schemaVersion: 1,
    format: "slab-backup-v1",
    createdAt: "2026-08-23T12:00:00Z",
    stackVersion,
    source: { projectName: "slab", accessMode: "private" },
    images: {},
    files: [
      {
        path: "metadata/VERSION",
        sha256: checksum(metadataPath),
        bytes: fs.statSync(metadataPath).size,
      },
    ],
    volumes: [
      {
        logicalName: "agents_data",
        dockerVolume: "slab_agents_data",
        archivePath: "volumes/agents_data.tar.gz",
        sha256: checksum(volumeArchive),
        bytes: fs.statSync(volumeArchive).size,
        schema: {
          kind: "sqlite",
          migrationCount: 3,
          latestMigration: "003_agents.cjs",
          userVersion: 0,
        },
      },
    ],
  };
  fs.writeFileSync(path.join(stage, "manifest.json"), JSON.stringify(manifest));
  if (extra) fs.writeFileSync(path.join(stage, "unexpected.txt"), "not declared");
  const archive = path.join(directory, "backup.tar.gz");
  const members = [
    "manifest.json",
    "metadata/VERSION",
    "volumes/agents_data.tar.gz",
  ];
  if (extra) members.push("unexpected.txt");
  run("tar", ["-czf", archive, "-C", stage, ...members]);
  return { archive, directory };
}

function backupShell(script, args = [], env = {}) {
  return spawnSync("sh", ["-c", `. "$1"; ${script}`, "backup-test", backupLibrary, ...args], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
}

test("verifies a versioned backup manifest and every declared payload", (t) => {
  const { archive } = backupFixture(t);
  const result = backupShell(
    'slabctl_error() { echo "slabctl: $*" >&2; return 1; }; slabctl_backup_verify "$2"',
    [archive],
  );
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Backup verified: 0\.1\.0-candidate\.10/);
  assert.match(result.stdout, /Volumes: 1/);
});

test("rejects undeclared archive members even when declared checksums are valid", (t) => {
  const { archive } = backupFixture(t, { extra: true });
  const result = backupShell(
    'slabctl_error() { echo "slabctl: $*" >&2; return 1; }; slabctl_backup_verify "$2"',
    [archive],
  );
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /members do not match/);
});

test("opens and verifies an age-wrapped backup only with a private identity", (t) => {
  const { archive, directory } = backupFixture(t);
  const encrypted = path.join(directory, "backup.tar.gz.age");
  fs.writeFileSync(
    encrypted,
    Buffer.concat([
      Buffer.from("age-encryption.org/v1\n"),
      fs.readFileSync(archive),
    ]),
  );
  const identity = path.join(directory, "backup.agekey");
  fs.writeFileSync(identity, "AGE-SECRET-KEY-TEST\n", { mode: 0o600 });
  const bin = path.join(directory, "bin");
  fs.mkdirSync(bin);
  fs.writeFileSync(
    path.join(bin, "age"),
    `#!/bin/sh
set -eu
output=
input=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --decrypt) ;;
    --identity) shift ;;
    --output) output=$2; shift ;;
    *) input=$1 ;;
  esac
  shift
done
tail -n +2 "$input" > "$output"
`,
    { mode: 0o755 },
  );
  fs.writeFileSync(path.join(bin, "age-keygen"), "#!/bin/sh\necho age1fixture\n", {
    mode: 0o755,
  });

  const missingIdentity = backupShell(
    'slabctl_error() { echo "slabctl: $*" >&2; return 1; }; slabctl_backup_verify "$2"',
    [encrypted],
    { PATH: `${bin}:${process.env.PATH}` },
  );
  assert.notEqual(missingIdentity.status, 0);
  assert.match(missingIdentity.stderr, /requires --identity/);

  const verified = backupShell(
    'slabctl_error() { echo "slabctl: $*" >&2; return 1; }; slabctl_backup_verify "$2" "$3"',
    [encrypted, identity],
    {
      PATH: `${bin}:${process.env.PATH}`,
      SLABCTL_EXPECTED_OWNER_UID: String(process.getuid()),
    },
  );
  assert.equal(verified.status, 0, verified.stderr);
  assert.match(verified.stdout, /Backup verified/);
});

test("restore dry-run validates version and volume identity without mutation", (t) => {
  const { archive, directory } = backupFixture(t);
  const installation = path.join(directory, "installation");
  fs.mkdirSync(installation);
  fs.writeFileSync(path.join(installation, "VERSION"), "0.1.0-candidate.10\n");
  const result = backupShell(
    [
      'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
      'slabctl_volume_names() { echo agents_data; }',
      'slabctl_resolve_volume() { echo slab_agents_data; }',
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      'SLABCTL_PROJECT_NAME=slab',
      'slabctl_restore_archive "$3" 1 0',
    ].join("; "),
    [installation, archive],
  );
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Restore dry run passed/);
  assert.match(result.stdout, /No data was changed/);
  assert.equal(fs.existsSync(path.join(installation, "config/restore-state.json")), false);
});

test("restore refuses a backup from a different stack version", (t) => {
  const { archive, directory } = backupFixture(t, { stackVersion: "0.2.0" });
  const installation = path.join(directory, "installation");
  fs.mkdirSync(installation);
  fs.writeFileSync(path.join(installation, "VERSION"), "0.1.0-candidate.10\n");
  const result = backupShell(
    [
      'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
      'slabctl_volume_names() { echo agents_data; }',
      'slabctl_resolve_volume() { echo slab_agents_data; }',
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      'SLABCTL_PROJECT_NAME=slab',
      'slabctl_restore_archive "$3" 1 0',
    ].join("; "),
    [installation, archive],
  );
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /not compatible/);
});
