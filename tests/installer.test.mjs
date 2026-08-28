import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const installer = path.join(root, "installer", "install.sh");

function createFixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-installer-"));
  const binaries = path.join(directory, "bin");
  const installDirectory = path.join(directory, "installation");
  const config = path.join(directory, "install.conf");
  const password = path.join(directory, "admin-password");
  const osRelease = path.join(directory, "os-release");
  fs.mkdirSync(binaries);
  fs.writeFileSync(
    path.join(binaries, "docker"),
    `#!/bin/sh
case "$*" in
  info|"compose version") exit 0 ;;
  *) echo "unexpected Docker command: $*" >&2; exit 91 ;;
esac
`,
    { mode: 0o755 },
  );
  fs.writeFileSync(osRelease, 'ID=ubuntu\nVERSION_ID="24.04"\n');
  fs.writeFileSync(
    config,
    [
      `SLAB_INSTALL_DIRECTORY=${installDirectory}`,
      "SLAB_ACCESS_MODE=private",
      "SLAB_PRIVATE_PORT=39209",
      "SLAB_COMPOSE_PROJECT_NAME=slab-dry-run",
      `SLAB_ADMIN_PASSWORD_FILE=${password}`,
      "",
    ].join("\n"),
    { mode: 0o600 },
  );
  fs.writeFileSync(password, "test-only-administrator-password\n", {
    mode: 0o600,
  });
  return {
    directory,
    binaries,
    installDirectory,
    config,
    password,
    osRelease,
  };
}

function run(fixture, argumentsList = ["--dry-run"]) {
  return spawnSync(
    installer,
    ["--non-interactive", "--config", fixture.config, ...argumentsList],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${fixture.binaries}:${process.env.PATH}`,
        SLAB_PREFLIGHT_UID: "0",
        SLAB_CONFIG_OWNER_UID: String(process.getuid()),
        SLAB_CONFIG_TRUST_ROOT: fixture.directory,
        SLAB_INSTALL_OWNER_UID: String(process.getuid()),
        SLAB_INSTALL_TRUST_ROOT: fixture.directory,
        SLAB_LOCK_OWNER_UID: String(process.getuid()),
        SLAB_LOCK_ROOT: path.join(fixture.directory, "locks"),
        SLAB_LOCK_TRUST_ROOT: fixture.directory,
        SLAB_HOST_LOCK_FILE: path.join(fixture.directory, "host-bootstrap.lock"),
        SLAB_MANAGEMENT_HOST_ROOT: path.join(fixture.directory, "host"),
        SLAB_MANAGEMENT_OWNER_UID: String(process.getuid()),
        SLAB_MANAGEMENT_TRUST_ROOT: fixture.directory,
        SLAB_OS_RELEASE_FILE: fixture.osRelease,
      },
    },
  );
}

test("non-interactive dry-run validates inputs without writing installation data", () => {
  const fixture = createFixture();
  try {
    const result = run(fixture);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Slab self-hosted setup/);
    assert.match(result.stdout, /Installation plan/);
    assert.match(result.stdout, /Reuse the installed Docker Engine and Compose V2/);
    assert.match(result.stdout, /automatic after a server reboot/);
    assert.match(result.stdout, /private mode/);
    assert.match(result.stdout, /Dry run complete/);
    assert.doesNotMatch(result.stdout, /\u001b\[/);
    assert.equal(fs.existsSync(fixture.installDirectory), false);
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});

test("dry-run explains that Docker will be provisioned when it is unavailable", () => {
  const fixture = createFixture();
  fs.writeFileSync(
    path.join(fixture.binaries, "docker"),
    "#!/bin/sh\nexit 1\n",
    { mode: 0o755 },
  );
  try {
    const result = run(fixture);
    assert.equal(result.status, 0, result.stderr);
    assert.match(
      result.stdout,
      /Install Docker CE, containerd, Buildx, and Compose V2 from Docker's official apt repository/,
    );
    assert.match(
      result.stdout,
      /Docker Engine and Compose V2 would be installed from Docker's official apt repository/,
    );
    assert.equal(fs.existsSync(fixture.installDirectory), false);
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});

test("a failed Compose pull reports sanitized status and preserves generated state", () => {
  const fixture = createFixture();
  fs.writeFileSync(
    path.join(fixture.binaries, "docker"),
    `#!/bin/sh
case "$*" in
  info|"compose version") exit 0 ;;
  *" config --quiet") exit 0 ;;
  *" pull") echo "simulated image pull failure" >&2; exit 92 ;;
  *" ps") echo "no services started" ; exit 0 ;;
  *) echo "unexpected Docker command: $*" >&2; exit 91 ;;
