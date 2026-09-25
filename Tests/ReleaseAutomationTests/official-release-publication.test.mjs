import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  runReleasePublication,
  promotePublicFeed,
  validateLocalArtifacts,
  validateReleaseAssets,
} from "../../scripts/official_release_publication.mjs";

const tag = "v0.32.0";
const version = "0.32.0";
const sourceCommit = "a".repeat(40);
const dmgName = "SelectiveRemote-0.32.0-arm64.dmg";
const hashName = `${dmgName}.sha256`;
const dmgBytes = Buffer.from("test-only-dmg");
const digest = createHash("sha256").update(dmgBytes).digest("hex");
const checksumText = `${digest}  ${dmgName}\n`;
const checksumDigest = createHash("sha256").update(checksumText).digest("hex");

function release({ draft = true, assets = true } = {}) {
  return {
    tag_name: tag,
    draft,
    assets: assets ? [
      { name: dmgName, size: dmgBytes.length, digest: `sha256:${digest}` },
      { name: hashName, size: Buffer.byteLength(checksumText),
        digest: `sha256:${checksumDigest}` },
    ] : [],
  };
}

function scenario({ initialRelease = null, failAt = "", checksum = checksumText } = {}) {
  let publicVersion = "0.31.0";
  let remoteRelease = initialRelease;
  const stages = [];
  const maybeFail = (name) => {
    stages.push(name);
    if (failAt === name) throw new Error(`test-only ${name} failure`);
  };
  const operations = {
    async verifyTag() { maybeFail("verifyTag"); },
    async getRelease() { stages.push("getRelease"); return remoteRelease; },
    async buildOfficial() { maybeFail("buildOfficial"); },
    async localArtifacts() {
      maybeFail("localArtifacts");
      return { dmgName, hashName, digest };
    },
    async createDraft() {
      maybeFail("createDraft");
      remoteRelease = release({ assets: false });
    },
    async uploadAssets() {
      maybeFail("uploadAssets");
      remoteRelease = release();
    },
    async readChecksumAsset() {
      stages.push("readChecksumAsset");
      return checksum;
    },
    async publishDraft() {
      maybeFail("publishDraft");
      remoteRelease = release({ draft: false });
    },
    async verifyPublishedArtifact() { maybeFail("verifyPublishedArtifact"); },
    async promoteFeed() {
      maybeFail("promoteFeed");
      if (publicVersion === version) return false;
      publicVersion = version;
      return true;
    },
  };
  return {
    operations, stages,
    get publicVersion() { return publicVersion; },
    get remoteRelease() { return remoteRelease; },
  };
}

for (const [name, stage] of [
  ["missing tag", "verifyTag"],
  ["failed signing", "buildOfficial"],
  ["failed notarization", "buildOfficial"],
  ["failed stapling", "buildOfficial"],
  ["missing DMG", "localArtifacts"],
  ["failed draft creation", "createDraft"],
  ["failed asset publication", "uploadAssets"],
  ["failed release publication", "publishDraft"],
]) {
  test(`${name} leaves the public feed at the previous release`, async () => {
    const state = scenario({ failAt: stage });
    await assert.rejects(
      runReleasePublication({ tag, version, sourceCommit,
        operations: state.operations }),
      new RegExp(`test-only ${stage} failure`, "u"),
    );
    assert.equal(state.publicVersion, "0.31.0");
    assert.ok(!state.stages.includes("promoteFeed"));
  });
}

test("existing tag without a release stages and verifies assets before feed promotion", async () => {
  const state = scenario();
  const result = await runReleasePublication({ tag, version, sourceCommit,
    operations: state.operations });
  assert.equal(result.feedAdvanced, true);
  assert.equal(state.publicVersion, version);
  assert.equal(state.remoteRelease.draft, false);
  assert.ok(state.stages.indexOf("publishDraft") < state.stages.indexOf("promoteFeed"));
  assert.ok(state.stages.indexOf("verifyPublishedArtifact") < state.stages.indexOf("promoteFeed"));
});

test("missing DMG on a published release blocks retry and keeps the previous feed", async () => {
  const state = scenario({ initialRelease: release({ draft: false, assets: false }) });
  await assert.rejects(
    runReleasePublication({ tag, version, sourceCommit,
      operations: state.operations }),
    /missing release asset.*\.dmg/u,
  );
  assert.equal(state.publicVersion, "0.31.0");
});

test("wrong remote checksum blocks release publication and feed promotion", async () => {
  const state = scenario({ checksum: `${"f".repeat(64)}  ${dmgName}\n` });
  await assert.rejects(
    runReleasePublication({ tag, version, sourceCommit,
      operations: state.operations }),
    /checksum/u,
  );
  assert.equal(state.publicVersion, "0.31.0");
  assert.equal(state.remoteRelease.draft, true);
});

test("wrong checksum on an already published release blocks feed promotion", async () => {
  const state = scenario({
    initialRelease: release({ draft: false }),
    checksum: `${"f".repeat(64)}  ${dmgName}\n`,
  });
  await assert.rejects(
    runReleasePublication({ tag, version, sourceCommit,
      operations: state.operations }),
    /checksum/u,
  );
  assert.equal(state.publicVersion, "0.31.0");
  assert.ok(!state.stages.includes("promoteFeed"));
});

test("feed push failure preserves the previous public version for retry", async () => {
  const state = scenario({ failAt: "promoteFeed" });
  await assert.rejects(
    runReleasePublication({ tag, version, sourceCommit,
      operations: state.operations }),
    /test-only promoteFeed failure/u,
  );
  assert.equal(state.remoteRelease.draft, false);
  assert.equal(state.publicVersion, "0.31.0");
});

