/** Offline Chromium regression for custom selects hosted in native dialogs.
 *
 * Uses the production HTML, CSS and selector module without network access.
 * Run: node cloud/tests/browser/modern-select-smoke.mjs [output-directory]
 */
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { mkdir, readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const publicRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../public");
const outputRoot = resolve(process.argv[2] ?? join(process.cwd(), ".artifacts", "modern-select-smoke"));
await mkdir(outputRoot, { recursive: true });

const html = (await readFile(join(publicRoot, "index.html"), "utf8"))
  .replace(/<script\b[^>]*>.*?<\/script>/gsu, "")
  .replace(/<link[^>]+(?:stylesheet|preconnect|icon)[^>]*>/gu, "");
const styles = await readFile(join(publicRoot, "styles.css"), "utf8");
const i18n = await readFile(join(publicRoot, "i18n.js"), "utf8");
const moduleSource = await readFile(join(publicRoot, "modern-select.js"), "utf8");
const moduleURL = `data:text/javascript;charset=utf-8,${encodeURIComponent(moduleSource)}`;
const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined;

const browser = await chromium.launch({ executablePath, headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, locale: "ru-RU" });
page.setDefaultTimeout(5000);
const errors = [];
page.on("pageerror", (error) => errors.push(String(error)));
await page.setContent(html);
await page.addStyleTag({ content: styles });
await page.addScriptTag({ content: i18n });
await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded")));
await page.addScriptTag({ type: "importmap", content: JSON.stringify({ imports: { "qa/modern-select.js": moduleURL } }) });
await page.evaluate(async () => {
  const { initializeModernSelects } = await import("qa/modern-select.js");
  initializeModernSelects();
  document.documentElement.classList.remove("app-booting");
  document.querySelector("#cloud-workspace").hidden = false;
  document.querySelector("#team-vault").hidden = false;
  document.querySelector("#team-selected").hidden = false;
  document.querySelector("#team-vault-workspace").hidden = false;
  document.body.dataset.portalView = "workspace";
});

const teamDialog = page.locator("#team-record-editor");
await page.evaluate(() => document.querySelector("#team-record-editor").showModal());
const teamTrigger = teamDialog.locator(".modern-select-trigger").first();
await teamTrigger.click();
const teamMenu = page.locator(`#${await teamTrigger.getAttribute("aria-controls")}`);
assert.equal(await teamMenu.isVisible(), true, "record-type options must render in the dialog top layer");
assert.equal(await teamMenu.getAttribute("role"), "listbox");
assert.equal(await teamTrigger.getAttribute("aria-expanded"), "true");
assert.equal(
  await teamMenu.locator("[role=option][data-index='1']").evaluate((node) => getComputedStyle(node).backgroundColor),
  "rgba(0, 0, 0, 0)",
  "shared selector option styling must not inherit the Team primary-button fill",
);
await teamMenu.getByRole("option", { name: "Credential" }).click();
assert.equal(await teamDialog.locator("#team-record-type").inputValue(), "credential");
assert.equal(await teamTrigger.evaluate((node) => node === document.activeElement), true);
assert.equal(await teamMenu.locator("[role=option][data-index='1']").getAttribute("aria-selected"), "true");

await teamTrigger.press("ArrowDown");
assert.equal(await teamMenu.isVisible(), true);
await teamMenu.locator("[role=option]:focus").waitFor();
await page.keyboard.press("End");
await page.keyboard.press("ArrowUp");
await page.keyboard.press("Enter");
assert.equal(await teamDialog.locator("#team-record-type").inputValue(), "snippet");
assert.equal(await teamMenu.locator("[role=option][data-index='2']").getAttribute("aria-selected"), "true");
await teamTrigger.press("Space");
assert.equal(await teamMenu.isVisible(), true);
await page.keyboard.press("Escape");
assert.equal(await teamMenu.isHidden(), true);
assert.equal(await teamTrigger.evaluate((node) => node === document.activeElement), true);

await teamTrigger.click();
await teamMenu.getByRole("option", { name: "Host", exact: true }).click();
assert.equal(await teamDialog.locator("#team-record-type").inputValue(), "host");
await teamTrigger.click();
await teamDialog.locator(".record-editor-heading").click();
assert.equal(await teamMenu.isHidden(), true, "outside interaction inside the dialog must dismiss the menu");
await page.evaluate(() => { document.querySelector("#team-record-type").disabled = true; });
await page.waitForFunction(() => document.querySelector("#team-record-editor .modern-select-trigger").disabled);
assert.equal(await teamTrigger.isDisabled(), true);
await page.evaluate(() => { document.querySelector("#team-record-type").disabled = false; });
await page.waitForFunction(() => !document.querySelector("#team-record-editor .modern-select-trigger").disabled);

for (const locale of ["ru", "en"]) {
  await page.evaluate((nextLocale) => window.SelectiveRemoteI18n.setLocale(nextLocale), locale);
  for (const theme of ["graphite", "light"]) {
    await page.evaluate((nextTheme) => { document.documentElement.dataset.theme = nextTheme; }, theme);
    await teamTrigger.click();
    await page.waitForTimeout(250);
    await teamMenu.screenshot({ path: join(outputRoot, `desktop-${locale}-${theme}.png`) });
    await page.keyboard.press("Escape");
  }
}
await teamDialog.evaluate((dialog) => dialog.close());

await page.setViewportSize({ width: 390, height: 844 });
const accountDialog = page.locator("#workspace-mobile-account");
await page.evaluate(() => window.SelectiveRemoteI18n.setLocale("ru"));
await page.evaluate(() => document.querySelector("#workspace-mobile-account").showModal());
const appearanceTrigger = accountDialog.locator(".modern-select-trigger");
await appearanceTrigger.click();
const appearanceMenu = accountDialog.locator(".modern-select-menu");
assert.equal(await appearanceMenu.isVisible(), true, "appearance options must render in the dialog top layer");
await page.waitForTimeout(250);
assert.equal(
  await appearanceMenu.evaluate((node) => node.parentElement?.classList.contains("modern-select")),
  true,
  "dialog selectors must keep the menu in their local stacking context",
);
assert.equal(
  await appearanceMenu.evaluate((menu) => [...menu.querySelectorAll(".modern-select-option")].every((option) => {
    const rect = option.getBoundingClientRect();
    const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
    return hit?.closest?.(".modern-select-option") === option;
  })),
  true,
  "every visible option must remain above the dialog controls in the pointer hit-test order",
);
await appearanceMenu.getByRole("option", { name: "Светлая" }).click();
assert.equal(await accountDialog.locator("[data-theme-select]").inputValue(), "light");
await appearanceTrigger.press("ArrowUp");
await appearanceMenu.locator("[role=option]:focus").waitFor();
await page.keyboard.press("Home");
await page.keyboard.press("Space");
assert.equal(await accountDialog.locator("[data-theme-select]").inputValue(), "graphite");
assert.equal(await appearanceMenu.isHidden(), true, "keyboard selection must close the menu");

for (const locale of ["ru", "en"]) {
  await page.evaluate((nextLocale) => window.SelectiveRemoteI18n.setLocale(nextLocale), locale);
  for (const theme of ["graphite", "light"]) {
    await page.evaluate((nextTheme) => { document.documentElement.dataset.theme = nextTheme; }, theme);
    await appearanceTrigger.click();
    await page.waitForTimeout(250);
    const box = await appearanceMenu.boundingBox();
    assert.ok(box && box.x >= 0 && box.x + box.width <= 390, `${locale}/${theme} menu must not clip`);
    await page.screenshot({
      path: join(outputRoot, `narrow-${locale}-${theme}.png`),
      clip: { x: 0, y: 0, width: 390, height: 600 },
    });
    await page.keyboard.press("Escape");
  }
}

await page.emulateMedia({ reducedMotion: "reduce" });
await appearanceTrigger.click();
assert.equal(await appearanceMenu.evaluate((node) => getComputedStyle(node).animationName), "none");
await page.keyboard.press("Escape");
await accountDialog.evaluate((dialog) => dialog.close());

await page.evaluate(() => {
  document.querySelector("#team-vault").hidden = true;
  document.querySelector("#workspace-settings").hidden = false;
});
const settingsCards = page.locator("#workspace-settings .account-settings-card");
const firstSettingsCard = await settingsCards.nth(0).boundingBox();
const secondSettingsCard = await settingsCards.nth(1).boundingBox();
assert.ok(
  firstSettingsCard && secondSettingsCard
    && Math.abs(firstSettingsCard.x - secondSettingsCard.x) < 2
    && secondSettingsCard.y > firstSettingsCard.y + firstSettingsCard.height,
  "narrow account settings cards must use a comfortable single-column flow",
);

assert.deepEqual(errors, []);
console.log(JSON.stringify({
  status: "passed",
  checks: [
    "dialog top-layer rendering",
    "Team Host/Credential/Snippet pointer and keyboard selection",
    "arrow/home/end/enter/space/escape",
    "focus return",
    "selected state",
    "outside dismissal",
    "disabled state",
    "narrow appearance",
    "RU/EN graphite/light desktop/narrow matrix",
    "dialog-bounded placement and pointer hit order",
    "narrow Settings single-column density",
    "reduced motion",
  ],
  screenshots: outputRoot,
}));
await browser.close();
