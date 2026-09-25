import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";

import {
  runOfficialReleasePreflight,
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

test("public update feed stays on the downloadable 0.31.0 release before 0.32.0 publication", async () => {
  const publicFeed = JSON.parse(await readFile(
    new URL("../../Resources/updates.json", import.meta.url), "utf8",
  ));
  assert.equal(publicFeed.version, "0.31.0");
  assert.equal(publicFeed.build, 162);
  assert.equal(publicFeed.downloadURL,
    "https://github.com/PastFly/Selective-Remote/releases/download/"
      + "v0.31.0/SelectiveRemote-0.31.0-arm64.dmg");
});

test("official preflight reads the tagged candidate while public feed remains 0.31.0", async () => {
  const root = await mkdtemp(join(tmpdir(), "sr-release-preflight-"));
  try {
    await mkdir(join(root, "scripts"));
    await mkdir(join(root, "Resources"));
    await writeFile(join(root, "scripts/build_app.sh"),
      'VERSION="0.32.0"\nBUILD_NUMBER="163"\n');
    const publicFeed = {
      version: "0.31.0", build: 162,
      downloadURL: "https://github.com/PastFly/Selective-Remote/releases/download/"
        + "v0.31.0/SelectiveRemote-0.31.0-arm64.dmg",
      releaseNotesURL:
        "https://github.com/PastFly/Selective-Remote/releases/tag/v0.31.0",
    };
    const candidate = {
      ...publicFeed, version: "0.32.0", build: 163,
      downloadURL: completeInput.manifestDownloadURL,
      releaseNotesURL: completeInput.manifestReleaseNotesURL,
    };
    await writeFile(join(root, "Resources/updates.json"), JSON.stringify(publicFeed));
    await writeFile(join(root, "Resources/updates.candidate.json"), JSON.stringify(candidate));
    const env = {
      TAG: completeInput.tag,
      TAG_COMMIT: completeInput.tagCommit,
      SOURCE_COMMIT: completeInput.sourceCommit,
      RELEASE_EXISTS: "false",
      EXPECTED_TEAM_ID: completeInput.expectedTeamID,
      EXPECTED_SIGNING_IDENTITY: completeInput.signingIdentity,
      P12_BASE64: completeInput.credentials.p12Base64,
      P12_PASSWORD: completeInput.credentials.p12Password,
      API_KEY_BASE64: completeInput.credentials.apiKeyBase64,
      API_KEY_ID: completeInput.credentials.apiKeyID,
      API_ISSUER_ID: completeInput.credentials.apiIssuerID,
    };
    const result = await runOfficialReleasePreflight(
      pathToFileURL(root + "/"), env,
    );
    assert.equal(result.version, "0.32.0");
    assert.equal(result.build, 163);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("permits retry preflight for an existing release while keeping exact tag checks", () => {
  assert.equal(
    validateOfficialReleasePreflight(withInput({ releaseExists: true })).tag,
    "v0.32.0",
  );
});

test("blocks a missing release tag before any build or publication", () => {
  assert.throws(
    () => validateOfficialReleasePreflight(withInput({ tag: "" })),
    /release tag is required/u,
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
