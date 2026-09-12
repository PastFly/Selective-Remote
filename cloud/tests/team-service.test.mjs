import assert from "node:assert/strict";
import test from "node:test";
import { CloudService } from "../src/service.mjs";

const teamID = "84f6c860-0d26-4ef5-8652-27cb8b991b70";
const membershipID = "7026d8a4-116a-4f61-9d8e-ff04e3a73360";
const deviceID = "33cc880e-084a-4d9a-b1ea-f99d2ff86032";
const vaultID = "bc01823b-1401-4058-9488-f4f6d1839b3b";
const session = {
  user_id: "user-1",
  device_id: deviceID,
  email: "owner@example.com",
  username: "owner.name",
};
const config = {
  publicOrigin: "https://cloud.example.invalid",
  teamInvitationTTLHours: 48,
  teamInvitationTokenPepper: "t".repeat(32),
  teamOutboxEncryptionKey: "o".repeat(32),
};

class TeamStore {
  constructor() {
    this.calls = [];
    this.job = null;
  }

  async listTeams(userID) {
    this.calls.push(["listTeams", userID]);
    return [{
      id: teamID,
      name: "Operations",
      membership_id: membershipID,
      role: "owner",
      epoch: 1,
      created_at: "2030-01-01T00:00:00.000Z",
      updated_at: "2030-01-01T00:00:00.000Z",
    }];
  }

  async createTeam(input) {
    this.calls.push(["createTeam", input]);
    return {
      team: { id: teamID, name: input.name, created_at: "now", updated_at: "now" },
      membership: { id: membershipID, role: "owner", epoch: 1 },
    };
  }

  async renameTeam(input) {
    this.calls.push(["renameTeam", input]);
    return {
      team: { id: teamID, name: input.name, created_at: "then", updated_at: "now" },
      membership: { id: membershipID, role: "owner", epoch: 1 },
    };
  }

  async transferTeamOwnership(input) {
    this.calls.push(["transferTeamOwnership", input]);
    return {
      transferred: true,
      teamID: input.teamID,
      previousOwnerMembershipID: membershipID,
      ownerMembershipID: input.membershipID,
    };
  }

  async archiveTeam(input) {
    this.calls.push(["archiveTeam", input]);
    return { archived: true, teamID: input.teamID };
  }

  async createTeamInvitation(input) {
    this.calls.push(["createTeamInvitation", input]);
    this.job = input.outboxEnvelope ? {
        id: "25b79add-2d18-4fa7-9ef7-9373f850001a",
        attempts: 1,
        payload_ciphertext: input.outboxEnvelope.ciphertext,
        nonce: input.outboxEnvelope.nonce,
        auth_tag: input.outboxEnvelope.authTag,
      } : null;
    return { invitation: {
      id: "471c3424-b6aa-41a0-959f-aeaa1e3ef79d",
      team_id: input.teamID,
      invitation_type: input.invitationType,
      target_username: input.username,
      team_name: "Operations",
      role: input.role,
      created_at: "now",
      expires_at: input.expiresAt,
    }, linkSecretEnvelope: input.linkSecretEnvelope };
  }

  async listTeamInvitations(teamID, userID) {
    this.calls.push(["listTeamInvitations", teamID, userID]);
    return [];
  }

  async listPendingTeamInvitations(userID) {
    this.calls.push(["listPendingTeamInvitations", userID]);
    return [];
  }

  async claimTeamInvitationOutbox() {
    const job = this.job;
    this.job = null;
    return job;
  }

  async completeTeamInvitationOutbox(jobID, owner) {
    this.calls.push(["completeTeamInvitationOutbox", jobID, owner]);
    return true;
  }

  async retryTeamInvitationOutbox(jobID, owner, seconds) {
    this.calls.push(["retryTeamInvitationOutbox", jobID, owner, seconds]);
    return true;
  }

