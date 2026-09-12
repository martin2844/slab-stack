import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

for (const failure of [false, true]) test(`WhatsApp host install ${failure ? "keeps configuration on failure" : "starts only WAHA and preserves existing profiles"}`, () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "slab-whatsapp-install-"));
  fs.mkdirSync(path.join(directory, "config"));
  const environment = path.join(directory, "config/install.env");
  const original = "COMPOSE_PROFILES=memory\nSLAB_WHATSAPP_ENABLED=false\nSLAB_PUBLIC_URL=https://agents.example.com\n";
  fs.writeFileSync(environment, original);
  try {
    const result = spawnSync("sh", ["-c", `set -eu
. "$1"
SLABCTL_INSTALL_DIRECTORY=$2
SLABCTL_ENVIRONMENT_FILE=$2/config/install.env
slabctl_compose() {
  printf '%s\\n' "$*" >> "$SLABCTL_INSTALL_DIRECTORY/calls"
  case "$*" in
    '--profile whatsapp config --services') printf '%s\\n' slab-whatsapp ;;
    '--profile whatsapp pull slab-whatsapp') ;;
    '--profile whatsapp up -d --no-deps --wait --wait-timeout 180 slab-whatsapp') ${failure ? "return 7" : ":"} ;;
    *) return 9 ;;
  esac
}
slabctl_install_whatsapp`, "test", path.resolve("installer/lib/update.sh"), directory], { encoding: "utf8" });
    assert.equal(result.status, failure ? 1 : 0, result.stderr);
    const saved = fs.readFileSync(environment, "utf8");
    if (failure) assert.equal(saved, original);
    else { assert.match(saved, /^COMPOSE_PROFILES=memory,whatsapp$/m); assert.match(saved, /^SLAB_WHATSAPP_ENABLED=true$/m); assert.match(saved, /^SLAB_PUBLIC_URL=https:\/\/agents.example.com$/m); }
    assert.equal(fs.readFileSync(path.join(directory, "calls"), "utf8").trim().split("\n").length, 3);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
