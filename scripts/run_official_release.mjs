import { spawn } from "node:child_process";
import { execFile as execFileCallback } from "node:child_process";
import { appendFile, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import { runOfficialReleasePreflight } from "./official_release_preflight.mjs";
import {
  promotePublicFeed,
  releaseRepository,
  runReleasePublication,
  validateLocalArtifacts,
} from "./official_release_publication.mjs";

const execFile = promisify(execFileCallback);
const repositoryPath = fileURLToPath(new URL("../", import.meta.url));

async function capture(program, args) {
  const { stdout } = await execFile(program, args, {
    cwd: repositoryPath,
    maxBuffer: 1024 * 1024,
  });
  return stdout.trim();
}

async function visible(program, args) {
  await new Promise((resolvePromise, reject) => {
    const child = spawn(program, args, {
      cwd: repositoryPath,
      stdio: "inherit",
      env: process.env,
    });
    child.on("error", reject);
    child.on("close", (code) => code === 0
      ? resolvePromise()
      : reject(new Error(`${program} failed with exit code ${code}`)));
  });
}

async function releaseForTag(tag) {
  try {
    const json = await capture("gh", [
      "api", `repos/${releaseRepository}/releases/tags/${tag}`,
    ]);
    return JSON.parse(json);
  } catch (error) {
    if (/HTTP 404/u.test(String(error.stderr ?? ""))) return null;
    throw error;
  }
}

async function downloadedChecksum(tag, version) {
  const name = `SelectiveRemote-${version}-arm64.dmg.sha256`;
  const root = await mkdtemp(join(tmpdir(), "sr-release-checksum-"));
  try {
    await capture("gh", ["release", "download", tag, "--repo",
      releaseRepository, "--pattern", name, "--dir", root]);
    return await readFile(join(root, name), "utf8");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

function productionOperations({ version, sourceCommit }) {
  return {
    async verifyTag(tag) {
      const [head, tagCommit, remoteRefs] = await Promise.all([
        capture("git", ["rev-parse", "HEAD"]),
        capture("git", ["rev-list", "-n", "1", tag]),
        capture("git", ["ls-remote", "--tags", "origin",
          `refs/tags/${tag}`, `refs/tags/${tag}^{}`]),
      ]);
      const lines = remoteRefs.split("\n").filter(Boolean);
      const remoteCommit = (lines.find((line) => line.endsWith(`refs/tags/${tag}^{}`))
        ?? lines.find((line) => line.endsWith(`refs/tags/${tag}`)))?.split("\t")[0];
      if (!remoteCommit || head !== sourceCommit || tagCommit !== sourceCommit
          || remoteCommit !== sourceCommit) {
        throw new Error("release tag is missing or does not match exact checked-out source");
      }
    },
    getRelease: releaseForTag,
    async buildOfficial() {
      await visible("./scripts/build_app.sh", []);
    },
    async localArtifacts() {
      const name = `SelectiveRemote-${version}-arm64.dmg`;
      return validateLocalArtifacts(
        join(repositoryPath, "dist", name),
        join(repositoryPath, "dist", `${name}.sha256`),
        version,
      );
    },
    async createDraft(tag) {
      const notes = await capture("python3", ["scripts/release_notes.py", version]);
      if (!notes) throw new Error("official release notes are empty");
      const root = await mkdtemp(join(tmpdir(), "sr-release-notes-"));
      try {
        const file = join(root, "notes.md");
        await writeFile(file, `${notes}\n`);
        await visible("gh", ["release", "create", tag,
          "--repo", releaseRepository,
          "--draft", "--verify-tag", "--fail-on-no-commits",
          "--title", `Selective Remote ${version}`,
          "--notes-file", file]);
      } finally {
        await rm(root, { recursive: true, force: true });
      }
    },
    async uploadAssets(tag, local) {
      await visible("gh", ["release", "upload", tag,
        local.dmgPath, local.hashPath,
        "--repo", releaseRepository, "--clobber"]);
    },
    readChecksumAsset: (tag) => downloadedChecksum(tag, version),
    async publishDraft(tag) {
      await visible("gh", ["release", "edit", tag,
        "--repo", releaseRepository, "--draft=false", "--latest"]);
    },
    async promoteFeed(_tag, tagCommit) {
      return promotePublicFeed({ repositoryPath, tagCommit });
    },
  };
}

async function main() {
  if (process.env.GITHUB_ACTIONS !== "true"
      || process.env.SELECTIVEREMOTE_RELEASE_MODE !== "official"
      || !process.env.GH_TOKEN) {
    throw new Error("official publication requires the protected GitHub Actions workflow");
  }
  const preflight = await runOfficialReleasePreflight(
    new URL("../", import.meta.url), process.env,
  );
  const result = await runReleasePublication({
    tag: preflight.tag,
    version: preflight.version,
    sourceCommit: process.env.SOURCE_COMMIT,
    operations: productionOperations({
      version: preflight.version,
      sourceCommit: process.env.SOURCE_COMMIT,
    }),
  });
  if (result.feedAdvanced && process.env.GITHUB_OUTPUT) {
    await appendFile(process.env.GITHUB_OUTPUT, "published=true\n");
  }
  process.stdout.write(result.feedAdvanced
    ? `Verified ${preflight.tag} published; public feed advanced.\n`
    : `Verified ${preflight.tag}; public feed already current.\n`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`Official release publication failed: ${error.message}\n`);
    process.exitCode = 1;
  });
}