  async acceptTeamInvitation(input) {
    this.calls.push(["acceptTeamInvitation", input]);
    return { membership: {
      id: membershipID,
      user_id: input.actorUserID,
      username: "owner",
      display_name: "Owner",
      role: "editor",
      epoch: 2,
      joined_at: "now",
    } };
  }

  async cancelTeamInvitation(input) {
    this.calls.push(["cancelTeamInvitation", input]);
    return { cancelled: true };
  }

  async updateTeamMembershipRole(input) {
    this.calls.push(["updateTeamMembershipRole", input]);
    return { membership: { id: input.membershipID, user_id: "user-2", role: input.role, epoch: 1 } };
  }

  async revokeTeamMembership(input) {
    this.calls.push(["revokeTeamMembership", input]);
    return { revoked: true, rotationRequiredVaults: 2 };
  }

  async listTeamMembers(team, actor, page = null) {
    this.calls.push(["listTeamMembers", team, actor, page]);
    const member = {
      id: membershipID, user_id: "user-1", username: "owner", display_name: "Owner",
      role: "owner", epoch: 1, joined_at: "2026-09-12T00:00:00.000Z",
    };
    return page ? { rows: [member], nextCursor: null, total: 1 } : [member];
  }

  async listSharedVaults(team, actor) {
    this.calls.push(["listSharedVaults", team, actor]);
    return [];
  }

  async createSharedVault(input) {
    this.calls.push(["createSharedVault", input]);
    return { vault: {
      id: "bc01823b-1401-4058-9488-f4f6d1839b3b",
      team_id: input.teamID,
      name: input.name,
      revision: 0,
      key_generation: 1,
      rotation_required: false,
    } };
  }

  async renameSharedVault(input) {
    this.calls.push(["renameSharedVault", input]);
    return { vault: {
      id: input.vaultID,
      team_id: input.teamID,
      name: input.name,
      revision: 6,
      key_generation: 1,
      rotation_required: false,
    } };
  }

  async approveDeviceKey(input) {
    this.calls.push(["approveDeviceKey", input]);
    return { approved: true, deviceID: input.deviceID };
  }

  async passwordIdentity(email) {
    this.calls.push(["passwordIdentity", email]);
    return { id: "user-1", password_hash: "synthetic-hash", disabled_at: null };
  }

  async bootstrapDeviceKey(input) {
    this.calls.push(["bootstrapDeviceKey", input]);
    return { approved: true, deviceID: input.actorDeviceID, bootstrapped: true };
  }

  async listTeamKeyDevices(team, vault, actor, device) {
    this.calls.push(["listTeamKeyDevices", team, vault, actor, device]);
    return [{
      membership_id: membershipID,
      membership_epoch: 1,
      device_id: deviceID,
      public_key_algorithm: "p256-ecdh-v1",
      public_key: JSON.stringify({ kty: "EC", crv: "P-256", x: "A".repeat(43), y: "B".repeat(43) }),
      has_wrapper: true,
    }];
  }

  async getSharedVault(team, vault, actor, device) {
    this.calls.push(["getSharedVault", team, vault, actor, device]);
    return {
      id: vaultID,
      team_id: teamID,
      name: "Production",
      revision: 1,
      key_generation: 1,
      rotation_required: false,
      envelope_version: 1,
      ciphertext: "AA",
      nonce: "B".repeat(16),
      auth_tag: "C".repeat(22),
      content_hash: "D".repeat(43),
      membership_id: membershipID,
      membership_epoch: 1,
      device_id: deviceID,
      wrapper_version: 1,
      ephemeral_public_key: { kty: "EC", crv: "P-256", x: "E".repeat(43), y: "F".repeat(43) },
      wrapper_ciphertext: "G".repeat(43),
      wrapper_nonce: "H".repeat(16),
      wrapper_auth_tag: "I".repeat(22),
      context_hash: "J".repeat(43),
    };
  }

  async putSharedVault(input) {
    this.calls.push(["putSharedVault", input]);
    return { conflict: false, revision: 1, keyGeneration: 1, rotationCompleted: false };
  }

