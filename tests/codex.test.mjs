import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function fixture(initialStatus = "READY_NO_RUNTIME") {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slabctl-codex-"));
  const hostRoot = path.join(directory, "host");
  const installDirectory = path.join(directory, "installation");
  const binDirectory = path.join(directory, "bin");
  const calls = path.join(directory, "docker-calls");
  const inputLength = path.join(directory, "api-key-length");
  fs.mkdirSync(path.join(hostRoot, "usr/local/bin"), { recursive: true });
  fs.mkdirSync(path.join(hostRoot, "usr/local/lib/slab-stack"), {
    recursive: true,
  });
  fs.mkdirSync(path.join(hostRoot, "etc/slab"), { recursive: true });
  fs.mkdirSync(path.join(installDirectory, "config"), { recursive: true });
  fs.mkdirSync(binDirectory);
  fs.copyFileSync(
    path.join(root, "bin/slabctl"),
    path.join(hostRoot, "usr/local/bin/slabctl"),
  );
  fs.chmodSync(path.join(hostRoot, "usr/local/bin/slabctl"), 0o755);
  fs.copyFileSync(
    path.join(root, "installer/lib/codex.sh"),
    path.join(hostRoot, "usr/local/lib/slab-stack/codex.sh"),
  );
  fs.writeFileSync(
    path.join(hostRoot, "etc/slab/install-directory"),
    `${installDirectory}\n`,
  );
  fs.writeFileSync(path.join(installDirectory, "config/access-mode"), "private\n");
  fs.writeFileSync(path.join(installDirectory, "config/install.env"), "TEST=1\n");
  fs.writeFileSync(path.join(installDirectory, "compose.yml"), "services: {}\n");
  fs.writeFileSync(path.join(installDirectory, "compose.private.yml"), "services: {}\n");
  fs.writeFileSync(
    path.join(installDirectory, "config/install-state.json"),
    JSON.stringify({
      version: "0.1.0-candidate.3",
      accessMode: "private",
      publicUrl: "http://127.0.0.1:3009",
      projectName: "slab",
      status: initialStatus,
      phase: "admin_configured",
      completedSteps: ["admin_configured"],
      updatedAt: "2026-08-20T10:00:00Z",
    }),
    { mode: 0o600 },
  );
  fs.writeFileSync(
    path.join(binDirectory, "docker"),
    `#!/bin/sh
printf '%s\\n' "$*" >> "$SLAB_TEST_DOCKER_CALLS"
case "$*" in
  *"login --with-api-key")
    IFS= read -r value
    printf '%s' "\${#value}" > "$SLAB_TEST_API_KEY_LENGTH"
    printf 'API key accepted\\n'
    ;;
  *"login --device-auth") printf 'Open the device authorization URL\\n' ;;
  *"login status") printf 'Logged in\\n' ;;
  *"node -e"*) exit 0 ;;
  *" logout") printf 'Logged out\\n' ;;
  *" restart slab-runner") exit 0 ;;
  *" ps -q slab-runner") printf 'runner-container\\n' ;;
  "inspect runner-container "*) printf 'healthy\\n' ;;
  *) printf 'unexpected docker call: %s\\n' "$*" >&2; exit 91 ;;
esac
`,
    { mode: 0o755 },
  );
  return { directory, hostRoot, installDirectory, binDirectory, calls, inputLength };
}

function run(current, args, input) {
  return spawnSync(path.join(current.hostRoot, "usr/local/bin/slabctl"), args, {
    encoding: "utf8",
    input,
    env: {
      ...process.env,
      PATH: `${current.binDirectory}:${process.env.PATH}`,
      SLABCTL_TEST_ROOT: current.hostRoot,
      SLABCTL_RUNNER_HEALTH_ATTEMPTS: "1",
      SLABCTL_RUNNER_HEALTH_DELAY_SECONDS: "0",
      SLAB_TEST_DOCKER_CALLS: current.calls,
      SLAB_TEST_API_KEY_LENGTH: current.inputLength,
    },
  });
}

test("Codex status inspects the Runner-owned persistent Codex home", () => {
  const current = fixture();
  try {
    const result = run(current, ["codex", "status"]);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Logged in/);
    const calls = fs.readFileSync(current.calls, "utf8");
    assert.match(
      calls,
      /exec -T -e CODEX_HOME=\/var\/lib\/slab-runner\/codex slab-runner \/usr\/local\/bin\/codex login status/,
    );
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("device login restarts Runner and promotes private install state to READY", () => {
  const current = fixture();
  try {
    const result = run(current, ["codex", "login"]);
    assert.equal(result.status, 0, result.stderr);
    const calls = fs.readFileSync(current.calls, "utf8");
    assert.match(calls, /login --device-auth/);
    assert.match(calls, /restart slab-runner/);
    assert.match(calls, /login status/);
    const state = JSON.parse(
      fs.readFileSync(
        path.join(current.installDirectory, "config/install-state.json"),
        "utf8",
      ),
    );
    assert.equal(state.status, "READY");
    assert.equal(state.lastKnownGood.status, "READY");
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("API-key login consumes stdin without exposing the key in output or Docker argv", () => {
  const current = fixture();
  const secret = "sk-test-only-never-log-this";
  try {
    const result = run(current, ["codex", "login", "--api-key"], `${secret}\n`);
    assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(result.stdout + result.stderr, new RegExp(secret));
    assert.equal(fs.readFileSync(current.inputLength, "utf8"), String(secret.length));
    assert.doesNotMatch(fs.readFileSync(current.calls, "utf8"), new RegExp(secret));
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("logout restarts Runner and demotes READY to READY_NO_RUNTIME", () => {
  const current = fixture("READY");
  try {
    const result = run(current, ["codex", "logout"]);
    assert.equal(result.status, 0, result.stderr);
    const calls = fs.readFileSync(current.calls, "utf8");
    assert.match(calls, / logout/);
    assert.match(calls, /restart slab-runner/);
    const state = JSON.parse(
      fs.readFileSync(
        path.join(current.installDirectory, "config/install-state.json"),
        "utf8",
      ),
    );
    assert.equal(state.status, "READY_NO_RUNTIME");
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("domain TLS_PENDING state is not overwritten by Codex login", () => {
  const current = fixture("TLS_PENDING");
  try {
    const result = run(current, ["codex", "login"]);
    assert.equal(result.status, 0, result.stderr);
    const state = JSON.parse(
      fs.readFileSync(
        path.join(current.installDirectory, "config/install-state.json"),
        "utf8",
      ),
    );
    assert.equal(state.status, "TLS_PENDING");
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("slabctl refuses to race an installer holding the management lock", () => {
  const current = fixture();
  const lockFile = path.join(
    current.installDirectory,
    "config/management.lock",
  );
  try {
    const result = spawnSync(
      "sh",
      [
        "-c",
        'exec 9>"$1"; flock -n 9; "$2" codex status',
        "held-lock",
        lockFile,
        path.join(current.hostRoot, "usr/local/bin/slabctl"),
      ],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          PATH: `${current.binDirectory}:${process.env.PATH}`,
          SLABCTL_TEST_ROOT: current.hostRoot,
          SLAB_TEST_DOCKER_CALLS: current.calls,
          SLAB_TEST_API_KEY_LENGTH: current.inputLength,
        },
      },
    );
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /already operating on this installation/);
    assert.equal(fs.existsSync(current.calls), false);
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});
