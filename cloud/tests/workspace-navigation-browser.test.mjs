import assert from "node:assert/strict";
import { mkdir, readFile } from "node:fs/promises";
import { basename, extname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

const origin = "https://cloud-workspace-fixture.invalid";
const publicRoot = fileURLToPath(new URL("../public/", import.meta.url));
const types = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript" };

test("workspace navigation keeps the selected scope and record creation visible", {
  skip: !process.env.PLAYWRIGHT_MODULE || !process.env.CHROMIUM_PATH,
  timeout: 60000,
}, async () => {
  const { chromium } = await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE));
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_PATH, args: ["--no-sandbox"] });
  const screenshotDir = process.env.SR_UX_SCREENSHOTS_DIR;
  if (screenshotDir) await mkdir(screenshotDir, { recursive: true });

  try {
    for (const [width, theme, locale] of [
      [1440, "graphite", "ru"], [1440, "light", "en"],
      [390, "graphite", "en"], [320, "light", "ru"],
    ]) {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      const errors = [];
      page.on("pageerror", error => errors.push(error.message));
      try {
        await page.route("**/*", async route => {
          const url = new URL(route.request().url());
          if (url.origin !== origin) return route.abort();
          const file = url.pathname === "/" || url.pathname.startsWith("/app/")
            ? "index.html" : basename(url.pathname);
          const type = types[extname(file)];
          if (!type) return route.fulfill({ status: 404 });
          let body = await readFile(join(publicRoot, file), "utf8");
          if (file === "index.html") body = body.replace(/\s*<script type="module" src="\/app\.js[^"]*"><\/script>/u, "");
          if (file === "app.js") body = body.slice(0, body.lastIndexOf('\nif (typeof document !== "undefined") {'));
          await route.fulfill({ contentType: type, body });
        });
        await page.goto(origin);
        await page.evaluate(async ({ theme, locale }) => {
          document.documentElement.classList.remove("app-booting");
          document.documentElement.dataset.theme = theme;
          window.SelectiveRemoteI18n.setLocale(locale);
          const { initializeLocalVault, initializePortalNavigation } = await import("/app.js");
          const vault = await initializeLocalVault();
          const records = [];
          let failSave = true;
          vault.useController({
            status: async () => "unlocked",
            document: () => ({ records }),
            upsert: async ({ id, type, data }) => {
              if (failSave) { failSave = false; throw new Error("synthetic_storage_failure"); }
              const index = records.findIndex(record => record.id === id);
              const record = { id: id ?? crypto.randomUUID(), type, data, modifiedAt: Date.now() };
              if (index < 0) records.push(record);
              else records[index] = record;
            },
          });
          const nav = initializePortalNavigation({
            vaultUI: vault,
            teamUI: { setView: (view, filter) => {
              const team = document.querySelector("#team-vault");
              team.dataset.teamView = view;
              document.querySelector("#team-selected").hidden = false;
              document.querySelector("#team-vault-workspace").hidden = view !== "hosts";
              document.querySelector("#team-record-create").hidden = view !== "hosts";
              team.dataset.testFilter = filter;
            }},
          });
          document.dispatchEvent(new KeyboardEvent("keydown", { key: "k", ctrlKey: true, bubbles: true }));
          if (document.querySelector("#workspace-command-dialog").open) throw new Error("signed_out_workspace_shortcut");
          nav.sessionChanged({ id: "synthetic-fixture", username: "synthetic" });
          window.syntheticVault = vault;
          await vault.restoreModeFromLocalStatus();
          vault.render();
        }, { theme, locale });

        const overviewCreate = page.locator("#workspace-create");
        const personal = page.locator("#local-vault");
        const create = page.locator("#local-record-create");
        const editor = page.locator("#local-record-editor-dialog");
        const team = page.locator("#team-vault");
        const menu = width > 880 ? ".workspace-sidebar" : ".workspace-mobile-nav";
        const personalNav = page.locator(`${menu} [data-workspace-target="local-vault"]`);
        const teamNav = page.locator(`${menu} [data-workspace-target="team-vault"]`);
        assert.match(await overviewCreate.innerText(), locale === "ru" ? /личную/u : /personal/iu);
        await overviewCreate.click();
        assert.equal(new URL(page.url()).pathname, "/app/personal-vault");
        assert.equal(await editor.isVisible(), true);
        await page.keyboard.press("Escape");
        assert.equal(await editor.isHidden(), true);
        assert.equal(await create.evaluate(node => node === document.activeElement), true);
        assert.equal(await create.isVisible(), true, "the add action must be visible with the utility menu closed");
        assert.equal(await overviewCreate.isHidden(), true, "one primary create action per workspace");
        assert.equal(await personalNav.getAttribute("aria-current"), "page");

        await personal.locator('#personal-vault-filters [data-record-filter="host"]').click();
        assert.equal(await personalNav.getAttribute("aria-current"), "page");
        assert.equal(await create.isVisible(), true);
        await create.click();
        assert.equal(await editor.locator("#local-record-type").inputValue(), "host");
        await editor.locator("#local-record-title").fill("TEST-ONLY-CODEX-UX");
        await editor.locator("#local-record-target").fill("synthetic.example.test");
        await editor.locator("#local-record-save").click();
        const feedback = editor.getByRole("alert");
        await feedback.waitFor({ state: "visible" });
        assert.match(await feedback.innerText(), locale === "ru" ? /Не удалось сохранить/u : /could not save|couldn.t save/iu);
        assert.equal(await editor.locator("#local-record-title").inputValue(), "TEST-ONLY-CODEX-UX");
        const formBottom = await editor.locator(".record-form-actions").boundingBox();
        const finalField = await editor.locator("#local-host-description").boundingBox();
        assert.ok(formBottom.y >= finalField.y + finalField.height - 1, "feedback and actions must not obscure form fields");
        await editor.locator("#local-record-cancel").scrollIntoViewIfNeeded();
        if (screenshotDir) await page.screenshot({ path: join(screenshotDir, `editor-${width}-${locale}-${theme}.png`) });
        await editor.locator("#local-record-save").click();
        await editor.waitFor({ state: "hidden" });
        await personal.getByText("TEST-ONLY-CODEX-UX", { exact: true }).first().waitFor();
        await page.evaluate(() => {
          window.syntheticVault.setConflictMode(true);
          document.querySelector("#local-vault-conflicts").hidden = false;
        });
        assert.equal(await create.isDisabled(), true);
        await page.locator(`${menu} [data-workspace-target="workspace-overview"]`).click();
        await overviewCreate.click();
        assert.equal(await page.locator("#local-vault-conflicts-title").evaluate(node => node === document.activeElement), true);
        assert.equal(await editor.isHidden(), true);
        await page.evaluate(() => window.syntheticVault.clearConflictUI());
        assert.equal(await create.isEnabled(), true);

        await personal.getByRole("button", { name: /^(Изменить|Edit)$/u }).first().click();
        await editor.locator("#local-record-title").fill("TEST-ONLY-CODEX-UX-EDITED");
        await editor.locator("#local-record-save").click();
        await editor.waitFor({ state: "hidden" });
        const personalSearch = personal.locator("#personal-vault-search");
        await personalSearch.fill("absent.example.test");
        assert.equal(await personal.getByText("TEST-ONLY-CODEX-UX-EDITED", { exact: true }).count(), 0);
        await personalSearch.clear();
        await personal.getByText("TEST-ONLY-CODEX-UX-EDITED", { exact: true }).first().waitFor();
        if (screenshotDir) await page.screenshot({ path: join(screenshotDir, `workspace-${width}-${locale}-${theme}.png`) });

        await personal.locator('#personal-vault-filters [data-record-filter="credential"]').click();
        await personal.locator('.host-scope-switcher [data-workspace-target="team-vault"]').click();
        assert.equal(new URL(page.url()).pathname, "/app/team-credentials");
        assert.equal(await teamNav.getAttribute("aria-current"), "page");
        assert.equal(await personalNav.getAttribute("aria-current"), null);
        assert.equal(await page.locator("#team-record-create").isVisible(), true);

        await page.locator('#team-resource-navigation [data-workspace-target="local-vault"]').click();
        assert.equal(new URL(page.url()).pathname, "/app/credentials");

        await teamNav.click();
        await team.locator('#team-view-tabs [data-team-view="access"]').click();
        assert.equal(new URL(page.url()).pathname, "/app/team-access");
        assert.match(await page.locator("#workspace-title").textContent(), /Доступ|Access/u);
        await team.locator('#team-view-tabs [data-team-view="teams"]').click();
        await page.goBack();
        assert.equal(await team.getAttribute("data-team-view"), "access");

        await page.keyboard.press("Control+k");
        const search = page.locator("#workspace-command-search");
        await search.fill(locale === "ru" ? "Настройки" : "Settings");
        await search.press("ArrowDown");
        assert.match(await page.locator(":focus").textContent(), /Настройки|Settings/u);
        await page.keyboard.press("ArrowUp");
        assert.equal(await search.evaluate(node => node === document.activeElement), true);
        await search.press("ArrowDown");
        await page.keyboard.press("Enter");
        assert.equal(new URL(page.url()).pathname, "/app/settings");
        assert.equal(await page.locator("#workspace-settings").isVisible(), true);
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true);
        assert.deepEqual(errors, []);
      } finally { await page.close(); }
    }
  } finally { await browser.close(); }
});
