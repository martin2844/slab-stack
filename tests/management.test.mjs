import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function install(
  hostRoot,
  installDirectory,
  extraEnv = {},
  bundleRoot = root,
  identity = { version: "0.1.0-candidate.10" },
) {
  fs.mkdirSync(installDirectory, { recursive: true });
  fs.writeFileSync(
    path.join(installDirectory, "VERSION"),
    `${identity.version}\n`,
  );
  if (identity.manifestVersion) {
    fs.writeFileSync(
      path.join(installDirectory, "release-manifest.json"),
      `${JSON.stringify({ stackVersion: identity.manifestVersion })}\n`,
    );
  }
  return spawnSync(
    "sh",
    [
      "-c",
      '. "$1"; . "$2"; slab_install_management_cli "$3" "$4" defer',
      "management-test",
      path.join(root, "installer/lib/prompts.sh"),
      path.join(root, "installer/lib/slabctl-install.sh"),
      bundleRoot,
      installDirectory,
    ],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        SLAB_MANAGEMENT_HOST_ROOT: hostRoot,
        SLAB_MANAGEMENT_OWNER_UID: String(process.getuid()),
        SLAB_MANAGEMENT_TRUST_ROOT: path.dirname(hostRoot),
        ...extraEnv,
      },
    },
  );
}

function assertRecoveredTarget(hostRoot, relative, expected, message) {
  const actual = fs.readFileSync(path.join(hostRoot, relative));
  if (relative === "usr/local/bin/slabctl") {
    assert.equal(
      actual.subarray(-expected.length).equals(expected),
      true,
      `${message}; the recovery wrapper must delegate to the previous launcher`,
    );
    return;
  }
  assert.deepEqual(actual, expected, message);
}

function prepareSlabctlInvocationFixture(directory) {
  const hostRoot = path.join(directory, "host");
  const installDirectory = path.join(directory, "slab");
  const fakeBin = path.join(directory, "fake-bin");
  fs.mkdirSync(fakeBin);
  fs.writeFileSync(
    path.join(fakeBin, "stat"),
    `#!/bin/sh
case "\${2:-}" in
  %u) printf '%s\\n' '${process.getuid()}' ;;
  %a) printf '%s\\n' '644' ;;
  *) exit 2 ;;
esac
`,
    { mode: 0o755 },
  );
  fs.writeFileSync(path.join(fakeBin, "flock"), "#!/bin/sh\nexit 0\n", {
    mode: 0o755,
  });
  const fixturePath = `${fakeBin}:${process.env.PATH}`;
  const installed = install(hostRoot, installDirectory, { PATH: fixturePath });
  assert.equal(installed.status, 0, installed.stderr);
  const config = path.join(installDirectory, "config");
  fs.mkdirSync(config, { recursive: true });
  fs.writeFileSync(
    path.join(config, "install-state.json"),
    `${JSON.stringify({ projectName: "slab" })}\n`,
  );
  fs.writeFileSync(path.join(config, "access-mode"), "private\n");
  fs.writeFileSync(path.join(config, "install.env"), "SLAB_PUBLIC_URL=http://localhost\n");
  fs.writeFileSync(path.join(installDirectory, "compose.yml"), "services: {}\n");
  fs.writeFileSync(
    path.join(installDirectory, "compose.private.yml"),
    "services: {}\n",
  );
  fs.writeFileSync(
    path.join(installDirectory, "release-manifest.json"),
    `${JSON.stringify({ channel: "candidate" })}\n`,
  );
  return {
    binary: path.join(hostRoot, "usr/local/bin/slabctl"),
    env: {
      ...process.env,
      PATH: fixturePath,
      SLABCTL_TEST_ROOT: hostRoot,
    },
  };
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
    const lifecycle = path.join(
      hostRoot,
      "usr/local/lib/slab-stack/lifecycle.sh",
    );
    const domain = path.join(hostRoot, "usr/local/lib/slab-stack/domain.sh");
    const proton = path.join(hostRoot, "usr/local/lib/slab-stack/proton.sh");
    const backup = path.join(hostRoot, "usr/local/lib/slab-stack/backup.sh");
    const releaseClient = path.join(
      hostRoot,
      "usr/local/lib/slab-stack/release-client.sh",
    );
    const releasePublicKey = path.join(
      hostRoot,
      "usr/local/lib/slab-stack/release-signing-public.pem",
    );
    const update = path.join(hostRoot, "usr/local/lib/slab-stack/update.sh");
    const doctor = path.join(hostRoot, "usr/local/lib/slab-stack/doctor.sh");
    const managerVersion = path.join(
      hostRoot,
      "usr/local/lib/slab-stack/VERSION",
    );
    const pointer = path.join(hostRoot, "etc/slab/install-directory");
    assert.match(
      fs.readFileSync(binary, "utf8"),
      /slab-stack-managed: slabctl/,
    );
    assert.match(
      fs.readFileSync(library, "utf8"),
      /slabctl_codex_login_device/,
    );
    assert.match(fs.readFileSync(lifecycle, "utf8"), /slabctl_stack_start/);
    assert.match(fs.readFileSync(domain, "utf8"), /slabctl_domain_verify/);
    assert.match(fs.readFileSync(proton, "utf8"), /slabctl_proton_setup/);
    assert.match(fs.readFileSync(backup, "utf8"), /slabctl_backup_create/);
    assert.match(
      fs.readFileSync(releaseClient, "utf8"),
      /slabctl_release_prepare/,
    );
    assert.match(fs.readFileSync(releasePublicKey, "utf8"), /BEGIN PUBLIC KEY/);
    assert.match(fs.readFileSync(update, "utf8"), /slabctl_update_apply/);
    assert.match(fs.readFileSync(doctor, "utf8"), /slabctl_support_bundle/);
    assert.equal(
      fs.readFileSync(managerVersion, "utf8").trim(),
      "0.1.0-candidate.10",
    );
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

test(
  "real slabctl parser rejects flags that do not belong to an update action",
  { skip: process.getuid() === 0 },
  () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-cli-options-"));
    try {
      const fixture = prepareSlabctlInvocationFixture(directory);
      for (const args of [
        ["update", "rollback", "--json", "--yes"],
        ["update", "rollback", "--target", "1.2.3", "--yes"],
        ["update", "rollback", "--channel", "stable", "--yes"],
        ["update", "recover-maintenance", "--json"],
        ["update", "recover-maintenance", "--target", "1.2.3"],
        ["update", "recover-maintenance", "--channel", "stable"],
        ["update", "recover-maintenance", "--yes"],
      ]) {
        const result = spawnSync(fixture.binary, args, {
          encoding: "utf8",
          env: fixture.env,
        });
        assert.equal(result.status, 2, `${args.join(" ")}\n${result.stderr}`);
        assert.match(result.stderr, /Usage:/);
      }
    } finally {
      fs.rmSync(directory, { recursive: true, force: true });
    }
  },
);

