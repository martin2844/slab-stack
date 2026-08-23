import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { DatabaseSync } from "node:sqlite";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

test("active-run drain query executes with SQLite strict identifier quoting", () => {
  const updateSource = fs.readFileSync(
    path.join(root, "installer/lib/update.sh"),
    "utf8",
  );
  const queryStart = updateSource.indexOf("`SELECT COUNT(*) AS count FROM runs");
  const queryEnd = updateSource.indexOf("`)", queryStart);
  assert.ok(queryStart >= 0 && queryEnd > queryStart, "active-run query must remain discoverable");
  const query = updateSource.slice(queryStart + 1, queryEnd);

  const database = new DatabaseSync(":memory:");
  database.exec(`CREATE TABLE runs (
    status TEXT NOT NULL,
    lease_owner TEXT,
    lease_expires_at TEXT
  )`);
  database.prepare(
    "INSERT INTO runs (status, lease_owner, lease_expires_at) VALUES (?, ?, ?)",
  ).run("running", null, null);
  database.prepare(
    "INSERT INTO runs (status, lease_owner, lease_expires_at) VALUES (?, ?, ?)",
  ).run("queued", "worker", "2099-01-01T00:00:00.000Z");
  database.prepare(
    "INSERT INTO runs (status, lease_owner, lease_expires_at) VALUES (?, ?, ?)",
  ).run("completed", null, null);

  assert.equal(
    database
      .prepare(query)
      .get(
        "running",
        "waiting_approval",
        "queued",
        "2026-08-23T00:00:00.000Z",
      ).count,
    2,
  );
});

function command(commandName, args, options = {}) {
  return spawnSync(commandName, args, { encoding: "utf8", ...options });
}

function sha256(filename) {
  return crypto
    .createHash("sha256")
    .update(fs.readFileSync(filename))
    .digest("hex");
}

const recoveryFiles = [
  "compose.yml",
  "compose.private.yml",
  "compose.domain.yml",
  "Caddyfile",
  "release-manifest.json",
  "VERSION",
  "config/install.env",
  "config/access-mode",
  "config/install-state.json",
];

function recoveryContents(install) {
  return Object.fromEntries(
    recoveryFiles.map((relative) => [
      relative,
      fs.readFileSync(path.join(install, relative), "utf8"),
    ]),
  );
}

