import assert from "node:assert/strict";
import test from "node:test";
import { PostgresStore } from "../src/postgres-store.mjs";
import { teamVaultWrapperContextHash } from "../src/security.mjs";

function fixture(respond) {
  const queries = [];
  const client = {
    async query(sql, parameters = []) {
      queries.push({ sql, parameters });
      return respond(sql, parameters);
    },
    release() { queries.push({ sql: "RELEASE", parameters: [] }); },
  };
  const pool = {
    async connect() { return client; },
    async query(sql, parameters = []) {
      queries.push({ sql, parameters });
      return respond(sql, parameters);
    },
  };
  return { store: new PostgresStore("unused", pool), queries };
}

const actorUserID = "1f386e3d-d7b7-4365-a116-19f68e7f512d";
const teamID = "84f6c860-0d26-4ef5-8652-27cb8b991b70";
const membershipID = "7026d8a4-116a-4f61-9d8e-ff04e3a73360";
const deviceID = "33cc880e-084a-4d9a-b1ea-f99d2ff86032";
const vaultID = "bc01823b-1401-4058-9488-f4f6d1839b3b";

function teamEnvelope({ baseRevision = 0, keyGeneration = 1, wrappers = [] } = {}) {
  return {
    baseRevision,
    keyGeneration,
    envelopeVersion: 1,
    ciphertext: "AA",
    nonce: "B".repeat(16),
    authTag: "C".repeat(22),
    contentHash: "D".repeat(43),
    wrappers,
  };
}

function teamWrapper(overrides = {}) {
  const { keyGeneration = 1, ...wrapperOverrides } = overrides;
  const wrapper = {
    membershipID,
    membershipEpoch: 1,
    deviceID,
    wrapperVersion: 1,
    ephemeralPublicKey: { kty: "EC", crv: "P-256", x: "E".repeat(43), y: "F".repeat(43) },
    ciphertext: "G".repeat(43),
    nonce: "H".repeat(16),
    authTag: "I".repeat(22),
    ...wrapperOverrides,
  };
  return {
    ...wrapper,
    contextHash: teamVaultWrapperContextHash({
      teamID,
      vaultID,
      keyGeneration,
      membershipID: wrapper.membershipID,
      membershipEpoch: wrapper.membershipEpoch,
      deviceID: wrapper.deviceID,
    }),
  };
}

function mutationReservation(sql) {
  return sql.includes("INSERT INTO team_mutation_receipts") ? { rows: [{ actor_user_id: actorUserID }] } : null;
}

test("Team creation atomically creates its first Owner and audit receipt", async () => {
  const team = { id: teamID, name: "Operations", created_at: new Date(), updated_at: new Date() };
  const membership = { id: membershipID, role: "owner", epoch: 1, joined_at: new Date() };
  const f = fixture((sql) => {
    const reservation = mutationReservation(sql);
    if (reservation) return reservation;
    if (sql.includes("INSERT INTO teams")) return { rows: [team] };
    if (sql.includes("INSERT INTO team_memberships")) return { rows: [membership] };
    return { rows: [], rowCount: 0 };
  });

  assert.deepEqual(await f.store.createTeam({
    actorUserID,
    name: "Operations",
    idempotencyKey: "request:team-create-01",
  }), { team, membership });

  assert.equal(f.queries[0].sql, "BEGIN");
  assert.ok(f.queries.some(({ sql }) => sql.includes("'owner'")));
  assert.ok(f.queries.some(({ sql }) => sql.includes("INSERT INTO team_audit_events")));
  assert.ok(f.queries.some(({ sql }) => sql.includes("UPDATE team_mutation_receipts")));
  assert.equal(f.queries.at(-2).sql, "COMMIT");
  assert.equal(f.queries.at(-1).sql, "RELEASE");
});

test("a repeated idempotency key replays the committed response without another mutation", async () => {
  const response = { team: { id: teamID, name: "Operations" }, membership: { id: membershipID, role: "owner", epoch: 1 } };
  const f = fixture((sql) => {
    if (sql.includes("INSERT INTO team_mutation_receipts")) return { rows: [] };
    if (sql.includes("SELECT response FROM team_mutation_receipts")) return { rows: [{ response }] };
    return { rows: [], rowCount: 0 };
  });

  assert.deepEqual(await f.store.createTeam({
    actorUserID,
    name: "Ignored on replay",
    idempotencyKey: "request:team-create-01",
  }), response);
  assert.equal(f.queries.some(({ sql }) => sql.includes("INSERT INTO teams")), false);
  assert.equal(f.queries.at(-2).sql, "COMMIT");
});

