import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = fileURLToPath(new URL("../../", import.meta.url));

test("0.32.0 release page renders both detailed languages", () => {
  const notes = execFileSync("python3", ["scripts/release_notes.py", "0.32.0"], {
    cwd: root,
    encoding: "utf8",
  });
  assert.match(notes, /Кандидат Selective Remote 0\.32 готовит первый публичный выпуск с Cloud/u);
  assert.match(notes, /The Selective Remote 0\.32 candidate prepares the first public release with Cloud/u);
  assert.match(notes, /Jump Host/u);
  assert.match(notes, /Keychain/u);
  assert.doesNotMatch(notes, /FINAL_DETAILED_RELEASE_NOTES|SHORT_GITHUB_RELEASE_NOTES/u);
});

test("app What's New RU/EN matches the release note source", async () => {
  const source = await readFile(new URL("../../releases/0.32.0-notes.md", import.meta.url), "utf8");
  for (const [language, changelog] of [
    ["RU", "CHANGELOG.md"], ["EN", "CHANGELOG_EN.md"],
  ]) {
    const marker = `## APP_WHATS_NEW_${language}\n`;
    const appCopy = source.split(marker)[1]?.split("\n## ")[0]?.trim();
    assert.ok(appCopy, `missing ${language} app copy`);
    const installedHistory = await readFile(new URL(`../../${changelog}`, import.meta.url), "utf8");
    const versionCopy = installedHistory.split("## 0.32.0\n")[1]?.split("\n## 0.31.0")[0]?.trim();
    assert.equal(versionCopy, appCopy);
  }
});
