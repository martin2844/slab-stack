import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const doctor = path.join(root, "installer/lib/doctor.sh");

function shell(script, args = [], env = {}) {
  return spawnSync("sh", ["-c", script, "doctor-test", ...args], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
}

test("diagnostic sanitizer removes bearer, JSON, environment, and opaque secrets", () => {
  const input = [
    "Authorization: Bearer bearer-secret-value",
    "Authorization: Basic c2VjcmV0LXZhbHVl",
    "Cookie: session=cookie-secret-value",
    "Set-Cookie: refresh=refresh-secret-value",
    "2026-08-23T12:00:00Z Authorization: Basic short-basic-secret",
    "2026-08-23T12:00:00Z Cookie: session=short-cookie-secret; Path=/",
    "https://user:url-secret-value@example.test/path",
    '{"apiKey":"json-secret-value","status":"failed"}',
    '{"x-api-key":"short-secret-123","x-auth-token":"other-secret-456"}',
    '{"Authorization":"Bearer json-authorization-secret","Cookie":"session=json-cookie-secret"}',
    "password=environment-secret-value",
    'SMTP_PASSWORD="quoted password secret"',
    "IMAP_TOKEN='single quoted token secret'",
    "0123456789abcdef0123456789abcdef",
  ].join("\n");
  const result = shell('. "$1"; slabctl_doctor_sanitize_stream', [doctor], {
    SLAB_TEST_INPUT: input,
  });
  // spawnSync input is separate from environment to exercise the stream.
  const streamed = spawnSync(
    "sh",
    ["-c", '. "$1"; slabctl_doctor_sanitize_stream', "doctor-test", doctor],
    { encoding: "utf8", input },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(streamed.status, 0, streamed.stderr);
  assert.doesNotMatch(
    streamed.stdout,
    /bearer-secret|c2VjcmV0|cookie-secret|refresh-secret|short-basic|short-cookie|url-secret|json-secret|short-secret-123|other-secret-456|json-authorization-secret|json-cookie-secret|environment-secret|quoted password|single quoted|0123456789abcdef/,
  );
  assert.match(streamed.stdout, /\[REDACTED\]/);
  assert.match(streamed.stdout, /"status":"failed"/);
});

test("doctor result is structured and fails only on an explicit failed check", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-doctor-json-"));
  try {
    const checks = path.join(directory, "checks.jsonl");
    const install = path.join(directory, "install");
    fs.mkdirSync(install);
    fs.writeFileSync(path.join(install, "VERSION"), "0.1.0\n");
    const result = shell(
      '. "$1"; SLABCTL_INSTALL_DIRECTORY="$2"; slabctl_doctor_append "$3" release pass ready; slabctl_doctor_append "$3" backup warn missing; slabctl_doctor_json "$3"',
      [doctor, install, checks],
    );
    assert.equal(result.status, 0, result.stderr);
    const payload = JSON.parse(result.stdout);
    assert.equal(payload.overall, "warn");
    assert.deepEqual(
      payload.checks.map((item) => item.id),
      ["release", "backup"],
    );

    const failed = shell(
      '. "$1"; SLABCTL_INSTALL_DIRECTORY="$2"; slabctl_doctor_append "$3" service fail unhealthy; slabctl_doctor_json "$3"',
      [doctor, install, path.join(directory, "failed.jsonl")],
    );
    assert.equal(JSON.parse(failed.stdout).overall, "fail");
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("support bundle is bounded, reviewable, and excludes secret values and databases", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-support-"));
  try {
    const install = path.join(directory, "install");
    const outputDirectory = path.join(directory, "output");
    const firstWriteMode = path.join(directory, "first-write-mode.txt");
    fs.mkdirSync(path.join(install, "config"), { recursive: true });
    fs.mkdirSync(path.join(install, "secrets"), { recursive: true });
    fs.writeFileSync(path.join(install, "VERSION"), "0.1.0\n");
    fs.writeFileSync(
      path.join(install, "release-manifest.json"),
      '{"schemaVersion":1,"stackVersion":"0.1.0","images":{}}\n',
    );
    fs.writeFileSync(
      path.join(install, "secrets", "token"),
      "must-never-appear\n",
    );
    const script = `
set -eu
. "$1"
slabctl_error() { echo "slabctl: $*" >&2; return 1; }
SLABCTL_INSTALL_DIRECTORY="$2"
slabctl_doctor_collect() { slabctl_doctor_append "$1" release.identity pass 0.1.0; }
slabctl_compose() {
  case "$1" in
    ps) printf 'slab-agents healthy\\n' ;;
    exec) printf '{"promptsIncluded":false,"runs":[]}' ;;
    logs) printf 'Authorization: Bearer must-never-appear\\n{"apiKey":"must-never-appear"}\\n' ;;
  esac
}
SLABCTL_FIRST_WRITE_MODE="$4"
tar() {
  /usr/bin/tar "$@"
  stat -c '%a' "$2" > "$SLABCTL_FIRST_WRITE_MODE"
}
docker() { printf 'Docker 28 password=must-never-appear\\n'; }
slabctl_support_bundle "$3" 1
`;
    const result = shell(script, [
      doctor,
      install,
      outputDirectory,
      firstWriteMode,
    ]);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Support bundle will include/);
    assert.match(result.stdout, /excludes database files, prompts, messages/);
    const archive = fs
      .readdirSync(outputDirectory)
      .map((name) => path.join(outputDirectory, name))
      .find((name) => name.endsWith(".tar.gz"));
    assert.ok(
      archive,
      `stdout=${result.stdout}\nstderr=${result.stderr}\nfiles=${fs.readdirSync(outputDirectory).join(",")}`,
    );
    const extract = path.join(directory, "extract");
    fs.mkdirSync(extract);
    const unpack = spawnSync("tar", ["-xzf", archive, "-C", extract], {
      encoding: "utf8",
    });
    assert.equal(unpack.status, 0, unpack.stderr);
    const files = [];
    const walk = (folder) => {
      for (const name of fs.readdirSync(folder)) {
        const filename = path.join(folder, name);
        if (fs.statSync(filename).isDirectory()) walk(filename);
        else files.push(filename);
      }
    };
    walk(extract);
    const contents = files
      .map((filename) => fs.readFileSync(filename, "utf8"))
      .join("\n");
    assert.doesNotMatch(contents, /must-never-appear/);
    assert.match(contents, /\[REDACTED\]/);
    assert.equal(
      files.some((filename) => filename.endsWith(".db")),
      false,
    );
    assert.equal(fs.statSync(archive).mode & 0o777, 0o600);
    assert.equal(fs.readFileSync(firstWriteMode, "utf8").trim(), "600");
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
