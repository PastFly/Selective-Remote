// Real component + authenticated browser adapter; synthetic scoped server responses.
// Run: PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node cloud/tests/browser/access-manager-smoke.mjs
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import assert from "node:assert/strict";
import { resolve } from "node:path";
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
      else if (url.pathname.endsWith("/access-context"))
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
          rows: [
            {
              id: resourceID,
              teamID,
              vaultID,
              policyKind: "CREDENTIAL",
              parentFolderID: null,
              resourceVersion: 1,
            },
          ],
          nextCursor: null,
        };
      else if (url.pathname.endsWith("/access-grants"))
        body = {
          rows: [
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
          rows: [
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
          members: [
            {
              id: userID,
              userID,
              displayName: "Synthetic recipient",
              username: "synthetic",
              role: "viewer",
              epoch: 1,
            },
          ],
          total: 1,
          nextCursor: null,
        };
      else if (url.pathname.includes("/resources-by-principal/"))
        body = {
          rows: [{ resourceID, policyEffective: policy }],
          nextCursor: null,
        };
      else if (url.pathname.includes("/who-has-access/"))
        body = {
          rows: [{ userID, policyEffective: policy }],
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
            effectiveUsable: "UNKNOWN",
            cryptoAvailable: "WRAP_PRESENT_UNVERIFIED",
            cryptoAvailableByPermission: { Reveal: "WRAP_PRESENT_UNVERIFIED" },
            effectiveUsableByPermission: { Reveal: "UNKNOWN" },
            blockedReasons: [],
          },
        };
      else if (
        url.pathname.endsWith("/access-preview") ||
        url.pathname.endsWith("/access-group-preview")
      ) {
        const request = JSON.parse(options.body);
        body = {
          token: "synthetic-preview",
          snapshotID: "a".repeat(64),
          details: request.cursor
            ? [
                {
                  vaultID,
                  resourceID,
                  subjectUserID: userID,
                  before: { policyEffective: policy },
                  after: { policyEffective: policy },
                  gainedMask: 0,
                  lostMask: 0,
                },
              ]
            : [],
          affectedGrants: [],
          counts: { pairs: 1, widened: 0, lost: 0, affectedGrants: 0 },
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
  await root
    .getByRole("checkbox", { name: "Synthetic recipient", exact: true })
    .check();
  await root
    .getByRole("navigation")
    .getByRole("button", { name: "Resources", exact: true })
    .click();
  await root.getByRole("checkbox", { name: /CREDENTIAL · eeee/ }).check();
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
  await root.getByRole("button", { name: "Load more consequences" }).click();
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
  await root.getByText("Change committed by server", { exact: true }).waitFor();
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
    .getByText("Device usability unverified", { exact: true })
    .waitFor();
  assert.equal(
    await root
      .getByText("Device usability unverified", { exact: true })
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
  await page.evaluate(() => qa.manager.setDraft(null));
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
      state === "V1_ACTIVE" ? /V1:/ : /READY\/ACTIVE:/,
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
  console.log(
    JSON.stringify({
      actualComponent: "AccessManager",
      authenticatedAdapter: true,
      commits: 1,
      callbacks: 1,
      requests: calls.length,
      errors: 0,
    }),
  );
} finally {
  await browser?.close();
  await new Promise((r) => server.close(r));
}
