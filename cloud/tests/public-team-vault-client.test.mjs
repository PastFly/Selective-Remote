import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import {
  generateTeamDeviceIdentity,
  wrapTeamVaultKeyForDevice,
} from "../public/team-vault-crypto.js";
import { generateVaultKey } from "../public/vault-crypto.js";
import { createAuthenticatedVaultClient } from "../public/vault-sync.js";

const userID = "99999999-9999-4999-8999-999999999999";
const teamID = "11111111-1111-4111-8111-111111111111";
const vaultID = "22222222-2222-4222-8222-222222222222";
const membershipID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const otherMembershipID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const deviceID = "44444444-4444-4444-8444-444444444444";
const otherDeviceID = "55555555-5555-4555-8555-555555555555";
const scope = { type: "team", teamID, vaultID };

function jsonResponse(status, value) {
  return new Response(value === null ? null : JSON.stringify(value), {
    status,
    headers: value === null ? {} : { "Content-Type": "application/json" },
  });
}

async function fixture() {
  const identity = await generateTeamDeviceIdentity(webcrypto);
  const vaultKey = await generateVaultKey(webcrypto);
  const wrapper = await wrapTeamVaultKeyForDevice({
    vaultKey,
    recipient: {
      membershipID,
      membershipEpoch: 1,
      deviceID,
      publicKey: identity.publicKey,
    },
    teamID,
    vaultID,
    keyGeneration: 1,
    cryptoValue: webcrypto,
  });
  return { identity, wrapper };
}

test("authenticated browser client registers its public key and keeps Team requests explicitly scoped", async () => {
  const { identity, wrapper } = await fixture();
  const calls = [];
  const token = "t".repeat(43);
  const fetchValue = async (path, options = {}) => {
    calls.push({ path, options });
    if (path === "/v1/auth/login") {
      return jsonResponse(200, {
        token,
        user: { id: userID, email: "user@example.invalid", username: "user", displayName: "User" },
        deviceID,
      });
    }
    if (path.endsWith("/key-devices")) {
      return jsonResponse(200, { devices: [{
        membershipID,
        membershipEpoch: 1,
        deviceID,
        publicKeyAlgorithm: "p256-ecdh-v1",
        publicKey: identity.publicKey,
        hasWrapper: true,
      }] });
    }
    if (path === `/v1/teams/${teamID}/vaults/${vaultID}` && !options.method) {
      return jsonResponse(200, {
        id: vaultID,
        teamID,
        name: "Operations",
        revision: 1,
        keyGeneration: 1,
        rotationRequired: false,
        envelopeVersion: 1,
        ciphertext: "AA",
        nonce: "A".repeat(16),
        authTag: "A".repeat(22),
        contentHash: "A".repeat(43),
        wrapper,
        createdAt: "2026-09-05T00:00:00.000Z",
        updatedAt: "2026-09-05T00:00:00.000Z",
      });
    }
    throw new Error(`unexpected_request:${path}`);
  };
  const client = createAuthenticatedVaultClient({ fetchValue });

  await client.login({
    username: "user",
    password: "synthetic-password",
    deviceID,
    publicKey: identity.publicKey,
  });
  const loginBody = JSON.parse(calls[0].options.body);
  assert.deepEqual(loginBody.device.publicKey, identity.publicKey);
  assert.equal(JSON.stringify(client.session()).includes(token), false);

  const devices = await client.listTeamKeyDevices(scope);
  assert.equal(devices.devices[0].deviceID, deviceID);
  assert.equal(devices.devices[0].hasWrapper, true);
  const remote = await client.getTeamVault(scope);
  assert.equal(remote.scope.teamID, teamID);
  assert.equal(remote.wrapper.deviceID, deviceID);
  for (const call of calls.slice(1)) {
    assert.equal(call.options.headers.Authorization, `Bearer ${token}`);
    assert.equal(call.path.includes(teamID), true);
    assert.equal(call.path.includes(vaultID), true);
  }
});

