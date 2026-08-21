import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bootstrap = path.join(root, "bootstrap/install.sh");
const packager = path.join(root, "scripts/package-release.sh");
const candidate = path.join(root, "releases/v0.1.0-candidate.10.json");

function command(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: "utf8", ...options });
  assert.notEqual(result.status, null, result.error?.message);
  return result;
}

function sha256(filename) {
  return crypto.createHash("sha256").update(fs.readFileSync(filename)).digest("hex");
}

function createSignedRelease(t, { version = "0.1.0-test.1", symlink = false } = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-bootstrap-test-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const releases = path.join(directory, "releases");
  const channels = path.join(directory, "channels");
  const releaseDirectory = path.join(releases, `v${version}`);
  const staging = path.join(directory, "staging");
  const bundleRoot = `slab-stack-${version}`;
  const bundleDirectory = path.join(staging, bundleRoot);
  const installerDirectory = path.join(bundleDirectory, "installer");
  const manifestDirectory = path.join(bundleDirectory, "releases");
  const marker = path.join(directory, "installer-ran");
  const privateKey = path.join(directory, "private.pem");
  const publicKey = path.join(directory, "public.pem");
  const publicKeyDer = path.join(directory, "public.der");
  const fixtureBootstrap = path.join(directory, "install.sh");

  fs.mkdirSync(releaseDirectory, { recursive: true });
  fs.mkdirSync(channels, { recursive: true });
  fs.mkdirSync(installerDirectory, { recursive: true });
  fs.mkdirSync(manifestDirectory, { recursive: true });
  fs.writeFileSync(
    path.join(installerDirectory, "install.sh"),
    `#!/bin/sh\nprintf '%s\\n' "$*" > "$SLAB_BOOTSTRAP_TEST_MARKER"\nprintf '%s\\n' "$(dirname -- "$0")" > "$SLAB_BOOTSTRAP_TEST_MARKER.root"\n`,
    { mode: 0o755 },
  );
  const manifest = path.join(manifestDirectory, `v${version}.json`);
  fs.writeFileSync(
    manifest,
    `${JSON.stringify({ schemaVersion: 1, stackVersion: version }, null, 2)}\n`,
  );
  if (symlink) {
    fs.symlinkSync("releases", path.join(bundleDirectory, "unsafe-link"));
  }

  const assetName = `${bundleRoot}.tar.gz`;
  const archive = path.join(releaseDirectory, assetName);
  const tarResult = command("tar", ["-czf", archive, "-C", staging, bundleRoot]);
  assert.equal(tarResult.status, 0, tarResult.stderr);
  const checksum = `${archive}.sha256`;
  fs.writeFileSync(checksum, `${sha256(archive)}  ${assetName}\n`);

  assert.equal(
    command("openssl", ["genpkey", "-algorithm", "ED25519", "-out", privateKey]).status,
    0,
  );
  assert.equal(
    command("openssl", ["pkey", "-in", privateKey, "-pubout", "-out", publicKey]).status,
    0,
  );
  assert.equal(
    command("openssl", [
      "pkey",
      "-pubin",
      "-in",
      publicKey,
      "-outform",
      "DER",
      "-out",
      publicKeyDer,
    ]).status,
    0,
  );
  assert.equal(
    command("openssl", [
      "pkeyutl",
      "-sign",
      "-rawin",
      "-inkey",
      privateKey,
      "-in",
      checksum,
      "-out",
      `${checksum}.sig`,
    ]).status,
    0,
  );

  const manifestSha256 = sha256(manifest);
  fs.writeFileSync(
    path.join(channels, "candidate.json"),
    `${JSON.stringify(
      {
        schemaVersion: 1,
        channel: "candidate",
        stackVersion: version,
        manifestUrl: `https://example.invalid/v${version}.json`,
        manifestSha256,
      },
      null,
      2,
    )}\n`,
  );

  const reviewedPublicKey = fs
    .readFileSync(path.join(root, "contracts/release-signing-public.pem"), "utf8")
    .trim();
  const fixturePublicKey = fs.readFileSync(publicKey, "utf8").trim();
  const fixturePublicKeySha256 = sha256(publicKeyDer);
  const fixtureBootstrapSource = fs
    .readFileSync(bootstrap, "utf8")
    .replace(reviewedPublicKey, fixturePublicKey)
    .replace(
      "2865983ef11b8070415642e0ebdcde17468f48392ee517a63f991f29e80c5293",
      fixturePublicKeySha256,
    );
  fs.writeFileSync(fixtureBootstrap, fixtureBootstrapSource, { mode: 0o755 });

  return {
    archive,
    bootstrap: fixtureBootstrap,
    checksum,
    channels,
    directory,
    manifest,
    marker,
    publicKey,
    releases,
    version,
  };
}

function runBootstrap(fixture, args) {
  return command("sh", [fixture.bootstrap, ...args], {
    env: {
      ...process.env,
      SLAB_BOOTSTRAP_ALLOW_INSECURE_TEST_SOURCE: "1",
      SLAB_BOOTSTRAP_CHANNEL_BASE_URL: pathToFileURL(fixture.channels).href,
      SLAB_BOOTSTRAP_RELEASE_BASE_URL: pathToFileURL(fixture.releases).href,
      SLAB_BOOTSTRAP_TEST_MARKER: fixture.marker,
    },
  });
}

test("verifies a signed exact-version bundle and cleans its temporary root", (t) => {
  const fixture = createSignedRelease(t);
  const result = runBootstrap(fixture, ["--version", fixture.version, "--", "--dry-run"]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Release signature and checksum verified/);
  const installerArguments = fs.readFileSync(fixture.marker, "utf8");
  assert.match(installerArguments, /--manifest/);
  assert.match(installerArguments, /--dry-run/);
  const extractedInstallerRoot = fs.readFileSync(`${fixture.marker}.root`, "utf8").trim();
  assert.equal(fs.existsSync(extractedInstallerRoot), false);
});

test("resolves candidate metadata and verifies the bundled manifest", (t) => {
  const fixture = createSignedRelease(t);
  const result = runBootstrap(fixture, ["--channel", "candidate", "--", "--help"]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(fixture.marker), true);
});

test("rejects an archive changed after its checksum was signed", (t) => {
  const fixture = createSignedRelease(t);
  fs.appendFileSync(fixture.archive, "tampered");
  const result = runBootstrap(fixture, ["--version", fixture.version]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /bundle checksum does not match/);
  assert.equal(fs.existsSync(fixture.marker), false);
});

test("rejects a checksum changed after signing", (t) => {
  const fixture = createSignedRelease(t);
  fs.writeFileSync(fixture.checksum, `${"0".repeat(64)}  slab-stack-${fixture.version}.tar.gz\n`);
  const result = runBootstrap(fixture, ["--version", fixture.version]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /signature verification failed/);
  assert.equal(fs.existsSync(fixture.marker), false);
});

test("rejects signed bundles containing symbolic links", (t) => {
  const fixture = createSignedRelease(t, { symlink: true });
  const result = runBootstrap(fixture, ["--version", fixture.version]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /non-regular entry/);
  assert.equal(fs.existsSync(fixture.marker), false);
});

test("rejects a channel whose manifest checksum does not match the signed bundle", (t) => {
  const fixture = createSignedRelease(t);
  const channelPath = path.join(fixture.channels, "candidate.json");
  const channel = JSON.parse(fs.readFileSync(channelPath, "utf8"));
  channel.manifestSha256 = "0".repeat(64);
  fs.writeFileSync(channelPath, `${JSON.stringify(channel, null, 2)}\n`);
  const result = runBootstrap(fixture, ["--channel", "candidate"]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /manifest does not match the selected channel/);
  assert.equal(fs.existsSync(fixture.marker), false);
});

test("packages the same manifest reproducibly with only installer runtime files", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-package-test-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const first = path.join(directory, "first");
  const second = path.join(directory, "second");
  const firstResult = command(packager, [candidate, first], { cwd: root });
  const secondResult = command(packager, [candidate, second], { cwd: root });
  assert.equal(firstResult.status, 0, firstResult.stderr);
  assert.equal(secondResult.status, 0, secondResult.stderr);

  const asset = "slab-stack-0.1.0-candidate.10.tar.gz";
  assert.equal(sha256(path.join(first, asset)), sha256(path.join(second, asset)));
  const listing = command("tar", ["-tzf", path.join(first, asset)]).stdout;
  assert.match(listing, /installer\/install\.sh/);
  assert.match(listing, /templates\/compose\.yml/);
  assert.match(listing, /bin\/slabctl/);
  assert.match(listing, /releases\/v0\.1\.0-candidate\.10\.json/);
  assert.doesNotMatch(listing, /node_modules|\.git\//);
  const checksumLine = fs.readFileSync(path.join(first, `${asset}.sha256`), "utf8");
  assert.equal(checksumLine, `${sha256(path.join(first, asset))}  ${asset}\n`);
});

test("keeps the embedded release trust root equal to the reviewed public key", () => {
  const publicKey = fs.readFileSync(
    path.join(root, "contracts/release-signing-public.pem"),
    "utf8",
  ).trim();
  const source = fs.readFileSync(bootstrap, "utf8");
  assert.match(source, new RegExp(publicKey.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.match(source, /2865983ef11b8070415642e0ebdcde17468f48392ee517a63f991f29e80c5293/);
});