test("an already published DMG failing signature/notary verification cannot advance the feed", async () => {
  const state = scenario({
    initialRelease: release({ draft: false }),
    failAt: "verifyPublishedArtifact",
  });
  await assert.rejects(
    runReleasePublication({ tag, version, sourceCommit,
      operations: state.operations }),
    /test-only verifyPublishedArtifact failure/u,
  );
  assert.equal(state.publicVersion, "0.31.0");
  assert.ok(!state.stages.includes("promoteFeed"));
});

test("retry completes a published release whose feed promotion previously failed", async () => {
  const state = scenario({ initialRelease: release({ draft: false }) });
  const result = await runReleasePublication({ tag, version, sourceCommit,
    operations: state.operations });
  assert.equal(result.feedAdvanced, true);
  assert.equal(state.publicVersion, version);
  assert.ok(!state.stages.includes("buildOfficial"));

  const again = await runReleasePublication({ tag, version, sourceCommit,
    operations: state.operations });
  assert.equal(again.feedAdvanced, false);
  assert.equal(state.publicVersion, version);
});

test("local and published assets must match the exact SHA-256 sidecar", async () => {
  const root = await mkdtemp(join(tmpdir(), "sr-release-assets-"));
  try {
    const dmg = join(root, dmgName);
    const sidecar = join(root, hashName);
    await writeFile(dmg, dmgBytes);
    await writeFile(sidecar, checksumText);
    const local = await validateLocalArtifacts(dmg, sidecar, version);
    assert.equal(local.digest, digest);
    assert.doesNotThrow(() => validateReleaseAssets(
      release({ draft: false }), checksumText, version, digest,
    ));
    await writeFile(sidecar, `${"f".repeat(64)}  ${dmgName}\n`);
    await assert.rejects(validateLocalArtifacts(dmg, sidecar, version), /checksum/u);
    await rm(dmg);
    await assert.rejects(validateLocalArtifacts(dmg, sidecar, version), /DMG/u);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("feed promotion pushes one verified manifest commit and a retry is idempotent", async () => {
  const root = await mkdtemp(join(tmpdir(), "sr-feed-push-"));
  const remote = join(root, "remote.git");
  const checkout = join(root, "checkout");
  const git = (...args) => execFileSync("git", args, { encoding: "utf8" }).trim();
  try {
    git("init", "--bare", "--initial-branch=main", remote);
    git("clone", remote, checkout);
    git("-C", checkout, "config", "user.name", "Test Release Bot");
    git("-C", checkout, "config", "user.email", "release@example.invalid");
    await mkdir(join(checkout, "Resources"));
    const previous = JSON.stringify({ version: "0.31.0", build: 162 });
    const candidate = JSON.stringify({ version: "0.32.0", build: 163 });
    await writeFile(join(checkout, "Resources/updates.json"), previous);
    await writeFile(join(checkout, "Resources/updates.candidate.json"), candidate);
    git("-C", checkout, "add", "Resources");
    git("-C", checkout, "commit", "-m", "test-only initial feed");
    git("-C", checkout, "push", "origin", "main");
    const tagCommit = git("-C", checkout, "rev-parse", "HEAD");

    const first = await promotePublicFeed({ repositoryPath: checkout, tagCommit });
    assert.equal(first, true);
    const published = git("--git-dir", remote, "show", "main:Resources/updates.json");
    assert.deepEqual(JSON.parse(published), { version: "0.32.0", build: 163 });
    const head = git("--git-dir", remote, "rev-parse", "main");
    assert.notEqual(head, tagCommit);

    const second = await promotePublicFeed({ repositoryPath: checkout, tagCommit });
    assert.equal(second, false);
    assert.equal(git("--git-dir", remote, "rev-parse", "main"), head);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("a changed main with the previous feed cannot be overwritten by a stale tag", async () => {
  const root = await mkdtemp(join(tmpdir(), "sr-feed-race-"));
  const remote = join(root, "remote.git");
  const checkout = join(root, "checkout");
  const git = (...args) => execFileSync("git", args, { encoding: "utf8" }).trim();
  try {
    git("init", "--bare", "--initial-branch=main", remote);
    git("clone", remote, checkout);
    git("-C", checkout, "config", "user.name", "Test Release Bot");
    git("-C", checkout, "config", "user.email", "release@example.invalid");
    await mkdir(join(checkout, "Resources"));
    await writeFile(join(checkout, "Resources/updates.json"),
      JSON.stringify({ version: "0.31.0", build: 162 }));
    await writeFile(join(checkout, "Resources/updates.candidate.json"),
      JSON.stringify({ version: "0.32.0", build: 163 }));
    git("-C", checkout, "add", "Resources");
    git("-C", checkout, "commit", "-m", "test-only tagged source");
    git("-C", checkout, "push", "origin", "main");
    const tagCommit = git("-C", checkout, "rev-parse", "HEAD");
    await writeFile(join(checkout, "other.txt"), "concurrent change");
    git("-C", checkout, "add", "other.txt");
    git("-C", checkout, "commit", "-m", "test-only concurrent main");
    git("-C", checkout, "push", "origin", "main");

    await assert.rejects(
      promotePublicFeed({ repositoryPath: checkout, tagCommit }),
      /main changed after the release tag/u,
    );
    assert.deepEqual(JSON.parse(git("--git-dir", remote,
      "show", "main:Resources/updates.json")),
      { version: "0.31.0", build: 162 });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
