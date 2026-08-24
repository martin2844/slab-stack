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
  return crypto
    .createHash("sha256")
    .update(fs.readFileSync(file))
    .digest("hex");
}

function backupFixture(
  t,
  {
    stackVersion = "0.1.0-candidate.10",
    schemaVersion = 1,
    appliedMigrations = ["003_agents.cjs"],
    expectedMigrations = appliedMigrations,
    externalAuth = [],
    extra = false,
    omitRequiredSecret = false,
  } = {},
) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-backup-test-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const stage = path.join(directory, "stage");
  const volumeSource = path.join(directory, "volume-source");
  fs.mkdirSync(path.join(stage, "metadata"), { recursive: true });
  fs.mkdirSync(path.join(stage, "secrets"), { recursive: true });
  fs.mkdirSync(path.join(stage, "volumes"), { recursive: true });
  fs.mkdirSync(volumeSource);
  const metadataNames = [
    "Caddyfile",
    "VERSION",
    "compose.domain.yml",
    "compose.private.yml",
    "compose.yml",
    "config-access-mode",
    "config-install-state.json",
    "config-install.env",
    "release-manifest.json",
  ];
  for (const name of metadataNames) {
    fs.writeFileSync(
      path.join(stage, "metadata", name),
      name === "VERSION" ? `${stackVersion}\n` : `${name}-fixture\n`,
    );
  }
  const secretNames = [
    "docs-api-key",
    "email-admin-key",
    "email-master-key",
    "runner-token",
    "session-secret",
    "work-api-key",
  ];
  for (const name of secretNames) {
    if (omitRequiredSecret && name === "session-secret") continue;
    fs.writeFileSync(path.join(stage, "secrets", name), `${name}-fixture\n`);
  }
  fs.writeFileSync(
    path.join(volumeSource, "slab-workspace.db"),
    "fixture-data\n",
  );
  const volumeArchive = path.join(stage, "volumes/agents_data.tar.gz");
  run("tar", ["-czf", volumeArchive, "-C", volumeSource, "."]);

  const payloadFiles = [
    ...metadataNames.map((name) => `metadata/${name}`),
    ...secretNames
      .filter((name) => !(omitRequiredSecret && name === "session-secret"))
      .map((name) => `secrets/${name}`),
  ];
  const manifest = {
    schemaVersion,
    format: `slab-backup-v${schemaVersion}`,
    createdAt: "2026-08-23T12:00:00Z",
    stackVersion,
    source: { projectName: "slab", accessMode: "private" },
    images: {},
    files: payloadFiles.map((payloadPath) => ({
      path: payloadPath,
      sha256: checksum(path.join(stage, payloadPath)),
      bytes: fs.statSync(path.join(stage, payloadPath)).size,
    })),
    volumes: [
      {
        logicalName: "agents_data",
        ...(schemaVersion === 2 ? { scope: "product" } : {}),
        dockerVolume: "slab_agents_data",
        archivePath: "volumes/agents_data.tar.gz",
        sha256: checksum(volumeArchive),
        bytes: fs.statSync(volumeArchive).size,
        schema: {
          kind: "sqlite",
          migrationCount: appliedMigrations.length,
          latestMigration: appliedMigrations.at(-1) ?? null,
          userVersion: 0,
          ...(schemaVersion === 2
            ? {
                appliedMigrations,
                expectedMigrations,
                matchesRelease:
                  JSON.stringify(appliedMigrations) ===
                  JSON.stringify(expectedMigrations),
              }
            : {}),
        },
      },
    ],
    ...(schemaVersion === 2 ? { externalAuth } : {}),
  };
  fs.writeFileSync(path.join(stage, "manifest.json"), JSON.stringify(manifest));
  if (extra)
    fs.writeFileSync(path.join(stage, "unexpected.txt"), "not declared");
  const archive = path.join(directory, "backup.tar.gz");
  const members = [
    "manifest.json",
    ...payloadFiles,
    "volumes/agents_data.tar.gz",
  ];
  if (extra) members.push("unexpected.txt");
  run("tar", ["-czf", archive, "-C", stage, ...members]);
  return { archive, directory, stage };
}

function backupShell(script, args = [], env = {}) {
  return spawnSync(
    "sh",
    ["-c", `. "$1"; ${script}`, "backup-test", backupLibrary, ...args],
    {
      encoding: "utf8",
      env: { ...process.env, ...env },
    },
  );
}

