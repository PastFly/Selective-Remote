import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const html = await readFile(new URL("../public/index.html", import.meta.url), "utf8");
const css = await readFile(new URL("../public/styles.css", import.meta.url), "utf8");
const i18n = await readFile(new URL("../public/i18n.js", import.meta.url), "utf8");

test("public portal exposes a persistent RU and EN locale switch", () => {
  assert.match(html, /\/i18n\.js\?v=171/);
  assert.match(i18n, /selective-remote\.locale\.v1/);
  assert.match(i18n, /navigator\.language/);
  assert.match(i18n, /URLSearchParams\(location\.search\)/);
  assert.match(i18n, /document\.documentElement\.lang = locale/);
  assert.match(i18n, /dataLocaleSwitch|dataset\.localeSwitch/);
  assert.match(i18n, /workspace-mobile/);
  assert.match(i18n, /\["ru", "en"\]/);
  assert.match(css, /\.locale-switch/);
  assert.match(css, /\.workspace-locale-mobile/);
  assert.match(html, /hreflang="ru"/);
  assert.match(html, /hreflang="en"/);
  assert.match(html, /hreflang="x-default"/);
});

test("locale changes preserve the current authenticated workspace", () => {
  assert.doesNotMatch(i18n, /location\.(?:reload|assign|replace)/);
  assert.doesNotMatch(i18n, /sessionStorage\.clear|localStorage\.clear/);
  assert.match(i18n, /MutationObserver/);
  assert.match(i18n, /selective-remote:locale-changed/);
});

test("English metadata and security-sensitive account surfaces are localized", () => {
  assert.match(i18n, /secure synchronization for Hosts, Credentials, Snippets, and Team Vaults/);
  assert.match(i18n, /Email/);
  assert.match(i18n, /Sign in to Cloud/);
  assert.match(i18n, /Delete account permanently/);
  assert.match(i18n, /Team revision conflict/);
});

test("every static Russian portal string has an English catalog entry", () => {
  const staticStrings = new Set();
  for (const match of html.matchAll(/>([^<>]*[А-Яа-яЁё][^<>]*)</gu)) {
    staticStrings.add(match[1].replace(/\s+/gu, " ").trim());
  }
  for (const match of html.matchAll(/(?:aria-label|title|placeholder|content)="([^"]*[А-Яа-яЁё][^"]*)"/gu)) {
    staticStrings.add(match[1].trim());
  }
  const catalogKeys = new Set([...i18n.matchAll(/^\s{4}"([^"]+)":/gmu)].map((match) => match[1]));
  assert.deepEqual([...staticStrings].filter((value) => !catalogKeys.has(value)), []);
});

test("dynamic authentication, synchronization, and Team errors have English messages", () => {
  for (const message of [
    "Incorrect email or password.",
    "The Cloud session expired. Sign in again.",
    "Synchronization is frozen until the key is rotated securely.",
    "This device has not been approved for Team Vault yet.",
    "The invitation is invalid, used, revoked, or expired.",
    "The email service is temporarily unavailable.",
  ]) assert.match(i18n, new RegExp(message.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&"), "u"));
});
