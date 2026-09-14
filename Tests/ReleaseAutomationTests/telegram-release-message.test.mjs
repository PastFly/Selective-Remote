import assert from "node:assert/strict";
import test from "node:test";

import {
  buildTelegramReleaseMessage,
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
  assert.match(result, /• Добавлен \*\*Team Vault\*\*/u);
  assert.match(result, /Исправлен SFTP/u);
  assert.match(result, /Полная история — https:\/\/example\.invalid\/changelog/u);
  assert.doesNotMatch(result, /^##/mu);
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