function writeTargetRelease(installation, migrations) {
  fs.writeFileSync(
    path.join(installation, "release-manifest.json"),
    JSON.stringify({
      dataCompatibility: {
        volumes: { agents_data: { migrations } },
      },
    }),
  );
}

test("portable backups exclude host-local Gemini OAuth state", () => {
  const result = backupShell(`
    printf '%s\\n' "$(slabctl_volume_scope runner_gemini)"
    printf '%s\\n' "$(slabctl_volume_scope runner_codex)"
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.stdout.trim().split("\n"), [
    "infrastructure",
    "product",
  ]);
});

test("authenticated Gemini state is recorded as requiring portable reauthentication", () => {
  const result = backupShell(`
    docker() {
      printf '%s' '[{"provider":"gemini","configuredAccounts":1,"portability":"reauthentication_required"}]'
    }
    slabctl_gemini_external_auth_metadata slab_runner_gemini fixture-runner
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), [
    {
      provider: "gemini",
      configuredAccounts: 1,
      portability: "reauthentication_required",
    },
  ]);
});

test("backup manifest contract accepts every emitted external authentication provider", () => {
  const schema = JSON.parse(
    fs.readFileSync(
      path.join(root, "contracts", "backup-manifest.schema.json"),
      "utf8",
    ),
  );
  assert.deepEqual(
    schema.properties.externalAuth.items.properties.provider.enum,
    ["gemini", "proton_bridge"],
  );
});