test("account device transport normalizes approval metadata and revokes without parsing a 204 body", async () => {
  const { identity } = await fixture();
  const calls = [];
  const timestamp = "2026-09-06T00:00:00.000Z";
  const client = createAuthenticatedVaultClient({
    fetchValue: async (path, options = {}) => {
      calls.push({ path, options });
      if (path === "/v1/auth/login") return jsonResponse(200, {
        token: "t".repeat(43), user: { id: userID, email: "user@example.invalid", username: "user", displayName: "User" }, deviceID,
      });
      if (path === "/v1/devices") return jsonResponse(200, { devices: [{
        id: otherDeviceID,
        name: "New browser",
        platform: "web",
        app_version: "0.32",
        created_at: timestamp,
        last_seen_at: timestamp,
        revoked_at: null,
        key_registered: true,
        public_key_algorithm: "p256-ecdh-v1",
        public_key: JSON.stringify(identity.publicKey),
        key_approved_at: null,
      }] });
      if (path === `/v1/devices/${otherDeviceID}` && options.method === "DELETE") {
        return new Response(null, { status: 204 });
      }
      throw new Error(`unexpected_request:${path}`);
    },
  });
  await client.login({ email: "user@example.invalid", password: "synthetic-password", deviceID, publicKey: identity.publicKey });

  const devices = await client.listDevices();
  assert.equal(client.deviceID(), deviceID);
  assert.equal(devices[0].id, otherDeviceID);
  assert.deepEqual(devices[0].publicKey, identity.publicKey);
  assert.equal(devices[0].keyApprovedAt, null);
  assert.deepEqual(await client.revokeDevice(otherDeviceID), { revoked: true, deviceID: otherDeviceID });
  const revoke = calls.at(-1);
  assert.equal(revoke.options.method, "DELETE");
  assert.match(revoke.options.headers.Authorization, /^Bearer /u);
  assert.equal(revoke.options.credentials, "same-origin");
});

test("Team writes carry idempotency and distinguish conflict from committed rotation", async () => {
  const { identity, wrapper } = await fixture();
  const calls = [];
  let puts = 0;
  const client = createAuthenticatedVaultClient({
    fetchValue: async (path, options = {}) => {
      calls.push({ path, options });
      if (path === "/v1/auth/login") {
        return jsonResponse(200, {
          token: "t".repeat(43),
          user: { id: userID, email: "user@example.invalid", username: "user", displayName: "User" },
          deviceID,
        });
      }
      if (path === `/v1/devices/${otherDeviceID}`) {
        return jsonResponse(200, { approved: true, deviceID: otherDeviceID });
      }
      if (path === "/v1/devices/bootstrap-key") {
        return jsonResponse(200, { approved: true, deviceID, bootstrapped: true });
      }
      if (path.endsWith("/wrappers")) {
        return jsonResponse(201, { granted: true, keyGeneration: 1, deviceID });
      }
      if (path === `/v1/teams/${teamID}/vaults/${vaultID}` && options.method === "PUT") {
        puts += 1;
        return puts === 1
          ? jsonResponse(409, { conflict: true, revision: 2, keyGeneration: 1 })
          : jsonResponse(200, { conflict: false, revision: 3, keyGeneration: 2, rotationCompleted: true });
      }
      throw new Error(`unexpected_request:${path}`);
    },
  });
  await client.login({
    email: "user@example.invalid",
    password: "synthetic-password",
    deviceID,
    publicKey: identity.publicKey,
  });

  await client.approveDeviceKey({
    deviceID: otherDeviceID,
    publicKey: identity.publicKey,
    idempotencyKey: "request:approve-device:01",
  });
  assert.deepEqual(await client.bootstrapDeviceKey({
    password: "synthetic-password",
    publicKey: identity.publicKey,
    idempotencyKey: "request:bootstrap-device:01",
  }), { approved: true, deviceID, bootstrapped: true });
  await client.grantTeamVaultWrapper(
    scope,
    { keyGeneration: 1, wrapper },
    "request:grant-wrapper:01",
  );
  const envelope = {
    baseRevision: 2,
    keyGeneration: 1,
    envelopeVersion: 1,
    ciphertext: "AA",
    nonce: "A".repeat(16),
    authTag: "A".repeat(22),
    contentHash: "A".repeat(43),
  };
  assert.deepEqual(
    await client.putTeamVault(scope, envelope, "request:team-vault-put:01"),
    { conflict: true, revision: 2, keyGeneration: 1 },
  );
  assert.deepEqual(
    await client.putTeamVault(
      scope,
      { ...envelope, keyGeneration: 2 },
      "request:team-vault-put:02",
    ),
    { conflict: false, revision: 3, keyGeneration: 2, rotationCompleted: true },
  );

  for (const call of calls.filter((value) => value.options.method && value.path !== "/v1/auth/login")) {
    assert.match(call.options.headers["Idempotency-Key"], /^request:/u);
    assert.equal(call.options.credentials, "same-origin");
  }
});