function signedRelease(t) {
  const directory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-release-client-"),
  );
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const version = "0.1.0-candidate.10";
  const channels = path.join(directory, "channels");
  const releases = path.join(directory, "releases");
  const releaseDirectory = path.join(releases, `v${version}`);
  const staging = path.join(directory, "staging");
  const bundleRoot = `slab-stack-${version}`;
  const bundle = path.join(staging, bundleRoot);
  const privateKey = path.join(directory, "private.pem");
  const publicKey = path.join(directory, "public.pem");
  const publicDer = path.join(directory, "public.der");
  fs.mkdirSync(path.join(bundle, "releases"), { recursive: true });
  fs.mkdirSync(channels, { recursive: true });
  fs.mkdirSync(releaseDirectory, { recursive: true });
  const manifest = path.join(bundle, "releases", `v${version}.json`);
  fs.writeFileSync(
    manifest,
    `${JSON.stringify({
      schemaVersion: 1,
      stackVersion: version,
      channel: "candidate",
      minimumSlabctlVersion: "0.1.0-candidate.9",
      migrationCompatibility: {
        minimumUpgradeStack: "0.1.0-candidate.1",
        minimumRollbackStack: "0.1.0-candidate.4",
      },
    })}\n`,
  );
  assert.equal(
    command("openssl", ["genpkey", "-algorithm", "ED25519", "-out", privateKey])
      .status,
    0,
  );
  assert.equal(
    command("openssl", [
      "pkey",
      "-in",
      privateKey,
      "-pubout",
      "-out",
      publicKey,
    ]).status,
    0,
  );
  assert.equal(
    command("openssl", [
      "pkey",
      "-pubin",
      "-in",
      publicKey,
      "-outform",
      "DER",
      "-out",
      publicDer,
    ]).status,
    0,
  );
  const archiveName = `${bundleRoot}.tar.gz`;
  const archive = path.join(releaseDirectory, archiveName);
  assert.equal(
    command("tar", ["-czf", archive, "-C", staging, bundleRoot]).status,
    0,
  );
  const checksum = `${archive}.sha256`;
  fs.writeFileSync(checksum, `${sha256(archive)}  ${archiveName}\n`);
  assert.equal(
    command("openssl", [
      "pkeyutl",
      "-sign",
      "-rawin",
      "-inkey",
      privateKey,
      "-in",
      checksum,
      "-out",
      `${checksum}.sig`,
    ]).status,
    0,
  );
  const channel = path.join(channels, "candidate.json");
  fs.writeFileSync(
    channel,
    `${JSON.stringify({
      schemaVersion: 1,
      channel: "candidate",
      stackVersion: version,
      manifestUrl: `https://example.invalid/v${version}.json`,
      manifestSha256: sha256(manifest),
    })}\n`,
  );
  assert.equal(
    command("openssl", [
      "pkeyutl",
      "-sign",
      "-rawin",
      "-inkey",
      privateKey,
      "-in",
      channel,
      "-out",
      `${channel}.sig`,
    ]).status,
    0,
  );
  const client = path.join(directory, "release-client.sh");
  const fingerprint = sha256(publicDer);
  fs.writeFileSync(
    client,
    fs
      .readFileSync(path.join(root, "installer/lib/release-client.sh"), "utf8")
      .replace(
        "2865983ef11b8070415642e0ebdcde17468f48392ee517a63f991f29e80c5293",
        fingerprint,
      ),
  );
  return { channel, channels, client, publicKey, releases, version };
}

function prepareRelease(fixture) {
  return command(
    "sh",
    [
      "-c",
      'set -e; . "$1"; slabctl_error() { echo "slabctl: $*" >&2; return 1; }; slabctl_validate_managed_file() { return 0; }; slabctl_release_prepare candidate "$2"; printf "%s|%s|%s\\n" "$SLAB_RELEASE_VERSION" "$SLAB_RELEASE_BUNDLE_ROOT" "$SLAB_RELEASE_MANIFEST"; slabctl_release_cleanup',
      "release-client-test",
      fixture.client,
      fixture.publicKey,
    ],
    {
      env: {
        ...process.env,
        SLAB_RELEASE_ALLOW_INSECURE_TEST_SOURCE: "1",
        SLAB_RELEASE_CHANNEL_BASE_URL: pathToFileURL(fixture.channels).href,
        SLAB_RELEASE_BUNDLE_BASE_URL: pathToFileURL(fixture.releases).href,
      },
    },
  );
}

test("release client accepts only a channel and bundle under the reviewed signature", (t) => {
  const fixture = signedRelease(t);
  const result = prepareRelease(fixture);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, new RegExp(`^${fixture.version}\\|`));

  const metadata = JSON.parse(fs.readFileSync(fixture.channel, "utf8"));
  metadata.stackVersion = "0.1.0-candidate.11";
  fs.writeFileSync(fixture.channel, `${JSON.stringify(metadata)}\n`);
  const tampered = prepareRelease(fixture);
  assert.notEqual(tampered.status, 0);
  assert.match(tampered.stderr, /channel signature verification failed/);
});

function updateFixture(
  t,
  {
    failHealthOnce = false,
    failHealthAlways = false,
    failMaintenanceOff = false,
    failManagementInstall = false,
    killManagementInstall = false,
    rollbackCompatible = true,
  } = {},
) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-update-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const install = path.join(directory, "install");
  const config = path.join(install, "config");
  const bundle = path.join(directory, "bundle");
  fs.mkdirSync(config, { recursive: true });
  fs.mkdirSync(path.join(bundle, "installer/lib"), { recursive: true });
  for (const relative of [
    "compose.yml",
    "compose.private.yml",
    "compose.domain.yml",
    "Caddyfile",
    "release-manifest.json",
  ]) {
    fs.writeFileSync(path.join(install, relative), `${relative}-old\n`);
  }
  fs.writeFileSync(path.join(install, "VERSION"), "0.1.0-candidate.9\n");
  fs.writeFileSync(
    path.join(config, "install.env"),
    "SLAB_PRIVATE_BIND_IP=127.0.0.1\nSLAB_PRIVATE_PORT=3009\nSLAB_DOMAIN=\nACME_EMAIL=\n",
  );
  fs.writeFileSync(path.join(config, "access-mode"), "private\n");
  fs.writeFileSync(
    path.join(config, "install-state.json"),
    `${JSON.stringify({
      version: "0.1.0-candidate.9",
      status: "READY",
      accessMode: "private",
      publicUrl: "http://127.0.0.1:3009",
      projectName: "slab",
    })}\n`,
  );
  const manifest = path.join(directory, "target.json");
  fs.writeFileSync(
    manifest,
    `${JSON.stringify({
      minimumSlabctlVersion: "0.1.0-candidate.10",
      migrationCompatibility: {
        minimumUpgradeStack: "0.1.0-candidate.1",
        minimumRollbackStack: rollbackCompatible
          ? "0.1.0-candidate.4"
          : "0.2.0",
      },
    })}\n`,
  );
  const script = `
