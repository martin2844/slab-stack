import assert from "node:assert/strict";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helper = path.join(root, "installer", "lib", "prompts.sh");

function run(functionCall) {
  return spawnSync("sh", ["-c", `. "$1"; ${functionCall}`, "prompts", helper], {
    encoding: "utf8",
  });
}

test("accepts scoped absolute installation directories", () => {
  for (const directory of ["/opt/slab", "/srv/slab", "/var/lib/slab-stack"]) {
    const result = run(`slab_validate_install_directory ${directory}`);
    assert.equal(result.status, 0, `${directory}: ${result.stderr}`);
  }
});

test("rejects relative, traversing, and broad installation targets", () => {
  for (const directory of ["slab", "/", "/opt", "/opt/../etc/slab"]) {
    const result = run(`slab_validate_install_directory ${directory}`);
    assert.notEqual(result.status, 0, directory);
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
