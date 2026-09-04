import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { applyMigrations } from "../src/migrations.mjs";
import { PostgresStore } from "../src/postgres-store.mjs";

const databaseURL = process.env.TEST_DATABASE_URL;
const migrationsDirectory = fileURLToPath(new URL("../migrations/", import.meta.url));

test("real PostgreSQL serializes Team authorization, invitations and revocation", {
  skip: databaseURL ? false : "TEST_DATABASE_URL is not configured",
}, async () => {
  const pool = new pg.Pool({ connectionString: databaseURL, max: 4 });
  try {
    await applyMigrations(pool, migrationsDirectory, { info() {} });
    const users = await pool.query(
      `INSERT INTO users (email, display_name, email_verified_at) VALUES
         ('owner@example.com', 'Owner', now()),
         ('admin@example.com', 'Admin', now()),
         ('viewer@example.com', 'Viewer', now()),
         ('other@example.com', 'Other', now())
       RETURNING id, email`,
    );
    const byEmail = Object.fromEntries(users.rows.map((row) => [row.email, row.id]));
    const store = new PostgresStore(databaseURL, pool);

    const created = await store.createTeam({
      actorUserID: byEmail["owner@example.com"],
      name: "Operations",
      idempotencyKey: "integration:team-create-01",
    });
    const replayed = await store.createTeam({
      actorUserID: byEmail["owner@example.com"],
      name: "Different ignored replay body",
      idempotencyKey: "integration:team-create-01",
    });
    assert.equal(replayed.team.id, created.team.id);
    assert.equal((await store.listTeams(byEmail["owner@example.com"])).length, 1);

    const shared = await store.createSharedVault({
      actorUserID: byEmail["owner@example.com"],
      teamID: created.team.id,
      name: "Production",
      idempotencyKey: "integration:vault-create-01",
    });
    assert.equal(Number(shared.vault.revision), 0);
    assert.equal(Number(shared.vault.key_generation), 1);

    const adminTokenHash = "a".repeat(64);
    const adminInvite = await store.createTeamInvitation({
      actorUserID: byEmail["owner@example.com"],
      teamID: created.team.id,
      email: "admin@example.com",
      role: "admin",
      tokenHash: adminTokenHash,
      expiresAt: new Date(Date.now() + 48 * 3_600_000),
      outboxEnvelope: { ciphertext: "AA", nonce: "B".repeat(16), authTag: "C".repeat(22) },
      idempotencyKey: "integration:invite-admin-01",
    });
    const accepted = await store.acceptTeamInvitation({
      actorUserID: byEmail["admin@example.com"],
      actorEmail: "admin@example.com",
      tokenHash: adminTokenHash,
      idempotencyKey: "integration:accept-admin-01",
    });
    assert.equal(accepted.membership.role, "admin");
    assert.equal(Number(accepted.membership.epoch), 1);
    await assert.rejects(store.acceptTeamInvitation({
      actorUserID: byEmail["admin@example.com"],
      actorEmail: "admin@example.com",
      tokenHash: adminTokenHash,
      idempotencyKey: "integration:accept-admin-02",
    }), /invalid_team_invitation/);

    await assert.rejects(store.createTeamInvitation({
      actorUserID: byEmail["admin@example.com"],
      teamID: created.team.id,
      email: "other@example.com",
      role: "admin",
      tokenHash: "b".repeat(64),
      expiresAt: new Date(Date.now() + 48 * 3_600_000),
      outboxEnvelope: { ciphertext: "AA", nonce: "B".repeat(16), authTag: "C".repeat(22) },
      idempotencyKey: "integration:admin-escalation-01",
    }), /team_access_denied/);

    const viewerTokenHash = "c".repeat(64);
    await store.createTeamInvitation({
      actorUserID: byEmail["admin@example.com"],
      teamID: created.team.id,
      email: "viewer@example.com",
      role: "viewer",
      tokenHash: viewerTokenHash,
      expiresAt: new Date(Date.now() + 48 * 3_600_000),
      outboxEnvelope: { ciphertext: "AA", nonce: "B".repeat(16), authTag: "C".repeat(22) },
      idempotencyKey: "integration:invite-viewer-01",
    });
    await assert.rejects(store.acceptTeamInvitation({
      actorUserID: byEmail["other@example.com"],
      actorEmail: "other@example.com",
      tokenHash: viewerTokenHash,
      idempotencyKey: "integration:accept-wrong-email-01",
    }), /invalid_team_invitation/);
    const viewer = await store.acceptTeamInvitation({
      actorUserID: byEmail["viewer@example.com"],
      actorEmail: "viewer@example.com",
      tokenHash: viewerTokenHash,
      idempotencyKey: "integration:accept-viewer-01",
    });
    await assert.rejects(store.createSharedVault({
      actorUserID: byEmail["viewer@example.com"],
      teamID: created.team.id,
      name: "Forbidden",
      idempotencyKey: "integration:viewer-vault-01",
    }), /team_access_denied/);

    const cancelled = await store.createTeamInvitation({
      actorUserID: byEmail["owner@example.com"],
      teamID: created.team.id,
      email: "other@example.com",
      role: "editor",
      tokenHash: "d".repeat(64),
      expiresAt: new Date(Date.now() + 48 * 3_600_000),
      outboxEnvelope: { ciphertext: "AA", nonce: "B".repeat(16), authTag: "C".repeat(22) },
      idempotencyKey: "integration:invite-cancel-01",
    });
    await store.cancelTeamInvitation({
      actorUserID: byEmail["owner@example.com"],
      teamID: created.team.id,
      invitationID: cancelled.invitation.id,
      idempotencyKey: "integration:cancel-invite-01",
    });
    const retired = await pool.query(
      "SELECT delivered_at FROM team_outbox_jobs WHERE aggregate_id = $1",
      [cancelled.invitation.id],
    );
    assert.ok(retired.rows[0].delivered_at);

    const revoked = await store.revokeTeamMembership({
      actorUserID: byEmail["owner@example.com"],
      teamID: created.team.id,
      membershipID: accepted.membership.id,
      idempotencyKey: "integration:revoke-admin-01",
    });
    assert.equal(revoked.rotationRequiredVaults, 1);
    await assert.rejects(
      store.listSharedVaults(created.team.id, byEmail["admin@example.com"]),
      /team_not_found/,
    );
    const rotation = await pool.query(
      `SELECT vault.rotation_required, task.status, task.removed_membership_id
       FROM shared_vaults AS vault
       JOIN shared_vault_rotation_tasks AS task ON task.vault_id = vault.id
       WHERE vault.id = $1`,
      [shared.vault.id],
    );
    assert.deepEqual(rotation.rows, [{
      rotation_required: true,
      status: "pending",
      removed_membership_id: accepted.membership.id,
    }]);
    assert.equal(viewer.membership.role, "viewer");
    assert.equal(adminInvite.invitation.email, "admin@example.com");
  } finally {
    await pool.end();
  }
});
