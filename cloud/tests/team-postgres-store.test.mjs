import assert from "node:assert/strict";
import test from "node:test";
import { PostgresStore } from "../src/postgres-store.mjs";

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