test("invitation creation locks authorization and stores hash plus encrypted outbox only", async () => {
  const invitation = {
    id: "471c3424-b6aa-41a0-959f-aeaa1e3ef79d",
    team_id: teamID,
    email: "member@example.com",
    role: "editor",
  };
  const f = fixture((sql) => {
    const reservation = mutationReservation(sql);
    if (reservation) return reservation;
    if (sql.includes("FROM team_memberships AS membership") && sql.includes("JOIN teams AS team")) {
      return { rows: [{ id: membershipID, user_id: actorUserID, role: "admin", epoch: 1 }] };
    }
    if (sql.includes("JOIN users AS account")) return { rows: [] };
    if (sql.includes("INSERT INTO team_invitations")) return { rows: [invitation] };
    return { rows: [], rowCount: 0 };
  });
  const tokenHash = "a".repeat(64);
  const outboxEnvelope = { ciphertext: "ciphertext", nonce: "n".repeat(16), authTag: "a".repeat(22) };

  await f.store.createTeamInvitation({
    actorUserID,
    teamID,
    email: "member@example.com",
    role: "editor",
    tokenHash,
    expiresAt: new Date("2030-01-03T00:00:00.000Z"),
    outboxEnvelope,
    idempotencyKey: "request:team-invite-01",
  });

  const actorLock = f.queries.find(({ sql }) => sql.includes("FOR UPDATE OF membership, team"));
  assert.deepEqual(actorLock.parameters, [teamID, actorUserID]);
  const invitationInsert = f.queries.find(({ sql }) => sql.includes("INSERT INTO team_invitations"));
  assert.equal(invitationInsert.parameters[3], tokenHash);
  const outboxInsert = f.queries.find(({ sql }) => sql.includes("INSERT INTO team_outbox_jobs"));
  assert.deepEqual(outboxInsert.parameters.slice(2), ["ciphertext", "n".repeat(16), "a".repeat(22)]);
  assert.equal(f.queries.some(({ sql }) => sql.includes(tokenHash)), false);
  assert.equal(f.queries.at(-2).sql, "COMMIT");
});

test("an Admin cannot invite another Admin even inside the transaction", async () => {
  const f = fixture((sql) => {
    const reservation = mutationReservation(sql);
    if (reservation) return reservation;
    if (sql.includes("FOR UPDATE OF membership, team")) {
      return { rows: [{ id: membershipID, user_id: actorUserID, role: "admin", epoch: 1 }] };
    }
    return { rows: [], rowCount: 0 };
  });

  await assert.rejects(f.store.createTeamInvitation({
    actorUserID,
    teamID,
    email: "admin@example.com",
    role: "admin",
    tokenHash: "b".repeat(64),
    expiresAt: new Date("2030-01-03T00:00:00.000Z"),
    outboxEnvelope: { ciphertext: "ciphertext", nonce: "n".repeat(16), authTag: "a".repeat(22) },
    idempotencyKey: "request:team-invite-02",
  }), /team_access_denied/);

  assert.equal(f.queries.some(({ sql }) => sql.includes("INSERT INTO team_invitations")), false);
  assert.equal(f.queries.at(-2).sql, "ROLLBACK");
});

test("cancelling an invitation also retires its pending durable delivery", async () => {
  const invitationID = "471c3424-b6aa-41a0-959f-aeaa1e3ef79d";
  const f = fixture((sql) => {
    const reservation = mutationReservation(sql);
    if (reservation) return reservation;
    if (sql.includes("FOR UPDATE OF membership, team")) {
      return { rows: [{ id: membershipID, user_id: actorUserID, role: "owner", epoch: 1 }] };
    }
    if (sql.includes("SELECT id, role FROM team_invitations")) {
      return { rows: [{ id: invitationID, role: "admin" }] };
    }
    return { rows: [], rowCount: 1 };
  });

  assert.deepEqual(await f.store.cancelTeamInvitation({
    actorUserID,
    teamID,
    invitationID,
    idempotencyKey: "request:team-cancel-01",
  }), { cancelled: true });
  assert.ok(f.queries.some(({ sql }) => sql.includes("UPDATE team_invitations SET cancelled_at")));
  assert.ok(f.queries.some(({ sql }) => sql.includes("UPDATE team_outbox_jobs SET delivered_at")));
  assert.equal(f.queries.at(-2).sql, "COMMIT");
});

