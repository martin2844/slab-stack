import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const prompts = path.join(root, "installer/lib/prompts.sh");
const codex = path.join(root, "installer/lib/codex.sh");
const systemd = path.join(root, "installer/lib/systemd.sh");

function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-systemd-"));
  const hostRoot = path.join(directory, "host");
  const installation = path.join(directory, "installation");
  const binaries = path.join(directory, "bin");
  const calls = path.join(directory, "systemctl-calls");
  fs.mkdirSync(hostRoot);
  fs.mkdirSync(path.join(installation, "config"), { recursive: true });
  fs.mkdirSync(binaries);
  fs.writeFileSync(
    path.join(binaries, "systemctl-test"),
    `#!/bin/sh
printf '%s\n' "$*" >> "$SLAB_TEST_SYSTEMCTL_CALLS"
if [ "$*" = "enable --now slab.service" ]; then
  exec 9>"$SLAB_TEST_MANAGEMENT_LOCK"
  flock -n 9 || { echo 'management lock was not released' >&2; exit 87; }
fi
`,
    { mode: 0o755 },
  );
  return { directory, hostRoot, installation, binaries, calls };
}

function run(current, command) {
  return spawnSync(
    "sh",
    [
      "-c",
      `. "$1"; . "$2"; . "$3"; ${command}`,
      "systemd-test",
      prompts,
      codex,
      systemd,
    ],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${current.binaries}:${process.env.PATH}`,
        SLAB_SYSTEMD_HOST_ROOT: current.hostRoot,
        SLAB_SYSTEMD_OWNER_UID: String(process.getuid()),
        SLAB_SYSTEMD_TRUST_ROOT: current.directory,
        SLAB_SYSTEMCTL_BIN: path.join(current.binaries, "systemctl-test"),
        SLAB_TEST_SYSTEMCTL_CALLS: current.calls,
        SLAB_TEST_MANAGEMENT_LOCK: path.join(
          current.installation,
          "config/management.lock",
        ),
      },
    },
  );
}

test("installs the managed systemd unit idempotently", () => {
  const current = fixture();
  try {
    const first = run(
      current,
      `slab_install_systemd_unit ${JSON.stringify(root)}`,
    );
    assert.equal(first.status, 0, first.stderr);
    const rerun = run(
      current,
      `slab_install_systemd_unit ${JSON.stringify(root)}`,
    );
    assert.equal(rerun.status, 0, rerun.stderr);
    const unit = fs.readFileSync(
      path.join(current.hostRoot, "etc/systemd/system/slab.service"),
      "utf8",
    );
    assert.match(unit, /slab-stack-managed: slab\.service/);
    assert.match(unit, /After=network-online\.target docker\.service/);
    assert.match(unit, /ExecStart=\/usr\/local\/bin\/slabctl stack start/);
    assert.match(unit, /ExecStop=\/usr\/local\/bin\/slabctl stack stop/);
    assert.match(unit, /WantedBy=multi-user\.target/);
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("refuses to replace an unmanaged slab.service", () => {
  const current = fixture();
  const unitDirectory = path.join(current.hostRoot, "etc/systemd/system");
  fs.mkdirSync(unitDirectory, { recursive: true });
  fs.writeFileSync(
    path.join(unitDirectory, "slab.service"),
    "[Service]\nExecStart=/bin/false\n",
  );
  try {
    const result = run(
      current,
      `slab_install_systemd_unit ${JSON.stringify(root)}`,
    );
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Refusing to replace an unmanaged systemd unit/);
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("activation releases the installer lock for systemd and reacquires it", () => {
  const current = fixture();
  try {
    const result = run(
      current,
      `slab_acquire_management_lock ${JSON.stringify(current.installation)} && ` +
        `slab_activate_systemd_unit ${JSON.stringify(current.installation)} && ` +
        `if sh -c 'exec 9>"$1"; flock -n 9' probe ${JSON.stringify(path.join(current.installation, "config/management.lock"))}; ` +
        `then echo 'installer did not reacquire management lock' >&2; exit 88; fi`,
    );
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      fs.readFileSync(current.calls, "utf8"),
      "daemon-reload\nenable --now slab.service\n",
    );
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});
