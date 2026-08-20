import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const preflight = path.join(root, "installer", "lib", "preflight.sh");
const bootstrap = path.join(root, "installer", "lib", "host-bootstrap.sh");

function writeExecutable(file, body) {
  fs.writeFileSync(file, `#!/bin/sh\nset -eu\n${body}\n`, { mode: 0o755 });
}

function createFixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-host-bootstrap-"));
  const binaries = path.join(directory, "bin");
  const hostRoot = path.join(directory, "host");
  const osRelease = path.join(directory, "os-release");
  const calls = path.join(directory, "calls");
  const dockerReady = path.join(directory, "docker-ready");
  fs.mkdirSync(binaries);
  fs.mkdirSync(hostRoot);
  fs.writeFileSync(
    osRelease,
    'ID=ubuntu\nVERSION_ID="26.04"\nVERSION_CODENAME=resolute\n',
  );
  writeExecutable(
    path.join(binaries, "curl"),
    `output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf 'test-only-docker-signing-key\n' > "$output"`,
  );
  writeExecutable(
    path.join(binaries, "gpg"),
    `printf 'fpr:::::::::%s:\n' "\${TEST_DOCKER_FINGERPRINT:-9DC858229FC7DD38854AE2D88D81803C0EBFCD88}"`,
  );
  writeExecutable(
    path.join(binaries, "apt-get"),
    `printf 'apt-get %s\n' "$*" >> "$TEST_CALLS"
case " $* " in *" docker-ce "*) : > "$TEST_DOCKER_READY" ;; esac`,
  );
  writeExecutable(
    path.join(binaries, "dpkg"),
    `case "$1" in --print-architecture) printf 'amd64\n' ;; *) exit 90 ;; esac`,
  );
  writeExecutable(path.join(binaries, "dpkg-query"), "exit 1");
  writeExecutable(
    path.join(binaries, "docker"),
    `[ -f "$TEST_DOCKER_READY" ] || exit 1
case "$*" in info|"compose version") exit 0 ;; *) exit 91 ;; esac`,
  );
  writeExecutable(
    path.join(binaries, "systemctl"),
    `printf 'systemctl %s\n' "$*" >> "$TEST_CALLS"`,
  );
  return { directory, binaries, hostRoot, osRelease, calls, dockerReady };
}

function run(fixture, script, environment = {}) {
  return spawnSync(
    "sh",
    [
      "-c",
      `. "$1"; . "$2"; ${script}`,
      "host-bootstrap",
      preflight,
      bootstrap,
    ],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${fixture.binaries}:${process.env.PATH}`,
        SLAB_HOST_ROOT: fixture.hostRoot,
        SLAB_OS_RELEASE_FILE: fixture.osRelease,
        SLAB_HOST_LOCK_FILE: path.join(fixture.directory, "host-bootstrap.lock"),
        TEST_CALLS: fixture.calls,
        TEST_DOCKER_READY: fixture.dockerReady,
        ...environment,
      },
    },
  );
}

test("renders the official Ubuntu 26.04 Docker repository with a verified key", () => {
  const fixture = createFixture();
  try {
    const result = run(
      fixture,
      "slab_write_docker_repository ubuntu resolute amd64",
    );
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      fs.readFileSync(
        path.join(fixture.hostRoot, "etc", "apt", "sources.list.d", "docker.sources"),
        "utf8",
      ),
      [
        "Types: deb",
        "URIs: https://download.docker.com/linux/ubuntu",
        "Suites: resolute",
        "Components: stable",
        "Architectures: amd64",
        "Signed-By: /etc/apt/keyrings/docker.asc",
        "",
      ].join("\n"),
    );
    assert.equal(
      fs.readFileSync(
        path.join(fixture.hostRoot, "etc", "apt", "keyrings", "docker.asc"),
        "utf8",
      ),
      "test-only-docker-signing-key\n",
    );
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});

test("rejects a Docker repository key with an unexpected fingerprint", () => {
  const fixture = createFixture();
  try {
    const result = run(
      fixture,
      "slab_write_docker_repository ubuntu resolute amd64",
      { TEST_DOCKER_FINGERPRINT: "0000000000000000000000000000000000000000" },
    );
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /fingerprint did not match/);
    assert.equal(
      fs.existsSync(
        path.join(fixture.hostRoot, "etc", "apt", "keyrings", "docker.asc"),
      ),
      false,
    );
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});

test("prepares Docker CE and Compose V2 from the official repository", () => {
  const fixture = createFixture();
  try {
    const result = run(fixture, "slab_prepare_host");
    assert.equal(result.status, 0, result.stderr);
    const calls = fs.readFileSync(fixture.calls, "utf8");
    assert.match(calls, /apt-get .*install -y ca-certificates curl gnupg jq openssl tar/);
    assert.match(
      calls,
      /apt-get .*install -y docker-ce docker-ce-cli containerd\.io docker-buildx-plugin docker-compose-plugin/,
    );
    assert.match(calls, /systemctl enable --now docker/);
    assert.equal(fs.existsSync(fixture.dockerReady), true);
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});

test("does not mutate apt configuration when Docker is already ready", () => {
  const fixture = createFixture();
  fs.writeFileSync(fixture.dockerReady, "ready\n");
  try {
    const result = run(fixture, "slab_prepare_host");
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.existsSync(fixture.calls), false);
    assert.equal(
      fs.existsSync(path.join(fixture.hostRoot, "etc", "apt", "sources.list.d")),
      false,
    );
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});

test("refuses to remove conflicting host packages automatically", () => {
  const fixture = createFixture();
  writeExecutable(
    path.join(fixture.binaries, "dpkg-query"),
    `case "$*" in *docker.io|*podman-docker) printf 'ii '\n ;; *) exit 1 ;; esac`,
  );
  try {
    const result = run(fixture, "slab_detect_conflicting_docker_packages");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /docker\.io/);
    assert.match(result.stderr, /podman-docker/);
    assert.match(result.stderr, /will not remove host packages automatically/);
  } finally {
    fs.rmSync(fixture.directory, { recursive: true, force: true });
  }
});
