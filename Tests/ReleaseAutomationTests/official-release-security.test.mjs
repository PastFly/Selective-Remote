import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  validateOfficialReleasePreflight,
} from "../../scripts/official_release_preflight.mjs";

const completeInput = Object.freeze({
  version: "0.32.0",
  build: 163,
  tag: "v0.32.0",
  releaseExists: false,
  tagCommit: "a".repeat(40),
  sourceCommit: "a".repeat(40),
  manifestVersion: "0.32.0",
  manifestBuild: 163,
  manifestDownloadURL:
    "https://github.com/PastFly/Selective-Remote/releases/download/"
      + "v0.32.0/SelectiveRemote-0.32.0-arm64.dmg",
  manifestReleaseNotesURL:
    "https://github.com/PastFly/Selective-Remote/releases/tag/v0.32.0",
  expectedTeamID: "ABCDE12345",
  signingIdentity: "Developer ID Application: Example Company (ABCDE12345)",
  credentials: {
    p12Base64: "test-p12-base64",
    p12Password: "test-p12-password",
    apiKeyBase64: "test-api-key-base64",
    apiKeyID: "TESTKEY123",
    apiIssuerID: "00000000-0000-0000-0000-000000000000",
  },
});

function withInput(overrides = {}) {
  return {
    ...completeInput,
    ...overrides,
    credentials: {
      ...completeInput.credentials,
      ...(overrides.credentials ?? {}),
    },
  };
}

test("accepts a complete exact official-release preflight", () => {
  assert.deepEqual(validateOfficialReleasePreflight(withInput()), {
    version: "0.32.0",
    build: 163,
    tag: "v0.32.0",
    teamID: "ABCDE12345",
    signingIdentity: "Developer ID Application: Example Company (ABCDE12345)",
  });
});

test("blocks an already published release tag", () => {
  assert.throws(
    () => validateOfficialReleasePreflight(withInput({ releaseExists: true })),
    /release v0\.32\.0 already exists/u,
  );
});

test("blocks a stale tag that does not identify the exact source commit", () => {
  assert.throws(
    () => validateOfficialReleasePreflight(withInput({ tagCommit: "b".repeat(40) })),
    /tag v0\.32\.0 does not identify the exact source commit/u,
  );
});

test("blocks a missing Developer ID Application identity", () => {
  assert.throws(
    () => validateOfficialReleasePreflight(withInput({ signingIdentity: "" })),
    /Developer ID Application identity is required/u,
  );
});

test("blocks an ad-hoc identity presented as official", () => {
  assert.throws(
    () => validateOfficialReleasePreflight(withInput({ signingIdentity: "-" })),
    /Developer ID Application identity is required/u,
  );
});

test("blocks a signing identity for a different Team ID", () => {
  assert.throws(
    () => validateOfficialReleasePreflight(withInput({
      signingIdentity: "Developer ID Application: Example Company (ZZZZZ99999)",
    })),
    /signing identity does not match expected Team ID/u,
  );
});

for (const [field, message] of [
  ["p12Base64", "Developer ID certificate is required"],
  ["p12Password", "Developer ID certificate password is required"],
  ["apiKeyBase64", "notarization API key is required"],
  ["apiKeyID", "notarization key ID is required"],
  ["apiIssuerID", "notarization issuer ID is required"],
]) {
  test(`blocks missing official credential: ${field}`, () => {
    assert.throws(
      () => validateOfficialReleasePreflight(withInput({
        credentials: { [field]: "" },
      })),
      new RegExp(message, "u"),
    );
  });
}

test("does not disclose credential values in validation errors", () => {
  const secret = "TEST-ONLY-SHOULD-NOT-LEAK";
  const input = withInput({
    signingIdentity: "invalid",
    credentials: {
      p12Base64: secret,
      p12Password: secret,
      apiKeyBase64: secret,
    },
  });

  assert.throws(
    () => validateOfficialReleasePreflight(input),
    (error) => {
      assert.doesNotMatch(String(error), new RegExp(secret, "u"));
      return true;
    },
  );
});

test("official publication is manual and community DMG is an explicit separate mode", async () => {
  const [releaseWorkflow, testDMGWorkflow, buildScript, installScript] = await Promise.all([
    readFile(new URL("../../.github/workflows/release.yml", import.meta.url), "utf8"),
    readFile(new URL("../../.github/workflows/test-dmg.yml", import.meta.url), "utf8"),
    readFile(new URL("../../scripts/build_app.sh", import.meta.url), "utf8"),
    readFile(new URL("../../scripts/build_and_install.sh", import.meta.url), "utf8"),
  ]);

  assert.match(releaseWorkflow, /workflow_dispatch:/u);
  assert.doesNotMatch(releaseWorkflow, /\n\s+push:\s*\n/u);
  assert.match(releaseWorkflow, /SELECTIVEREMOTE_RELEASE_MODE:\s*official/u);
  assert.match(releaseWorkflow, /EXPECTED_TEAM_ID:\s*\$\{\{ vars\.APPLE_TEAM_ID \}\}/u);
  assert.match(releaseWorkflow, /EXPECTED_SIGNING_IDENTITY:\s*\$\{\{ vars\.DEVELOPER_ID_APPLICATION_IDENTITY \}\}/u);
  assert.match(releaseWorkflow, /official_release_preflight\.mjs/u);
  assert.match(releaseWorkflow, /SOURCE_COMMIT:\s*\$\{\{ steps\.release\.outputs\.source_commit \}\}/u);
  assert.doesNotMatch(releaseWorkflow, /tag_commit[^\n]*GITHUB_SHA/u);
  assert.doesNotMatch(releaseWorkflow, /ad-hoc signed community DMG/u);
  assert.match(testDMGWorkflow, /SELECTIVEREMOTE_RELEASE_MODE:\s*community/u);
  assert.match(buildScript, /SELECTIVEREMOTE_RELEASE_MODE:-/u);
  assert.match(buildScript, /official\)\s*[\s\S]*Developer\\ ID\\ Application:/u);
  assert.match(buildScript, /community\)\s*[\s\S]*SIGN_IDENTITY="-"/u);
  assert.doesNotMatch(buildScript, /find-identity[^\n]*Developer ID Application/u);
  assert.match(installScript, /SELECTIVEREMOTE_RELEASE_MODE=community/u);
});
