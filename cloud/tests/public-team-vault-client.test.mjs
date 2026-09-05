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
        user: { id: userID, email: "user@example.invalid", displayName: "User" },
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
    email: "user@example.invalid",
    password: "synthetic-password",
    deviceID,
    publicKey: identity.publicKey,
  });
  const loginBody = JSON.parse(calls[0].options.body);
  assert.deepEqual(loginBody.device.publicKey, identity.publicKey);
  assert.equal(JSON.stringify(client.session()).includes(token), false);

  const devices = await client.listTeamKeyDevices(scope);
  assert.equal(devices.devices[0].deviceID, deviceID);
  const remote = await client.getTeamVault(scope);
  assert.equal(remote.scope.teamID, teamID);
  assert.equal(remote.wrapper.deviceID, deviceID);
  for (const call of calls.slice(1)) {
    assert.equal(call.options.headers.Authorization, `Bearer ${token}`);
    assert.equal(call.path.includes(teamID), true);
    assert.equal(call.path.includes(vaultID), true);
  }
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
          user: { id: userID, email: "user@example.invalid", displayName: "User" },
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
    assert.equal(call.options.credentials, "omit");
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
    email: "user@example.invalid",
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
  const client = createAuthenticatedVaultClient({
    fetchValue: async (path, options = {}) => {
      calls.push({ path, options });
      if (path === "/v1/auth/login") return jsonResponse(200, {
        token: "t".repeat(43), user: { id: userID, email: "user@example.invalid", displayName: "User" }, deviceID,
      });
      if (path === "/v1/teams" && !options.method) return jsonResponse(200, { teams: [team] });
      if (path === "/v1/teams" && options.method === "POST") return jsonResponse(201, { team });
      if (path.endsWith("/members") && !options.method) return jsonResponse(200, { members: [member] });
      if (path.endsWith("/invitations")) return jsonResponse(201, { invitation: {
        id: "66666666-6666-4666-8666-666666666666",
        teamID,
        email: "member@example.invalid",
        role: "viewer",
        status: "pending",
        createdAt: timestamps.createdAt,
        expiresAt: "2026-09-07T00:00:00.000Z",
      } });
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
  assert.deepEqual(await client.listTeamMembers(teamID), [member]);
  const invitation = await client.inviteTeamMember({ teamID, email: "MEMBER@example.invalid", role: "viewer" });
  assert.equal(invitation.email, "member@example.invalid");
  assert.equal("token" in invitation, false);
  assert.deepEqual(await client.acceptTeamInvitation({ token: "x".repeat(48) }), member);
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
});
