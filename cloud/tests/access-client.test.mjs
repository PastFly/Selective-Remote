import test from "node:test";
import assert from "node:assert/strict";
import { createAccessClient } from "../public/access-client.js";
import { createAuthenticatedVaultClient } from "../public/vault-sync.js";
const teamID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  vaultID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  userID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
  deviceID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const scope = { teamID, vaultID };
test("authenticated adapter owns bearer binding and invalidates 401", async () => {
  let status = 200;
  const calls = [];
  const client = createAuthenticatedVaultClient({
    fetchValue: async (path, options) => {
      calls.push({ path, options });
      return new Response(
        JSON.stringify(
          path === "/v1/auth/login"
            ? {
                token: "s".repeat(32),
                deviceID,
                user: {
                  id: userID,
                  email: "a@a.invalid",
                  username: "aaa",
                  displayName: "A",
                },
              }
            : { rows: [], nextCursor: null },
        ),
        { status },
      );
    },
  });
  // Session restoration uses existing public session API.
  await client.login({
    email: "a@a.invalid",
    password: "synthetic-password",
    deviceID,
  });
  const access = client.accessClient();
  await access.listVaults(teamID);
  assert.equal(
    calls.at(-1).options.headers.Authorization,
    `Bearer ${"s".repeat(32)}`,
  );
  assert.equal(calls.at(-1).options.credentials, "same-origin");
  status = 401;
  await assert.rejects(access.listVaults(teamID), /authentication_required/);
  assert.equal(client.session(), null);
});
test("exact routes, canonical explicit subjects, empty page cursor and scope rejection", async () => {
  const calls = [];
  let body = { rows: [], nextCursor: userID };
  const client = createAccessClient({
    request: async (path, options) => {
      calls.push({ path, options });
      return new Response(JSON.stringify(body));
    },
    currentUserID: () => userID,
    currentDeviceID: () => deviceID,
  });
  await client.whoHas(scope, userID);
  assert.match(calls.at(-1).path, /who-has-access\/cccc/);
  body = {
    policyEffective: {
      policyAllowed: true,
      policyMask: 1,
      paths: [],
      blockedReasons: [],
    },
    deviceUsability: {
      deviceID,
      effectiveUsable: "UNKNOWN",
      cryptoAvailable: "WRAP_PRESENT_UNVERIFIED",
      blockedReasons: [],
    },
  };
  await client.effective(
    scope,
    userID,
    userID.toUpperCase(),
    deviceID.toUpperCase(),
  );
  assert.match(calls.at(-1).path, /subjectUserID=cccc.*subjectDeviceID=dddd/);
  await assert.rejects(
    client.effective(scope, userID, userID, null),
    /invalid_access_device/,
  );
  body = {
    rows: [
      {
        id: userID,
        teamID: userID,
        vaultID,
        policyKind: "HOST",
        parentFolderID: null,
        resourceVersion: 1,
      },
    ],
    nextCursor: null,
  };
  await assert.rejects(client.listResources(scope), /access_scope_mismatch/);
});
test("preview repeats complete request, commit uses token and stable idempotency key; typed errors", async () => {
  const calls = [];
  let status = 200,
    body = {
      token: "synthetic",
      snapshotID: "a".repeat(64),
      details: [],
      affectedGrants: [],
      counts: { pairs: 0, widened: 0, lost: 0, affectedGrants: 0 },
      nextCursor: "100",
    };
  const client = createAccessClient({
    request: async (path, options) => {
      calls.push({ path, options });
      return new Response(JSON.stringify(body), { status });
    },
    currentUserID: () => userID,
    currentDeviceID: () => deviceID,
  });
  const request = { type: "GROUP_CREATE", name: "New" };
  await client.preview(scope, request, "50");
  assert.deepEqual(JSON.parse(calls.at(-1).options.body), {
    request,
    cursor: "50",
  });
  body = {
    group: { id: userID, team_id: teamID, name: "New", version: "1" },
    notificationCandidates: [],
    counts: { pairs: 0 },
  };
  await client.commit(scope, request, "synthetic", "stable-key");
  assert.equal(calls.at(-1).options.headers["Idempotency-Key"], "stable-key");
  status = 409;
  body = { error: "group_grants_must_be_revoked_first", safeCount: "1001+" };
  await assert.rejects(
    client.preview(scope, request),
    (e) => e.code === body.error && e.safeCount === "1001+",
  );
});

