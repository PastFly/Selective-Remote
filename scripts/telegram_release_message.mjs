#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const TELEGRAM_MESSAGE_LIMIT = 4096;
const DEFAULT_SAFE_LIMIT = 3900;

function collapseBlankLines(value) {
  return value.replace(/\n{3,}/gu, "\n\n").trim();
}

export function releaseBodyToPlainText(value = "") {
  return collapseBlankLines(
    String(value)
      .replace(/\r/gu, "")
      .replace(/^\s*#{1,6}\s+/gmu, "")
      .replace(/\[([^\]]+)\]\((https?:\/\/[^)]+)\)/gu, "$1 — $2")
      .replace(/\[([^\]]+)\]\([^)]+\)/gu, "$1")
      .replace(/`([^`]+)`/gu, "$1")
      .replace(/^\s*---+\s*$/gmu, "")
      .replace(/^\s*[-*]\s+/gmu, "• "),
  );
}

function truncateCodePoints(value, maximum) {
  const points = Array.from(value);
  if (points.length <= maximum) return value;
  return points.slice(0, Math.max(0, maximum - 1)).join("").trimEnd() + "…";
}

export function buildTelegramReleaseMessage(
  release,
  { donationURL = "", maximumLength = DEFAULT_SAFE_LIMIT } = {},
) {
  if (!release || typeof release !== "object") {
    throw new TypeError("release must be an object");
  }
  const tag = String(release.tag_name ?? "").trim();
  const title = String(release.name ?? "").trim() || tag || "Selective Remote";
  const releaseURL = String(release.html_url ?? "").trim();
  if (!tag || !releaseURL) {
    throw new Error("release tag_name and html_url are required");
  }

  const status = release.prerelease
    ? "Доступна новая предварительная версия."
    : "Доступна новая версия приложения.";
  const header = "🚀 " + title + "\n\n" + status + "\n\nЧто изменилось:\n";
  const donation = String(donationURL).trim();
  const footerParts = [
    "📦 Скачать и посмотреть полное описание:\n" + releaseURL,
  ];
  if (donation) {
    footerParts.push("❤️ Поддержать разработку:\n" + donation);
  }
  const footer = "\n\n" + footerParts.join("\n\n");
  const emptyBody = "Подробности обновления доступны на странице релиза.";
  const body = releaseBodyToPlainText(release.body) || emptyBody;
  const continuation = "\n\nПолный список изменений доступен по ссылке ниже.";
  const bodyBudget = Math.max(
    0,
    maximumLength - Array.from(header + footer + continuation).length,
  );
  const bodyText = Array.from(body).length > bodyBudget
    ? truncateCodePoints(body, bodyBudget) + continuation
    : body;
  const message = header + bodyText + footer;

  if (Array.from(message).length > maximumLength) {
    throw new Error("Telegram release message exceeds the configured safe limit");
  }
  if (Array.from(message).length > TELEGRAM_MESSAGE_LIMIT) {
    throw new Error("Telegram release message exceeds Telegram's limit");
  }
  return message;
}

async function main() {
  const releasePath = process.argv[2];
  if (!releasePath) {
    throw new Error("Usage: telegram_release_message.mjs <release.json>");
  }
  const release = JSON.parse(await readFile(releasePath, "utf8"));
  process.stdout.write(buildTelegramReleaseMessage(release, {
    donationURL: process.env.TELEGRAM_DONATION_URL ?? "",
  }));
}

const invokedPath = process.argv[1] ? pathToFileURL(process.argv[1]).href : "";
if (import.meta.url === invokedPath) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