test("invitation acceptance locks one token and advances a revoked membership epoch", async () => {
  const acceptedMembership = {
    id: membershipID,
    team_id: teamID,
    user_id: actorUserID,
    role: "viewer",
    epoch: 3,
  };
  const f = fixture((sql) => {
    const reservation = mutationReservation(sql);
    if (reservation) return reservation;
    if (sql.includes("FROM team_invitations AS invitation")) {
      return { rows: [{ id: "invite-1", team_id: teamID, email: "member@example.com", role: "viewer" }] };
    }
    if (sql.includes("ORDER BY epoch DESC")) return { rows: [{ id: "old", epoch: 2, revoked_at: new Date() }] };
    if (sql.includes("INSERT INTO team_memberships")) return { rows: [acceptedMembership] };
    if (sql.includes("UPDATE team_invitations SET accepted_at")) return { rows: [{ id: "invite-1" }] };
    return { rows: [], rowCount: 0 };
  });

  const result = await f.store.acceptTeamInvitation({
    actorUserID,
    actorEmail: "member@example.com",
    tokenHash: "c".repeat(64),
    idempotencyKey: "request:team-accept-01",
  });

  assert.deepEqual(result, { membership: acceptedMembership });
  const membershipInsert = f.queries.find(({ sql }) => sql.includes("INSERT INTO team_memberships"));
  assert.equal(membershipInsert.parameters[3], 3);
  assert.ok(f.queries.some(({ sql }) => sql.includes("FOR UPDATE OF invitation, team")));
  assert.equal(f.queries.at(-2).sql, "COMMIT");
});

test("membership revocation immediately freezes every active shared Vault", async () => {
  const targetUserID = "6a812c55-aa74-4be4-bf1a-4cfcd362b459";
  const f = fixture((sql) => {
    const reservation = mutationReservation(sql);
    if (reservation) return reservation;
    if (sql.includes("FOR UPDATE OF membership, team")) {
      return { rows: [{ id: membershipID, user_id: actorUserID, role: "owner", epoch: 1 }] };
    }
    if (sql.includes("WHERE team_id = $1 AND id = $2") && sql.includes("FOR UPDATE")) {
      return { rows: [{ id: "target-membership", user_id: targetUserID, role: "editor", epoch: 4 }] };
    }
    if (sql.includes("UPDATE team_memberships SET revoked_at")) {
      return { rows: [{ id: "target-membership", user_id: targetUserID, role: "editor", epoch: 4 }], rowCount: 1 };
    }
    if (sql.includes("UPDATE shared_vaults SET rotation_required")) {
      return { rows: [{ id: "vault-1" }, { id: "vault-2" }], rowCount: 2 };
    }
    return { rows: [], rowCount: 0 };
  });

  assert.deepEqual(await f.store.revokeTeamMembership({
    actorUserID,
    teamID,
    membershipID: "target-membership",
    idempotencyKey: "request:member-revoke-01",
  }), { revoked: true, rotationRequiredVaults: 2 });
  assert.ok(f.queries.some(({ sql }) => sql.includes("rotation_required = true")));
  assert.ok(f.queries.some(({ sql }) => sql.includes("INSERT INTO shared_vault_rotation_tasks")));
  assert.equal(f.queries.at(-2).sql, "COMMIT");
});

test("outbox claim uses multi-replica-safe SKIP LOCKED leasing", async () => {
  const job = { id: "job-1", attempts: 1 };
  const f = fixture((sql) => sql.includes("SKIP LOCKED") ? { rows: [job] } : { rows: [] });

  assert.equal(await f.store.claimTeamInvitationOutbox("claim-owner"), job);
  assert.match(f.queries[0].sql, /FOR UPDATE SKIP LOCKED/);
  assert.match(f.queries[0].sql, /claimed_at < now\(\) - interval '5 minutes'/);
  assert.deepEqual(f.queries[0].parameters, ["claim-owner"]);
});