esac
`,
    { mode: 0o755 },
  );
  try {
    const result = run(fixture, []);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Installation did not reach readiness/);
    assert.match(result.stderr, /No application data or generated secrets were deleted/);
    assert.doesNotMatch(
      result.stdout + result.stderr,
      /test-only-administrator-password/,
    );
    assert.equal(
      fs.existsSync(path.join(fixture.installDirectory, "secrets", "session-secret")),
      true,
    );
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});

test("refuses an unknown non-empty target and a mismatched installed version", () => {
  const fixture = createFixture();
  try {
    fs.mkdirSync(fixture.installDirectory);
    fs.writeFileSync(path.join(fixture.installDirectory, "unknown"), "data");
    const unknown = run(fixture);
    assert.notEqual(unknown.status, 0);
    assert.match(unknown.stderr, /not empty and has no Slab VERSION marker/);

    fs.rmSync(path.join(fixture.installDirectory, "unknown"));
    fs.writeFileSync(path.join(fixture.installDirectory, "VERSION"), "9.9.9\n");
    const mismatch = run(fixture);
    assert.notEqual(mismatch.status, 0);
    assert.match(mismatch.stderr, /already installed/);
    assert.match(mismatch.stderr, /slabctl update/);
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});

test("rejects a rerun that changes the persisted Compose project identity", () => {
  const fixture = createFixture();
  try {
    fs.mkdirSync(path.join(fixture.installDirectory, "config"), { recursive: true });
    fs.writeFileSync(path.join(fixture.installDirectory, "VERSION"), "0.1.2-candidate.40\n");
    fs.writeFileSync(
      path.join(fixture.installDirectory, "config", "install-state.json"),
      JSON.stringify({
        version: "0.1.2-candidate.40",
        accessMode: "private",
        publicUrl: "http://127.0.0.1:39209",
        projectName: "slab-original",
        status: "READY_NO_RUNTIME",
      }),
      { mode: 0o600 },
    );
    const result = run(fixture);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /identity differs from the existing installation/);
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});

test("a failed rerun records failure while preserving the last-known-good identity", () => {
  const fixture = createFixture();
  fs.writeFileSync(
    path.join(fixture.binaries, "docker"),
    `#!/bin/sh
case "$*" in
  info|"compose version") exit 0 ;;
  *" config --quiet") exit 0 ;;
  *" pull") echo "simulated rerun failure token=must-not-leak" >&2; exit 92 ;;
  *" ps") echo "no services started"; exit 0 ;;
  *) echo "unexpected Docker command: $*" >&2; exit 91 ;;
esac
`,
    { mode: 0o755 },
  );
  try {
    fs.mkdirSync(path.join(fixture.installDirectory, "config"), { recursive: true });
    fs.writeFileSync(path.join(fixture.installDirectory, "VERSION"), "0.1.2-candidate.40\n");
    fs.writeFileSync(
      path.join(fixture.installDirectory, "config", "install-state.json"),
      JSON.stringify({
        version: "0.1.2-candidate.40",
        accessMode: "private",
        publicUrl: "http://127.0.0.1:39209",
        projectName: "slab-dry-run",
        status: "READY_NO_RUNTIME",
        updatedAt: "2026-08-20T09:00:00Z",
      }),
      { mode: 0o600 },
    );
    const result = run(fixture, []);
    assert.notEqual(result.status, 0);
    const state = JSON.parse(
      fs.readFileSync(path.join(fixture.installDirectory, "config", "install-state.json"), "utf8"),
    );
    assert.equal(state.status, "FAILED");
    assert.equal(state.lastKnownGood.status, "READY_NO_RUNTIME");
    assert.equal(state.lastKnownGood.projectName, "slab-dry-run");
    assert.doesNotMatch(result.stdout + result.stderr, /must-not-leak/);
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});