test("paged member search and all bounded directories use wire scope", async () => {
  const calls = [];
  let body = { members: [], nextCursor: userID, total: 1000 };
  const c = createAccessClient({
    request: async (path) => {
      calls.push(path);
      return new Response(JSON.stringify(body));
    },
  });
  const page = await c.listMembers(teamID, {
    search: "Alice %",
    cursor: userID,
  });
  assert.equal(page.nextCursor, userID);
  assert.match(calls.at(-1), /search=Alice\+%25/);
  body = {
    rows: [{ id: userID, team_id: teamID, name: "G", version: "2" }],
    nextCursor: null,
  };
  await c.listGroups(teamID, { search: "_%" });
  assert.match(calls.at(-1), /search=_%25/);
  body = {
    rows: [
      {
        id: deviceID,
        groupID: userID,
        userID,
        membershipID: teamID,
        membershipEpoch: 1,
        version: 2,
      },
    ],
    nextCursor: null,
  };
  await c.listGroupMembers(teamID, userID);
  body = {
    rows: [{ id: userID, name: "Device", platform: "web", admitted: true }],
    nextCursor: null,
  };
  await c.listDevices(scope, userID);
  assert.match(calls.at(-1), /subjectUserID=cccc/);
  body = {
    rows: [
      {
        id: deviceID,
        principal_kind: "GROUP",
        principal_id: userID,
        target_kind: "RESOURCE",
        target_id: teamID,
        permission_mask: 13,
        version: "3",
      },
    ],
    nextCursor: null,
  };
  const grants = await c.listGrants(scope);
  assert.equal(grants.rows[0].version, 3);
  await assert.rejects(
    c.listGroups(teamID, { limit: 51 }),
    /invalid_access_page/,
  );
});
test("all policy paths survive and no implicit current-device fallback", async () => {
  const paths = [
    {
      id: teamID,
      principalKind: "USER",
      principalID: userID,
      grantTargetKind: "RESOURCE",
      grantTargetID: teamID,
      sourceType: "DIRECT",
      mask: 13,
      effectiveMask: 13,
      permissions: ["View", "Edit", "ManageAccess"],
    },
    {
      id: vaultID,
      principalKind: "GROUP",
      principalID: deviceID,
      grantTargetKind: "FOLDER",
      grantTargetID: vaultID,
      sourceType: "INHERITED_CONTAINER",
      mask: 33,
      effectiveMask: 1,
      permissions: ["View"],
    },
  ];
  const c = createAccessClient({
    request: async () =>
      new Response(
        JSON.stringify({
          rows: [
            {
              userID,
              policyEffective: {
                policyAllowed: true,
                policyMask: 13,
                paths,
                blockedReasons: [],
              },
            },
          ],
          nextCursor: null,
        }),
      ),
    currentDeviceID: () => deviceID,
  });
  const r = await c.whoHas(scope, teamID);
  assert.deepEqual(r.rows[0].policyEffective.paths, paths);
  await assert.rejects(
    c.effective(scope, teamID, userID, undefined),
    /invalid_access_device/,
  );
});

test("a successful HTTP response with mismatched mutation scope is rejected", async () => {
  const c = createAccessClient({
    request: async () =>
      new Response(
        JSON.stringify({
          removed: true,
          edgeID: teamID,
          notificationCandidates: [],
          counts: { pairs: 0, widened: 0, lost: 0 },
        }),
      ),
  });
  await assert.rejects(
    c.commit(
      scope,
      {
        type: "GROUP_MEMBER_REMOVE",
        groupID: userID,
        edgeID: deviceID,
        expectedVersion: 1,
      },
      "t",
      "key",
    ),
    /access_scope_mismatch/,
  );
});

test("exact resource lookup validates requested ID and scope without scanning pages", async () => {
  const calls = [];
  let body = {
    id: userID,
    teamID,
    vaultID,
    policyKind: "CREDENTIAL",
    parentFolderID: null,
    resourceVersion: 2,
  };
  const c = createAccessClient({
    request: async (path) => {
      calls.push(path);
      return new Response(JSON.stringify(body));
    },
  });
  assert.equal(
    (await c.getResource(scope, userID.toUpperCase())).policyKind,
    "CREDENTIAL",
  );
  assert.deepEqual(calls, [
    `/v1/teams/${teamID}/vaults/${vaultID}/access-resources/${userID}`,
  ]);
  body = { ...body, id: deviceID };
  await assert.rejects(c.getResource(scope, userID), /access_scope_mismatch/);
  body = { ...body, id: userID, teamID: deviceID };
  await assert.rejects(c.getResource(scope, userID), /access_scope_mismatch/);
});
