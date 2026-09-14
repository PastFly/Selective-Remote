import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  buildTelegramReleaseMessage,
  compactReleaseBody,
  DEFAULT_SUPPORT_URL,
  releaseBodyToPlainText,
} from "../../scripts/telegram_release_message.mjs";

test("converts GitHub release Markdown into readable Telegram text", () => {
  const result = releaseBodyToPlainText([
    "## Что изменилось",
    "",
    "- Добавлен **Team Vault**",
    "- Исправлен SFTP",
    "- [Полная история](https://example.invalid/changelog)",
  ].join("\n"));

  assert.match(result, /^Что изменилось/mu);
  assert.match(result, /• Добавлен Team Vault/u);
  assert.doesNotMatch(result, /\*\*/u);
  assert.match(result, /Исправлен SFTP/u);
  assert.match(result, /Полная история — https:\/\/example\.invalid\/changelog/u);
  assert.doesNotMatch(result, /^##/mu);
});

test("keeps release announcements to six highlights and one release link", () => {
  const bullets = Array.from(
    { length: 10 },
    (_, index) => "- Изменение " + (index + 1),
  ).join("\n");
  const compact = compactReleaseBody(
    releaseBodyToPlainText(
      "## Что изменилось в 0.32.0\n\n"
        + bullets
        + "\n\n---\nПолная история: [CHANGELOG.md](https://example.invalid/CHANGELOG.md)",
    ),
  );

  assert.equal((compact.match(/^• /gmu) ?? []).length, 7);
  assert.match(compact, /• Изменение 6/u);
  assert.doesNotMatch(compact, /Изменение 7/u);
  assert.match(compact, /Остальные изменения — на странице релиза/u);
  assert.doesNotMatch(compact, /CHANGELOG/u);
});

test("builds a stable release announcement with download and donation links", () => {
  const message = buildTelegramReleaseMessage({
    tag_name: "v0.32.0",
    name: "Selective Remote 0.32.0",
    body: "- Командные хосты\n- Синхронизация",
    html_url: "https://github.com/PastFly/Selective-Remote/releases/tag/v0.32.0",
    prerelease: false,
  }, {
    donationURL: "https://example.invalid/donate",
  });

  assert.match(message, /^🚀 Selective Remote 0\.32\.0/u);
  assert.match(message, /Доступна новая версия приложения/u);
  assert.match(message, /• Командные хосты/u);
  assert.match(message, /📦 Скачать/u);
  assert.match(message, /❤️ Поддержать разработку/u);
  assert.ok(Array.from(message).length <= 3900);
});

test("includes the canonical support page when no donation override is provided", () => {
  const message = buildTelegramReleaseMessage({
    tag_name: "v0.32.0",
    name: "Selective Remote 0.32.0",
    body: "- Улучшена синхронизация",
    html_url: "https://example.invalid/release",
    prerelease: false,
  });

  assert.match(message, /❤️ Поддержать разработку/u);
  assert.ok(message.includes(DEFAULT_SUPPORT_URL));
});

test("removes a release-owned summary heading after the fixed introduction", () => {
  const message = buildTelegramReleaseMessage({
    tag_name: "v0.31.0",
    name: "Selective Remote 0.31.0",
    body: "## Что изменилось в 0.31.0\n\n- Исправлена навигация",
    html_url: "https://example.invalid/release",
    prerelease: false,
  });

  assert.equal((message.match(/Что изменилось/gu) ?? []).length, 1);
  assert.doesNotMatch(message, /Что изменилось в 0\.31\.0/u);
  assert.match(message, /• Исправлена навигация/u);
});

test("marks prereleases and truncates long release notes safely", () => {
  const message = buildTelegramReleaseMessage({
    tag_name: "v0.33.0-beta.1",
    name: "",
    body: "Изменение ".repeat(1000),
    html_url: "https://example.invalid/release",
    prerelease: true,
  });

  assert.match(message, /^🚀 v0\.33\.0-beta\.1/u);
  assert.match(message, /предварительная версия/u);
  assert.match(message, /Полный список изменений/u);
  assert.ok(Array.from(message).length <= 3900);
});

test("requires a release tag and URL", () => {
  assert.throws(
    () => buildTelegramReleaseMessage({ body: "Missing identity" }),
    /tag_name and html_url are required/u,
  );
});


test("release workflow explicitly calls the reusable Telegram workflow", async () => {
  const [releaseWorkflow, telegramWorkflow] = await Promise.all([
    readFile(new URL("../../.github/workflows/release.yml", import.meta.url), "utf8"),
    readFile(new URL("../../.github/workflows/telegram-release.yml", import.meta.url), "utf8"),
  ]);

  assert.match(releaseWorkflow, /announce-telegram:/u);
  assert.match(releaseWorkflow, /needs\.release\.outputs\.published == 'true'/u);
  assert.match(releaseWorkflow, /uses: \.\/\.github\/workflows\/telegram-release\.yml/u);
  assert.match(releaseWorkflow, /secrets: inherit/u);
  assert.match(telegramWorkflow, /workflow_call:/u);
  assert.match(telegramWorkflow, /github\.event_name == 'workflow_call'/u);
  assert.doesNotMatch(telegramWorkflow, /release:\s*\n\s*types: \[published\]/u);
});