test("initial shared ciphertext and the complete device wrapper set commit atomically", async () => {
  const f = fixture((sql) => {
    const reservation = mutationReservation(sql);
    if (reservation) return reservation;
    if (sql.includes("FOR UPDATE OF membership, team, vault, device")) {
      return { rows: [{
        membership_id: membershipID, role: "owner", epoch: 1, key_approved_at: new Date(),
        revision: 0, key_generation: 1, rotation_required: false,
      }] };
    }
    if (sql.includes("ORDER BY membership.id, device.id") && sql.includes("FOR UPDATE")) {
      return { rows: [{ membership_id: membershipID, membership_epoch: 1, device_id: deviceID }] };
    }
    return { rows: [], rowCount: 1 };
  });

  assert.deepEqual(await f.store.putSharedVault({
    actorUserID,
    actorDeviceID: deviceID,
    teamID,
    vaultID,
    envelope: teamEnvelope({ wrappers: [teamWrapper()] }),
    idempotencyKey: "request:team-vault-init-01",
  }), { conflict: false, revision: 1, keyGeneration: 1, rotationCompleted: false });
  assert.ok(f.queries.some(({ sql }) => sql.includes("INSERT INTO shared_vault_key_wrappers")));
  assert.ok(f.queries.some(({ sql }) => sql.includes("INSERT INTO shared_vault_revisions")));
  assert.equal(f.queries.at(-2).sql, "COMMIT");
});

test("initial shared Vault write rejects a partial wrapper set before ciphertext is stored", async () => {
  const secondDeviceID = "aef6452c-1ad8-48bb-b4b5-ea9c207b707b";
  const f = fixture((sql) => {
    const reservation = mutationReservation(sql);
    if (reservation) return reservation;
    if (sql.includes("FOR UPDATE OF membership, team, vault, device")) {
      return { rows: [{
        membership_id: membershipID, role: "owner", epoch: 1, key_approved_at: new Date(),
        revision: 0, key_generation: 1, rotation_required: false,
      }] };
    }
    if (sql.includes("ORDER BY membership.id, device.id") && sql.includes("FOR UPDATE")) {
      return { rows: [
        { membership_id: membershipID, membership_epoch: 1, device_id: deviceID },
        { membership_id: membershipID, membership_epoch: 1, device_id: secondDeviceID },
      ] };
    }
    return { rows: [], rowCount: 0 };
  });

  await assert.rejects(f.store.putSharedVault({
    actorUserID,
    actorDeviceID: deviceID,
    teamID,
    vaultID,
    envelope: teamEnvelope({ wrappers: [teamWrapper()] }),
    idempotencyKey: "request:team-vault-init-02",
  }), /incomplete_team_vault_wrappers/);
  assert.equal(f.queries.some(({ sql }) => sql.includes("INSERT INTO shared_vault_revisions")), false);
  assert.equal(f.queries.at(-2).sql, "ROLLBACK");
});

test("a wrapper replayed under another authorization context is rejected", async () => {
  const f = fixture((sql) => {
    const reservation = mutationReservation(sql);
    if (reservation) return reservation;
    if (sql.includes("FOR UPDATE OF membership, team, vault, device")) {
      return { rows: [{
        membership_id: membershipID, role: "owner", epoch: 1, key_approved_at: new Date(),
        revision: 0, key_generation: 1, rotation_required: false,
      }] };
    }
    if (sql.includes("ORDER BY membership.id, device.id") && sql.includes("FOR UPDATE")) {
      return { rows: [{ membership_id: membershipID, membership_epoch: 1, device_id: deviceID }] };
    }
    return { rows: [], rowCount: 0 };
  });
  await assert.rejects(f.store.putSharedVault({
    actorUserID,
    actorDeviceID: deviceID,
    teamID,
    vaultID,
    envelope: teamEnvelope({
      wrappers: [{ ...teamWrapper(), contextHash: "J".repeat(43) }],
    }),
    idempotencyKey: "request:team-vault-context-01",
  }), /invalid_team_vault_wrapper_context/);
  assert.equal(f.queries.some(({ sql }) => sql.includes("INSERT INTO shared_vault_key_wrappers")), false);
});

