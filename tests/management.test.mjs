import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function install(hostRoot, installDirectory) {
  return spawnSync(
    "sh",
    [
      "-c",
      '. "$1"; . "$2"; slab_install_management_cli "$3" "$4"',
      "management-test",
      path.join(root, "installer/lib/prompts.sh"),
      path.join(root, "installer/lib/slabctl-install.sh"),
      root,
      installDirectory,
    ],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        SLAB_MANAGEMENT_HOST_ROOT: hostRoot,
        SLAB_MANAGEMENT_OWNER_UID: String(process.getuid()),
        SLAB_MANAGEMENT_TRUST_ROOT: path.dirname(hostRoot),
      },
    },
  );
}

test("installs slabctl idempotently and pins it to one installation", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-management-"));
  const hostRoot = path.join(directory, "host");
  const firstInstall = path.join(directory, "slab-a");
  const secondInstall = path.join(directory, "slab-b");
  try {
    const first = install(hostRoot, firstInstall);
    assert.equal(first.status, 0, first.stderr);
    const binary = path.join(hostRoot, "usr/local/bin/slabctl");
    const library = path.join(hostRoot, "usr/local/lib/slab-stack/codex.sh");
    const lifecycle = path.join(hostRoot, "usr/local/lib/slab-stack/lifecycle.sh");
    const pointer = path.join(hostRoot, "etc/slab/install-directory");
    assert.match(fs.readFileSync(binary, "utf8"), /slab-stack-managed: slabctl/);
    assert.match(fs.readFileSync(library, "utf8"), /slabctl_codex_login_device/);
    assert.match(fs.readFileSync(lifecycle, "utf8"), /slabctl_stack_start/);
    assert.equal(fs.readFileSync(pointer, "utf8").trim(), firstInstall);
    assert.equal(fs.statSync(binary).mode & 0o777, 0o755);
    assert.equal(fs.statSync(pointer).mode & 0o777, 0o644);

    const rerun = install(hostRoot, firstInstall);
    assert.equal(rerun.status, 0, rerun.stderr);

    const conflicting = install(hostRoot, secondInstall);
    assert.notEqual(conflicting.status, 0);
    assert.match(conflicting.stderr, /already registered/);
    assert.equal(fs.readFileSync(pointer, "utf8").trim(), firstInstall);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("does not replace an unmanaged command at the host boundary", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-management-"));
  const hostRoot = path.join(directory, "host");
  const binaryDirectory = path.join(hostRoot, "usr/local/bin");
  fs.mkdirSync(binaryDirectory, { recursive: true });
  fs.writeFileSync(path.join(binaryDirectory, "slabctl"), "#!/bin/sh\nexit 7\n", {
    mode: 0o755,
  });
  try {
    const result = install(hostRoot, path.join(directory, "slab"));
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Refusing to replace an unmanaged slabctl/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
