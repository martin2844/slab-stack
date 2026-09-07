import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

// Execute the real initialization, EXIT/signal traps, and optional onboarding.
// Host provisioning is excluded; all post-install control flow stays intact.
const installerSource = fs.readFileSync(path.join(root, "installer/install.sh"), "utf8");
const parsingMarker = 'while [ "$#" -gt 0 ]; do';
const onboardingMarker = "# The product installation is complete at this point.";
assert.equal(installerSource.split(parsingMarker).length, 2);
assert.equal(installerSource.split(onboardingMarker).length, 2);
const installerPrefix = installerSource.slice(0, installerSource.indexOf(parsingMarker));
const onboarding = installerSource.slice(installerSource.indexOf(onboardingMarker));

for (const prompt of ["Proton", "Codex", "Gemini"]) {
  for (const action of ["skip", "EOF", "interrupt"]) {
    test(`installer finalizes after ${action} at optional ${prompt} prompt`, { timeout: 15000 }, async () => {
      const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-completion-"));
      const state = { status: prompt === "Gemini" ? "READY" : "READY_NO_RUNTIME", phase: "admin_configured" };
      fs.mkdirSync(path.join(directory, "config"));
      const stateFile = path.join(directory, "config/install-state.json");
      fs.writeFileSync(stateFile, JSON.stringify(state));
      const fixture = `
SLAB_INSTALL_DIRECTORY=$TEST_INSTALL_DIRECTORY
SLAB_INSTALL_PHASE=admin_configured
SLAB_INSTALL_STARTED=1
SLAB_ACCESS_MODE=private
SLAB_PUBLIC_URL=http://192.0.2.1:3009
SLAB_PRIVATE_BIND_IP=192.0.2.1
SLAB_PRIVATE_PORT=3009
admin_readiness=200
completion_state=$TEST_COMPLETION_STATE
codex_authenticated=0
runtime_authenticated=0
if [ "$TEST_PROMPT" = Gemini ]; then
  codex_authenticated=1
  runtime_authenticated=1
fi
slabctl_proton_available() { [ "$TEST_PROMPT" = Proton ]; }
slabctl_proton_configured() { return 1; }
slabctl_gemini_status() { return 1; }
`;
      try {
        const result = await new Promise((resolve, reject) => {
          const child = spawn("script", ["-qE", "always", "-ec",
            'exec sh -c "$TEST_INSTALLER_SOURCE" "$TEST_INSTALLER_PATH"', "/dev/null"], {
            timeout: 10000,
            env: { ...process.env, NO_COLOR: "1", TEST_INSTALLER_SOURCE: installerPrefix + fixture + onboarding,
              TEST_INSTALLER_PATH: path.join(root, "installer/install.sh"),
              TEST_INSTALL_DIRECTORY: directory, TEST_PROMPT: prompt, TEST_COMPLETION_STATE: state.status },
          });
          let output = "";
          const answered = new Set();
          child.stdout.on("data", (chunk) => {
            output += chunk.toString();
            for (const [name, text] of [
              ["Proton", "Connect a Proton mailbox now?"],
              ["Codex", "Authenticate Codex now?"],
              ["Gemini", "Authenticate the optional Gemini runtime now?"],
            ]) {
              if (!answered.has(name) && output.includes(text)) {
                answered.add(name);
                child.stdin.write(name === prompt && action !== "skip"
                  ? (action === "EOF" ? "\x04" : "\x03") : "n\n");
              }
            }
          });
          child.stderr.on("data", (chunk) => { output += chunk.toString(); });
          child.on("error", reject);
          child.on("close", (status) => resolve({ status, output }));
        });
        assert.equal(result.status, action === "skip" ? 0 : action === "EOF" ? 1 : 130, result.output);
        assert.equal(result.output.split("SLAB INSTALLATION COMPLETE").length - 1, 1, result.output);
        const finalOutput = result.output.slice(result.output.indexOf("SLAB INSTALLATION COMPLETE"));
        assert.match(finalOutput, /http:\/\/192\.0\.2\.1:3009/);
        assert.match(finalOutput, /sudo slabctl changepass/);
        assert.ok(finalOutput.includes(`Installation status: ${state.status}`));
        if (action !== "skip") assert.match(result.output, /Optional setup was interrupted/);
        assert.deepEqual(JSON.parse(fs.readFileSync(stateFile, "utf8")), state);
      } finally {
        fs.rmSync(directory, { recursive: true, force: true });
      }
    });
  }
}

test("installer never claims completion when the core installation fails", () => {
  const result = spawnSync("sh", ["-c", installerPrefix + '\nSLAB_INSTALL_STARTED=1\nfalse\n',
    path.join(root, "installer/install.sh")], { encoding: "utf8" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Installation did not reach readiness/);
  assert.doesNotMatch(result.stdout, /SLAB INSTALLATION COMPLETE/);
});

for (const scenario of [
  { name: "new public IP installation", mode: "private", ip: "192.0.2.1", url: "http://192.0.2.1:3009", status: "READY", admin: "503" },
  { name: "existing installation without runtime", mode: "private", ip: "192.0.2.1", url: "http://192.0.2.1:3009", status: "READY_NO_RUNTIME", admin: "200" },
  { name: "local access through SSH", mode: "private", ip: "127.0.0.1", url: "http://127.0.0.1:3009", status: "READY", admin: "200" },
  { name: "ready HTTPS domain", mode: "domain", url: "https://agents.example.com", status: "READY", admin: "503" },
  { name: "domain awaiting TLS", mode: "domain", url: "https://agents.example.com", status: "TLS_PENDING", admin: "200" },
  { name: "domain awaiting TLS and runtime", mode: "domain", url: "https://agents.example.com", status: "TLS_PENDING", admin: "200", runtime: "0" },
]) {
  test(`completion summary: ${scenario.name}`, () => {
    const runtime = scenario.runtime ?? (scenario.status === "READY_NO_RUNTIME" ? "0" : "1");
    const result = spawnSync("sh", ["-eu", "-c", '. "$1"; slab_ui_print_completion "$2" "$3" "$4"', "test",
      path.join(root, "installer/lib/ui.sh"), scenario.status, scenario.admin, runtime], {
      encoding: "utf8",
      env: { ...process.env, NO_COLOR: "1", SLAB_ACCESS_MODE: scenario.mode,
        SLAB_PRIVATE_BIND_IP: scenario.ip ?? "", SLAB_PRIVATE_PORT: "3009", SLAB_PUBLIC_URL: scenario.url },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /SLAB INSTALLATION COMPLETE/);
    assert.ok(result.stdout.includes(scenario.url));
    assert.ok(result.stdout.includes(`Installation status: ${scenario.status}`));
    assert.match(result.stdout, /sudo slabctl changepass/);
    assert.doesNotMatch(result.stdout, /\u001b\[/);
    if (scenario.admin === "200") {
      assert.match(result.stdout, /existing administrator password was kept/);
      assert.doesNotMatch(result.stdout, /password you just created/);
    } else {
      assert.match(result.stdout, /password you just created/);
    }
    if (scenario.ip === "127.0.0.1") assert.match(result.stdout, /ssh -L 3009:127.0.0.1:3009/);
    if (runtime === "0") assert.match(result.stdout, /sudo slabctl codex login/);
    else assert.doesNotMatch(result.stdout, /sudo slabctl codex login/);
    if (scenario.status === "TLS_PENDING") {
      assert.match(result.stdout, /address is not ready yet/);
      assert.match(result.stdout, /sudo slabctl domain verify/);
      assert.doesNotMatch(result.stdout, /HTTPS is ready/);
    }
  });
}