test("rotation advances the generation and completes pending work in one transaction", async () => {
  const f = fixture((sql) => {
    const reservation = mutationReservation(sql);
    if (reservation) return reservation;
    if (sql.includes("FOR UPDATE OF membership, team, vault, device")) {
      return { rows: [{
        membership_id: membershipID, role: "admin", epoch: 1, key_approved_at: new Date(),
        revision: 4, key_generation: 2, rotation_required: true,
      }] };
    }
    if (sql.includes("ORDER BY membership.id, device.id") && sql.includes("FOR UPDATE")) {
      return { rows: [{ membership_id: membershipID, membership_epoch: 1, device_id: deviceID }] };
    }
    return { rows: [], rowCount: 1 };
  });

  assert.deepEqual(await f.store.putSharedVault({
    actorUserID,
    actorDeviceID: deviceID,
    teamID,
    vaultID,
    envelope: teamEnvelope({
      baseRevision: 4,
      keyGeneration: 3,
      wrappers: [teamWrapper({ keyGeneration: 3 })],
    }),
    idempotencyKey: "request:team-vault-rotate-01",
  }), { conflict: false, revision: 5, keyGeneration: 3, rotationCompleted: true });
  assert.ok(f.queries.some(({ sql }) => sql.includes("shared_vault_rotation_tasks SET status = 'completed'")));
  assert.ok(f.queries.some(({ parameters }) => parameters.includes("team.vault_rotated")));
});

test("Viewer writes and unapproved-device reads fail before ciphertext access", async () => {
  const write = fixture((sql) => {
    const reservation = mutationReservation(sql);
    if (reservation) return reservation;
    if (sql.includes("FOR UPDATE OF membership, team, vault, device")) {
      return { rows: [{
        membership_id: membershipID, role: "viewer", epoch: 1, key_approved_at: new Date(),
        revision: 1, key_generation: 1, rotation_required: false,
      }] };
    }
    return { rows: [], rowCount: 0 };
  });
  await assert.rejects(write.store.putSharedVault({
    actorUserID,
    actorDeviceID: deviceID,
    teamID,
    vaultID,
    envelope: teamEnvelope({ baseRevision: 1, wrappers: null }),
    idempotencyKey: "request:team-vault-viewer-01",
  }), /team_access_denied/);

  const read = fixture((sql) => sql.includes("LEFT JOIN shared_vault_key_wrappers")
    ? { rows: [{ id: vaultID, key_approved_at: null }] }
    : { rows: [] });
  await assert.rejects(
    read.store.getSharedVault(teamID, vaultID, actorUserID, deviceID),
    /device_approval_required/,
  );
});

test("login cannot revive a revoked device or replace an approved device key", async () => {
  const f = fixture((sql) => sql.includes("INSERT INTO devices") ? { rows: [] } : { rows: [], rowCount: 0 });
  await assert.rejects(f.store.createSession({
    userID: actorUserID,
    device: {
      id: deviceID,
      name: "Browser",
      platform: "web",
      appVersion: "0.32.0",
      publicKey: JSON.stringify({ kty: "EC", crv: "P-256", x: "A".repeat(43), y: "B".repeat(43) }),
    },
    sessionHash: "session-hash",
    expiresAt: new Date("2030-01-01T00:00:00.000Z"),
  }), /invalid_device/);
  const upsert = f.queries.find(({ sql }) => sql.includes("INSERT INTO devices"));
  assert.doesNotMatch(upsert.sql, /revoked_at\s*=\s*NULL/);
  assert.match(upsert.sql, /devices\.public_key = EXCLUDED\.public_key/);
  assert.equal(f.queries.some(({ sql }) => sql.includes("INSERT INTO sessions")), false);
  assert.equal(f.queries.at(-2).sql, "ROLLBACK");
});