test("resolves legacy Compose volumes that predate project labels", () => {
  const result = backupShell(`
    SLABCTL_PROJECT_NAME=slab
    slabctl_error() { echo "slabctl: $*" >&2; return 1; }
    docker() {
      if [ "$1 $2 $3" = "volume ls -q" ]; then
        return 0
      fi
      if [ "$1 $2 $3" = "volume inspect slab_caddy_config" ]; then
        return 0
      fi
      return 1
    }
    slabctl_resolve_volume caddy_config
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), "slab_caddy_config");
});

test("does not guess a legacy volume when the exact Compose name is absent", () => {
  const result = backupShell(`
    SLABCTL_PROJECT_NAME=slab
    slabctl_error() { echo "slabctl: $*" >&2; return 1; }
    docker() {
      [ "$1 $2 $3" = "volume ls -q" ] && return 0
      return 1
    }
    slabctl_resolve_volume missing_data
  `);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /expected one Docker volume/);
});

test("schema inspection keeps SQL read-only while allowing SQLite WAL coordination", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-schema-probe-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const dockerArgs = path.join(directory, "docker-args");
  const result = backupShell(
    `
      SLABCTL_INSTALL_DIRECTORY=/fixture
      jq() { printf '%s\n' fixture-image; }
      docker() {
        printf '%s\n' "$*" > "$DOCKER_ARGS"
        printf '%s\n' '{"kind":"sqlite","migrationCount":0,"latestMigration":null,"userVersion":0}'
      }
      slabctl_database_schema docs_data slab_docs_data
    `,
    [],
    { DOCKER_ARGS: dockerArgs },
  );
  assert.equal(result.status, 0, result.stderr);
  const invocation = fs.readFileSync(dockerArgs, "utf8");
  assert.match(invocation, /type=volume,src=slab_docs_data,dst=\/data/);
  assert.doesNotMatch(invocation, /dst=\/data,readonly/);
  assert.match(invocation, /readonly: true/);
});

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

test("rejects a self-consistent backup that omits a required secret", (t) => {
  const { archive } = backupFixture(t, { omitRequiredSecret: true });
  const result = backupShell(
    'slabctl_error() { echo "slabctl: $*" >&2; return 1; }; slabctl_backup_verify "$2"',
    [archive],
  );
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /manifest is invalid/);
});

test("rejects v2 schema metadata that does not match its source release", (t) => {
  const { stage } = backupFixture(t, {
    schemaVersion: 2,
    appliedMigrations: ["001.cjs"],
  });
  const manifestPath = path.join(stage, "manifest.json");
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  manifest.volumes[0].schema.matchesRelease = false;
  fs.writeFileSync(manifestPath, JSON.stringify(manifest));
  const result = backupShell(
    'slabctl_backup_validate_manifest "$2"',
    [manifestPath],
  );
  assert.notEqual(result.status, 0);
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
  fs.writeFileSync(
    path.join(bin, "age-keygen"),
    "#!/bin/sh\necho age1fixture\n",
    {
      mode: 0o755,
    },
  );

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
      "slabctl_volume_names() { echo agents_data; }",
      "slabctl_resolve_volume() { echo slab_agents_data; }",
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      "SLABCTL_PROJECT_NAME=slab",
      'slabctl_restore_archive "$3" 1 0',
    ].join("; "),
    [installation, archive],
  );
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Restore dry run passed/);
  assert.match(result.stdout, /No data was changed/);
  assert.equal(
    fs.existsSync(path.join(installation, "config/restore-state.json")),
    false,
  );
});

test("restore refuses a backup from a different stack version", (t) => {
  const { archive, directory } = backupFixture(t, { stackVersion: "0.2.0" });
  const installation = path.join(directory, "installation");
  fs.mkdirSync(installation);
  fs.writeFileSync(path.join(installation, "VERSION"), "0.1.0-candidate.10\n");
  const result = backupShell(
    [
      'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
      "slabctl_volume_names() { echo agents_data; }",
      "slabctl_resolve_volume() { echo slab_agents_data; }",
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      "SLABCTL_PROJECT_NAME=slab",
      'slabctl_restore_archive "$3" 1 0',
    ].join("; "),
    [installation, archive],
  );
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /not compatible/);
});

test("v2 restore accepts a different stack version when migrations are a supported prefix", (t) => {
  const { archive, directory } = backupFixture(t, {
    schemaVersion: 2,
    stackVersion: "0.1.0-candidate.15",
    appliedMigrations: ["001.cjs", "002.cjs"],
  });
  const installation = path.join(directory, "installation");
  fs.mkdirSync(installation);
  fs.writeFileSync(path.join(installation, "VERSION"), "0.1.0-candidate.16\n");
  writeTargetRelease(installation, ["001.cjs", "002.cjs", "003.cjs"]);
  const result = backupShell(
    [
      'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
      "slabctl_volume_names() { printf '%s\\n' agents_data caddy_data caddy_config; }",
      "slabctl_resolve_volume() { echo slab_agents_data; }",
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      "SLABCTL_PROJECT_NAME=slab",
      'slabctl_restore_archive "$3" 1 0',
    ].join("; "),
    [installation, archive],
  );
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Backup stack version: 0\.1\.0-candidate\.15/);
  assert.match(result.stdout, /Installed stack version: 0\.1\.0-candidate\.16/);
  assert.match(result.stdout, /Volumes: 1/);
});

test("v2 restore rejects migrations unknown to the installed release before mutation", (t) => {
  const { archive, directory } = backupFixture(t, {
    schemaVersion: 2,
    stackVersion: "0.1.0-candidate.17",
    appliedMigrations: ["001.cjs", "future.cjs"],
  });
  const installation = path.join(directory, "installation");
  fs.mkdirSync(installation);
  fs.writeFileSync(path.join(installation, "VERSION"), "0.1.0-candidate.16\n");
  writeTargetRelease(installation, ["001.cjs", "002.cjs"]);
  const result = backupShell(
    [
      'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
      "slabctl_volume_names() { echo agents_data; }",
      "slabctl_resolve_volume() { echo slab_agents_data; }",
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      "SLABCTL_PROJECT_NAME=slab",
      'slabctl_restore_archive "$3" 1 0',
    ].join("; "),
    [installation, archive],
  );
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /schema for agents_data is not supported/);
  assert.equal(
    fs.existsSync(path.join(installation, "config/restore-state.json")),
    false,
  );
});

test("backup schema gate rejects database drift from the signed release", () => {
  const matching = backupShell(
    `slabctl_schema_matches_release '{"kind":"sqlite","matchesRelease":true}'`,
  );
  assert.equal(matching.status, 0, matching.stderr);
  const drifted = backupShell(
    `slabctl_schema_matches_release '{"kind":"sqlite","matchesRelease":false}'`,
  );
  assert.notEqual(drifted.status, 0);
});

test("restore refuses mutation when running-service inspection fails", (t) => {
  const { archive, directory } = backupFixture(t);
  const installation = path.join(directory, "installation");
  fs.mkdirSync(installation);
  fs.writeFileSync(path.join(installation, "VERSION"), "0.1.0-candidate.10\n");
  const result = backupShell(
    [
      'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
      "slabctl_volume_names() { echo agents_data; }",
      "slabctl_resolve_volume() { echo slab_agents_data; }",
      "slabctl_compose() { return 1; }",
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      "SLABCTL_PROJECT_NAME=slab",
      'slabctl_restore_archive "$3" 0 1',
    ].join("; "),
    [installation, archive],
  );
  assert.notEqual(result.status, 0);
  assert.match(
    result.stderr,
    /could not inspect running services before restore/,
  );
  assert.equal(
    fs.existsSync(path.join(installation, "config/restore-state.json")),
    false,
  );
});

test("restore stops services when post-restore health fails", (t) => {
  const { archive, directory } = backupFixture(t);
  const installation = path.join(directory, "installation");
  const operations = path.join(directory, "operations.txt");
  fs.mkdirSync(path.join(installation, "config"), { recursive: true });
  fs.mkdirSync(path.join(installation, "secrets"), { recursive: true });
  fs.writeFileSync(path.join(installation, "VERSION"), "0.1.0-candidate.10\n");
  const result = backupShell(
    [
      'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
      "slabctl_volume_names() { echo agents_data; }",
      "slabctl_resolve_volume() { echo slab_agents_data; }",
      "slabctl_backup_runtime_image() { echo fixture-image; }",
      'slabctl_compose() { [ "$1" = ps ] && return 0; }',
      'docker() { [ "$1" = run ]; }',
      'OPERATIONS="$4"',
      'slabctl_stack_start() { echo start >> "$OPERATIONS"; }',
      "slabctl_wait_for_healthy_stack() { return 1; }",
      'slabctl_stack_stop() { echo stop >> "$OPERATIONS"; }',
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      "SLABCTL_PROJECT_NAME=slab",
      'slabctl_restore_archive "$3" 0 1',
    ].join("; "),
    [installation, archive, operations],
  );
  assert.notEqual(result.status, 0);
  assert.equal(fs.existsSync(operations), true, result.stderr);
  assert.deepEqual(fs.readFileSync(operations, "utf8").trim().split("\n"), [
    "start",
    "stop",
  ]);
  const state = JSON.parse(
    fs.readFileSync(
      path.join(installation, "config/restore-state.json"),
      "utf8",
    ),
  );
  assert.equal(state.status, "RECOVERY_REQUIRED");
  assert.match(state.message, /stack is stopped/i);
});

test("successful restore clears maintenance restored from a pre-update backup", (t) => {
  const { archive, directory } = backupFixture(t);
  const installation = path.join(directory, "installation");
  const operations = path.join(directory, "operations.txt");
  fs.mkdirSync(path.join(installation, "config"), { recursive: true });
  fs.mkdirSync(path.join(installation, "secrets"), { recursive: true });
  fs.writeFileSync(path.join(installation, "VERSION"), "0.1.0-candidate.10\n");
  const result = backupShell(
    [
      'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
      "slabctl_volume_names() { echo agents_data; }",
      "slabctl_resolve_volume() { echo slab_agents_data; }",
      "slabctl_backup_runtime_image() { echo fixture-image; }",
      'slabctl_compose() { [ "$1" = ps ] && return 0; }',
      'docker() { [ "$1" = run ]; }',
      'OPERATIONS="$4"',
      'slabctl_stack_start() { echo start >> "$OPERATIONS"; }',
      "slabctl_wait_for_healthy_stack() { :; }",
      'slabctl_update_exit_maintenance() { echo maintenance-off >> "$OPERATIONS"; }',
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      "SLABCTL_PROJECT_NAME=slab",
      'slabctl_restore_archive "$3" 0 1',
    ].join("; "),
    [installation, archive, operations],
  );
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(fs.readFileSync(operations, "utf8").trim().split("\n"), [
    "start",
    "maintenance-off",
  ]);
  const state = JSON.parse(
    fs.readFileSync(
      path.join(installation, "config/restore-state.json"),
      "utf8",
    ),
  );
  assert.equal(state.status, "RESTORED");
  const backupState = JSON.parse(
    fs.readFileSync(path.join(installation, "config/backup-state.json"), "utf8"),
  );
  assert.equal(backupState.lastSuccessfulBackup.archive, archive);
  assert.match(backupState.lastSuccessfulBackup.sha256, /^[a-f0-9]{64}$/);
});

test("restore clears non-portable Gemini sessions before services start", (t) => {
  const { archive, directory } = backupFixture(t);
  const installation = path.join(directory, "installation");
  const operations = path.join(directory, "operations.txt");
  fs.mkdirSync(path.join(installation, "config"), { recursive: true });
  fs.mkdirSync(path.join(installation, "secrets"), { recursive: true });
  fs.writeFileSync(path.join(installation, "VERSION"), "0.1.0-candidate.10\n");
  const result = backupShell(
    [
      'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
      "slabctl_volume_names() { echo agents_data; }",
      "slabctl_resolve_volume() { echo slab_agents_data; }",
      "slabctl_backup_runtime_image() { echo fixture-image; }",
      'slabctl_compose() { [ "$1" = ps ] && return 0; }',
      'OPERATIONS="$4"',
      'docker() { case "$*" in *"UPDATE threads SET runtime_thread_id = NULL"*) echo clear-gemini-session >> "$OPERATIONS" ;; esac; [ "$1" = run ]; }',
      'slabctl_stack_start() { echo start >> "$OPERATIONS"; }',
      "slabctl_wait_for_healthy_stack() { :; }",
      "slabctl_update_exit_maintenance() { :; }",
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      "SLABCTL_PROJECT_NAME=slab",
      'slabctl_restore_archive "$3" 0 1',
    ].join("; "),
    [installation, archive, operations],
  );
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(fs.readFileSync(operations, "utf8").trim().split("\n"), [
    "clear-gemini-session",
    "start",
  ]);
});

test("v2 restore persists external providers that require host reauthentication", (t) => {
  const externalAuth = [
    {
      provider: "proton_bridge",
      configuredAccounts: 1,
      portability: "reauthentication_required",
    },
    {
      provider: "gemini",
      configuredAccounts: 1,
      portability: "reauthentication_required",
    },
  ];
  const { archive, directory } = backupFixture(t, {
    schemaVersion: 2,
    appliedMigrations: ["001.cjs"],
    externalAuth,
  });
  const installation = path.join(directory, "installation");
  fs.mkdirSync(path.join(installation, "config"), { recursive: true });
  fs.mkdirSync(path.join(installation, "secrets"), { recursive: true });
  fs.writeFileSync(path.join(installation, "VERSION"), "0.1.0-candidate.16\n");
  writeTargetRelease(installation, ["001.cjs"]);
  const result = backupShell(
    [
      'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
      "slabctl_volume_names() { echo agents_data; }",
      "slabctl_resolve_volume() { echo slab_agents_data; }",
      "slabctl_backup_runtime_image() { echo fixture-image; }",
      'slabctl_compose() { [ "$1" = ps ] && return 0; }',
      'docker() { [ "$1" = run ]; }',
      "slabctl_stack_start() { :; }",
      "slabctl_wait_for_healthy_stack() { :; }",
      "slabctl_update_exit_maintenance() { :; }",
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      "SLABCTL_PROJECT_NAME=slab",
      'slabctl_restore_archive "$3" 0 1',
    ].join("; "),
    [installation, archive],
  );
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /authenticate again on this host/);
  const state = JSON.parse(
    fs.readFileSync(path.join(installation, "config/restore-state.json"), "utf8"),
  );
  assert.deepEqual(state.reauthenticationRequired, externalAuth);
});

test("restore pauses dispatch when verified-backup state cannot be persisted", (t) => {
  const { archive, directory } = backupFixture(t);
  const installation = path.join(directory, "installation");
  const operations = path.join(directory, "operations.txt");
  fs.mkdirSync(path.join(installation, "config"), { recursive: true });
  fs.mkdirSync(path.join(installation, "secrets"), { recursive: true });
  fs.writeFileSync(path.join(installation, "VERSION"), "0.1.0-candidate.10\n");
  const result = backupShell(
    [
      'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
      "slabctl_volume_names() { echo agents_data; }",
      "slabctl_resolve_volume() { echo slab_agents_data; }",
      "slabctl_backup_runtime_image() { echo fixture-image; }",
      'slabctl_compose() { [ "$1" = ps ] && return 0; }',
      'docker() { [ "$1" = run ]; }',
      'OPERATIONS="$4"',
      'slabctl_stack_start() { echo start >> "$OPERATIONS"; }',
      "slabctl_wait_for_healthy_stack() { :; }",
      'slabctl_update_exit_maintenance() { echo maintenance-off >> "$OPERATIONS"; }',
      'slabctl_update_enter_maintenance() { echo maintenance-on >> "$OPERATIONS"; }',
      "slabctl_write_backup_state() { return 1; }",
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      "SLABCTL_PROJECT_NAME=slab",
      'slabctl_restore_archive "$3" 0 1',
    ].join("; "),
    [installation, archive, operations],
  );
  assert.notEqual(result.status, 0);
  assert.deepEqual(fs.readFileSync(operations, "utf8").trim().split("\n"), [
    "start",
    "maintenance-off",
    "maintenance-on",
  ]);
  const state = JSON.parse(
    fs.readFileSync(path.join(installation, "config/restore-state.json"), "utf8"),
  );
  assert.equal(state.status, "RECOVERY_REQUIRED");
  assert.match(state.message, /metadata could not be persisted/);
});

test("backup output is private from the first archive write", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-backup-mode-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const installation = path.join(directory, "install");
  const destination = path.join(directory, "output");
  fs.mkdirSync(path.join(installation, "config"), { recursive: true });
  fs.mkdirSync(path.join(installation, "secrets"), { recursive: true });
  fs.mkdirSync(destination);
  for (const name of [
    "release-manifest.json",
    "VERSION",
    "compose.yml",
    "compose.private.yml",
    "compose.domain.yml",
    "Caddyfile",
  ]) {
    fs.writeFileSync(
      path.join(installation, name),
      name === "release-manifest.json" ? '{"images":{}}\n' : "fixture\n",
    );
  }
  fs.writeFileSync(path.join(installation, "config/access-mode"), "private\n");
  fs.writeFileSync(path.join(installation, "config/install.env"), "A=1\n");
  fs.writeFileSync(
    path.join(installation, "config/install-state.json"),
    "{}\n",
  );
  fs.writeFileSync(path.join(installation, "secrets/session"), "secret\n");
  const modeFile = path.join(directory, "mode.txt");
  const result = backupShell(
    [
      'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      "SLABCTL_PROJECT_NAME=slab",
      'SLABCTL_MODE_FILE="$4"',
      'slabctl_compose() { [ "$1" != ps ] || return 0; }',
      "slabctl_volume_names() { :; }",
      "slabctl_backup_runtime_image() { echo unused; }",
      "slabctl_backup_verify() { :; }",
      "slabctl_write_backup_state() { :; }",
      "slabctl_stack_start() { :; }",
      'tar() { : > "$2"; stat -c "%a" "$2" > "$SLABCTL_MODE_FILE"; }',
      "umask 022",
      'slabctl_backup_create "$3"',
    ].join("; "),
    [installation, destination, modeFile],
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(modeFile, "utf8").trim(), "600");
});

test("backup refuses a live snapshot when service inspection fails", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-backup-ps-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const installation = path.join(directory, "install");
  const destination = path.join(directory, "backup.tar.gz");
  fs.mkdirSync(path.join(installation, "config"), { recursive: true });
  fs.mkdirSync(path.join(installation, "secrets"), { recursive: true });
  for (const name of [
    "release-manifest.json",
    "VERSION",
    "compose.yml",
    "compose.private.yml",
    "compose.domain.yml",
    "Caddyfile",
  ]) {
    fs.writeFileSync(
      path.join(installation, name),
      name === "release-manifest.json" ? '{"images":{}}\n' : "fixture\n",
    );
  }
  fs.writeFileSync(path.join(installation, "config/access-mode"), "private\n");
  fs.writeFileSync(path.join(installation, "config/install.env"), "A=1\n");
  fs.writeFileSync(
    path.join(installation, "config/install-state.json"),
    "{}\n",
  );
  fs.writeFileSync(path.join(installation, "secrets/session"), "secret\n");

  const result = backupShell(
    [
      'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      "SLABCTL_PROJECT_NAME=slab",
      "slabctl_compose() { return 1; }",
      'slabctl_backup_create "$3"',
    ].join("; "),
    [installation, destination],
  );
  assert.notEqual(result.status, 0);
  assert.match(
    result.stderr,
    /could not inspect running services before backup/,
  );
  assert.equal(fs.existsSync(destination), false);
});
