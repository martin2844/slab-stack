import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const prompts = path.join(root, "installer", "lib", "prompts.sh");
const config = path.join(root, "installer", "lib", "config.sh");

function run(script, environment = {}) {
  return spawnSync(
    "sh",
    ["-c", `. "$1"; . "$2"; ${script}`, "config", prompts, config],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        SLAB_CONFIG_OWNER_UID: String(process.getuid()),
        ...environment,
      },
    },
  );
}

test("loads and validates a declarative private installer config", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-config-"));
  const filename = path.join(directory, "install.conf");
  fs.writeFileSync(
    filename,
    [
      `SLAB_INSTALL_DIRECTORY=${directory}/installation`,
      "SLAB_ACCESS_MODE=private",
      "SLAB_PRIVATE_BIND_IP=127.0.0.1",
      "SLAB_PRIVATE_PORT=39009",
      "SLAB_COMPOSE_PROJECT_NAME=slab-test",
      "",
    ].join("\n"),
    { mode: 0o600 },
  );
  try {
    const direct = spawnSync(
      "sh",
      [
        "-c",
        'set -e; . "$1"; . "$2"; slab_load_noninteractive_config "$3"; slab_finalize_noninteractive_config; printf "%s|%s|%s" "$SLAB_PUBLIC_URL" "$SLAB_PRIVATE_PORT" "$SLAB_COMPOSE_PROJECT_NAME"',
        "config",
        prompts,
        config,
        filename,
      ],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          SLAB_CONFIG_OWNER_UID: String(process.getuid()),
          SLAB_CONFIG_TRUST_ROOT: directory,
          SLAB_INSTALL_OWNER_UID: String(process.getuid()),
          SLAB_INSTALL_TRUST_ROOT: directory,
        },
      },
    );
    assert.equal(direct.status, 0, direct.stderr);
    assert.equal(direct.stdout, "http://127.0.0.1:39009|39009|slab-test");
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("rejects unknown keys and group-readable config", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-config-bad-"));
  const filename = path.join(directory, "install.conf");
  try {
    fs.writeFileSync(filename, "SLAB_UNKNOWN=value\n", { mode: 0o600 });
    const testEnvironment = { SLAB_CONFIG_TRUST_ROOT: directory };
    const unknown = run(`slab_load_noninteractive_config "${filename}"`, testEnvironment);
    assert.notEqual(unknown.status, 0);
    assert.match(unknown.stderr, /Unknown installer config key/);

    fs.chmodSync(filename, 0o640);
    const exposed = run(`slab_load_noninteractive_config "${filename}"`, testEnvironment);
    assert.notEqual(exposed.status, 0);
    assert.match(exposed.stderr, /must use mode 0400 or 0600/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("reads a one-line private password file without printing it", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-password-"));
  const filename = path.join(directory, "password");
  fs.writeFileSync(filename, "not-a-real-secret-password\n", { mode: 0o600 });
  try {
    const testEnvironment = { SLAB_CONFIG_TRUST_ROOT: directory };
    const accepted = run(
      `slab_read_admin_password_file "${filename}"; printf '%s' "\${SLAB_ADMIN_PASSWORD:+loaded}"`,
      testEnvironment,
    );
    assert.equal(accepted.status, 0, accepted.stderr);
    assert.equal(accepted.stdout, "loaded");
    assert.doesNotMatch(accepted.stderr, /not-a-real-secret/);

    fs.writeFileSync(filename, "first-password-line\nsecond-line\n", {
      mode: 0o600,
    });
    const rejected = run(`slab_read_admin_password_file "${filename}"`, testEnvironment);
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.stderr, /exactly one line/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("rejects private files stored below a writable parent", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-config-parent-"));
  const writableParent = path.join(directory, "writable");
  const filename = path.join(writableParent, "install.conf");
  fs.mkdirSync(writableParent, { mode: 0o700 });
  fs.writeFileSync(filename, "SLAB_ACCESS_MODE=private\n", { mode: 0o600 });
  fs.chmodSync(writableParent, 0o777);
  try {
    const result = run(`slab_load_noninteractive_config "${filename}"`, {
      SLAB_CONFIG_TRUST_ROOT: directory,
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /cannot be group\/world writable/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
