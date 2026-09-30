// Real component + authenticated browser adapter; synthetic scoped server responses.
// Run: PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node cloud/tests/browser/access-manager-smoke.mjs
import { readFile, mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import assert from "node:assert/strict";
import { resolve, join } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";
const playwrightPath = process.env.PLAYWRIGHT_MODULE;
if (!playwrightPath) throw new Error("PLAYWRIGHT_MODULE is required");
const { chromium } = await import(pathToFileURL(playwrightPath));
const publicRoot = resolve("cloud/public");
const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://localhost");
    if (url.pathname === "/") {
      const html = await readFile(`${publicRoot}/index.html`, "utf8");
      res.setHeader("Content-Type", "text/html");
      res.end(html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, ""));
      return;
    }
    if (["/fixtures/access-manager.html", "/fixtures/access-manager-fixture.js"].includes(url.pathname)) {
      res.setHeader("Content-Type", url.pathname.endsWith(".js") ? "application/javascript" : "text/html");
      res.end(await readFile(resolve("cloud/tests" + url.pathname)));
      return;
    }
    const name = url.pathname.slice(1);
    if (!/^[\w-]+\.(js|css)$/u.test(name)) {
      res.writeHead(404);
      res.end();
      return;
    }
    res.setHeader(
      "Content-Type",
      name.endsWith(".js") ? "application/javascript" : "text/css",
    );
    res.end(
      await readFile(
        name === "access-manager.js" && process.env.ACCESS_MANAGER_SOURCE
          ? process.env.ACCESS_MANAGER_SOURCE
          : `${publicRoot}/${name}`,
      ),
    );
  } catch {
    res.writeHead(404);
    res.end();
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
let browser;
try {
  browser = await chromium.launch({
    headless: true,
    executablePath: process.env.CHROMIUM_PATH ?? chromium.executablePath(),
  });
  const page = await browser.newPage({
    viewport: { width: 1280, height: 1000 },
  });
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.evaluate(async () => {
    const teamID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      vaultID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      userID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      deviceID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      resourceID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      groupID = "ffffffff-ffff-4fff-8fff-ffffffffffff",
      groupBID = "12121212-1212-4212-8212-121212121212",
      offPageID = "13131313-1313-4313-8313-131313131313";
    window.qa = {
      requests: [],
      commits: 0,
      callbacks: 0,
      scenario: "preparing",
      scaleMembers: 1,
      scaleResources: 1,
      ids: {
        teamID,
        vaultID,
        userID,
        deviceID,
        resourceID,
        groupID,
        groupBID,
        offPageID,
      },
    };
    const paths = [
      {
        id: resourceID,
        principalKind: "USER",
        principalID: userID,
        grantTargetKind: "RESOURCE",
        grantTargetID: resourceID,
        sourceType: "DIRECT",
        mask: 15,
        effectiveMask: 15,
        permissions: ["ViewMetadata", "Reveal", "Edit", "ManageAccess"],
      },
      {
        id: groupID,
        principalKind: "GROUP",
        principalID: groupID,
        grantTargetKind: "FOLDER",
        grantTargetID: groupID,
        sourceType: "INHERITED_CONTAINER",
        mask: 33,
        effectiveMask: 1,
        permissions: ["ViewMetadata"],
      },
    ];
    const policy = {
      policyAllowed: true,
      policyMask: 15,
      paths,
      blockedReasons: [],
    };
    const fetchValue = async (path, options = {}) => {
      const url = new URL(path, location.href);
      qa.requests.push({
        path,
        method: options.method ?? "GET",
        authorization: options.headers?.Authorization,
        body: options.body ? JSON.parse(options.body) : null,
      });
      let body;
      if (url.pathname === "/v1/auth/login")
        body = {
          token: "s".repeat(32),
          deviceID,
          user: {
            id: userID,
            email: "synthetic@invalid.invalid",
            username: "synthetic",
            displayName: "Synthetic",
          },
        };
      else if (url.pathname.endsWith("/access-vaults"))
        body = {
          rows: [
            {
              id: vaultID,
              teamID,
              name: "Synthetic Vault",
              formatState: qa.formatState ?? "V2_PREPARING",
            },
          ],
          nextCursor: null,
        };
      else if (url.pathname.endsWith("/access-context")) {
        if (qa.scenario === "loading") await new Promise((release) => { qa.releaseLoading = release; });
        if (qa.scenario === "error") throw Error("synthetic_read_error");
        body = {
          formatState: qa.formatState ?? "V2_PREPARING",
          policyMutationAvailable: !qa.formatState,
          groupMutationAvailable: !qa.formatState,
          blockers:
            qa.formatState === "V1_ACTIVE"
              ? ["access_v2_preparing_required"]
              : qa.formatState
                ? ["crypto_publication_required"]
                : [],
          resource_acl_v2: false,
        };
      }
      else if (url.pathname.endsWith(`/access-resources/${offPageID}`))
        body = {
          id: offPageID,
          teamID,
          vaultID,
          policyKind: "CREDENTIAL",
          parentFolderID: null,
          resourceVersion: 2,
        };
      else if (url.pathname.endsWith("/access-resources"))
        body = {
          rows: qa.scenario === "empty" ? [] : [
            {
              id: resourceID,
              teamID,
              vaultID,
              policyKind: "CREDENTIAL",
              parentFolderID: null,
              resourceVersion: 1,
            },
          ...Array.from({ length: Math.min(qa.scaleResources - 1, 49) }, (_, i) => ({
            id: `00000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
            teamID, vaultID, policyKind: "HOST", parentFolderID: null, resourceVersion: 1,
          }))],
          nextCursor: qa.scaleResources > 50 ? "00000000-0000-4000-8000-000000000049" : null,
        };
      else if (url.pathname.endsWith("/access-grants"))
        body = {
          rows: qa.scenario === "empty" ? [] : [
            {
              id: resourceID,
              principal_kind: "USER",
              principal_id: userID,
              target_kind: "RESOURCE",
              target_id: offPageID,
              permission_mask: 15,
              version: "1",
            },
          ],
          nextCursor: null,
        };
      else if (url.pathname.endsWith("/access-groups"))
        body = {
          rows: qa.scenario === "empty" ? [] : [
            {
              id: groupID,
              team_id: teamID,
              name: "Synthetic group",
              version: "1",
            },
            { id: groupBID, team_id: teamID, name: "Group B", version: "7" },
          ],
          nextCursor: null,
        };
      else if (url.pathname.endsWith(`/access-groups/${groupBID}/members`))
        body = { rows: [], nextCursor: null };
      else if (url.pathname.endsWith(`/access-groups/${groupID}/members`))
        body = {
          rows: [
            {
              id: resourceID,
              groupID,
              userID,
              membershipID: userID,
              membershipEpoch: 1,
              version: 1,
            },
          ],
          nextCursor: null,
        };
      else if (url.pathname.endsWith("/members"))
        body = {
          members: qa.scenario === "empty" ? [] : [
            {
              id: userID,
              userID,
              displayName: "Synthetic recipient",
              username: "synthetic",
              role: "viewer",
              epoch: 1,
            },
          ...Array.from({ length: Math.min(qa.scaleMembers - 1, 49) }, (_, i) => ({
            id: `11111111-1111-4111-8111-${String(i + 1).padStart(12, "0")}`,
            userID: `11111111-1111-4111-8111-${String(i + 1).padStart(12, "0")}`,
            displayName: `Synthetic recipient ${i + 1}`, username: `synthetic${i + 1}`,
            role: "viewer", epoch: 1,
          }))],
          total: qa.scaleMembers,
          nextCursor: qa.scaleMembers > 50 ? "11111111-1111-4111-8111-000000000049" : null,
        };
      else if (url.pathname.includes("/resources-by-principal/"))
        body = {
          rows: [{ resourceID, policyEffective: policy }],
          nextCursor: null,
        };
      else if (url.pathname.includes("/who-has-access/"))
        body = {
          rows: [{ userID, policyEffective: { ...policy,
            paths: qa.scenario === "direct" ? paths.slice(0, 1) :
              qa.scenario === "group" ? paths.slice(1) : paths } }],
          nextCursor: null,
        };
      else if (url.pathname.endsWith("/access-devices"))
        body = {
          rows: [
            {
              id: deviceID,
              name: "Synthetic device",
              platform: "web",
              admitted: true,
            },
          ],
          nextCursor: null,
        };
      else if (url.pathname.includes("/effective-access/"))
        body = {
          policyEffective: policy,
          deviceUsability: {
            deviceID,
            effectiveUsable: qa.scenario === "no-key" ? "NO" : "UNKNOWN",
            cryptoAvailable: qa.scenario === "no-key" ? "NO" : "WRAP_PRESENT_UNVERIFIED",
            cryptoAvailableByPermission: { Reveal: qa.scenario === "no-key" ? "NO" : "WRAP_PRESENT_UNVERIFIED" },
            effectiveUsableByPermission: { Reveal: qa.scenario === "no-key" ? "NO" : "UNKNOWN" },
            blockedReasons: qa.scenario === "no-key" ? ["KEY_UNAVAILABLE"] : [],
          },
        };
      else if (
        url.pathname.endsWith("/access-preview") ||
        url.pathname.endsWith("/access-group-preview")
      ) {
        const request = JSON.parse(options.body);
        const detail = {
          vaultID, resourceID, subjectUserID: userID,
          before: { policyEffective: policy }, after: { policyEffective: policy },
          gainedMask: 0, lostMask: 0,
        };
        const malformed = qa.malformedPreview;
        body = {
          token: "synthetic-preview",
          snapshotID: "a".repeat(64),
          details: malformed === "incomplete" ? [] :
            malformed === "duplicate" ? [detail] : request.cursor ? [detail] : [],
          affectedGrants: [],
          counts: { pairs: malformed === "duplicate" || (malformed === "changed-counts" && request.cursor) ? 2 : 1,
            widened: 0, lost: 0, affectedGrants: 0 },
          nextCursor: request.cursor ? null : "50",
        };
      } else if (
        url.pathname.endsWith("/access-commit") ||
        url.pathname.endsWith("/access-group-commit")
      ) {
        qa.commits++;
        body = { applied: 1, notificationCandidates: [], counts: { pairs: 1 } };
      } else throw Error(`Unexpected synthetic route ${url.pathname}`);
      return new Response(JSON.stringify(body));
    };
    const { createAuthenticatedVaultClient } = await import("/vault-sync.js");
    const client = createAuthenticatedVaultClient({ fetchValue });
    await client.login({
      email: "synthetic@invalid.invalid",
      password: "synthetic",
      deviceID,
    });
    const { createAccessManager } = await import("/access-manager.js");
    document.documentElement.lang = "en";
    document.documentElement.dataset.theme = "light";
    const root = document.querySelector("#team-access-view");
    document.body.replaceChildren(root);
    root.hidden = false;
    qa.manager = createAccessManager({
      root,
      client: client.accessClient(),
      context: { teamID, vaultID, role: "owner" },
      resolveLabel: () => null,
      onCommitted: () => qa.callbacks++,
    });
    await qa.manager.refresh();
  });
  const root = page.locator("#team-access-view");
  assert.equal(
    await root.getByRole("heading", { name: "Access & sharing" }).count(),
    1,
  );
  const recipientCheck = root.getByRole("checkbox", { name: "Synthetic recipient", exact: true });
  await recipientCheck.focus();
  assert.equal(await recipientCheck.evaluate((element) => document.activeElement === element), true);
  await page.keyboard.press("Space");
  assert.equal(await recipientCheck.isChecked(), true);
  await root
    .getByRole("navigation")
    .getByRole("button", { name: "Resources", exact: true })
    .click();
  await root.getByRole("checkbox", { name: /Credential · eeee/ }).check();
  await root.getByRole("button", { name: "Edit", exact: true }).click();
  assert.equal(
    await root
      .getByRole("checkbox", { name: "Reveal secret", exact: true })
      .isChecked(),
    true,
  );
  assert.equal(
    await root.getByRole("checkbox", { name: "Edit", exact: true }).isChecked(),
    true,
  );
  await root.getByRole("button", { name: "Grant access", exact: true }).click();
  await root
    .getByRole("button", { name: "Preview consequences", exact: true })
    .click();
  assert.equal(
    await root
      .getByRole("button", { name: "Confirm change", exact: true })
      .isDisabled(),
    true,
  );
  await root.getByRole("button", { name: "Load more consequences" }).focus();
  await page.keyboard.press("Enter");
  await root
    .getByText(/Inherited from container/)
    .first()
    .waitFor();
  assert.equal(
    (await root.getByText(/Inherited from container/).count()) > 0,
    true,
  );
  await root
    .getByRole("button", { name: "Confirm change", exact: true })
    .click();
  await root.getByText("Change saved", { exact: true }).waitFor();
  assert.equal(await page.evaluate(() => qa.commits), 1);
  assert.equal(await page.evaluate(() => qa.callbacks), 1);
  await root
    .getByRole("navigation")
    .getByRole("button", { name: "Members", exact: true })
    .click();
  await root
    .locator(".access-directory")
    .getByRole("button", { name: "Resources", exact: true })
    .click();
  await root
    .getByLabel("Member device")
    .selectOption(await page.evaluate(() => qa.ids.deviceID));
  await root.getByRole("button", { name: "Check device", exact: true }).click();
  await root
    .getByText("Device availability: Availability on this device is unverified", { exact: true })
    .waitFor();
  assert.equal(
    await root
      .getByText("Device availability: Availability on this device is unverified", { exact: true })
      .count(),
    1,
  );
  assert.equal(
    await root.innerText().then((v) => v.includes("DENIED_PLAINTEXT_CANARY")),
    false,
  );
  // Regression: switching group detail must never rebind an open rename.
  await root
    .getByRole("navigation")
    .getByRole("button", { name: "Groups", exact: true })
    .click();
  const groupA = root
    .locator(".access-directory li")
    .filter({ hasText: "Synthetic group" });
  const groupB = root
    .locator(".access-directory li")
    .filter({ hasText: "Group B" });
  await groupA.getByRole("button", { name: "Rename", exact: true }).click();
  await groupB
    .getByRole("button", { name: "Group members", exact: true })
    .click();
  await root
    .getByRole("heading", { name: "Group members: Group B", exact: true })
    .waitFor();
  const renameForm = root
    .locator(".access-detail")
    .filter({ has: page.getByLabel("Group name", { exact: true }) });
  await renameForm.getByLabel("Group name", { exact: true }).fill("Renamed A");
  await renameForm.getByRole("button", { name: "Rename", exact: true }).click();
  assert.deepEqual(await page.evaluate(() => qa.manager.state().draft), {
    type: "GROUP_RENAME",
    groupID: await page.evaluate(() => qa.ids.groupID),
    expectedVersion: 1,
    name: "Renamed A",
  });
  await page.evaluate(() => qa.manager.setDraft(null));
  // Regression: grant target is intentionally absent from registry first page.
  await root
    .locator(".access-grant")
    .getByRole("button", { name: "Change permissions", exact: true })
    .click();
  const grantForm = root.locator(".access-grant-editor");
  await grantForm.waitFor();
  await grantForm.getByRole("button", { name: "Edit", exact: true }).click();
  assert.equal(
    await grantForm
      .getByRole("checkbox", { name: "Reveal secret", exact: true })
      .isChecked(),
    true,
  );
  await grantForm
    .getByRole("button", { name: "Change permissions", exact: true })
    .click();
  assert.deepEqual(await page.evaluate(() => qa.manager.state().draft), {
    changes: [
      {
        type: "GRANT_CHANGE",
        grantID: await page.evaluate(() => qa.ids.resourceID),
        expectedVersion: 1,
        permissionMask: 7,
      },
    ],
  });
  await root
    .getByRole("button", { name: "Preview consequences", exact: true })
    .click();
  await root
    .getByRole("button", { name: "Load more consequences", exact: true })
    .waitFor();
  assert.equal(
    await page.evaluate(
      () =>
        qa.requests.filter((r) =>
          r.path.endsWith("/access-resources/" + qa.ids.offPageID),
        ).length,
    ),
    1,
  );
  await root.getByRole("button", { name: "Cancel", exact: true }).last().focus();
  await page.keyboard.press("Escape");
  assert.equal(await page.evaluate(() => qa.manager.state().preview), null);
  for (const malformed of ["incomplete", "duplicate", "changed-counts"]) {
    await page.evaluate((value) => {
      qa.malformedPreview = value;
      qa.manager.setDraft({ changes: [{ type: "GRANT_REVOKE", grantID: qa.ids.resourceID, expectedVersion: 1 }] });
    }, malformed);
    await root.getByRole("button", { name: "Preview consequences", exact: true }).click();
    const confirm = root.getByRole("button", { name: "Confirm change", exact: true });
    assert.equal(await confirm.isDisabled(), true, malformed);
    await root.getByRole("button", { name: "Load more consequences", exact: true }).click();
    await page.waitForFunction(() => qa.manager.state().preview === null);
    assert.equal(await confirm.count(), 0, malformed);
    assert.equal(await page.evaluate(() => qa.commits), 1, malformed);
  }
  await page.evaluate(() => { qa.malformedPreview = null; });
  await page.evaluate(() => {
    document.documentElement.lang = "ru";
    document.dispatchEvent(new CustomEvent("selective-remote:locale-changed"));
  });
  assert.equal(
    await root
      .getByRole("heading", { name: "Доступ и общий доступ", exact: true })
      .count(),
    1,
  );
  for (const state of ["V1_ACTIVE", "V2_READY", "V2_ACTIVE"]) {
    await page.evaluate(async (state) => {
      qa.formatState = state;
      await qa.manager.refresh();
    }, state);
    assert.equal(
      await root
        .getByRole("button", { name: "Добавить доступ", exact: true })
        .count(),
      0,
    );
    assert.match(
      await root.innerText(),
      state === "V1_ACTIVE" ? /Доступ применяется ко всему хранилищу/ : /Изменения доступа здесь недоступны/,
    );
  }
  const calls = await page.evaluate(() => qa.requests);
  assert.equal(
    calls
      .filter((c) => c.path !== "/v1/auth/login")
      .every((c) => c.authorization === "Bearer " + "s".repeat(32)),
    true,
  );
  assert.deepEqual(errors, []);
  const scale = [];
  for (const [members, resources] of [[5, 50], [100, 500], [1000, 5000]]) {
    const result = await page.evaluate(async ({ members, resources }) => {
      qa.scaleMembers = members;
      qa.scaleResources = resources;
      qa.formatState = "V2_PREPARING";
      qa.scenario = "preparing";
      const start = performance.now(), requestsBefore = qa.requests.length;
      await qa.manager.refresh();
      const state = qa.manager.state();
      return { members, resources,
        renderedMembers: state.pages.members.rows.length,
        renderedResources: state.pages.resources.rows.length,
        requests: qa.requests.length - requestsBefore,
        elapsedMs: Math.round(performance.now() - start) };
    }, { members, resources });
    assert.ok(result.renderedMembers <= 50 && result.renderedResources <= 50);
    assert.ok(result.requests <= 8);
    scale.push(result);
  }
  const routePage = await browser.newPage();
  await routePage.goto(`http://127.0.0.1:${server.address().port}/fixtures/access-manager.html`);
  assert.equal(await routePage.frameLocator('iframe[title="Actual Team workspace"]').locator("#team-access-view").count(), 1);
  await routePage.goto(`http://127.0.0.1:${server.address().port}/`);
  const route = await routePage.evaluate(async () => {
    const { initializeTeamWorkspace } = await import("/app.js");
    const empty = async () => ({ rows: [], nextCursor: null });
    const accessClient = {
      listVaults: empty, listMembers: empty, listGroups: empty,
      listResources: empty, listGrants: empty,
      getContext: async () => ({ formatState: "V2_PREPARING",
        policyMutationAvailable: true, groupMutationAvailable: true, blockers: [] }),
    };
    const workspace = initializeTeamWorkspace({
      client: { accessClient: () => accessClient, deviceID: () => null,
        session: () => null }, setIntervalValue: () => 0,
    });
    workspace.setView("access");
    const root = document.querySelector("#team-access-view");
    for (let parent = root; parent; parent = parent.parentElement) parent.hidden = false;
    workspace.accessManager.setContext({ teamID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      vaultID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", role: "owner" });
    await workspace.accessManager.refresh();
    return { route: document.querySelector("#team-vault").dataset.teamView,
      sameRoot: root.querySelector(".access-manager") !== null };
  });
  assert.deepEqual(route, { route: "access", sameRoot: true });
  await routePage.close();
  if (process.env.ACCESS_QA_MATRIX === "1") {
    const output = process.env.ACCESS_QA_OUTPUT ?? await mkdtemp(join(tmpdir(), "access-qa-"));
    await mkdir(output, { recursive: true });
    const manifest = { mode: "LOCAL_VISUAL_PREVIEW", session: "FRESH_ANONYMOUS",
      origin: "http://127.0.0.1", component: "AccessManager", routeSmoke: route,
      scale, screenshots: [] };
    const scenarios = ["empty", "loading", "v1", "preparing", "ready", "active",
      "direct", "group", "multiple-paths", "no-key", "unknown", "error"];
    for (const scenario of scenarios) {
      await page.evaluate(async (scenario) => {
        document.documentElement.lang = "en";
        document.dispatchEvent(new CustomEvent("selective-remote:locale-changed"));
        qa.scenario = scenario;
        qa.scaleMembers = 1;
        qa.scaleResources = 1;
        qa.formatState = ({ v1: "V1_ACTIVE", ready: "V2_READY", active: "V2_ACTIVE" })[scenario] ?? "V2_PREPARING";
        qa.manager.setContext({ teamID: qa.ids.teamID, vaultID: qa.ids.vaultID, role: "owner" });
        if (scenario === "loading") qa.pendingRefresh = qa.manager.refresh();
        else await qa.manager.refresh().catch(() => {});
      }, scenario);
      if (["direct", "group", "multiple-paths"].includes(scenario)) {
        await root.getByRole("navigation").getByRole("button", { name: "Resources", exact: true }).click();
        await root.locator(".access-directory li").first()
          .getByRole("button", { name: "Who has access permission" }).click();
        await root.locator(".access-detail .access-paths li").first().waitFor();
        const expected = scenario === "multiple-paths" ? 2 : 1;
        assert.equal(await root.locator(".access-detail .access-paths li").count(), expected, scenario);
      }
      if (["no-key", "unknown"].includes(scenario)) {
        await root.getByRole("navigation").getByRole("button", { name: "Members", exact: true }).click();
        await root.locator(".access-directory li").first()
          .getByRole("button", { name: "Resources", exact: true }).click();
        await root.getByText("Opening data: Not checked", { exact: true }).first().waitFor();
        assert.match(await root.innerText(), /Opening data: Not checked/);
        assert.match(await root.innerText(), /Device availability: Not checked/);
        await root.getByLabel("Member device")
          .selectOption(await page.evaluate(() => qa.ids.deviceID));
        await root.getByRole("button", { name: "Check device" }).click();
        await root.getByText(scenario === "no-key" ? "Device availability: Unavailable on device" : "Device availability: Availability on this device is unverified", { exact: true }).waitFor();
        assert.match(await root.innerText(), scenario === "no-key" ? /Unavailable on device|This device cannot open the resource data/ : /Availability on this device is unverified/);
        const effectiveText = await root.innerText();
        assert.match(effectiveText, /Access permission: allowed/);
        assert.match(effectiveText, scenario === "no-key" ? /Opening data: Unavailable/ : /Opening data: Opening data is unverified/);
        assert.match(effectiveText, scenario === "no-key" ? /Opening data · Reveal secret: Unavailable/ : /Opening data · Reveal secret: Opening data is unverified/);
        assert.match(effectiveText, /Device availability · Reveal secret:/);
      }
      const rendered = await root.innerText();
      if (scenario === "empty") {
        assert.match(rendered, /Nothing on this page/);
        assert.doesNotMatch(rendered, /Other paths remain/);
        assert.equal(await page.evaluate(() => qa.manager.state().pages.grants.rows.length), 0);
      }
      if (scenario === "loading") assert.match(rendered, /Loading/);
      if (scenario === "v1") assert.match(rendered, /Access applies to the whole Vault/);
      if (["ready", "active"].includes(scenario)) assert.match(rendered, /Access changes are unavailable here/);
      if (scenario === "error") assert.match(rendered, /Action failed|Cloud|synthetic_read_error/);
      for (const locale of ["ru", "en"]) for (const theme of ["light", "graphite"])
        for (const [viewport, width, height] of [["desktop", 1280, 900], ["tablet", 820, 900], ["mobile", 390, 844]]) {
          await page.setViewportSize({ width, height });
          await page.evaluate(({ locale, theme }) => {
            document.documentElement.lang = locale;
            document.documentElement.dataset.theme = theme;
            document.dispatchEvent(new CustomEvent("selective-remote:locale-changed"));
          }, { locale, theme });
          if (locale === "ru" && ["direct", "group", "multiple-paths"].includes(scenario)) {
            const pathCopy = await root.locator(".access-detail .access-paths").innerText();
            assert.doesNotMatch(pathCopy, /\b(?:USER|GROUP|RESOURCE|FOLDER)\b/);
            assert.match(pathCopy, /Участник|Группа/);
            const grantCopy = await root.locator(".access-grant").first().innerText();
            assert.doesNotMatch(grantCopy, /\b(?:USER|GROUP|RESOURCE|FOLDER)\b|\(15\)/);
            assert.match(grantCopy, /Участник.*Ресурс/s);
            const whoTitle = await root.locator(".access-detail h3").filter({ hasText: "Кому доступно" }).innerText();
            assert.match(whoTitle, /Учётные данные/);
            assert.doesNotMatch(whoTitle, /CREDENTIAL/);
          }
          const filename = `${scenario}-${locale}-${theme}-${viewport}.png`;
          await root.screenshot({ path: join(output, filename) });
          const overflow = await root.evaluate((node) => node.scrollWidth > node.clientWidth + 2);
          manifest.screenshots.push({ scenario, locale, theme, viewport, filename, overflow });
        }
      if (scenario === "loading") await page.evaluate(async () => {
        qa.releaseLoading();
        await qa.pendingRefresh;
      });
    }
    await writeFile(join(output, "manifest.json"), JSON.stringify(manifest, null, 2));
    console.log(JSON.stringify({ matrix: manifest.screenshots.length, output,
      overflow: manifest.screenshots.filter((item) => item.overflow).length }));
  }
  console.log(
    JSON.stringify({
      actualComponent: "AccessManager",
      authenticatedAdapter: true,
      commits: 1,
      callbacks: 1,
      requests: calls.length,
      scale,
      errors: 0,
    }),
  );
} finally {
  await browser?.close();
  await new Promise((r) => server.close(r));
}
