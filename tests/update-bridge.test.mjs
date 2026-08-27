import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const update = path.join(root, "installer/lib/update.sh");
const requestSchema = JSON.parse(
  fs.readFileSync(
    path.join(root, "contracts/update-bridge-request.schema.json"),
    "utf8",
  ),
);
const requestId = "4c830c98-6785-4a88-9df1-f9d26ca57b24";

function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-update-bridge-"));
  const bridge = path.join(directory, "bridge");
  const bin = path.join(directory, "bin");
  const calls = path.join(directory, "calls");
  const syncCalls = path.join(directory, "sync-calls");
  for (const [relative, mode] of [
    ["", 0o755],
    ["requests", 0o1733],
    ["requests/.claimed", 0o700],
    ["requests/.uploads", 0o700],
    ["processing", 0o700],
    ["status", 0o755],
    ["status/requests", 0o755],
  ]) {
    fs.mkdirSync(path.join(bridge, relative), { recursive: true, mode });
    fs.chmodSync(path.join(bridge, relative), mode);
  }
  fs.mkdirSync(bin);
  fs.writeFileSync(
    path.join(bin, "stat-test"),
    `#!/bin/sh
[ "$1" = -c ] || exit 2
shift
exec node -e '
  const fs = require("node:fs");
  const value = fs.lstatSync(process.argv[2]);
  const output = {
    "%u": value.uid,
    "%a": (value.mode & 0o7777).toString(8),
    "%h": value.nlink,
    "%s": value.size,
    "%Y": Math.floor(value.mtimeMs / 1000),
  }[process.argv[1]];
  if (output === undefined) process.exit(2);
  process.stdout.write(String(output) + "\\n");
' "$1" "$2"
`,
    { mode: 0o755 },
  );
  fs.writeFileSync(
    path.join(bin, "sync-test"),
    `#!/bin/sh
[ "$1" = -f ] || exit 2
printf '%s\n' "$2" >> "$SLAB_TEST_SYNC_CALLS"
case "$2" in
  *"\${SLAB_TEST_FAIL_SYNC_MATCH:-__never__}") exit 91 ;;
esac
`,
    { mode: 0o755 },
  );
  return { directory, bridge, bin, calls, syncCalls };
}

function request(overrides = {}) {
  const requested = new Date(Date.now() - 5_000);
  const expires = new Date(requested.getTime() + 10 * 60_000);
  return {
    schemaVersion: 1,
    requestId,
    action: "check",
    channel: "stable",
    target: null,
    requestedAt: requested.toISOString().replace(/\.\d{3}Z$/, "Z"),
    expiresAt: expires.toISOString().replace(/\.\d{3}Z$/, "Z"),
    ...overrides,
  };
}

function writeRequest(current, payload = request(), mode = 0o600) {
  const destination = path.join(
    current.bridge,
    "requests",
    `${payload.requestId}.json`,
  );
  fs.writeFileSync(destination, `${JSON.stringify(payload)}\n`, { mode });
  fs.chmodSync(destination, mode);
  return destination;
}