set -eu
slabctl_error() { echo "slabctl: $*" >&2; return 1; }
slabctl_release_cleanup() { :; }
. "$1"
SLABCTL_INSTALL_DIRECTORY="$2"
SLABCTL_STATE_FILE="$2/config/install-state.json"
SLABCTL_ACCESS_MODE=private
SLABCTL_ENVIRONMENT_FILE="$2/config/install.env"
SLABCTL_UPDATE_BACKUP_DIRECTORY="$3"
SLABCTL_MANAGER_VERSION=0.1.0-candidate.10
release_public_key_file="$2/public.pem"
SLAB_RELEASE_VERSION=0.1.0-candidate.10
SLAB_RELEASE_BUNDLE_ROOT="$4"
SLAB_RELEASE_MANIFEST="$5"
COMPOSE_CALLS="$6"
OPERATION_LOG="$7"
slabctl_release_prepare() { :; }
slabctl_update_agents_database() {
  printf 'agents:%s\n' "$1" >> "$OPERATION_LOG"
  ${failMaintenanceOff ? '[ "$1" != maintenance-off ] || return 1' : ":"}
  [ "$1" = active-count ] && printf 0 || :
}
slabctl_backup_create() { mkdir -p "$(dirname -- "$1")"; : > "$1"; }
slabctl_update_render_release() {
  for relative in compose.yml compose.private.yml compose.domain.yml Caddyfile release-manifest.json config/install.env config/access-mode; do
    printf 'target-release:%s\\n' "$relative" > "$SLABCTL_INSTALL_DIRECTORY/$relative"
  done
}
slabctl_compose() { printf '%s\n' "$*" >> "$COMPOSE_CALLS"; }
health_calls=0
slabctl_wait_for_healthy_stack() {
  health_calls=$((health_calls + 1))
  ${failHealthAlways ? "false" : failHealthOnce ? '[ "$health_calls" -gt 1 ]' : ":"}
}
slabctl_update_functional_smoke() { :; }
slabctl_update_install_management() {
  printf 'management:install\n' >> "$OPERATION_LOG"
  ${killManagementInstall ? "sh -c 'kill -KILL \"$PPID\"'" : ":"}
  ${failManagementInstall ? "return 1" : ":"}
}
slabctl_update_apply candidate 1
`;
  return {
    args: [
      "-c",
      script,
      "update-test",
      path.join(root, "installer/lib/update.sh"),
      install,
      path.join(directory, "backups"),
      bundle,
      manifest,
      path.join(directory, "compose-calls.txt"),
      path.join(directory, "operations.txt"),
    ],
    install,
    composeCalls: path.join(directory, "compose-calls.txt"),
    operations: path.join(directory, "operations.txt"),
  };
}

test("update apply records backup, release identity, and terminal success", (t) => {
  const fixture = updateFixture(t);
  const result = command("sh", fixture.args);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(
    fs.readFileSync(path.join(fixture.install, "VERSION"), "utf8").trim(),
    "0.1.0-candidate.10",
  );
  const state = JSON.parse(
    fs.readFileSync(
      path.join(fixture.install, "config/update-state.json"),
      "utf8",
    ),
  );
  assert.equal(state.status, "UPDATED");
  assert.equal(state.fromVersion, "0.1.0-candidate.9");
  assert.equal(state.toVersion, "0.1.0-candidate.10");
  assert.equal(state.rollbackCompatible, true);
  assert.equal(fs.existsSync(state.backupPath), true);
  const operations = fs.readFileSync(fixture.operations, "utf8");
  assert.ok(
    operations.indexOf("management:install") <
      operations.lastIndexOf("agents:maintenance-off"),
    operations,
  );
});

test("early update phases persist null artifacts instead of an empty ledger", (t) => {
  const directory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-update-state-"),
  );
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  fs.mkdirSync(path.join(directory, "config"), { recursive: true });
  const script = `
