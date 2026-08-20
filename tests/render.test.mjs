import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helper = path.join(root, "installer", "lib", "render.sh");
const manifest = path.join(
  root,
  "releases",
  "v0.1.0-candidate.2.json",
);

function render(directory, mode, publicUrl, domain = "", email = "") {
  return spawnSync(
    "sh",
    [
      "-c",
      '. "$1"; slab_render_installation "$2" "$3" "$4" "$5" "$6" "$7" "$8" 127.0.0.1 3009',
      "render",
      helper,
      root,
      directory,
      manifest,
      mode,
      publicUrl,
      domain,
      email,
    ],
    { encoding: "utf8" },
  );
}

test("renders a private installation from an immutable manifest", () => {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-render-private-"),
  );
  try {
    const result = render(
      temporaryDirectory,
      "private",
      "http://127.0.0.1:3009",
    );
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      fs.readFileSync(path.join(temporaryDirectory, "VERSION"), "utf8").trim(),
      "0.1.0-candidate.2",
    );
    assert.equal(
      fs
        .readFileSync(
          path.join(temporaryDirectory, "config", "access-mode"),
          "utf8",
        )
        .trim(),
      "private",
    );
    const environment = fs.readFileSync(
      path.join(temporaryDirectory, "config", "install.env"),
      "utf8",
    );
    assert.match(environment, /^SLAB_PUBLIC_URL=http:\/\/127\.0\.0\.1:3009$/m);
    assert.match(environment, /^SLAB_AGENTS_IMAGE=.*@sha256:[a-f0-9]{64}$/m);
    assert.doesNotMatch(environment, /password|api[_-]?key=/i);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("renders domain configuration without changing image pins", () => {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-render-domain-"),
  );
  try {
    const result = render(
      temporaryDirectory,
      "domain",
      "https://agents.example.com",
      "agents.example.com",
      "ops@example.com",
    );
    assert.equal(result.status, 0, result.stderr);
    const environment = fs.readFileSync(
      path.join(temporaryDirectory, "config", "install.env"),
      "utf8",
    );
    assert.match(environment, /^SLAB_DOMAIN=agents\.example\.com$/m);
    assert.match(environment, /^ACME_EMAIL=ops@example\.com$/m);
    assert.ok(fs.existsSync(path.join(temporaryDirectory, "Caddyfile")));
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("rejects an unknown access mode before writing files", () => {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-render-invalid-"),
  );
  try {
    const result = render(temporaryDirectory, "public-http", "http://example.com");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Unsupported access mode/);
    assert.deepEqual(fs.readdirSync(temporaryDirectory), []);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});