  async grantSharedVaultWrapper(input) {
    this.calls.push(["grantSharedVaultWrapper", input]);
    return { granted: true, keyGeneration: input.keyGeneration, deviceID: input.wrapper.deviceID };
  }
}

test("Team creation derives Owner identity from the authenticated session", async () => {
  const store = new TeamStore();
  const service = new CloudService(store, config);
  const result = await service.createTeam(session, { name: " Operations ", ownerUserID: "attacker" }, "request:team-create-01");

  assert.equal(result.team.id, teamID);
  assert.equal(result.team.membershipID, membershipID);
  assert.equal(result.team.role, "owner");
  assert.deepEqual(store.calls[0][1], {
    actorUserID: "user-1",
    name: "Operations",
    idempotencyKey: "request:team-create-01",
  });
});

test("Team rename remains Owner-scoped and derives actor identity from the session", async () => {
  const store = new TeamStore();
  const service = new CloudService(store, config);
  const result = await service.renameTeam(
    session,
    teamID,
    { name: " Platform ", actorUserID: "attacker" },
    "request:team-rename-01",
  );
  assert.equal(result.team.name, "Platform");
  assert.deepEqual(store.calls[0][1], {
    actorUserID: session.user_id,
    teamID,
    name: "Platform",
    idempotencyKey: "request:team-rename-01",
  });
});

test("ownership transfer and Team archive require password reauthentication", async () => {
  const targetMembershipID = "87806d7b-d3a9-4701-8262-f247bd5de1e9";
  const store = new TeamStore();
  const service = new CloudService(store, config, null, console, async (password, hash) => (
    password === "synthetic-password" && hash === "synthetic-hash"
  ));

  assert.equal((await service.transferTeamOwnership(
    session,
    teamID,
    { membershipID: targetMembershipID, password: "synthetic-password", actorUserID: "attacker" },
    "request:team-transfer-01",
  )).ownerMembershipID, targetMembershipID);
  assert.deepEqual(store.calls[1][1], {
    actorUserID: session.user_id,
    teamID,
    membershipID: targetMembershipID,
    idempotencyKey: "request:team-transfer-01",
  });

  assert.deepEqual(await service.archiveTeam(
    session,
    teamID,
    { expectedName: "Operations", password: "synthetic-password", actorUserID: "attacker" },
    "request:team-archive-01",
  ), { archived: true, teamID });
  assert.deepEqual(store.calls[3][1], {
    actorUserID: session.user_id,
    teamID,
    expectedName: "Operations",
    idempotencyKey: "request:team-archive-01",
  });

  await assert.rejects(service.transferTeamOwnership(
    session,
    teamID,
    { membershipID: targetMembershipID, password: "wrong-password-value" },
    "request:team-transfer-02",
  ), /invalid_credentials/);
  await assert.rejects(service.archiveTeam(
    session,
    teamID,
    { expectedName: " Operations ", password: "synthetic-password" },
    "request:team-archive-02",
  ), /team_name_mismatch/);
  assert.equal(store.calls.filter(([name]) => name === "transferTeamOwnership").length, 1);
  assert.equal(store.calls.filter(([name]) => name === "archiveTeam").length, 1);
});

test("invitation listings stay scoped to the authenticated user and Team", async () => {
  const store = new TeamStore();
  const service = new CloudService(store, config);

  assert.deepEqual(await service.listTeamInvitations(session, teamID), { invitations: [] });
  assert.deepEqual(await service.listPendingTeamInvitations(session), { invitations: [] });
  assert.deepEqual(store.calls, [
    ["listTeamInvitations", teamID, session.user_id],
    ["listPendingTeamInvitations", session.user_id],
  ]);
});