function run(current, extraEnv = {}) {
  return spawnSync(
    "sh",
    [
      "-c",
      `set -eu
. "$1"
slabctl_error() { printf 'slabctl: %s\\n' "$*" >&2; return 1; }
slabctl_update_check() {
  printf 'check:%s:%s\\n' "$1" "$3" >> "$SLAB_TEST_CALLS"
  if [ "\${SLAB_TEST_FAIL_CHECK:-0}" = 1 ]; then
    echo 'slabctl: post-apply refresh unavailable' >&2
    return 19
  fi
  printf '{"schemaVersion":1,"status":"up_to_date","channel":"%s","components":[]}\\n' "$1"
}
slabctl_update_apply() {
  printf 'apply:%s:%s\\n' "$1" "$3" >> "$SLAB_TEST_CALLS"
  if [ "\${SLAB_TEST_FAIL_APPLY:-0}" = 1 ]; then
    echo 'curl: https://secret-token@example.invalid/releases' >&2
    echo 'slabctl: target apply failed safely' >&2
    return 23
  fi
}
slabctl_update_bridge_process`,
      "update-bridge-test",
      update,
    ],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${current.bin}:${process.env.PATH}`,
        SLAB_UPDATE_BRIDGE_ROOT: current.bridge,
        SLAB_UPDATE_BRIDGE_REQUEST_UID: String(process.getuid()),
        SLABCTL_EXPECTED_OWNER_UID: String(process.getuid()),
        SLABCTL_STAT_BIN: path.join(current.bin, "stat-test"),
        SLABCTL_SYNC_BIN: path.join(current.bin, "sync-test"),
        SLAB_TEST_CALLS: current.calls,
        SLAB_TEST_SYNC_CALLS: current.syncCalls,
        ...extraEnv,
      },
    },
  );
}

function status(current, id = requestId) {
  return JSON.parse(
    fs.readFileSync(
      path.join(current.bridge, "status/requests", `${id}.json`),
      "utf8",
    ),
  );
}

function validateRequestPayload(current, payload, nowEpoch) {
  const requestPath = path.join(current.directory, "request.json");
  fs.writeFileSync(requestPath, `${JSON.stringify(payload)}\n`);
  return spawnSync(
    "sh",
    [
      "-c",
      '. "$1"; slabctl_update_bridge_validate_request "$2" "$3" "$4"',
      "validate-update-request",
      update,
      requestPath,
      payload.requestId,
      String(nowEpoch),
    ],
    { encoding: "utf8" },
  );
}

test("request contract publishes the runtime's canonical UTC timestamp", () => {
  const pattern = new RegExp(requestSchema.properties.requestedAt.pattern);
  assert.equal(pattern.test("2026-08-27T12:00:00Z"), true);
  assert.equal(pattern.test("2026-08-27T12:00:00.000Z"), false);
  assert.equal(pattern.test("2026-08-27T14:00:00+02:00"), false);
});

test("runtime rejects normalized invalid calendar dates", () => {
  const current = fixture();
  try {
    const payload = request({
      requestedAt: "2026-04-31T00:00:00Z",
      expiresAt: "2026-04-31T00:10:00Z",
    });
    const normalizedNow = Date.parse("2026-05-01T00:00:05Z") / 1000;
    const result = validateRequestPayload(current, payload, normalizedNow);
    assert.notEqual(result.status, 0);
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("processes a valid check and publishes atomic machine-readable status", () => {
  const current = fixture();
  try {
    writeRequest(current);
    const result = run(current);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.existsSync(current.calls), true, result.stderr);
    assert.equal(fs.readFileSync(current.calls, "utf8"), "check:stable:\n");
    const published = status(current);
    assert.equal(published.state, "succeeded");
    assert.equal(published.action, "check");
    assert.equal(published.result.status, "up_to_date");
    assert.deepEqual(
      JSON.parse(
        fs.readFileSync(path.join(current.bridge, "status/latest.json"), "utf8"),
      ),
      published,
    );
    assert.equal(
      fs.existsSync(path.join(current.bridge, "requests", `${requestId}.json`)),
      false,
    );
    assert.equal(
      fs.existsSync(path.join(current.bridge, "processing", `${requestId}.json`)),
      false,
    );
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("processes at most one queued request per worker activation", () => {
  const current = fixture();
  const secondId = "8d724f48-bf64-41e9-a4ec-a6c4f9f6511f";
  try {
    writeRequest(current);
    writeRequest(current, request({ requestId: secondId }));
    const first = run(current);
    assert.equal(first.status, 0, first.stderr);
    assert.equal(fs.readFileSync(current.calls, "utf8"), "check:stable:\n");
    assert.equal(
      fs.readdirSync(path.join(current.bridge, "requests"))
        .filter((entry) => entry.endsWith(".json")).length,
      1,
    );

    const second = run(current);
    assert.equal(second.status, 0, second.stderr);
    assert.equal(
      fs.readFileSync(current.calls, "utf8"),
      "check:stable:\ncheck:stable:\n",
    );
    assert.equal(status(current, secondId).state, "succeeded");
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("periodic worker activation sweeps junk uploads and expired terminal status", () => {
  const current = fixture();
  try {
    const junk = path.join(current.bridge, "requests", "junk.bin");
    const upload = path.join(current.bridge, "requests/.uploads", "stale.tmp");
    const abandonedStatusTemporary = path.join(
      current.bridge,
      "status/.status.abandoned",
    );
    const abandonedLatestTemporary = path.join(
      current.bridge,
      "status/.latest.abandoned",
    );
    const oldStatus = path.join(
      current.bridge,
      "status/requests",
      `${requestId}.json`,
    );
    fs.writeFileSync(junk, "junk");
    fs.writeFileSync(upload, "partial");
    fs.writeFileSync(abandonedStatusTemporary, "partial");
    fs.writeFileSync(abandonedLatestTemporary, "partial");
    fs.writeFileSync(
      oldStatus,
      `${JSON.stringify({ state: "succeeded" })}\n`,
      { mode: 0o644 },
    );
    const old = new Date(Date.now() - 2 * 24 * 60 * 60_000);
    fs.utimesSync(upload, old, old);
    fs.utimesSync(oldStatus, old, old);

    const result = run(current);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.existsSync(junk), false);
    assert.equal(fs.existsSync(upload), false);
    assert.equal(fs.existsSync(abandonedStatusTemporary), false);
    assert.equal(fs.existsSync(abandonedLatestTemporary), false);
    assert.equal(fs.existsSync(oldStatus), false);
    assert.equal(fs.existsSync(current.calls), false);
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("evicts the oldest terminal status before the bounded transport fills", () => {
  const current = fixture();
  const oldestId = "8d724f48-bf64-41e9-a4ec-a6c4f9f6511f";
  const runningId = "9b6555a4-f827-4687-a66b-13aa6309941e";
  try {
    const statusDirectory = path.join(current.bridge, "status/requests");
    const oldest = path.join(statusDirectory, `${oldestId}.json`);
    fs.writeFileSync(oldest, '{"state":"succeeded"}\n', { mode: 0o644 });
    fs.writeFileSync(
      path.join(statusDirectory, `${runningId}.json`),
      '{"state":"running"}\n',
      { mode: 0o644 },
    );
    const old = new Date(Date.now() - 60_000);
    fs.utimesSync(oldest, old, old);
    writeRequest(current);

    const result = run(current, { SLAB_UPDATE_BRIDGE_STATUS_MAXIMUM: "2" });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.existsSync(oldest), false);
    assert.equal(status(current).state, "succeeded");
    assert.equal(
      fs.existsSync(path.join(statusDirectory, `${runningId}.json`)),
      true,
    );
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("removes a rejected request even when status publication fails", () => {
  const current = fixture();
  try {
    const destination = writeRequest(current, request(), 0o640);
    fs.writeFileSync(
      path.join(current.bin, "mktemp"),
      `#!/bin/sh
case "$1" in
  */status/.status.*) exit 71 ;;
esac
exec /usr/bin/mktemp "$@"
`,
      { mode: 0o755 },
    );

    const rejected = run(current);
    assert.notEqual(rejected.status, 0, rejected.stderr);
    assert.equal(fs.existsSync(destination), false);

    fs.rmSync(path.join(current.bin, "mktemp"));
    const nextId = "8d724f48-bf64-41e9-a4ec-a6c4f9f6511f";
    writeRequest(current, request({ requestId: nextId }));
    const next = run(current);
    assert.equal(next.status, 0, next.stderr);
    assert.equal(status(current, nextId).state, "succeeded");
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("passes only the approved channel and exact target to apply", () => {
  const current = fixture();
  try {
    writeRequest(
      current,
      request({
        action: "apply",
        channel: "candidate",
        target: "0.1.3-candidate.2",
      }),
    );
    const result = run(current);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      fs.readFileSync(current.calls, "utf8"),
      "apply:candidate:0.1.3-candidate.2\ncheck:candidate:0.1.3-candidate.2\n",
    );
    const published = status(current);
    assert.equal(published.state, "succeeded");
    assert.equal(published.target, "0.1.3-candidate.2");
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("records a bounded failure without replaying an apply", () => {
  const current = fixture();
  try {
    writeRequest(
      current,
      request({ action: "apply", target: "0.1.3" }),
    );
    const result = run(current, { SLAB_TEST_FAIL_APPLY: "1" });
    assert.equal(result.status, 23, result.stderr);
    assert.equal(fs.readFileSync(current.calls, "utf8"), "apply:stable:0.1.3\n");
    const published = status(current);
    assert.equal(published.state, "failed");
    assert.equal(published.error.code, "update_failed");
    assert.match(published.error.message, /target apply failed safely/);
    assert.doesNotMatch(published.error.message, /secret-token/);

    writeRequest(current, request({ action: "apply", target: "0.1.3" }));
    const replay = run(current);
    assert.equal(replay.status, 0, replay.stderr);
    assert.equal(fs.readFileSync(current.calls, "utf8"), "apply:stable:0.1.3\n");
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("durable replay ledger survives loss of the ephemeral status transport", () => {
  const current = fixture();
  const payload = request();
  try {
    writeRequest(current, payload);
    const first = run(current);
    assert.equal(first.status, 0, first.stderr);
    fs.rmSync(path.join(current.bridge, "status/latest.json"));
    fs.rmSync(
      path.join(current.bridge, "status/requests", `${requestId}.json`),
    );

    writeRequest(current, payload);
    const replay = run(current);
    assert.equal(replay.status, 0, replay.stderr);
    assert.equal(fs.readFileSync(current.calls, "utf8"), "check:stable:\n");
    const published = status(current);
    assert.equal(published.state, "failed");
    assert.equal(published.error.code, "duplicate_request");
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("keeps a confirmed apply successful when advisory refresh fails", () => {
  const current = fixture();
  try {
    writeRequest(current, request({ action: "apply", target: "0.1.3" }));
    const result = run(current, { SLAB_TEST_FAIL_CHECK: "1" });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      fs.readFileSync(current.calls, "utf8"),
      "apply:stable:0.1.3\ncheck:stable:0.1.3\n",
    );
    const published = status(current);
    assert.equal(published.state, "succeeded");
    assert.equal(published.result, null);
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("does not execute before the claimed request journal is durable", () => {
  const current = fixture();
  try {
    writeRequest(current, request({ action: "apply", target: "0.1.3" }));
    const failed = run(current, {
      SLAB_TEST_FAIL_SYNC_MATCH: `/${requestId}.json`,
    });
    assert.notEqual(failed.status, 0, failed.stderr);
    assert.equal(fs.existsSync(current.calls), false);
    assert.equal(
      fs.existsSync(
        path.join(current.bridge, "processing", `${requestId}.json`),
      ),
      true,
    );

    const recovered = run(current);
    assert.equal(recovered.status, 0, recovered.stderr);
    assert.equal(fs.existsSync(current.calls), false);
    assert.equal(status(current).error.code, "bridge_interrupted");
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("rejects stale, extensible, and non-exact apply requests", () => {
  for (const payload of [
    request({
      requestedAt: "2024-01-01T00:00:00Z",
      expiresAt: "2024-01-01T00:10:00Z",
    }),
    request({ unexpectedCommand: "sh -c id" }),
    request({ action: "apply", target: null }),
  ]) {
    const current = fixture();
    try {
      writeRequest(current, payload);
      const result = run(current);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(fs.existsSync(current.calls), false);
      assert.equal(status(current).error.code, "invalid_request");
    } finally {
      fs.rmSync(current.directory, { recursive: true, force: true });
    }
  }
});

test("rejects request files with writable modes or extra hard links", () => {
  for (const setup of [
    (current) => writeRequest(current, request(), 0o640),
    (current) => {
      const source = writeRequest(current);
      fs.linkSync(source, path.join(current.directory, "retained-link"));
    },
  ]) {
    const current = fixture();
    try {
      setup(current);
      const result = run(current);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(fs.existsSync(current.calls), false);
      assert.equal(status(current).error.code, "invalid_request");
    } finally {
      fs.rmSync(current.directory, { recursive: true, force: true });
    }
  }
});

test("rejects request payloads above the bounded copy limit", () => {
  const current = fixture();
  try {
    const destination = writeRequest(current);
    fs.appendFileSync(destination, " ".repeat(20_000));
    fs.chmodSync(destination, 0o600);
    const result = run(current);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.existsSync(current.calls), false);
    assert.equal(status(current).error.code, "invalid_request");
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("marks an abandoned claimed request uncertain instead of rerunning it", () => {
  const current = fixture();
  try {
    const payload = request({ action: "apply", target: "0.1.3" });
    fs.writeFileSync(
      path.join(current.bridge, "processing", `${requestId}.json`),
      `${JSON.stringify(payload)}\n`,
      { mode: 0o600 },
    );
    const result = run(current);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.existsSync(current.calls), false);
    const published = status(current);
    assert.equal(published.state, "failed");
    assert.equal(published.error.code, "bridge_interrupted");
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("retains an abandoned claim until interrupted status publishes", () => {
  const current = fixture();
  try {
    const claim = path.join(
      current.bridge,
      "processing",
      `${requestId}.json`,
    );
    fs.writeFileSync(claim, `${JSON.stringify(request())}\n`, { mode: 0o600 });
    const running = {
      action: "apply",
      channel: "stable",
      target: "0.1.3",
      requestedAt: request().requestedAt,
      startedAt: request().requestedAt,
      state: "running",
    };
    const requestStatus = path.join(
      current.bridge,
      "status/requests",
      `${requestId}.json`,
    );
    fs.writeFileSync(requestStatus, `${JSON.stringify(running)}\n`, {
      mode: 0o644,
    });
    fs.writeFileSync(
      path.join(current.bridge, "status/latest.json"),
      `${JSON.stringify(running)}\n`,
      { mode: 0o644 },
    );
    fs.writeFileSync(
      path.join(current.bin, "mktemp"),
      `#!/bin/sh
case "$1" in
  */status/.status.*) exit 71 ;;
