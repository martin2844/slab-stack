import assert from "node:assert/strict";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helper = path.join(root, "installer", "lib", "preflight.sh");

function run(functionCall, environment = {}) {
  return spawnSync("sh", ["-c", `. "$1"; ${functionCall}`, "preflight", helper], {
    encoding: "utf8",
    env: { ...process.env, ...environment },
  });
}

test("accepts the documented operating systems and architectures", () => {
  for (const fixture of [
    "ubuntu 22.04 x86_64",
    "ubuntu 24.04 amd64",
    "ubuntu 26.04 amd64",
    "debian 12 aarch64",
    "debian 12.9 arm64",
  ]) {
    const [distribution, version, architecture] = fixture.split(" ");
    const result = run(
      `slab_validate_platform ${distribution} ${version} ${architecture}`,
    );
    assert.equal(result.status, 0, `${fixture}: ${result.stderr}`);
  }
});

test("rejects unsupported operating systems and architectures", () => {
  const distribution = run("slab_validate_platform fedora 42 amd64");
  assert.notEqual(distribution.status, 0);
  assert.match(distribution.stderr, /unsupported host/);

  const architecture = run("slab_validate_platform ubuntu 24.04 riscv64");
  assert.notEqual(architecture.status, 0);
  assert.match(architecture.stderr, /unsupported architecture/);
});

test("requires explicit root execution", () => {
  const rejected = run("slab_require_root", { SLAB_PREFLIGHT_UID: "1000" });
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /run the installer as root/);

  const accepted = run("slab_require_root", { SLAB_PREFLIGHT_UID: "0" });
  assert.equal(accepted.status, 0, accepted.stderr);
});

test("reports every missing command in one actionable error", () => {
  const result = run(
    "slab_require_commands definitely-not-a-command another-missing-command",
  );
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /definitely-not-a-command/);
  assert.match(result.stderr, /another-missing-command/);
});