test("legacy email invitation API persists only a hash and encrypted durable outbox payload", async () => {
  const store = new TeamStore();
  let delivered;
  const service = new CloudService(store, config, {
    async sendTeamInvitation(payload) { delivered = payload; },
  });
  const response = await service.createTeamInvitation(
    session,
    teamID,
    { email: " MEMBER@Example.com ", role: "editor" },
    "request:team-invite-01",
  );
  const stored = store.calls.find(([name]) => name === "createTeamInvitation")[1];

  assert.match(stored.tokenHash, /^[0-9a-f]{64}$/);
  assert.equal(JSON.stringify(stored).includes("token\":"), false);
  assert.doesNotMatch(JSON.stringify(stored.outboxEnvelope), /member@example\.com|editor/);
  assert.equal("token" in response.invitation, false);
  assert.equal(response.invitation.type, "email");
  assert.equal("email" in response.invitation, false);
  assert.equal(response.invitation.acceptanceURL, null);
  assert.equal(await service.dispatchTeamInvitationOutbox(), true);
  assert.equal(delivered.recipient, "member@example.com");
  assert.equal(delivered.teamName, "Operations");
  assert.equal(delivered.invitedBy, "owner.name");
  assert.ok(delivered.token.length >= 40);
  assert.equal(store.calls.at(-1)[0], "completeTeamInvitationOutbox");
});