esac
exec /usr/bin/mktemp "$@"
`,
      { mode: 0o755 },
    );

    const interrupted = run(current);
    assert.notEqual(interrupted.status, 0, interrupted.stderr);
    assert.equal(fs.existsSync(claim), true);
    assert.equal(status(current).state, "running");
    assert.equal(fs.existsSync(current.calls), false);

    fs.rmSync(path.join(current.bin, "mktemp"));
    const recovered = run(current);
    assert.equal(recovered.status, 0, recovered.stderr);
    assert.equal(fs.existsSync(claim), false);
    assert.equal(status(current).state, "failed");
    assert.equal(status(current).error.code, "bridge_interrupted");
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("reconciles latest status before clearing a partially published terminal claim", () => {
  const current = fixture();
  try {
    const payload = request({ action: "apply", target: "0.1.3" });
    const claim = path.join(
      current.bridge,
      "processing",
      `${requestId}.json`,
    );
    fs.writeFileSync(claim, `${JSON.stringify(payload)}\n`, { mode: 0o600 });
    const running = {
      action: "apply",
      channel: "stable",
      target: "0.1.3",
      requestedAt: payload.requestedAt,
      startedAt: payload.requestedAt,
      state: "running",
    };
    fs.writeFileSync(
      path.join(current.bridge, "status/requests", `${requestId}.json`),
      `${JSON.stringify(running)}\n`,
      { mode: 0o644 },
    );
    const latestPath = path.join(current.bridge, "status/latest.json");
    fs.writeFileSync(latestPath, `${JSON.stringify(running)}\n`, {
      mode: 0o644,
    });
    fs.writeFileSync(
      path.join(current.bin, "mv"),
      `#!/bin/sh
