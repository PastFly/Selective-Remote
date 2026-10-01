// Local production AccessManager fixture. Synthetic responses, no staging session.
import { createServer } from "node:http";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import assert from "node:assert/strict";
const playwrightPath = process.env.PLAYWRIGHT_MODULE;
if (!playwrightPath) throw new Error("PLAYWRIGHT_MODULE is required");
const { chromium } = await import(pathToFileURL(playwrightPath));
const base = resolve("cloud/public"), output = process.env.ACCESS_QA_OUTPUT ?? "/private/tmp/release-convergence-access";
const server = createServer(async (req, res) => {
  try {
    const pathname = new URL(req.url, "http://localhost").pathname;
    const name = pathname === "/" ? "index.html" : pathname.slice(1);
    if (!/^[\w-]+\.(?:js|css|html)$/.test(name)) throw Error();
    let body = await readFile(join(base, name));
    if (name === "index.html") body = body.toString().replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, "");
    res.setHeader("Content-Type", name.endsWith(".html") ? "text/html" : name.endsWith(".js") ? "application/javascript" : "text/css");
    res.end(body);
  } catch { res.writeHead(404).end(); }
});
await new Promise(r => server.listen(0, "127.0.0.1", r));
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_PATH ?? chromium.executablePath() });
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.evaluate(async () => {
    const teamID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", vaultID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", userID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc", deviceID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd", resourceID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
    window.qa = { teamID, vaultID, userID, deviceID, resourceID, formatState: "V2_PREPARING", commits: 0, callbacks: 0, usable: "UNKNOWN", crypto: "WRAP_PRESENT_UNVERIFIED" };
    const page = rows => ({ rows, nextCursor: null });
    const policy = { policyAllowed: true, policyMask: 7, paths: [{ principalKind: "USER", principalID: userID, grantTargetKind: "RESOURCE", grantTargetID: resourceID, sourceType: "DIRECT", permissions: ["ViewMetadata", "Reveal", "Edit"] }], blockedReasons: [] };
    const effective = () => ({ policyEffective: policy, deviceUsability: { cryptoAvailable: qa.crypto, cryptoAvailableByPermission: { ViewMetadata: "NOT_REQUIRED", Reveal: qa.crypto, Edit: qa.crypto }, effectiveUsable: qa.usable, effectiveUsableByPermission: { ViewMetadata: "YES", Reveal: qa.usable, Edit: qa.usable }, blockedReasons: qa.usable === "NO" ? ["KEY_UNAVAILABLE"] : [] } });
    const client = {
      listVaults: async () => page([{ id: vaultID, name: "QA", formatState: qa.formatState }]),
      getContext: async () => ({ formatState: qa.formatState, policyMutationAvailable: true, groupMutationAvailable: true, blockers: [] }),
      listMembers: async () => page([{ id: teamID, userID, displayName: "Alex" }]),
      listGroups: async () => page([]),
      listResources: async () => page([{ id: resourceID, policyKind: "CREDENTIAL", resourceVersion: 1 }]),
      listGrants: async () => page([]),
      resourcesByPrincipal: async () => page([{ resourceID, policyKind: "CREDENTIAL", policyEffective: policy }]),
      listDevices: async () => page([{ id: deviceID, name: "Mac", platform: "macOS", admitted: true }]),
      effective: async () => effective(),
      preview: async (_scope, _draft, options) => ({ token: "synthetic-preview", snapshotID: "a".repeat(64), details: options ? [{ vaultID, resourceID, subjectUserID: userID, before: { policyEffective: { ...policy, policyAllowed: false, policyMask: 0, paths: [] } }, after: { policyEffective: policy }, gainedMask: 7, lostMask: 0 }] : [], affectedGrants: [], counts: { pairs: 1, widened: 1, lost: 0, affectedGrants: 0 }, nextCursor: options ? null : "50" }),
      commit: async () => { qa.commits++; return { applied: 1, notificationCandidates: [], counts: { pairs: 1 } }; },
    };
    document.documentElement.lang = "en";
    document.documentElement.dataset.theme = "light";
    const root = document.querySelector("#team-access-view");
    document.body.replaceChildren(root);
    root.hidden = false;
    const { createAccessManager } = await import("/access-manager.js");
    qa.manager = createAccessManager({ root, client, context: { teamID, vaultID, role: "owner" }, resolveLabel: () => null, onCommitted: () => qa.callbacks++ });
    await qa.manager.refresh();
  });
  const root = page.locator("#team-access-view");
  await root.getByRole("checkbox", { name: "Alex", exact: true }).check();
  await root.getByRole("navigation").getByRole("button", { name: "Resources", exact: true }).click();
  await root.getByRole("checkbox", { name: /Credential ·/ }).check();
  await root.getByRole("button", { name: "Edit", exact: true }).click();
  await root.getByRole("button", { name: "Grant access", exact: true }).click();
  await root.getByRole("button", { name: "Preview consequences", exact: true }).click();
  assert.equal(await root.getByRole("button", { name: "Confirm change", exact: true }).isDisabled(), true);
  const loadMore = root.getByRole("button", { name: "Load more consequences", exact: true });
  await loadMore.focus();
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => qa.manager.state().preview?.complete === true);
  const baseline = { text: await root.innerText(), focused: await page.evaluate(() => ({ tag: document.activeElement.tagName, text: document.activeElement.textContent, preview: document.activeElement.classList.contains("access-preview") })) };
  if (process.env.ACCESS_BASELINE === "1") {
    await root.screenshot({ path: join(output, "baseline-en-light-desktop.png") });
    await writeFile(join(output, "baseline.json"), JSON.stringify(baseline, null, 2));
    console.log(JSON.stringify({ mode: "LOCAL_SYNTHETIC_BASELINE", output, focusAfterPagination: baseline.focused }));
  } else {
    assert.equal(baseline.focused.preview, true, "removed Load more must return focus to preview, never Confirm");
    assert.doesNotMatch(baseline.text, /\b(?:V[12](?:_[A-Z_]+)?|PREPARING|READY|ACTIVE|USER|GROUP)\b|cryptographic|User policy|Gained permissions: 7/);
    await root.screenshot({ path: join(output, "fixed-preview-en-light-desktop.png") });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.evaluate(() => { document.documentElement.lang = "ru"; document.documentElement.dataset.theme = "graphite"; document.dispatchEvent(new CustomEvent("selective-remote:locale-changed")); });
    assert.equal(await root.evaluate(n => n.scrollWidth > n.clientWidth + 2), false);
    await root.screenshot({ path: join(output, "fixed-preview-ru-graphite-mobile.png") });
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.evaluate(() => { document.documentElement.lang = "en"; document.documentElement.dataset.theme = "light"; document.dispatchEvent(new CustomEvent("selective-remote:locale-changed")); });
    const cancel = root.getByRole("button", { name: "Cancel", exact: true });
    await cancel.focus();
    await page.keyboard.press("Enter");
    assert.equal(await root.getByRole("button", { name: "Grant access", exact: true }).evaluate(n => document.activeElement === n), true, "Cancel returns keyboard focus to draft initiator");
    await root.getByRole("button", { name: "Grant access", exact: true }).click();
    await root.getByRole("button", { name: "Preview consequences", exact: true }).click();
    await root.getByRole("button", { name: "Cancel", exact: true }).focus();
    await page.keyboard.press("Escape");
    assert.equal(await root.getByRole("button", { name: "Grant access", exact: true }).evaluate(n => document.activeElement === n), true, "Escape returns focus to draft initiator");
    await root.getByRole("button", { name: "Grant access", exact: true }).click();
    await root.getByRole("button", { name: "Preview consequences", exact: true }).click();
    await root.getByRole("button", { name: "Load more consequences", exact: true }).click();
    await page.waitForFunction(() => qa.manager.state().preview?.complete === true);
    await root.getByRole("button", { name: "Confirm change", exact: true }).dblclick();
    await page.waitForFunction(() => qa.commits === 1);
    assert.equal(await page.evaluate(() => qa.callbacks), 1);
    await root.getByRole("navigation").getByRole("button", { name: "Members", exact: true }).click();
    await root.locator(".access-directory").getByRole("button", { name: "Resources", exact: true }).click();
    await root.getByLabel("Member device").selectOption(await page.evaluate(() => qa.deviceID));
    for (const usable of ["UNKNOWN", "NO", "YES"]) {
      await page.evaluate(value => { qa.usable = value; qa.crypto = value === "NO" ? "KEY_UNAVAILABLE" : "WRAP_PRESENT_UNVERIFIED"; }, usable);
      await root.getByRole("button", { name: "Check device", exact: true }).click();
      const text = await root.innerText();
      assert.match(text, /Access permission: allowed/);
      await root.screenshot({ path: join(output, `device-${usable.toLowerCase()}-en-light-desktop.png`) });
      assert.match(text, usable === "YES" ? /Available on this device/ : usable === "NO" ? /Unavailable on device/ : /Availability on this device is unverified/);
    }
    const manifest = { mode: "LOCAL_SYNTHETIC_PRODUCTION_COMPONENT", stagingAuthenticated: false, screenshots: [], keyboard: { finalPageFocus: "preview", cancelFocus: "draft initiator", escapeFocus: "draft initiator" }, deviceUsability: ["UNKNOWN", "NO", "YES"], extraScreenshots: ["fixed-preview-en-light-desktop.png", "fixed-preview-ru-graphite-mobile.png", "device-unknown-en-light-desktop.png", "device-no-en-light-desktop.png", "device-yes-en-light-desktop.png"], errors };
    for (const state of ["V1_ACTIVE", "V2_PREPARING", "V2_READY", "V2_ACTIVE"]) {
      await page.evaluate(async value => { qa.formatState = value; await qa.manager.refresh(); }, state);
      if (state !== "V2_PREPARING") {
        assert.equal(await root.getByRole("button", { name: "Grant access", exact: true }).count(), 0);
        await page.evaluate(() => qa.manager.setDraft({ type: "GROUP_CREATE", name: "QA" }));
        const gate = await page.evaluate(async () => { try { await qa.manager.preview(); return "passed"; } catch (e) { return e.message; } });
        assert.notEqual(gate, "passed");
        await page.evaluate(() => qa.manager.setDraft(null));
      }
      for (const locale of ["ru", "en"]) for (const theme of ["graphite", "light"]) for (const [viewport, width, height] of [["desktop", 1280, 900], ["tablet", 820, 900], ["mobile", 390, 844]]) {
        await page.setViewportSize({ width, height });
        await page.evaluate(({ locale, theme }) => { document.documentElement.lang = locale; document.documentElement.dataset.theme = theme; document.dispatchEvent(new CustomEvent("selective-remote:locale-changed")); }, { locale, theme });
        const text = await root.innerText();
        assert.doesNotMatch(text, /\b(?:V[12](?:_[A-Z_]+)?|PREPARING|READY|ACTIVE|USER|GROUP)\b|cryptographic|Credential Edit|User policy/);
        if (locale === "ru") assert.doesNotMatch(text, /Vault|View|Reveal|Edit|policy/);
        const overflow = await root.evaluate(n => n.scrollWidth > n.clientWidth + 2);
        assert.equal(overflow, false, `${state}/${locale}/${theme}/${viewport} overflow`);
        const filename = `${state.toLowerCase()}-${locale}-${theme}-${viewport}.png`;
        await root.screenshot({ path: join(output, filename) });
        manifest.screenshots.push({ state, locale, theme, viewport, filename, overflow });
      }
    }
    assert.deepEqual(errors, []);
    await writeFile(join(output, "manifest.json"), JSON.stringify(manifest, null, 2));
    console.log(JSON.stringify({ mode: manifest.mode, output, screenshots: manifest.screenshots.length, commits: await page.evaluate(() => qa.commits), callbacks: await page.evaluate(() => qa.callbacks), errors }));
  }
} finally { await browser.close(); await new Promise(r => server.close(r)); }