test("publishes the verified target version for both stack and manager identity", () => {
  const directory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-management-version-"),
  );
  const hostRoot = path.join(directory, "host");
  const installDirectory = path.join(directory, "slab");
  try {
    const result = install(hostRoot, installDirectory, {}, root, {
      version: "0.1.0-candidate.9",
      manifestVersion: "0.1.0-candidate.10",
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      fs.readFileSync(path.join(installDirectory, "VERSION"), "utf8").trim(),
      "0.1.0-candidate.10",
    );
    assert.equal(
      fs
        .readFileSync(
          path.join(hostRoot, "usr/local/lib/slab-stack/VERSION"),
          "utf8",
        )
        .trim(),
      "0.1.0-candidate.10",
    );
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("does not replace an unmanaged command at the host boundary", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-management-"));
  const hostRoot = path.join(directory, "host");
  const binaryDirectory = path.join(hostRoot, "usr/local/bin");
  fs.mkdirSync(binaryDirectory, { recursive: true });
  fs.writeFileSync(
    path.join(binaryDirectory, "slabctl"),
    "#!/bin/sh\nexit 7\n",
    {
      mode: 0o755,
    },
  );
  try {
    const result = install(hostRoot, path.join(directory, "slab"));
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Refusing to replace an unmanaged slabctl/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("restores the previous management CLI when replacement fails mid-install", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-management-"));
  const hostRoot = path.join(directory, "host");
  const installDirectory = path.join(directory, "slab");
  try {
    const first = install(hostRoot, installDirectory);
    assert.equal(first.status, 0, first.stderr);
    const managedTargets = [
      "usr/local/bin/slabctl",
      "usr/local/lib/slab-stack/codex.sh",
      "usr/local/lib/slab-stack/lifecycle.sh",
      "usr/local/lib/slab-stack/domain.sh",
      "usr/local/lib/slab-stack/proton.sh",
      "usr/local/lib/slab-stack/backup.sh",
      "usr/local/lib/slab-stack/release-client.sh",
      "usr/local/lib/slab-stack/release-signing-public.pem",
      "usr/local/lib/slab-stack/update.sh",
      "usr/local/lib/slab-stack/doctor.sh",
      "usr/local/lib/slab-stack/VERSION",
      "etc/slab/install-directory",
    ];
    const before = Object.fromEntries(
      managedTargets.map((relative) => [
        relative,
        fs.readFileSync(path.join(hostRoot, relative)),
      ]),
    );

    const replacementBundle = path.join(directory, "replacement-bundle");
    fs.mkdirSync(path.join(replacementBundle, "installer/lib"), {
      recursive: true,
    });
    fs.mkdirSync(path.join(replacementBundle, "bin"), { recursive: true });
    fs.mkdirSync(path.join(replacementBundle, "contracts"), {
      recursive: true,
    });
    for (const relative of [
      "bin/slabctl",
      "installer/lib/codex.sh",
      "installer/lib/lifecycle.sh",
      "installer/lib/domain.sh",
      "installer/lib/proton.sh",
      "installer/lib/backup.sh",
      "installer/lib/release-client.sh",
      "contracts/release-signing-public.pem",
      "installer/lib/update.sh",
      "installer/lib/doctor.sh",
    ]) {
      const target = path.join(replacementBundle, relative);
      fs.copyFileSync(path.join(root, relative), target);
      fs.appendFileSync(target, "\n# replacement-bundle-marker\n");
    }
    fs.writeFileSync(
      path.join(installDirectory, "VERSION"),
      "0.1.0-candidate.11\n",
    );

    const fakeBin = path.join(directory, "fake-bin");
    const failMarker = path.join(directory, "move-failed-once");
    const failTarget = path.join(
      hostRoot,
      "usr/local/lib/slab-stack/doctor.sh",
    );
    fs.mkdirSync(fakeBin);
    fs.writeFileSync(
      path.join(fakeBin, "mv"),
      `#!/bin/sh
if [ "\${2:-}" = "$FAIL_TARGET" ] && [ ! -e "$FAIL_MARKER" ]; then
  : > "$FAIL_MARKER"
  exit 1
fi
exec /bin/mv "$@"
`,
      { mode: 0o755 },
    );

    const failed = install(
      hostRoot,
      installDirectory,
      {
        PATH: `${fakeBin}:${process.env.PATH}`,
        FAIL_MARKER: failMarker,
        FAIL_TARGET: failTarget,
      },
      replacementBundle,
    );
    assert.notEqual(failed.status, 0);
    for (const relative of managedTargets) {
      assertRecoveredTarget(
        hostRoot,
        relative,
        before[relative],
        `${relative} must be restored byte-for-byte`,
      );
    }
    assert.equal(fs.existsSync(failMarker), true);
    assert.equal(
      fs
        .readdirSync(path.join(hostRoot, "etc/slab"))
        .some((name) => name.startsWith(".management-rollback.")),
      false,
    );
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("cleans preparation artifacts when management backup fails before mutation", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-management-"));
  const hostRoot = path.join(directory, "host");
  const installDirectory = path.join(directory, "slab");
  try {
    const first = install(hostRoot, installDirectory);
    assert.equal(first.status, 0, first.stderr);
    const fakeBin = path.join(directory, "fake-bin");
    fs.mkdirSync(fakeBin);
    fs.writeFileSync(
      path.join(fakeBin, "cp"),
      `#!/bin/sh
case "\${3:-}" in
  */.management-rollback.*/codex) exit 1 ;;
esac
exec /bin/cp "$@"
`,
      { mode: 0o755 },
    );
    const failed = install(hostRoot, installDirectory, {
      PATH: `${fakeBin}:${process.env.PATH}`,
    });
    assert.notEqual(failed.status, 0);
    for (const relative of [
      "usr/local/bin",
      "usr/local/lib/slab-stack",
      "etc/slab",
    ]) {
      const names = fs.readdirSync(path.join(hostRoot, relative));
      assert.equal(
        names.some(
          (name) =>
            name.startsWith(".management-rollback.") ||
            name.startsWith(".slabctl.") ||
            name.startsWith(".codex.sh.") ||
            name.startsWith(".install-directory."),
        ),
        false,
        `${relative} contains a stranded preparation artifact: ${names.join(", ")}`,
      );
    }
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("a fresh slabctl process recovers an interrupted management generation", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-management-"));
  const hostRoot = path.join(directory, "host");
  const installDirectory = path.join(directory, "slab");
  try {
    const first = install(hostRoot, installDirectory);
    assert.equal(first.status, 0, first.stderr);
    const targets = {
      binary: "usr/local/bin/slabctl",
      codex: "usr/local/lib/slab-stack/codex.sh",
      lifecycle: "usr/local/lib/slab-stack/lifecycle.sh",
      domain: "usr/local/lib/slab-stack/domain.sh",
      proton: "usr/local/lib/slab-stack/proton.sh",
      backup: "usr/local/lib/slab-stack/backup.sh",
      "release-client": "usr/local/lib/slab-stack/release-client.sh",
      "release-public-key":
        "usr/local/lib/slab-stack/release-signing-public.pem",
      update: "usr/local/lib/slab-stack/update.sh",
      doctor: "usr/local/lib/slab-stack/doctor.sh",
      "manager-version": "usr/local/lib/slab-stack/VERSION",
      pointer: "etc/slab/install-directory",
    };
    const before = Object.fromEntries(
      Object.entries(targets).map(([name, relative]) => [
        name,
        fs.readFileSync(path.join(hostRoot, relative)),
      ]),
    );
    const registry = path.join(hostRoot, "etc/slab");
    const rollback = path.join(registry, ".management-rollback.crash");
    fs.mkdirSync(rollback, { mode: 0o700 });
    for (const [name, relative] of Object.entries(targets)) {
      fs.writeFileSync(path.join(rollback, name), before[name]);
      fs.writeFileSync(path.join(rollback, `${name}.present`), "");
      if (name !== "binary") {
        fs.writeFileSync(
          path.join(hostRoot, relative),
          `mixed-generation:${name}\n`,
        );
      }
    }
    const journal = path.join(registry, "management-transaction");
    fs.writeFileSync(journal, `${rollback}\n`, { mode: 0o600 });

    const recovered = spawnSync(
      path.join(hostRoot, targets.binary),
      ["--help"],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          SLABCTL_TEST_ROOT: hostRoot,
        },
      },
    );
    // The minimal fixture lacks a full installation config, but recovery occurs
    // before normal slabctl loading and must complete regardless of that exit.
    assert.notEqual(recovered.error?.code, "ENOENT");
    for (const [name, relative] of Object.entries(targets)) {
      assertRecoveredTarget(
        hostRoot,
        relative,
        before[name],
        `${relative} must come from one recovered generation`,
      );
    }
    assert.equal(fs.existsSync(journal), false);
    assert.equal(fs.existsSync(rollback), false);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("management recovery keeps its recovery-aware launcher until every library is restored", () => {
  const directory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-recovery-kill-"),
  );
  const hostRoot = path.join(directory, "host");
  const installDirectory = path.join(directory, "slab");
  const targets = {
    binary: "usr/local/bin/slabctl",
    codex: "usr/local/lib/slab-stack/codex.sh",
    lifecycle: "usr/local/lib/slab-stack/lifecycle.sh",
    domain: "usr/local/lib/slab-stack/domain.sh",
    proton: "usr/local/lib/slab-stack/proton.sh",
    backup: "usr/local/lib/slab-stack/backup.sh",
    "release-client": "usr/local/lib/slab-stack/release-client.sh",
    "release-public-key": "usr/local/lib/slab-stack/release-signing-public.pem",
    update: "usr/local/lib/slab-stack/update.sh",
    doctor: "usr/local/lib/slab-stack/doctor.sh",
    "manager-version": "usr/local/lib/slab-stack/VERSION",
    pointer: "etc/slab/install-directory",
  };
  try {
    const first = install(hostRoot, installDirectory);
    assert.equal(first.status, 0, first.stderr);
    const before = Object.fromEntries(
      Object.entries(targets).map(([name, relative]) => [
        name,
        fs.readFileSync(path.join(hostRoot, relative)),
      ]),
    );
    const registry = path.join(hostRoot, "etc/slab");
    const rollback = path.join(registry, ".management-rollback.old-manager");
    fs.mkdirSync(rollback, { mode: 0o700 });
    for (const [name, relative] of Object.entries(targets)) {
      fs.writeFileSync(path.join(rollback, name), before[name]);
      fs.writeFileSync(path.join(rollback, `${name}.present`), "");
      if (name !== "binary") {
        fs.writeFileSync(path.join(hostRoot, relative), `mixed:${name}\n`);
      }
    }
    const oldLauncher = "#!/bin/sh\n# old-manager-without-recovery\nexit 88\n";
    fs.writeFileSync(path.join(rollback, "binary"), oldLauncher, {
      mode: 0o755,
    });
    const oldLifecycle = [
      "#!/bin/sh",
      "slab_acquire_management_lock() { :; }",
      "slabctl_load_installation() { :; }",
      "",
    ].join("\n");
    const oldUpdate = "#!/bin/sh\n# old-update-without-maintenance-recovery\n";
    fs.writeFileSync(path.join(rollback, "lifecycle"), oldLifecycle);
    fs.writeFileSync(path.join(rollback, "update"), oldUpdate);
    before.lifecycle = Buffer.from(oldLifecycle);
    before.update = Buffer.from(oldUpdate);
    const recoveryMarker = path.join(directory, "maintenance-recovered");
    const recoveryUpdate = fs.readFileSync(
      path.join(root, "installer/lib/update.sh"),
      "utf8",
    );
    fs.writeFileSync(
      path.join(rollback, "recovery-update.sh"),
      `${recoveryUpdate}
slabctl_update_recover_maintenance() {
  printf '%s\n' '{"status":"UPDATED"}' > "$SLABCTL_INSTALL_DIRECTORY/config/update-state.json"
  : > "$RECOVERY_MARKER"
}
`,
      { mode: 0o600 },
    );
    fs.writeFileSync(
      path.join(rollback, "recovery-manager-version"),
      "0.1.0-candidate.10\n",
      { mode: 0o600 },
    );
    fs.mkdirSync(path.join(installDirectory, "config"), { recursive: true });
    fs.writeFileSync(
      path.join(installDirectory, "config/update-state.json"),
      `${JSON.stringify({
        status: "APPLYING",
        fromVersion: "0.1.0-candidate.9",
        toVersion: "0.1.0-candidate.10",
      })}\n`,
    );
    fs.writeFileSync(
      path.join(installDirectory, "release-manifest.json"),
      `${JSON.stringify({ channel: "candidate" })}\n`,
    );
    const journal = path.join(registry, "management-transaction");
    fs.writeFileSync(journal, `${rollback}\n`, { mode: 0o600 });

    const fakeBin = path.join(directory, "fake-bin");
    fs.mkdirSync(fakeBin);
    fs.writeFileSync(
      path.join(fakeBin, "mv"),
      `#!/bin/sh
/bin/mv "$@" || exit 1
destination=
for argument do destination=$argument; done
[ "$destination" != "$LAUNCHER" ] || kill -KILL "$PPID"
`,
      { mode: 0o755 },
    );
    const launcher = path.join(hostRoot, targets.binary);
    const interrupted = spawnSync(launcher, ["update", "recover-maintenance"], {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${fakeBin}:${process.env.PATH}`,
        LAUNCHER: launcher,
        RECOVERY_MARKER: recoveryMarker,
        SLABCTL_TEST_ROOT: hostRoot,
      },
    });
    assert.ok(
      interrupted.signal === "SIGKILL" || interrupted.status === 137,
      `expected recovery SIGKILL, got status=${interrupted.status} signal=${interrupted.signal}`,
    );
    assert.equal(fs.existsSync(journal), true);
    assert.match(fs.readFileSync(launcher, "utf8"), /slab-stack-managed/);
    assert.match(fs.readFileSync(launcher, "utf8"), /old-manager/);
    assert.match(fs.readFileSync(launcher, "utf8"), /management-transaction/);

    const recovered = spawnSync(launcher, ["update", "recover-maintenance"], {
      encoding: "utf8",
      env: {
        ...process.env,
        RECOVERY_MARKER: recoveryMarker,
        SLABCTL_TEST_ROOT: hostRoot,
      },
    });
    assert.equal(recovered.status, 0, recovered.stderr);
    assert.equal(fs.existsSync(recoveryMarker), true);
    assert.equal(
      JSON.parse(
        fs.readFileSync(
          path.join(installDirectory, "config/update-state.json"),
          "utf8",
        ),
      ).status,
      "UPDATED",
    );
    assert.equal(fs.existsSync(journal), false);
    assert.equal(fs.existsSync(rollback), false);
    assert.equal(
      fs
        .readFileSync(launcher)
        .subarray(-Buffer.byteLength(oldLauncher))
        .toString(),
      oldLauncher,
    );
    for (const [name, relative] of Object.entries(targets)) {
      if (name === "binary") continue;
      assert.deepEqual(
        fs.readFileSync(path.join(hostRoot, relative)),
        before[name],
      );
    }
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("the real installer publishes recovery before its first managed mutation", () => {
  const directory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-management-kill-"),
  );
  const hostRoot = path.join(directory, "host");
  const installDirectory = path.join(directory, "slab");
  const targets = {
    binary: "usr/local/bin/slabctl",
    codex: "usr/local/lib/slab-stack/codex.sh",
    lifecycle: "usr/local/lib/slab-stack/lifecycle.sh",
    domain: "usr/local/lib/slab-stack/domain.sh",
    proton: "usr/local/lib/slab-stack/proton.sh",
    backup: "usr/local/lib/slab-stack/backup.sh",
    "release-client": "usr/local/lib/slab-stack/release-client.sh",
    "release-public-key": "usr/local/lib/slab-stack/release-signing-public.pem",
    update: "usr/local/lib/slab-stack/update.sh",
    doctor: "usr/local/lib/slab-stack/doctor.sh",
    "manager-version": "usr/local/lib/slab-stack/VERSION",
    pointer: "etc/slab/install-directory",
  };
  try {
    const first = install(hostRoot, installDirectory);
    assert.equal(first.status, 0, first.stderr);
    const before = Object.fromEntries(
      Object.entries(targets).map(([name, relative]) => [
        name,
        fs.readFileSync(path.join(hostRoot, relative)),
      ]),
    );

    const replacementBundle = path.join(directory, "replacement-bundle");
    for (const relative of [
      "bin/slabctl",
      "installer/lib/codex.sh",
      "installer/lib/lifecycle.sh",
      "installer/lib/domain.sh",
      "installer/lib/proton.sh",
      "installer/lib/backup.sh",
      "installer/lib/release-client.sh",
      "contracts/release-signing-public.pem",
      "installer/lib/update.sh",
      "installer/lib/doctor.sh",
    ]) {
      const target = path.join(replacementBundle, relative);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.copyFileSync(path.join(root, relative), target);
      fs.appendFileSync(target, "\n# interrupted-generation-marker\n");
    }
    fs.writeFileSync(
      path.join(installDirectory, "VERSION"),
      "0.1.0-candidate.11\n",
    );

    const fakeBin = path.join(directory, "fake-bin");
    const moveCount = path.join(directory, "move-count");
    fs.mkdirSync(fakeBin);
    fs.writeFileSync(
      path.join(fakeBin, "mv"),
      `#!/bin/sh
count=0
[ ! -f "$MOVE_COUNT" ] || count=$(cat "$MOVE_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$MOVE_COUNT"
/bin/mv "$@" || exit 1
if [ "$count" -eq 2 ]; then
  kill -KILL "$PPID"
fi
`,
      { mode: 0o755 },
    );

    const interrupted = install(
      hostRoot,
      installDirectory,
      {
        PATH: `${fakeBin}:${process.env.PATH}`,
        MOVE_COUNT: moveCount,
      },
      replacementBundle,
    );
    // The killed management subshell is wrapped by `sh -c`, which may expose
    // SIGKILL either as a signal or as the conventional 128 + 9 exit status.
    assert.ok(
      interrupted.signal === "SIGKILL" || interrupted.status === 137,
      `expected abrupt SIGKILL, got status=${interrupted.status} signal=${interrupted.signal}`,
    );
    const journal = path.join(hostRoot, "etc/slab/management-transaction");
    assert.equal(fs.existsSync(journal), true);

    const recovered = spawnSync(
      path.join(hostRoot, targets.binary),
      ["--help"],
      {
        encoding: "utf8",
        env: { ...process.env, SLABCTL_TEST_ROOT: hostRoot },
      },
    );
    assert.notEqual(recovered.error?.code, "ENOENT");
    for (const [name, relative] of Object.entries(targets)) {
      assertRecoveredTarget(
        hostRoot,
        relative,
        before[name],
        `${relative} must be restored after process death`,
      );
    }
    assert.equal(fs.existsSync(journal), false);
    assert.equal(
      fs
        .readdirSync(path.join(hostRoot, "etc/slab"))
        .some((name) => name.startsWith(".management-rollback.")),
      false,
    );
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
