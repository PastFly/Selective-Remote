import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const OFFICIAL_DOWNLOAD_PREFIX =
  "https://github.com/PastFly/Selective-Remote/releases/download/";
const OFFICIAL_RELEASE_PREFIX =
  "https://github.com/PastFly/Selective-Remote/releases/tag/";

function required(value, message) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(message);
  }
  return value.trim();
}

export function validateOfficialReleasePreflight(input) {
  const version = required(input.version, "release version is required");
  const build = Number(input.build);
  const tag = required(input.tag, "release tag is required");
  const sourceCommit = required(input.sourceCommit, "source commit is required");
  const tagCommit = required(input.tagCommit, "tag commit is required");
  const expectedTag = `v${version}`;

  if (!Number.isSafeInteger(build) || build <= 0) {
    throw new Error("release build must be a positive integer");
  }
  if (tag !== expectedTag) {
    throw new Error(`tag ${tag} does not match version ${version}`);
  }
  if (input.releaseExists) {
    throw new Error(`release ${tag} already exists`);
  }
  if (tagCommit !== sourceCommit) {
    throw new Error(`tag ${tag} does not identify the exact source commit`);
  }
  if (input.manifestVersion !== version || Number(input.manifestBuild) !== build) {
    throw new Error("update manifest version/build does not match release metadata");
  }
  const expectedDownload =
    `${OFFICIAL_DOWNLOAD_PREFIX}${tag}/SelectiveRemote-${version}-arm64.dmg`;
  if (input.manifestDownloadURL !== expectedDownload) {
    throw new Error("update manifest download URL does not match release metadata");
  }
  if (input.manifestReleaseNotesURL !== `${OFFICIAL_RELEASE_PREFIX}${tag}`) {
    throw new Error("update manifest release-notes URL does not match release metadata");
  }

  const teamID = required(input.expectedTeamID, "expected Team ID is required");
  if (!/^[A-Z0-9]{10}$/u.test(teamID)) {
    throw new Error("expected Team ID must be ten uppercase letters or digits");
  }
  const signingIdentity = required(
    input.signingIdentity,
    "Developer ID Application identity is required",
  );
  if (!signingIdentity.startsWith("Developer ID Application: ")) {
    throw new Error("Developer ID Application identity is required");
  }
  if (!signingIdentity.endsWith(`(${teamID})`)) {
    throw new Error("signing identity does not match expected Team ID");
  }

  const credentials = input.credentials ?? {};
  required(credentials.p12Base64, "Developer ID certificate is required");
  required(credentials.p12Password, "Developer ID certificate password is required");
  required(credentials.apiKeyBase64, "notarization API key is required");
  required(credentials.apiKeyID, "notarization key ID is required");
  required(credentials.apiIssuerID, "notarization issuer ID is required");

  return { version, build, tag, teamID, signingIdentity };
}

function releaseAssignment(source, name) {
  const match = source.match(new RegExp(`^${name}="([^"]+)"$`, "mu"));
  if (!match) throw new Error(`${name} is missing from scripts/build_app.sh`);
  return match[1];
}

export async function runOfficialReleasePreflight(rootURL, environment = process.env) {
  const [buildScript, manifestText] = await Promise.all([
    readFile(new URL("scripts/build_app.sh", rootURL), "utf8"),
    readFile(new URL("Resources/updates.json", rootURL), "utf8"),
  ]);
  const manifest = JSON.parse(manifestText);
  return validateOfficialReleasePreflight({
    version: releaseAssignment(buildScript, "VERSION"),
    build: Number(releaseAssignment(buildScript, "BUILD_NUMBER")),
    tag: environment.TAG,
    releaseExists: environment.RELEASE_EXISTS === "true",
    tagCommit: environment.TAG_COMMIT,
    sourceCommit: environment.SOURCE_COMMIT,
    manifestVersion: manifest.version,
    manifestBuild: manifest.build,
    manifestDownloadURL: manifest.downloadURL,
    manifestReleaseNotesURL: manifest.releaseNotesURL,
    expectedTeamID: environment.EXPECTED_TEAM_ID,
    signingIdentity: environment.EXPECTED_SIGNING_IDENTITY,
    credentials: {
      p12Base64: environment.P12_BASE64,
      p12Password: environment.P12_PASSWORD,
      apiKeyBase64: environment.API_KEY_BASE64,
      apiKeyID: environment.API_KEY_ID,
      apiIssuerID: environment.API_ISSUER_ID,
    },
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  try {
    const result = await runOfficialReleasePreflight(
      new URL("../", import.meta.url),
    );
    process.stdout.write(
      `Official release preflight passed for ${result.tag} (${result.build}).\n`,
    );
  } catch (error) {
    process.stderr.write(`Official release preflight failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
