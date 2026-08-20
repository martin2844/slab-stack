import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helper = path.join(root, "installer", "lib", "prompts.sh");

function run(functionCall, environment = {}) {
  return spawnSync("sh", ["-c", `. "$1"; ${functionCall}`, "prompts", helper], {
    encoding: "utf8",
    env: { ...process.env, ...environment },
  });
}

test("accepts scoped absolute installation directories under a trusted root", () => {
  const trustedRoot = fs.mkdtempSync(path.join(os.tmpdir(), "slab-prompt-accepted-"));
  const environment = {
    SLAB_INSTALL_OWNER_UID: String(process.getuid()),
    SLAB_INSTALL_TRUST_ROOT: trustedRoot,
  };
  try {
    for (const directory of ["slab", "nested/slab", "data/slab-stack"]) {
      const target = path.join(trustedRoot, directory);
      const result = run(`slab_validate_install_directory ${target}`, environment);
      assert.equal(result.status, 0, `${target}: ${result.stderr}`);
    }
  } finally {
    fs.rmSync(trustedRoot, { recursive: true, force: true });
  }
});

test("rejects relative, traversing, broad, and aliased installation targets", () => {
  for (const directory of [
    "slab",
    "/",
    "/opt",
    "/opt/../etc/slab",
    "/opt//slab",
    "/opt/slab/",
  ]) {
    const result = run(`slab_validate_install_directory ${directory}`);
    assert.notEqual(result.status, 0, directory);
  }
});

test("rejects symbolic-link and non-directory installation targets", () => {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-prompt-target-"),
  );
  const linked = path.join(temporaryDirectory, "linked");
  const file = path.join(temporaryDirectory, "file");
  fs.symlinkSync(path.join(temporaryDirectory, "destination"), linked);
  fs.writeFileSync(file, "not a directory");
  try {
    const environment = {
      SLAB_INSTALL_OWNER_UID: String(process.getuid()),
      SLAB_INSTALL_TRUST_ROOT: temporaryDirectory,
    };
    assert.notEqual(run(`slab_validate_install_directory ${linked}`, environment).status, 0);
    assert.notEqual(run(`slab_validate_install_directory ${file}`, environment).status, 0);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("rejects symlinked ancestors and writable installation parents", () => {
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-prompt-trust-"));
  const realParent = path.join(temporaryDirectory, "real");
  const linkedParent = path.join(temporaryDirectory, "linked");
  fs.mkdirSync(realParent);
  fs.symlinkSync(realParent, linkedParent);
  const environment = {
    SLAB_INSTALL_OWNER_UID: String(process.getuid()),
    SLAB_INSTALL_TRUST_ROOT: temporaryDirectory,
  };
  try {
    assert.notEqual(
      run(`slab_validate_install_directory ${linkedParent}/slab`, environment).status,
      0,
    );
    fs.chmodSync(realParent, 0o775);
    assert.notEqual(
      run(`slab_validate_install_directory ${realParent}/slab`, environment).status,
      0,
    );
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("validates access mode, domain, and optional ACME email", () => {
  assert.equal(run("slab_validate_access_mode private").status, 0);
  assert.equal(run("slab_validate_access_mode domain").status, 0);
  assert.notEqual(run("slab_validate_access_mode public-http").status, 0);

  assert.equal(run("slab_validate_domain agents.example.com").status, 0);
  assert.notEqual(run("slab_validate_domain https://agents.example.com").status, 0);
  assert.notEqual(run("slab_validate_domain localhost").status, 0);

  assert.equal(run("slab_validate_email ops@example.com").status, 0);
  assert.equal(run("slab_validate_email ''").status, 0);
  assert.notEqual(run("slab_validate_email invalid").status, 0);
});

test("password validation requires matching bounded values", () => {
  assert.equal(
    run("slab_validate_passwords strong-password strong-password").status,
    0,
  );
  assert.notEqual(run("slab_validate_passwords short short").status, 0);
  assert.notEqual(
    run("slab_validate_passwords strong-password different-password").status,
    0,
  );
});

test("interactive password input preserves the installer's outer traps", {
  skip: spawnSync("sh", ["-c", "command -v script"], { encoding: "utf8" }).status !== 0,
}, () => {
  const shellCommand = [
    "set -e",
    `. '${helper}'`,
    "trap 'printf OUTER_TRAP_PRESERVED >&2' EXIT",
    "slab_prompt_password",
    '[ "$SLAB_ADMIN_PASSWORD" = strong-password ]',
  ].join("; ");
  const result = spawnSync(
    "script",
    ["-qec", shellCommand, "/dev/null"],
    { encoding: "utf8", input: "strong-password\nstrong-password\n" },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout + result.stderr, /OUTER_TRAP_PRESERVED/);
});

test("interactive password mismatch cannot continue bootstrap", {
  skip: spawnSync("sh", ["-c", "command -v script"], { encoding: "utf8" }).status !== 0,
}, () => {
  const shellCommand = [
    "set -e",
    `. '${helper}'`,
    "slab_prompt_password",
    "printf SHOULD_NOT_CONTINUE",
  ].join("; ");
  const result = spawnSync(
    "script",
    ["-qec", shellCommand, "/dev/null"],
    { encoding: "utf8", input: "strong-password\ndifferent-password\n" },
  );
  assert.notEqual(result.status, 0);
  assert.match(result.stdout + result.stderr, /passwords do not match/i);
  assert.doesNotMatch(result.stdout + result.stderr, /SHOULD_NOT_CONTINUE/);
});
