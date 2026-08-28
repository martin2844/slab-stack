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
const slabctlInstall = path.join(root, "installer/lib/slabctl-install.sh");
const render = path.join(root, "installer/lib/render.sh");

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
    path.join(binaries, "stat"),
    `#!/bin/sh
[ "$1" = -c ] || exit 2
shift
exec node -e '
  const fs = require("node:fs");
  const value = fs.lstatSync(process.argv[2]);
  const output = {
    "%u": value.uid,
    "%a": (value.mode & 0o7777).toString(8),
  }[process.argv[1]];
  if (output === undefined) process.exit(2);
  process.stdout.write(String(output) + "\\n");
' "$1" "$2"
`,
    { mode: 0o755 },
  );
  fs.writeFileSync(
    path.join(binaries, "systemctl-test"),
    `#!/bin/sh
printf '%s\n' "$*" >> "$SLAB_TEST_SYSTEMCTL_CALLS"
if [ "$*" = "enable --now slab.service slab-update-bridge.path slab-update-bridge-sweep.timer" ]; then
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
        SLAB_UPDATE_BRIDGE_REQUEST_UID: String(process.getuid()),
        SLAB_SYSTEMD_TRUST_ROOT: current.directory,
        SLAB_MANAGEMENT_HOST_ROOT: current.hostRoot,
        SLAB_MANAGEMENT_OWNER_UID: String(process.getuid()),
        SLAB_MANAGEMENT_TRUST_ROOT: current.directory,
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
    const bridgeService = fs.readFileSync(
      path.join(
        current.hostRoot,
        "etc/systemd/system/slab-update-bridge.service",
      ),
      "utf8",
    );
    const bridgePath = fs.readFileSync(
      path.join(current.hostRoot, "etc/systemd/system/slab-update-bridge.path"),
      "utf8",
    );
    const bridgePrepare = fs.readFileSync(
      path.join(
        current.hostRoot,
        "etc/systemd/system/slab-update-bridge-prepare.service",
      ),
      "utf8",
    );
    const bridgeMount = fs.readFileSync(
      path.join(
        current.hostRoot,
        "etc/systemd/system/var-lib-slab\\x2dupdate\\x2dbridge-requests.mount",
      ),
      "utf8",
    );
    const statusMount = fs.readFileSync(
      path.join(
        current.hostRoot,
        "etc/systemd/system/var-lib-slab\\x2dupdate\\x2dbridge-status.mount",
      ),
      "utf8",
    );
    const sweepTimer = fs.readFileSync(
      path.join(
        current.hostRoot,
        "etc/systemd/system/slab-update-bridge-sweep.timer",
      ),
      "utf8",
    );
    assert.match(bridgeService, /slabctl update bridge-process/);
    assert.match(bridgeService, /NoNewPrivileges=yes/);
    assert.match(bridgeService, /Requires=slab-update-bridge-prepare\.service/);
    assert.doesNotMatch(bridgeService, /Requires=.*docker\.service/);
    assert.match(bridgeService, /Requires=slab-update-bridge-prepare\.service/);
    assert.doesNotMatch(bridgeService, /Requires=.*docker\.service/);
    assert.match(bridgePath, /requests\/\*\.json/);
    assert.match(bridgePath, /processing\/\*\.json/);
    assert.match(bridgePrepare, /requests\/\.claimed/);
    assert.match(
      bridgePrepare,
      /chown 10001:0 \/var\/lib\/slab-update-bridge\/requests\/\.uploads/,
    );
    assert.doesNotMatch(bridgePrepare, /install .* -o 10001 /);
    assert.match(bridgePrepare, /PartOf=var-lib-slab\\x2dupdate/);
    assert.match(bridgeMount, /Options=size=1M,nr_inodes=256/);
    assert.match(statusMount, /Options=size=8M,nr_inodes=4096/);
    assert.match(sweepTimer, /OnUnitInactiveSec=1min/);
    assert.equal(
      fs.statSync(
        path.join(current.hostRoot, "var/lib/slab-update-bridge/requests"),
      ).mode & 0o1777,
      0o1733,
    );
    assert.equal(
      fs.statSync(
        path.join(current.hostRoot, "var/lib/slab-update-bridge/status"),
      ).mode & 0o777,
      0o755,
    );
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

test("refuses a symbolic-link update bridge directory before creating children", () => {
  const current = fixture();
  const bridgeRoot = path.join(
    current.hostRoot,
    "var/lib/slab-update-bridge",
  );
  const outside = path.join(current.directory, "outside");
  fs.mkdirSync(bridgeRoot, { recursive: true });
  fs.mkdirSync(outside);
  fs.symlinkSync(outside, path.join(bridgeRoot, "status"));
  try {
    const result = run(
      current,
      `slab_install_systemd_unit ${JSON.stringify(root)}`,
    );
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /symbolic-link update bridge directory/);
    assert.equal(fs.existsSync(path.join(outside, "requests")), false);
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("activation releases the installer lock for systemd and reacquires it", {
  skip: process.platform === "darwin" && !process.env.CI,
}, () => {
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
      "daemon-reload\n" +
        "enable --now var-lib-slab\\x2dupdate\\x2dbridge-requests.mount " +
        "var-lib-slab\\x2dupdate\\x2dbridge-status.mount\n" +
        "enable --now slab-update-bridge-prepare.service\n" +
        "enable --now slab.service slab-update-bridge.path " +
        "slab-update-bridge-sweep.timer\n",
    );
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("activates the update watcher without restarting the stack", () => {
  const current = fixture();
  try {
    const result = run(
      current,
      `slab_install_systemd_unit ${JSON.stringify(root)} && ` +
        "slab_activate_update_bridge_path",
    );
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      fs.readFileSync(current.calls, "utf8"),
      "daemon-reload\n" +
        "enable --now var-lib-slab\\x2dupdate\\x2dbridge-requests.mount " +
        "var-lib-slab\\x2dupdate\\x2dbridge-status.mount\n" +
        "enable --now slab-update-bridge-prepare.service\n" +
        "enable --now slab-update-bridge.path slab-update-bridge-sweep.timer\n",
    );
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("target management installer provisions the bridge for an older updater", () => {
  const current = fixture();
  fs.writeFileSync(path.join(current.installation, "VERSION"), "0.1.2\n");
  try {
    const result = run(
      current,
      `. ${JSON.stringify(slabctlInstall)}; ` +
        `slab_install_management_cli ${JSON.stringify(root)} ` +
        `${JSON.stringify(current.installation)}`,
    );
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      fs.readFileSync(current.calls, "utf8"),
      "daemon-reload\n" +
        "enable --now var-lib-slab\\x2dupdate\\x2dbridge-requests.mount " +
        "var-lib-slab\\x2dupdate\\x2dbridge-status.mount\n" +
        "enable --now slab-update-bridge-prepare.service\n" +
        "enable --now slab-update-bridge.path slab-update-bridge-sweep.timer\n",
    );
    assert.equal(
      fs.existsSync(
        path.join(
          current.hostRoot,
          "etc/systemd/system/slab-update-bridge.path",
        ),
      ),
      true,
    );
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("target renderer mounts the bounded inbox before an older updater starts Compose", () => {
  const current = fixture();
  fs.writeFileSync(path.join(current.installation, "VERSION"), "0.1.2\n");
  try {
    const result = run(
      current,
      `. ${JSON.stringify(render)}; ` +
        `SLABCTL_INSTALL_DIRECTORY=${JSON.stringify(current.installation)}; ` +
        `slab_render_installation ${JSON.stringify(root)} ` +
        `${JSON.stringify(current.installation)} ` +
        `${JSON.stringify(path.join(root, "releases/v0.1.2-candidate.37.json"))} ` +
        `private http://127.0.0.1:3009 '' '' 127.0.0.1 3009 0`,
    );
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      fs.readFileSync(current.calls, "utf8"),
      "daemon-reload\n" +
        "enable --now var-lib-slab\\x2dupdate\\x2dbridge-requests.mount " +
        "var-lib-slab\\x2dupdate\\x2dbridge-status.mount\n" +
        "enable --now slab-update-bridge-prepare.service\n" +
        "enable --now slab-update-bridge.path slab-update-bridge-sweep.timer\n",
    );
    assert.equal(
      fs.existsSync(path.join(current.installation, "compose.yml")),
      true,
    );
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});
