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
};
const config = {
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

  async createTeamInvitation(input) {
    this.calls.push(["createTeamInvitation", input]);
    this.job = {
      id: "25b79add-2d18-4fa7-9ef7-9373f850001a",
      attempts: 1,
      payload_ciphertext: input.outboxEnvelope.ciphertext,
      nonce: input.outboxEnvelope.nonce,
      auth_tag: input.outboxEnvelope.authTag,
    };
    return { invitation: {
      id: "471c3424-b6aa-41a0-959f-aeaa1e3ef79d",
      team_id: input.teamID,
      email: input.email,
      role: input.role,
      created_at: "now",
      expires_at: input.expiresAt,
    } };
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
    return { membership: { id: membershipID, user_id: input.actorUserID, role: "editor", epoch: 2 } };
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

  async listTeamMembers(team, actor) {
    this.calls.push(["listTeamMembers", team, actor]);
    return [{ id: membershipID, user_id: "user-1", role: "owner", epoch: 1 }];
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

  async approveDeviceKey(input) {
    this.calls.push(["approveDeviceKey", input]);
    return { approved: true, deviceID: input.deviceID };
  }

  async listTeamKeyDevices(team, vault, actor) {
    this.calls.push(["listTeamKeyDevices", team, vault, actor]);
    return [{
      membership_id: membershipID,
      membership_epoch: 1,
      device_id: deviceID,
      public_key_algorithm: "p256-ecdh-v1",
      public_key: JSON.stringify({ kty: "EC", crv: "P-256", x: "A".repeat(43), y: "B".repeat(43) }),
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

test("invitation API persists only a hash and encrypted durable outbox payload", async () => {
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
  const stored = store.calls[0][1];

  assert.match(stored.tokenHash, /^[0-9a-f]{64}$/);
  assert.equal(JSON.stringify(stored).includes("token\":"), false);
  assert.doesNotMatch(JSON.stringify(stored.outboxEnvelope), /member@example\.com|editor/);
  assert.equal("token" in response.invitation, false);
  assert.equal(response.invitation.email, "member@example.com");
  assert.equal(await service.dispatchTeamInvitationOutbox(), true);
  assert.equal(delivered.recipient, "member@example.com");
  assert.ok(delivered.token.length >= 40);
  assert.equal(store.calls.at(-1)[0], "completeTeamInvitationOutbox");
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

test("invitation acceptance binds the verified session email and never accepts a body user ID", async () => {
  const store = new TeamStore();
  const service = new CloudService(store, config);
  await service.acceptTeamInvitation(
    session,
    { token: "opaque-invitation", userID: "attacker", email: "attacker@example.com" },
    "request:team-accept-01",
  );
  const stored = store.calls[0][1];

  assert.equal(stored.actorUserID, "user-1");
  assert.equal(stored.actorEmail, "owner@example.com");
  assert.match(stored.tokenHash, /^[0-9a-f]{64}$/);
  assert.equal("token" in stored, false);
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

  assert.equal(created.vault.teamID, teamID);
  assert.equal(created.vault.revision, 0);
  assert.equal(created.vault.keyGeneration, 1);
  for (const [, value] of store.calls) {
    if (value && typeof value === "object" && "actorUserID" in value) assert.equal(value.actorUserID, "user-1");
  }
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
