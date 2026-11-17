import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

function contrastRatio(foreground, background) {
  const luminance = value => {
    const channels = value.match(/\d+(?:\.\d+)?/gu)?.slice(0, 3).map(Number);
    assert.equal(channels?.length, 3, `expected an RGB color, got ${value}`);
    const linear = channels.map(channel => {
      const s = channel / 255;
      return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
  };
  const values = [luminance(foreground), luminance(background)].sort((a, b) => b - a);
  return (values[0] + 0.05) / (values[1] + 0.05);
}

test("mobile workspace keeps the sync status readable and its panel usable", {
  skip: !process.env.PLAYWRIGHT_MODULE || !process.env.CHROMIUM_PATH,
  timeout: 30000,
}, async () => {
  const { chromium } = await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE));
  const html = (await readFile(new URL("../public/index.html", import.meta.url), "utf8"))
    .replace(/<script\b[^>]*>.*?<\/script>/gsu, "")
    .replace(/<link[^>]+(?:stylesheet|preconnect|icon)[^>]*>/gu, "");
  const css = await readFile(new URL("../public/styles.css", import.meta.url), "utf8");
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_PATH, args: ["--no-sandbox"] });
  try {
    const page = await browser.newPage({ viewport: { width: 320, height: 844 } });
    try {
      await page.route("**/*", route => route.fulfill({ status: 200, contentType: "text/html", body: "<!doctype html><html><body></body></html>" }));
      await page.goto("https://mobile-fixture.invalid/");
      await page.setContent(html);
      await page.addStyleTag({ content: css });
      await page.evaluate(() => {
        document.documentElement.classList.remove("app-booting");
        document.body.dataset.portalView = "workspace";
        document.querySelector("#cloud-workspace").hidden = false;
      });
      for (const width of [320, 390, 560]) for (const theme of ["graphite", "light"]) {
        await page.setViewportSize({ width, height: 844 });
        await page.evaluate(value => { document.documentElement.dataset.theme = value; }, theme);
        for (const text of ["Статус неизвестен", "Status unknown", "Наблюдаемые Vaults подтверждены", "Observed Vaults confirmed"]) {
          await page.locator("#workspace-sync-state span").evaluate((element, value) => { element.textContent = value; }, text);
          const label = page.locator("#workspace-sync-state span");
          assert.equal(await label.isVisible(), true);
          assert.equal(await label.evaluate(element => element.scrollWidth <= element.clientWidth + 1), true,
            `sync status must not be truncated at ${width}px (${theme}, ${text})`);
          const summary = page.locator("#workspace-sync-state");
          await summary.hover();
          await summary.click();
          const panel = await page.locator(".workspace-sync-panel").boundingBox();
          assert.ok(panel && panel.x >= 0 && panel.x + panel.width <= width + 1, "sync panel must fit the viewport");
          assert.equal(await summary.evaluate(element => getComputedStyle(element, "::after").display), "none",
            "the tooltip must not cover the open sync panel");
          await summary.click();
        }
        const create = page.locator("#workspace-create");
        await create.hover();
        const tooltip = await create.evaluate(element => {
          const style = getComputedStyle(element, "::after");
          return { color: style.color, background: style.backgroundColor };
        });
        assert.ok(contrastRatio(tooltip.color, tooltip.background) >= 4.5,
          `tooltip text must remain readable in ${theme}`);
      }
    } finally { await page.close(); }
  } finally { await browser.close(); }
});
