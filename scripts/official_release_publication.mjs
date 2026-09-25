import { createHash } from "node:crypto";
import { execFile as execFileCallback } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { promisify } from "node:util";

const RELEASE_OWNER = "PastFly";
const RELEASE_REPOSITORY = "Selective-Remote";
const execFile = promisify(execFileCallback);

async function git(repositoryPath, ...arguments_) {
  const { stdout } = await execFile("git", ["-C", repositoryPath, ...arguments_], {
    maxBuffer: 1024 * 1024,
  });
  return stdout.trim();
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function assetNames(version) {
  const dmgName = `SelectiveRemote-${version}-arm64.dmg`;
  return { dmgName, hashName: `${dmgName}.sha256` };
}

function readChecksum(text, dmgName) {
  const match = text.match(/^([a-f0-9]{64})  ([^\r\n]+)\r?\n?$/u);
  if (!match || match[2] !== dmgName) {
    throw new Error("release checksum sidecar has an invalid name or format");
  }
  return match[1];
}

export async function validateLocalArtifacts(dmgPath, hashPath, version) {
  const { dmgName, hashName } = assetNames(version);
  if (basename(dmgPath) !== dmgName || basename(hashPath) !== hashName) {
    throw new Error("official DMG or checksum filename does not match release version");
  }
  let dmg;
  try {
    dmg = await readFile(dmgPath);
  } catch {
    throw new Error("official DMG is missing");
  }
  if (dmg.length === 0) throw new Error("official DMG is empty");
  let checksum;
  try {
    checksum = await readFile(hashPath, "utf8");
  } catch {
    throw new Error("official DMG checksum sidecar is missing");
  }
  const digest = sha256(dmg);
  if (readChecksum(checksum, dmgName) !== digest) {
    throw new Error("official DMG checksum does not match its bytes");
  }
  return { dmgPath, hashPath, dmgName, hashName, digest };
}

export function validateReleaseAssets(release, checksumText, version, localDigest) {
  const { dmgName, hashName } = assetNames(version);
  if (!release || release.tag_name !== `v${version}`) {
    throw new Error("release tag does not match the candidate manifest");
  }
  const assets = release.assets ?? [];
  for (const name of [dmgName, hashName]) {
    if (assets.filter((asset) => asset.name === name).length !== 1) {
      throw new Error(`missing release asset ${name}`);
    }
  }
  if (assets.length !== 2) throw new Error("release has unexpected assets");
  const dmg = assets.find((asset) => asset.name === dmgName);
  const hash = assets.find((asset) => asset.name === hashName);
  const expectedDigest = readChecksum(checksumText, dmgName);
  if (dmg.size <= 0 || dmg.digest !== `sha256:${expectedDigest}`) {
    throw new Error("published DMG digest does not match checksum sidecar");
  }
  if (hash.size !== Buffer.byteLength(checksumText)
      || hash.digest !== `sha256:${sha256(checksumText)}`) {
    throw new Error("published checksum asset does not match its bytes");
  }
  if (localDigest && localDigest !== expectedDigest) {
    throw new Error("published checksum differs from locally verified DMG");
  }
  return expectedDigest;
}

export async function runReleasePublication({ tag, version, sourceCommit, operations }) {
  await operations.verifyTag(tag, sourceCommit);
  let release = await operations.getRelease(tag);
  let localDigest;

  if (!release || release.draft) {
    await operations.buildOfficial();
    const local = await operations.localArtifacts(version);
    localDigest = local.digest;
    if (!release) await operations.createDraft(tag);
    await operations.uploadAssets(tag, local);
    release = await operations.getRelease(tag);
    if (!release?.draft) {
      throw new Error("release must remain draft until assets are verified");
    }
    validateReleaseAssets(
      release, await operations.readChecksumAsset(tag), version, localDigest,
    );
    await operations.publishDraft(tag);
  }

  release = await operations.getRelease(tag);
  if (!release || release.draft) {
    throw new Error("official release is not published");
  }
  validateReleaseAssets(
    release, await operations.readChecksumAsset(tag), version, localDigest,
  );
  const feedAdvanced = await operations.promoteFeed(tag, sourceCommit);
  return { feedAdvanced };
}

export async function promotePublicFeed({ repositoryPath, tagCommit }) {
  const candidateText = await readFile(
    join(repositoryPath, "Resources/updates.candidate.json"), "utf8",
  );
  const candidate = JSON.parse(candidateText);
  await git(repositoryPath, "fetch", "origin", "main");
  const mainHead = await git(repositoryPath, "rev-parse", "origin/main");
  const publicText = await git(repositoryPath, "show", "origin/main:Resources/updates.json");
  const publicManifest = JSON.parse(publicText);
  if (JSON.stringify(publicManifest) === JSON.stringify(candidate)) return false;
  if (mainHead !== tagCommit) {
    throw new Error("main changed after the release tag; public feed was not advanced");
  }
  const taggedPublic = JSON.parse(await git(
    repositoryPath, "show", `${tagCommit}:Resources/updates.json`,
  ));
  if (JSON.stringify(publicManifest) !== JSON.stringify(taggedPublic)) {
    throw new Error("public feed changed after the release tag");
  }
  if (!Number.isSafeInteger(candidate.build)
      || !Number.isSafeInteger(publicManifest.build)
      || candidate.build <= publicManifest.build) {
    throw new Error("candidate feed does not advance the public release");
  }

  const tempRoot = await mkdtemp(join(tmpdir(), "sr-publish-feed-"));
  const worktree = join(tempRoot, "worktree");
  let added = false;
  try {
    await git(repositoryPath, "worktree", "add", "--detach", worktree, "origin/main");
    added = true;
    await writeFile(join(worktree, "Resources/updates.json"), candidateText);
    await git(worktree, "add", "Resources/updates.json");
    await git(worktree,
      "-c", "user.name=github-actions[bot]",
      "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
      "commit", "-m", `Publish verified ${candidate.version} update feed`);
    await git(worktree, "push", "origin", "HEAD:refs/heads/main");
  } finally {
    if (added) await git(repositoryPath, "worktree", "remove", worktree);
    await rm(tempRoot, { recursive: true, force: true });
  }
  return true;
}

export const releaseRepository = `${RELEASE_OWNER}/${RELEASE_REPOSITORY}`;
