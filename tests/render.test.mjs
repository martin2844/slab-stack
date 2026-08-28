import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helper = path.join(root, "installer", "lib", "render.sh");
const manifest = path.join(root, "releases", "v0.1.2-candidate.39.json");

function render(
  directory,
  mode,
  publicUrl,
  domain = "",
  email = "",
  writeIdentity = "1",
  environment = {},
) {
  return spawnSync(
    "sh",
    [
      "-c",
      '. "$1"; slab_render_installation "$2" "$3" "$4" "$5" "$6" "$7" "$8" 127.0.0.1 3009 "$9"',
      "render",
      helper,
      root,
      directory,
      manifest,
      mode,
      publicUrl,
      domain,
      email,
      writeIdentity,
    ],
    { encoding: "utf8", env: { ...process.env, ...environment } },
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
      "0.1.2-candidate.39",
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
    for (const secret of [
      "honcho-api-key",
      "honcho-openai-api-key",
      "honcho-db-password",
    ]) {
      const secretPath = path.join(temporaryDirectory, "secrets", secret);
      assert.ok(fs.statSync(secretPath).isFile());
      assert.ok(fs.readFileSync(secretPath, "utf8").trim().length > 0);
      assert.equal(fs.statSync(secretPath).mode & 0o777, 0o444);
    }
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("renders managed memory without writing its API key to the environment", () => {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-render-managed-memory-"),
  );
  try {
    const result = render(
      temporaryDirectory,
      "private",
      "http://127.0.0.1:3009",
      "",
      "",
      "1",
      {
        SLAB_MEMORY_MODE: "managed",
        SLAB_HONCHO_URL: "https://api.honcho.dev",
        SLAB_HONCHO_WORKSPACE_ID: "demo-memory",
        SLAB_MEMORY_MAX_CONTEXT_TOKENS: "700",
      },
    );
    assert.equal(result.status, 0, result.stderr);
    const environment = fs.readFileSync(
      path.join(temporaryDirectory, "config", "install.env"),
      "utf8",
    );
    assert.match(environment, /^SLAB_MEMORY_MODE=managed$/m);
    assert.match(environment, /^SLAB_MEMORY_PROVIDER=honcho$/m);
    assert.match(environment, /^COMPOSE_PROFILES=$/m);
    assert.match(
      environment,
      /^SLAB_HONCHO_API_KEY_FILE_IN_CONTAINER=\/run\/secrets\/honcho_api_key$/m,
    );
    assert.doesNotMatch(environment, /managed-honcho-secret/);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("renders self-hosted memory as an internal Compose profile", () => {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-render-self-hosted-memory-"),
  );
  try {
    const result = render(
      temporaryDirectory,
      "private",
      "http://127.0.0.1:3009",
      "",
      "",
      "1",
      { SLAB_MEMORY_MODE: "self_hosted" },
    );
    assert.equal(result.status, 0, result.stderr);
    const environment = fs.readFileSync(
      path.join(temporaryDirectory, "config", "install.env"),
      "utf8",
    );
    assert.match(environment, /^COMPOSE_PROFILES=memory$/m);
    assert.match(environment, /^SLAB_HONCHO_URL=http:\/\/honcho-api:8000$/m);
    assert.match(environment, /^SLAB_MEMORY_PROVIDER=honcho$/m);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("update rendering can defer the installed version identity", () => {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-render-deferred-identity-"),
  );
  try {
    fs.writeFileSync(
      path.join(temporaryDirectory, "VERSION"),
      "0.1.0-candidate.9\n",
    );
    const result = render(
      temporaryDirectory,
      "private",
      "http://127.0.0.1:3009",
      "",
      "",
      "0",
    );
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      fs.readFileSync(path.join(temporaryDirectory, "VERSION"), "utf8").trim(),
      "0.1.0-candidate.9",
    );
    assert.equal(
      JSON.parse(
        fs.readFileSync(
          path.join(temporaryDirectory, "release-manifest.json"),
          "utf8",
        ),
      ).stackVersion,
      "0.1.2-candidate.39",
    );
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("legacy nine-argument update rendering also defers identity", () => {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-render-legacy-update-"),
  );
  try {
    fs.writeFileSync(
      path.join(temporaryDirectory, "VERSION"),
      "0.1.0-candidate.9\n",
    );
    const result = spawnSync(
      "sh",
      [
        "-c",
        '. "$1"; slab_render_installation "$2" "$3" "$4" private http://127.0.0.1:3009 "" "" 127.0.0.1 3009',
        "legacy-render",
        helper,
        root,
        temporaryDirectory,
        manifest,
      ],
      { encoding: "utf8" },
    );
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      fs.readFileSync(path.join(temporaryDirectory, "VERSION"), "utf8").trim(),
      "0.1.0-candidate.9",
    );
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

test("omits the optional Caddy ACME email directive when no email is configured", () => {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-render-domain-empty-email-"),
  );
  try {
    const result = render(
      temporaryDirectory,
      "domain",
      "https://agents.example.com",
      "agents.example.com",
      "",
    );
    assert.equal(result.status, 0, result.stderr);
    const caddyfile = fs.readFileSync(
      path.join(temporaryDirectory, "Caddyfile"),
      "utf8",
    );
    assert.doesNotMatch(caddyfile, /email \{\$ACME_EMAIL\}/);
    assert.match(caddyfile, /admin off/);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("rejects an unknown access mode before writing files", () => {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-render-invalid-"),
  );
  try {
    const result = render(
      temporaryDirectory,
      "public-http",
      "http://example.com",
    );
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Unsupported access mode/);
    assert.deepEqual(fs.readdirSync(temporaryDirectory), []);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("rejects managed-file symlinks instead of writing through them", () => {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "slab-render-link-"),
  );
  const outside = path.join(temporaryDirectory, "outside");
  const installation = path.join(temporaryDirectory, "installation");
  fs.mkdirSync(installation);
  fs.writeFileSync(outside, "must remain unchanged");
  fs.symlinkSync(outside, path.join(installation, "compose.yml"));
  try {
    const result = render(installation, "private", "http://127.0.0.1:3009");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Refusing symbolic-link managed file/);
    assert.equal(fs.readFileSync(outside, "utf8"), "must remain unchanged");
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});