set -eu
. "$1"
SLABCTL_INSTALL_DIRECTORY="$2"
slabctl_update_write_state DRAINING 0.1.0 0.2.0 stable "Waiting" "" "" false
`;
  const result = command("sh", [
    "-c",
    script,
    "update-state-test",
    path.join(root, "installer/lib/update.sh"),
    directory,
  ]);
  assert.equal(result.status, 0, result.stderr);
  const state = JSON.parse(
    fs.readFileSync(path.join(directory, "config/update-state.json"), "utf8"),
  );
  assert.equal(state.status, "DRAINING");
  assert.equal(state.backupPath, null);
  assert.equal(state.recoveryDirectory, null);
});

test("failed compatible update restores the prior release and remains auditable", (t) => {
  const fixture = updateFixture(t, { failHealthOnce: true });
  const before = recoveryContents(fixture.install);
  const result = command("sh", fixture.args);
  assert.notEqual(result.status, 0);
  assert.deepEqual(recoveryContents(fixture.install), before);
  const state = JSON.parse(
    fs.readFileSync(
      path.join(fixture.install, "config/update-state.json"),
      "utf8",
    ),
  );
  assert.equal(state.status, "ROLLED_BACK");
  assert.equal(state.fromVersion, "0.1.0-candidate.10");
  assert.equal(state.toVersion, "0.1.0-candidate.9");
  assert.match(result.stderr, /Previous release restored successfully/);
});

test("management replacement failure restores every managed release file", (t) => {
  const fixture = updateFixture(t, { failManagementInstall: true });
  const before = recoveryContents(fixture.install);
  const result = command("sh", fixture.args);
  assert.notEqual(result.status, 0);
  assert.deepEqual(recoveryContents(fixture.install), before);
  const state = JSON.parse(
    fs.readFileSync(
      path.join(fixture.install, "config/update-state.json"),
      "utf8",
    ),
  );
  assert.equal(state.status, "ROLLED_BACK");
});

test("installed identity is not advanced before management replacement commits", (t) => {
  const fixture = updateFixture(t, { killManagementInstall: true });
  const result = command("sh", fixture.args);
  assert.ok(
    result.signal === "SIGKILL" || result.status === 137,
    `expected abrupt SIGKILL, got status=${result.status} signal=${result.signal}`,
  );
  assert.equal(
    fs.readFileSync(path.join(fixture.install, "VERSION"), "utf8").trim(),
    "0.1.0-candidate.9",
  );
  const state = JSON.parse(
    fs.readFileSync(
      path.join(fixture.install, "config/update-state.json"),
      "utf8",
    ),
  );
  assert.equal(state.status, "APPLYING");
});

test("automatic rollback does not claim recovery while maintenance remains enabled", (t) => {
  const fixture = updateFixture(t, {
    failHealthOnce: true,
    failMaintenanceOff: true,
  });
  const result = command("sh", fixture.args);
  assert.notEqual(result.status, 0);
  const state = JSON.parse(
    fs.readFileSync(
      path.join(fixture.install, "config/update-state.json"),
      "utf8",
    ),
  );
  assert.equal(state.status, "RECOVERY_REQUIRED");
  assert.match(state.message, /maintenance mode/i);
  assert.doesNotMatch(result.stderr, /Previous release restored successfully/);
  assert.match(result.stderr, /agent dispatch remains in maintenance mode/);

  const recovery = command("sh", [
    "-c",
    [
      'set -eu; . "$1"',
      'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      "slabctl_compose() { :; }",
      "slabctl_wait_for_healthy_stack() { :; }",
      "slabctl_update_functional_smoke() { :; }",
      'slabctl_update_agents_database() { [ "$1" = maintenance-off ]; }',
      "slabctl_update_recover_maintenance",
    ].join("; "),
    "maintenance-recovery-test",
    path.join(root, "installer/lib/update.sh"),
    fixture.install,
  ]);
  assert.equal(recovery.status, 0, recovery.stderr);
  const recoveredState = JSON.parse(
    fs.readFileSync(
      path.join(fixture.install, "config/update-state.json"),
      "utf8",
    ),
  );
  assert.equal(recoveredState.status, "ROLLED_BACK");
  assert.match(recovery.stdout, /maintenance cleared/);
});

test("an interrupted APPLYING state can be reconciled against the installed release", (t) => {
  const fixture = updateFixture(t);
  fs.writeFileSync(
    path.join(fixture.install, "VERSION"),
    "0.1.0-candidate.9\n",
  );
  fs.writeFileSync(
    path.join(fixture.install, "release-manifest.json"),
    `${JSON.stringify({ stackVersion: "0.1.0-candidate.10" })}\n`,
  );
  fs.writeFileSync(
    path.join(fixture.install, "config/update-state.json"),
    `${JSON.stringify({
      schemaVersion: 1,
      status: "APPLYING",
      fromVersion: "0.1.0-candidate.9",
      toVersion: "0.1.0-candidate.10",
      channel: "candidate",
      message: "Installing management files.",
      backupPath: "/var/backups/slab/pre-update.tar.gz",
      recoveryDirectory: "/var/lib/slab/config/update-recovery/previous",
      rollbackCompatible: true,
    })}\n`,
  );
  const operations = path.join(
    path.dirname(fixture.install),
    "recovery-operations.txt",
  );
  const recovery = command("sh", [
    "-c",
    [
      'set -eu; . "$1"',
      'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
      'SLABCTL_INSTALL_DIRECTORY="$2"',
      'SLABCTL_STATE_FILE="$2/config/install-state.json"',
      'OPERATIONS="$3"',
      "slabctl_compose() { :; }",
      "slabctl_wait_for_healthy_stack() { :; }",
      "slabctl_update_functional_smoke() { :; }",
      'slabctl_update_agents_database() { printf "%s\\n" "$1" >> "$OPERATIONS"; }',
      "slabctl_update_recover_maintenance",
    ].join("; "),
    "interrupted-applying-recovery-test",
    path.join(root, "installer/lib/update.sh"),
    fixture.install,
    operations,
  ]);
  assert.equal(recovery.status, 0, recovery.stderr);
  const recoveredState = JSON.parse(
    fs.readFileSync(
      path.join(fixture.install, "config/update-state.json"),
      "utf8",
    ),
  );
  assert.equal(recoveredState.status, "UPDATED");
  assert.match(recoveredState.message, /interrupted update/i);
  assert.equal(
    fs.readFileSync(path.join(fixture.install, "VERSION"), "utf8").trim(),
    "0.1.0-candidate.10",
  );
  assert.equal(fs.readFileSync(operations, "utf8").trim(), "maintenance-off");
});

for (const terminalCase of [
  {
    status: "UPDATED",
    installed: "0.1.0-candidate.10",
    expected: "UPDATED",
  },
  {
    status: "ROLLED_BACK",
    installed: "0.1.0-candidate.9",
    expected: "ROLLED_BACK",
    fromVersion: "0.1.0-candidate.10",
    toVersion: "0.1.0-candidate.9",
  },
]) {
  test(`terminal ${terminalCase.status} state can clear maintenance after process death`, (t) => {
    const fixture = updateFixture(t);
    const fromVersion = terminalCase.fromVersion ?? "0.1.0-candidate.9";
    const toVersion = terminalCase.toVersion ?? "0.1.0-candidate.10";
    fs.writeFileSync(
      path.join(fixture.install, "VERSION"),
      `${terminalCase.installed}\n`,
    );
    fs.writeFileSync(
      path.join(fixture.install, "config/update-state.json"),
      `${JSON.stringify({
        schemaVersion: 1,
        status: terminalCase.status,
        fromVersion,
        toVersion,
        channel: "candidate",
        message: "Terminal ledger persisted before maintenance clear.",
        backupPath: "/var/backups/slab/pre-update.tar.gz",
        recoveryDirectory: "/var/lib/slab/config/update-recovery/previous",
        rollbackCompatible: true,
      })}\n`,
    );
    const operations = path.join(
      path.dirname(fixture.install),
      `recover-${terminalCase.status}.txt`,
    );
    const recovery = command("sh", [
      "-c",
      [
        'set -eu; . "$1"',
        'slabctl_error() { echo "slabctl: $*" >&2; return 1; }',
        'SLABCTL_INSTALL_DIRECTORY="$2"',
        'OPERATIONS="$3"',
        "slabctl_compose() { :; }",
        "slabctl_wait_for_healthy_stack() { :; }",
        "slabctl_update_functional_smoke() { :; }",
        'slabctl_update_agents_database() { printf "%s\\n" "$1" >> "$OPERATIONS"; }',
        "slabctl_update_recover_maintenance",
      ].join("; "),
      "terminal-maintenance-recovery-test",
      path.join(root, "installer/lib/update.sh"),
      fixture.install,
      operations,
    ]);
    assert.equal(recovery.status, 0, recovery.stderr);
    const recoveredState = JSON.parse(
      fs.readFileSync(
        path.join(fixture.install, "config/update-state.json"),
        "utf8",
      ),
    );
    assert.equal(recoveredState.status, terminalCase.expected);
    assert.equal(fs.readFileSync(operations, "utf8").trim(), "maintenance-off");
  });
}

test("SemVer precedence treats a stable release as newer than its prerelease", () => {
  const script = [
    '. "$1"',
    "slabctl_update_version_at_least 1.0.0 1.0.0-candidate.1",
    "! slabctl_update_version_at_least 1.0.0-candidate.1 1.0.0",
    "slabctl_update_version_at_least 0.1.0-candidate.10 0.1.0-candidate.9",
  ].join("; ");
  const result = command("sh", [
    "-c",
    script,
    "semver-test",
    path.join(root, "installer/lib/update.sh"),
  ]);
  assert.equal(result.status, 0, result.stderr);
});

test("recovery-required update failures stop the mutated stack", (t) => {
  const fixture = updateFixture(t, {
    failHealthAlways: true,
    rollbackCompatible: false,
  });
  const result = command("sh", fixture.args);
  assert.notEqual(result.status, 0);
  const state = JSON.parse(
    fs.readFileSync(
      path.join(fixture.install, "config/update-state.json"),
      "utf8",
    ),
  );
  assert.equal(state.status, "RECOVERY_REQUIRED");
  assert.match(state.message, /stack is stopped/i);
  assert.match(fs.readFileSync(fixture.composeCalls, "utf8"), /^stop$/m);
});

test("failed automatic rollback also stops the stack before recovery", (t) => {
  const fixture = updateFixture(t, { failHealthAlways: true });
  const result = command("sh", fixture.args);
  assert.notEqual(result.status, 0);
  const state = JSON.parse(
    fs.readFileSync(
      path.join(fixture.install, "config/update-state.json"),
      "utf8",
    ),
  );
  assert.equal(state.status, "RECOVERY_REQUIRED");
  assert.match(state.message, /stack is stopped/i);
  assert.match(fs.readFileSync(fixture.composeCalls, "utf8"), /^stop$/m);
});

test("an unresolved recovery state blocks another update attempt", () => {
  const directory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-update-blocked-"),
  );
  try {
    fs.mkdirSync(path.join(directory, "config"), { recursive: true });
    fs.writeFileSync(
      path.join(directory, "config/update-state.json"),
      '{"status":"RECOVERY_REQUIRED"}\n',
    );
    const result = command("sh", [
      "-c",
      '. "$1"; slabctl_error() { echo "$*" >&2; return 1; }; SLABCTL_INSTALL_DIRECTORY="$2"; slabctl_update_assert_recoverable_state',
      "recovery-gate-test",
      path.join(root, "installer/lib/update.sh"),
      directory,
    ]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /requires recovery/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("maintenance drain includes queued runs that already hold a lease", () => {
  const source = fs.readFileSync(
    path.join(root, "installer/lib/update.sh"),
    "utf8",
  );
  assert.match(
    source,
    /status=\? AND lease_owner IS NOT NULL AND lease_expires_at > \?/,
  );
});