test("only an already-approved account device can approve another public key", async () => {
  const targetDeviceID = "aef6452c-1ad8-48bb-b4b5-ea9c207b707b";
  const publicKey = JSON.stringify({
    kty: "EC", crv: "P-256", x: "A".repeat(43), y: "B".repeat(43), ext: true, key_ops: [],
  });
  const f = fixture((sql) => {
    const reservation = mutationReservation(sql);
    if (reservation) return reservation;
    if (sql.includes("SELECT id FROM devices")) return { rows: [{ id: deviceID }] };
    if (sql.includes("SELECT id, public_key FROM devices")) {
      return { rows: [{ id: targetDeviceID, public_key: publicKey }] };
    }
    if (sql.includes("UPDATE devices SET key_approved_at")) {
      return { rows: [{ id: targetDeviceID, key_approved_at: new Date() }] };
    }
    return { rows: [], rowCount: 1 };
  });
  assert.deepEqual(await f.store.approveDeviceKey({
    actorUserID,
    actorDeviceID: deviceID,
    deviceID: targetDeviceID,
    expectedPublicKey: publicKey,
    idempotencyKey: "request:device-approve-01",
  }), { approved: true, deviceID: targetDeviceID });
  const actorLock = f.queries.find(({ sql }) => sql.includes("SELECT id FROM devices"));
  assert.match(actorLock.sql, /key_approved_at IS NOT NULL/);
  assert.match(actorLock.sql, /public_key_algorithm = 'p256-ecdh-v1'/);
  assert.ok(f.queries.some(({ sql }) => sql.includes("SELECT id, public_key FROM devices") && sql.includes("FOR UPDATE")));
  assert.equal(f.queries.at(-2).sql, "COMMIT");
});

test("legacy accounts can atomically bootstrap only their first approved Team device", async () => {
  const publicKey = JSON.stringify({
    kty: "EC", crv: "P-256", x: "A".repeat(43), y: "B".repeat(43), ext: true, key_ops: [],
  });
  const f = fixture((sql) => {
    const reservation = mutationReservation(sql);
    if (reservation) return reservation;
    if (sql.includes("SELECT id FROM users")) return { rows: [{ id: actorUserID }] };
    if (sql.includes("SELECT id, public_key, public_key_algorithm, key_approved_at")) {
      return { rows: [{
        id: deviceID,
        public_key: publicKey,
        public_key_algorithm: "p256-ecdh-v1",
        key_approved_at: null,
      }] };
    }
    if (sql.includes("SELECT id FROM devices") && sql.includes("key_approved_at IS NOT NULL")) {
      return { rows: [] };
    }
    return { rows: [], rowCount: 1 };
  });

  assert.deepEqual(await f.store.bootstrapDeviceKey({
    actorUserID,
    actorDeviceID: deviceID,
    expectedPublicKey: publicKey,
    idempotencyKey: "request:device-bootstrap-01",
  }), { approved: true, deviceID, bootstrapped: true });
  const userLock = f.queries.find(({ sql }) => sql.includes("SELECT id FROM users"));
  const deviceLock = f.queries.find(({ sql }) => sql.includes("SELECT id, public_key, public_key_algorithm"));
  assert.match(userLock.sql, /FOR UPDATE/);
  assert.ok(f.queries.indexOf(userLock) < f.queries.indexOf(deviceLock));
  assert.ok(f.queries.some(({ sql }) => sql.includes("UPDATE devices SET key_approved_at = now()")));
  assert.equal(f.queries.at(-2).sql, "COMMIT");
});

test("first-device bootstrap refuses to bypass an existing approved device", async () => {
  const publicKey = JSON.stringify({
    kty: "EC", crv: "P-256", x: "A".repeat(43), y: "B".repeat(43), ext: true, key_ops: [],
  });
  const f = fixture((sql) => {
    const reservation = mutationReservation(sql);
    if (reservation) return reservation;
    if (sql.includes("SELECT id FROM users")) return { rows: [{ id: actorUserID }] };
    if (sql.includes("SELECT id, public_key, public_key_algorithm, key_approved_at")) {
      return { rows: [{
        id: deviceID,
        public_key: publicKey,
        public_key_algorithm: "p256-ecdh-v1",
        key_approved_at: null,
      }] };
    }
    if (sql.includes("SELECT id FROM devices") && sql.includes("key_approved_at IS NOT NULL")) {
      return { rows: [{ id: "approved-device" }] };
    }
    return { rows: [], rowCount: 0 };
  });
  await assert.rejects(f.store.bootstrapDeviceKey({
    actorUserID,
    actorDeviceID: deviceID,
    expectedPublicKey: publicKey,
    idempotencyKey: "request:device-bootstrap-02",
  }), /device_approval_required/);
  assert.equal(f.queries.some(({ sql }) => sql.includes("UPDATE devices SET key_approved_at = now()")), false);
  assert.equal(f.queries.at(-2).sql, "ROLLBACK");
});