test("username invitations are account-bound while link invitations return one sealed URL", async () => {
  const store = new TeamStore();
  const service = new CloudService(store, config);

  const usernameResponse = await service.createTeamInvitation(
    session,
    teamID,
    { username: " Member.Name ", role: "viewer" },
    "request:team-username-01",
  );
  const usernameStored = store.calls[0][1];
  assert.equal(usernameStored.invitationType, "username");
  assert.equal(usernameStored.username, "member.name");
  assert.equal(usernameStored.email, null);
  assert.equal(usernameStored.outboxEnvelope, null);
  assert.equal(usernameResponse.invitation.targetUsername, "member.name");
  assert.equal(usernameResponse.invitation.acceptanceURL, null);

  const linkResponse = await service.createTeamInvitation(
    session,
    teamID,
    { type: "link", role: "editor" },
    "request:team-link-01",
  );
  const linkStored = store.calls[1][1];
  assert.equal(linkStored.invitationType, "link");
  assert.equal(linkStored.email, null);
  assert.equal(linkStored.username, null);
  assert.doesNotMatch(JSON.stringify(linkStored.linkSecretEnvelope), /accept-team-invitation|token/iu);
  assert.match(linkResponse.invitation.acceptanceURL, /^https:\/\/cloud\.example\.invalid\/#accept-team-invitation\?token=/u);
  assert.equal("token" in linkResponse.invitation, false);
  assert.equal("email" in linkResponse.invitation, false);
});

test("failed invitation delivery is sanitized and durably rescheduled", async () => {
  const store = new TeamStore();
  const warnings = [];
  const service = new CloudService(store, config, {
    async sendTeamInvitation() { throw new Error("provider-secret"); },
  }, { warn(value) { warnings.push(value); } });
  await service.createTeamInvitation(
    session,
    teamID,
    { email: "member@example.com", role: "viewer" },
    "request:team-invite-02",
  );

  assert.equal(await service.dispatchTeamInvitationOutbox(), false);
  assert.equal(store.calls.at(-1)[0], "retryTeamInvitationOutbox");
  assert.equal(warnings.length, 1);
  assert.doesNotMatch(warnings[0], /provider-secret|member@example\.com/);
});

test("invitation acceptance binds email links or a username invitation ID to the session", async () => {
  const store = new TeamStore();
  const service = new CloudService(store, config);
  const accepted = await service.acceptTeamInvitation(
    session,
    { token: "opaque-invitation", userID: "attacker", email: "attacker@example.com" },
    "request:team-accept-01",
  );
  const stored = store.calls[0][1];

  assert.equal(stored.actorUserID, "user-1");
  assert.equal(stored.actorDeviceID, deviceID);
  assert.equal(stored.actorEmail, "owner@example.com");
  assert.equal(stored.invitationID, null);
  assert.match(stored.tokenHash, /^[0-9a-f]{64}$/);
  assert.equal("token" in stored, false);
  assert.equal(accepted.membership.username, "owner");
  assert.equal(accepted.membership.displayName, "Owner");

  await service.acceptTeamInvitation(
    session,
    { invitationID: "471c3424-b6aa-41a0-959f-aeaa1e3ef79d", userID: "attacker" },
    "request:team-accept-02",
  );
  const usernameStored = store.calls[1][1];
  assert.equal(usernameStored.actorUserID, "user-1");
  assert.equal(usernameStored.actorDeviceID, deviceID);
  assert.equal(usernameStored.invitationID, "471c3424-b6aa-41a0-959f-aeaa1e3ef79d");
  assert.equal(usernameStored.tokenHash, null);
  await assert.rejects(
    service.acceptTeamInvitation(
      session,
      { invitationID: "471c3424-b6aa-41a0-959f-aeaa1e3ef79d", token: "also-present" },
      "request:team-accept-03",
    ),
    /invalid_team_invitation/,
  );
});

test("invitation cancellation remains explicitly scoped and idempotent", async () => {
  const store = new TeamStore();
  const service = new CloudService(store, config);
  const invitationID = "471c3424-b6aa-41a0-959f-aeaa1e3ef79d";

  assert.deepEqual(
    await service.cancelTeamInvitation(session, teamID, invitationID, "request:team-cancel-01"),
    { cancelled: true },
  );
  assert.deepEqual(store.calls[0][1], {
    actorUserID: "user-1",
    teamID,
    invitationID,
    idempotencyKey: "request:team-cancel-01",
  });
});

test("member and shared-Vault operations preserve explicit Team scope", async () => {
  const store = new TeamStore();
  const service = new CloudService(store, config);

  await service.listTeamMembers(session, teamID);
  await service.updateTeamMembershipRole(session, teamID, membershipID, { role: "viewer" }, "request:member-role-01");
  assert.deepEqual(
    await service.revokeTeamMembership(session, teamID, membershipID, "request:member-revoke-01"),
    { revoked: true, rotationRequiredVaults: 2 },
  );
  await service.listSharedVaults(session, teamID);
  const created = await service.createSharedVault(
    session,
    teamID,
    { name: " Production " },
    "request:vault-create-01",
  );
  const renamed = await service.renameSharedVault(
    session,
    teamID,
    created.vault.id,
    { name: " Production Vault " },
    "request:vault-rename-01",
  );

  assert.equal(created.vault.teamID, teamID);
  assert.equal(created.vault.revision, 0);
  assert.equal(created.vault.keyGeneration, 1);
  assert.equal(renamed.vault.name, "Production Vault");
  assert.deepEqual(store.calls.find(([name]) => name === "renameSharedVault")[1], {
    actorUserID: "user-1",
    teamID,
    vaultID: created.vault.id,
    name: "Production Vault",
    idempotencyKey: "request:vault-rename-01",
  });
  for (const [, value] of store.calls) {
    if (value && typeof value === "object" && "actorUserID" in value) assert.equal(value.actorUserID, "user-1");
  }
});

test("member directory query is normalized without changing the legacy response contract", async () => {
  const store = new TeamStore();
  const service = new CloudService(store, config);
  assert.deepEqual(await service.listTeamMembers(session, teamID, {
    search: "  OWN  ", role: "OWNER", limit: "25", cursor: membershipID,
  }), {
    members: [{
      id: membershipID, userID: "user-1", username: "owner", displayName: "Owner",
      role: "owner", epoch: 1, joinedAt: "2026-09-12T00:00:00.000Z",
    }],
    nextCursor: null,
    total: 1,
  });
  assert.deepEqual(store.calls[0], ["listTeamMembers", teamID, "user-1", {
    search: "own", role: "owner", limit: 25, cursor: membershipID,
  }]);
  await assert.rejects(
    service.listTeamMembers(session, teamID, { limit: "101" }),
    /invalid_team_member_query/,
  );
});

test("Team ciphertext service binds session device, generation and wrapper context", async () => {
  const store = new TeamStore();
  const service = new CloudService(store, config);
  const wrapper = {
    membershipID,
    membershipEpoch: 1,
    deviceID,
    wrapperVersion: 1,
    ephemeralPublicKey: { kty: "EC", crv: "P-256", x: "E".repeat(43), y: "F".repeat(43) },
    ciphertext: "G".repeat(43),
    nonce: "H".repeat(16),
    authTag: "I".repeat(22),
    contextHash: "J".repeat(43),
  };
  const envelope = {
    baseRevision: 0,
    keyGeneration: 1,
    envelopeVersion: 1,
    ciphertext: "AA",
    nonce: "B".repeat(16),
    authTag: "C".repeat(22),
    contentHash: "D".repeat(43),
    wrappers: [wrapper],
  };

  const devicePublicKey = { kty: "EC", crv: "P-256", x: "A".repeat(43), y: "B".repeat(43) };
  await service.approveDeviceKey(
    session,
    deviceID,
    { publicKey: devicePublicKey },
    "request:device-approve-01",
  );
  const devices = await service.listTeamKeyDevices(session, teamID, vaultID);
  const vault = await service.getSharedVault(session, teamID, vaultID);
  await service.putSharedVault(session, teamID, vaultID, envelope, "request:team-vault-put-01");
  await service.grantSharedVaultWrapper(
    session,
    teamID,
    vaultID,
    { keyGeneration: 1, wrapper },
    "request:team-wrapper-grant-01",
  );

  assert.equal(devices.devices[0].publicKey.crv, "P-256");
  assert.equal(devices.devices[0].hasWrapper, true);
  assert.deepEqual(
    store.calls.find(([name]) => name === "listTeamKeyDevices").slice(1),
    [teamID, vaultID, session.user_id, deviceID],
  );
  assert.equal(vault.wrapper.membershipEpoch, 1);
  for (const call of store.calls.filter(([name]) => [
    "approveDeviceKey", "putSharedVault", "grantSharedVaultWrapper",
  ].includes(name))) {
    assert.equal(call[1].actorUserID, "user-1");
    assert.equal(call[1].actorDeviceID, deviceID);
  }
  assert.deepEqual(JSON.parse(store.calls.find(([name]) => name === "approveDeviceKey")[1].expectedPublicKey), {
    ...devicePublicKey,
    ext: true,
    key_ops: [],
  });
});

test("first Team device bootstrap requires password verification and stays bound to the session device", async () => {
  const store = new TeamStore();
  const service = new CloudService(store, config, null, console, async (password, hash) => (
    password === "synthetic-password" && hash === "synthetic-hash"
  ));
  const publicKey = { kty: "EC", crv: "P-256", x: "A".repeat(43), y: "B".repeat(43) };
  assert.deepEqual(await service.bootstrapDeviceKey(
    session,
    { password: "synthetic-password", publicKey },
    "request:device-bootstrap-01",
  ), { approved: true, deviceID, bootstrapped: true });
  assert.deepEqual(store.calls[0], ["passwordIdentity", session.email]);
  assert.deepEqual(store.calls[1][1], {
    actorUserID: session.user_id,
    actorDeviceID: session.device_id,
    expectedPublicKey: JSON.stringify({ ...publicKey, ext: true, key_ops: [] }),
    idempotencyKey: "request:device-bootstrap-01",
  });

  await assert.rejects(
    service.bootstrapDeviceKey(session, { password: "wrong-password-value", publicKey }, "request:device-bootstrap-02"),
    /invalid_credentials/,
  );
  assert.equal(store.calls.filter(([name]) => name === "bootstrapDeviceKey").length, 1);
});