test("invalid Team scope, key sets and idempotency fail before a network request", async () => {
  const calls = [];
  const client = createAuthenticatedVaultClient({ fetchValue: async (...input) => {
    calls.push(input);
    return jsonResponse(500, { error: "must_not_call" });
  } });

  await assert.rejects(client.getTeamVault({ type: "personal", teamID, vaultID }), /invalid_team_vault_scope/);
  await assert.rejects(client.listTeamKeyDevices({ type: "team", teamID, vaultID: "bad" }), /invalid_team_vault_scope/);
  await assert.rejects(
    client.approveDeviceKey({ deviceID, publicKey: {}, idempotencyKey: "request:approve-device:01" }),
    /invalid_team_device_public_key/,
  );
  assert.equal(calls.length, 0);
});

test("browser Team management covers lifecycle, members, invitations and shared Vault metadata", async () => {
  const { identity } = await fixture();
  const calls = [];
  const timestamps = { createdAt: "2026-09-05T00:00:00.000Z", updatedAt: "2026-09-05T00:00:00.000Z" };
  const team = {
    id: teamID,
    name: "Operations",
    membershipID,
    role: "owner",
    membershipEpoch: 1,
    ...timestamps,
  };
  const member = {
    id: membershipID,
    userID,
    username: "user",
    displayName: "User",
    role: "owner",
    epoch: 1,
    joinedAt: timestamps.createdAt,
  };
  const vault = {
    id: vaultID,
    teamID,
    name: "Operations",
    revision: 0,
    keyGeneration: 1,
    rotationRequired: false,
    ...timestamps,
  };
  const usernameInvitation = {
    id: "66666666-6666-4666-8666-666666666666",
    teamID,
    teamName: "Operations",
    type: "username",
    targetUsername: "member",
    role: "viewer",
    status: "pending",
    createdAt: timestamps.createdAt,
    expiresAt: "2026-09-07T00:00:00.000Z",
    acceptanceURL: null,
  };
  const linkInvitation = {
    ...usernameInvitation,
    id: "77777777-7777-4777-8777-777777777777",
    type: "link",
    targetUsername: null,
    acceptanceURL: `https://cloud.example.invalid/#accept-team-invitation?token=${"x".repeat(43)}`,
  };
  const pendingInvitation = {
    ...usernameInvitation,
    id: "88888888-8888-4888-8888-888888888888",
    targetUsername: "user",
  };
  const client = createAuthenticatedVaultClient({
    fetchValue: async (path, options = {}) => {
      calls.push({ path, options });
      if (path === "/v1/auth/login") return jsonResponse(200, {
        token: "t".repeat(43), user: { id: userID, email: "user@example.invalid", username: "user", displayName: "User" }, deviceID,
      });
      if (path === "/v1/teams" && !options.method) return jsonResponse(200, { teams: [team] });
      if (path === "/v1/teams" && options.method === "POST") return jsonResponse(201, { team });
      if (path === `/v1/teams/${teamID}` && options.method === "PATCH") {
        return jsonResponse(200, { team: { ...team, name: "Platform" } });
      }
      if (path === `/v1/teams/${teamID}/ownership-transfer` && options.method === "POST") {
        return jsonResponse(200, {
          transferred: true,
          teamID,
          previousOwnerMembershipID: membershipID,
          ownerMembershipID: otherMembershipID,
        });
      }
      if (path === `/v1/teams/${teamID}` && options.method === "DELETE") {
        return jsonResponse(200, { archived: true, teamID });
      }
      if (path.endsWith("/members") && !options.method) return jsonResponse(200, { members: [member] });
      if (path === `/v1/teams/${teamID}/invitations` && !options.method) {
        return jsonResponse(200, { invitations: [usernameInvitation, { ...linkInvitation, acceptanceURL: null }] });
      }
      if (path === "/v1/team-invitations" && !options.method) {
        return jsonResponse(200, { invitations: [pendingInvitation] });
      }
      if (path === `/v1/teams/${teamID}/invitations` && options.method === "POST") {
        return jsonResponse(201, {
          invitation: JSON.parse(options.body).type === "link" ? linkInvitation : usernameInvitation,
        });
      }
      if (path === `/v1/teams/${teamID}/invitations/${linkInvitation.id}` && options.method === "DELETE") {
        return jsonResponse(200, { cancelled: true });
      }
      if (path === "/v1/team-invitations/accept") return jsonResponse(200, { membership: member });
      if (path.endsWith(`/${membershipID}`) && options.method === "PATCH") {
        return jsonResponse(200, { membership: { ...member, role: "editor" } });
      }
      if (path.endsWith(`/${membershipID}`) && options.method === "DELETE") {
        return jsonResponse(200, { revoked: true, rotationRequiredVaults: 1 });
      }
      if (path.endsWith("/vaults") && !options.method) return jsonResponse(200, { vaults: [vault] });
      if (path.endsWith("/vaults") && options.method === "POST") return jsonResponse(201, { vault });
      throw new Error(`unexpected_request:${path}`);
    },
  });
  await client.login({
    email: "user@example.invalid", password: "synthetic-password", deviceID, publicKey: identity.publicKey,
  });

  assert.deepEqual(await client.listTeams(), [team]);
  assert.deepEqual(await client.createTeam({ name: " Operations " }), team);
  assert.equal((await client.renameTeam({ teamID, name: " Platform " })).name, "Platform");
  assert.deepEqual(await client.transferTeamOwnership({
    teamID,
    membershipID: otherMembershipID,
    password: "synthetic-password",
  }), {
    transferred: true,
    teamID,
    previousOwnerMembershipID: membershipID,
    ownerMembershipID: otherMembershipID,
  });
  assert.deepEqual(await client.archiveTeam({
    teamID,
    expectedName: "Operations",
    password: "synthetic-password",
  }), { archived: true, teamID });
  await assert.rejects(client.archiveTeam({
    teamID,
    expectedName: " Operations ",
    password: "synthetic-password",
  }), /team_name_mismatch/);
  assert.equal(calls.filter(({ path, options }) => path === `/v1/teams/${teamID}` && options.method === "DELETE").length, 1);
  assert.deepEqual(await client.listTeamMembers(teamID), [member]);
  assert.deepEqual(await client.listTeamInvitations(teamID), [usernameInvitation, { ...linkInvitation, acceptanceURL: null }]);
  assert.deepEqual(await client.listPendingTeamInvitations(), [pendingInvitation]);
  const invitation = await client.inviteTeamMember({ teamID, username: "@MEMBER", role: "viewer" });
  assert.equal(invitation.targetUsername, "member");
  assert.equal("token" in invitation, false);
  const link = await client.inviteTeamMember({ teamID, type: "link", role: "viewer" });
  assert.match(link.acceptanceURL, /#accept-team-invitation\?token=/u);
  assert.deepEqual(await client.acceptTeamInvitation({ token: "x".repeat(48) }), member);
  assert.deepEqual(await client.acceptTeamInvitation({ invitationID: usernameInvitation.id }), member);
  assert.deepEqual(await client.cancelTeamInvitation({ teamID, invitationID: linkInvitation.id }), { cancelled: true });
  assert.equal((await client.updateTeamMemberRole({ teamID, membershipID, role: "editor" })).role, "editor");
  assert.deepEqual(await client.revokeTeamMember({ teamID, membershipID }), {
    revoked: true, rotationRequiredVaults: 1,
  });
  assert.deepEqual(await client.listSharedVaults(teamID), [vault]);
  assert.deepEqual(await client.createSharedVault({ teamID, name: " Operations " }), vault);

  for (const call of calls.filter(({ options }) => options.method && options.method !== "POST" || options.body)) {
    if (call.path === "/v1/auth/login") continue;
    assert.match(call.options.headers.Authorization, /^Bearer /u);
    if (call.options.method !== undefined) assert.match(call.options.headers["Idempotency-Key"], /^web:/u);
  }
  assert.doesNotMatch(JSON.stringify(calls), /localStorage|sessionStorage/u);
  assert.equal(JSON.stringify(client.session()).includes("synthetic-password"), false);
});
