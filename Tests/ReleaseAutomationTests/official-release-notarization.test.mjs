import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const script = new URL("../../scripts/notarize_official_release.sh", import.meta.url);

async function runNotarization({ failStage = "" } = {}) {
  const root = await mkdtemp(join(tmpdir(), "sr-notary-test-"));
  const log = join(root, "commands.log");
  const dmg = join(root, "SelectiveRemote-0.32.0-arm64.dmg");
  await writeFile(dmg, "test-only-dmg");

  const fakeXcrun = join(root, "xcrun");
  await writeFile(fakeXcrun, `#!/bin/bash
set -eu
printf 'xcrun %s\\n' "$*" >> "$COMMAND_LOG"
if [[ "$FAIL_STAGE" == "notary" && "$1" == "notarytool" ]]; then exit 41; fi
if [[ "$FAIL_STAGE" == "staple" && "$1 $2" == "stapler staple" ]]; then exit 42; fi
`);
  await chmod(fakeXcrun, 0o755);

  const fakeSpctl = join(root, "spctl");
  await writeFile(fakeSpctl, `#!/bin/bash
set -eu
printf 'spctl %s\\n' "$*" >> "$COMMAND_LOG"
`);
  await chmod(fakeSpctl, 0o755);

  const result = spawnSync("/bin/bash", [script.pathname, dmg], {
    encoding: "utf8",
    env: {
      ...process.env,
      PATH: `${root}:${process.env.PATH}`,
      COMMAND_LOG: log,
      FAIL_STAGE: failStage,
      SELECTIVEREMOTE_NOTARY_PROFILE: "TEST-ONLY-NOTARY-PROFILE",
    },
  });
  const commands = await readFile(log, "utf8").catch(() => "");
  return { result, commands };
}

test("official notarization completes submit, staple, validate, and Gatekeeper checks", async () => {
  const { result, commands } = await runNotarization();
  assert.equal(result.status, 0, result.stderr);
  assert.match(commands, /xcrun notarytool submit .* --wait/u);
  assert.match(commands, /xcrun stapler staple/u);
  assert.match(commands, /xcrun stapler validate/u);
  assert.match(commands, /spctl --assess --type open/u);
});

test("failed notarization aborts before stapling", async () => {
  const { result, commands } = await runNotarization({ failStage: "notary" });
  assert.equal(result.status, 41);
  assert.match(commands, /xcrun notarytool submit/u);
  assert.doesNotMatch(commands, /stapler/u);
  assert.doesNotMatch(commands, /spctl/u);
});

test("failed stapling aborts before validation and Gatekeeper", async () => {
  const { result, commands } = await runNotarization({ failStage: "staple" });
  assert.equal(result.status, 42);
  assert.match(commands, /xcrun notarytool submit/u);
  assert.match(commands, /xcrun stapler staple/u);
  assert.doesNotMatch(commands, /stapler validate/u);
  assert.doesNotMatch(commands, /spctl/u);
});