case "$2" in
  */status/latest.json) exit 72 ;;
esac
exec /bin/mv "$@"
`,
      { mode: 0o755 },
    );

    const partial = run(current);
    assert.notEqual(partial.status, 0, partial.stderr);
    assert.equal(fs.existsSync(claim), true);
    assert.equal(status(current).state, "failed");
    assert.equal(JSON.parse(fs.readFileSync(latestPath, "utf8")).state, "running");

    fs.rmSync(path.join(current.bin, "mv"));
    const recovered = run(current);
    assert.equal(recovered.status, 0, recovered.stderr);
    assert.equal(fs.existsSync(claim), false);
    assert.equal(status(current).state, "failed");
    assert.equal(JSON.parse(fs.readFileSync(latestPath, "utf8")).state, "failed");
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});

test("does not follow an abandoned request symlink", () => {
  const current = fixture();
  try {
    const outside = path.join(current.directory, "outside.json");
    fs.writeFileSync(
      outside,
      `${JSON.stringify({
        action: "apply",
        channel: "candidate",
        target: "99.0.0",
        requestedAt: "2026-01-01T00:00:00Z",
      })}\n`,
    );
    fs.symlinkSync(
      outside,
      path.join(current.bridge, "processing", `${requestId}.json`),
    );
    const result = run(current);
    assert.equal(result.status, 0, result.stderr);
    const published = status(current);
    assert.equal(published.state, "failed");
    assert.equal(published.action, null);
    assert.equal(published.channel, null);
    assert.equal(published.target, null);
  } finally {
    fs.rmSync(current.directory, { recursive: true, force: true });
  }
});
