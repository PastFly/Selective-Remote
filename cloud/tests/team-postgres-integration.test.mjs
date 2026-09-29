import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { webcrypto } from "node:crypto";
import { applyMigrations } from "../src/migrations.mjs";
import { PostgresStore } from "../src/postgres-store.mjs";
import { teamVaultWrapperContextHash } from "../src/security.mjs";
import { generateTeamDeviceIdentity } from "../public/team-vault-crypto.js";
import { generateResourceCEK, encryptResourcePart, wrapResourceCEK } from "../public/resource-crypto-v2.js";

const databaseURL = process.env.TEST_DATABASE_URL;
const migrationsDirectory = fileURLToPath(new URL("../migrations/", import.meta.url));
const ownerDeviceID = "33cc880e-084a-4d9a-b1ea-f99d2ff86032";
const ownerSecondDeviceID = "625a4479-dbc4-4f2b-88b8-f42179275d46";
const adminDeviceID = "e5cb5666-8db7-4fd8-88f7-0a3b0a8df156";
const viewerDeviceID = "aef6452c-1ad8-48bb-b4b5-ea9c207b707b";
const viewerSecondDeviceID = "5a5bcf31-01d0-40d5-95ae-7d041553b5d9";
const legacyDeviceID = "c9afe150-1081-49dc-ad2e-ea67c59a4a25";
const legacySecondDeviceID = "dab87dc1-99fd-43f4-aa31-cba26c207cff";

function integrationWrapper(membership, deviceID, marker, teamID, vaultID, keyGeneration) {
  return {
    membershipID: membership.id,
    membershipEpoch: Number(membership.epoch),
    deviceID,
    wrapperVersion: 1,
    ephemeralPublicKey: { kty: "EC", crv: "P-256", x: marker.repeat(43), y: "Z".repeat(43) },
    ciphertext: marker.repeat(43),
    nonce: marker.repeat(16),
    authTag: marker.repeat(22),
    contextHash: teamVaultWrapperContextHash({
      teamID,
      vaultID,
      keyGeneration,
      membershipID: membership.id,
      membershipEpoch: Number(membership.epoch),
      deviceID,
    }),
  };
}

test("real PostgreSQL serializes Team authorization, invitations and revocation", {
  skip: databaseURL ? false : "TEST_DATABASE_URL is not configured",
}, async () => {
  const pool = new pg.Pool({ connectionString: databaseURL, max: 4 });
  try {
    await applyMigrations(pool, migrationsDirectory, { info() {} });
    const users = await pool.query(
      `INSERT INTO users (email, username, display_name, email_verified_at) VALUES
         ('owner@example.com', 'owner', 'Owner', now()),
         ('admin@example.com', 'admin', 'Admin', now()),
         ('viewer@example.com', 'viewer', 'Viewer', now()),
         ('other@example.com', 'other', 'Other', now()),
         ('legacy@example.com', 'legacy', 'Legacy', now())
       RETURNING id, email`,
    );
    const byEmail = Object.fromEntries(users.rows.map((row) => [row.email, row.id]));
    const store = new PostgresStore(databaseURL, pool);

    const created = await store.createTeam({
      actorUserID: byEmail["owner@example.com"],
      name: "Operations",
      idempotencyKey: "integration:team-create-01",
    });
    const publicKey = JSON.stringify({
      kty: "EC", crv: "P-256", x: "A".repeat(43), y: "B".repeat(43), ext: true, key_ops: [],
    });
    await pool.query(
      `INSERT INTO devices
        (id, user_id, name, platform, public_key, public_key_algorithm,
         key_registered_at, key_approved_at)
       VALUES ($1, $2, 'Owner browser', 'web', $3, 'p256-ecdh-v1', now(), now()),
              ($4, $5, 'Viewer browser', 'web', $3, 'p256-ecdh-v1', now(), now()),
              ($6, $7, 'Admin browser', 'web', $3, 'p256-ecdh-v1', now(), NULL)`,
      [ownerDeviceID, byEmail["owner@example.com"], publicKey,
        viewerDeviceID, byEmail["viewer@example.com"],
        adminDeviceID, byEmail["admin@example.com"]],
    );
    await pool.query(
      `INSERT INTO devices
        (id, user_id, name, platform, public_key, public_key_algorithm, key_registered_at)
       VALUES ($1, $2, 'Legacy browser', 'web', $3, 'p256-ecdh-v1', now()),
              ($4, $2, 'Legacy second browser', 'web', $3, 'p256-ecdh-v1', now())`,
      [legacyDeviceID, byEmail["legacy@example.com"], publicKey, legacySecondDeviceID],
    );
    assert.deepEqual(await store.bootstrapDeviceKey({
      actorUserID: byEmail["legacy@example.com"],
      actorDeviceID: legacyDeviceID,
      expectedPublicKey: publicKey,
      idempotencyKey: "integration:device-bootstrap-01",
    }), { approved: true, deviceID: legacyDeviceID, bootstrapped: true });
    await assert.rejects(store.bootstrapDeviceKey({
      actorUserID: byEmail["legacy@example.com"],
      actorDeviceID: legacySecondDeviceID,
      expectedPublicKey: publicKey,
      idempotencyKey: "integration:device-bootstrap-02",
    }), /device_approval_required/);
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
    const initial = await store.putSharedVault({
      actorUserID: byEmail["owner@example.com"],
      actorDeviceID: ownerDeviceID,
      teamID: created.team.id,
      vaultID: shared.vault.id,
      envelope: {
        baseRevision: 0,
        keyGeneration: 1,
        envelopeVersion: 1,
        ciphertext: "AA",
        nonce: "B".repeat(16),
        authTag: "C".repeat(22),
        contentHash: "D".repeat(43),
        wrappers: [integrationWrapper(
          created.membership, ownerDeviceID, "E", created.team.id, shared.vault.id, 1,
        )],
      },
      idempotencyKey: "integration:vault-initialize-01",
    });
    assert.equal(initial.revision, 1);
    await assert.rejects(store.registerResourceIdentity({
      actorUserID: byEmail["owner@example.com"], actorDeviceID: ownerDeviceID,
      teamID: created.team.id, vaultID: shared.vault.id,
      resourceID: "9e01c763-e16d-4a6b-bd6f-6795f09f02da",
      policyClass: "folder", parentFolderID: null,
    }), /team_not_found/u);

    // This state is unreachable through product routes in this foundation PR.
    // Exercise the future cutover boundary directly, then restore the v1 fixture.
    await pool.query(
      "UPDATE shared_vaults SET format_state = 'V2_ACTIVE', format_schema_version = 2 WHERE id = $1",
      [shared.vault.id],
    );
    assert.ok(!(await store.listSharedVaults(created.team.id, byEmail["owner@example.com"]))
      .some((vault) => vault.id === shared.vault.id));
    await assert.rejects(store.getSharedVault(created.team.id, shared.vault.id,
      byEmail["owner@example.com"], ownerDeviceID), /team_not_found/u);
    await assert.rejects(store.listTeamKeyDevices(created.team.id, shared.vault.id,
      byEmail["owner@example.com"], ownerDeviceID), /team_not_found/u);
    await assert.rejects(store.putSharedVault({
      actorUserID: byEmail["owner@example.com"], actorDeviceID: ownerDeviceID,
      teamID: created.team.id, vaultID: shared.vault.id,
      envelope: { baseRevision: 1, keyGeneration: 1, envelopeVersion: 1,
        ciphertext: "AA", nonce: "B".repeat(16), authTag: "C".repeat(22),
        contentHash: "D".repeat(43), wrappers: null },
      idempotencyKey: "integration:v2-legacy-write-denied",
    }), /team_not_found/u);
    await assert.rejects(store.grantSharedVaultWrapper({
      actorUserID: byEmail["owner@example.com"], actorDeviceID: ownerDeviceID,
      teamID: created.team.id, vaultID: shared.vault.id, wrapper: integrationWrapper(
        created.membership, ownerDeviceID, "E", created.team.id, shared.vault.id, 1),
      keyGeneration: 1, idempotencyKey: "integration:v2-legacy-wrapper-denied",
    }), /team_not_found/u);
    await pool.query(
      "UPDATE shared_vaults SET format_state = 'V1_ACTIVE', format_schema_version = 1 WHERE id = $1",
      [shared.vault.id],
    );
    await pool.query(
      "UPDATE shared_vaults SET format_state = 'V2_PREPARING', format_schema_version = 2 WHERE id = $1",
      [shared.vault.id],
    );
    const folderResourceID = "9e01c763-e16d-4a6b-bd6f-6795f09f02da";
    const childResourceID = "eb48ea7c-c63e-4b11-96fb-829601e46678";
    const resourceActor = { actorUserID: byEmail["owner@example.com"],
      actorDeviceID: ownerDeviceID, teamID: created.team.id, vaultID: shared.vault.id };
    const folderIdentity = await store.registerResourceIdentity({ ...resourceActor,
      resourceID: folderResourceID, policyClass: "folder", parentFolderID: null });
    assert.equal(folderIdentity.id, folderResourceID);
    const childIdentity = await store.registerResourceIdentity({ ...resourceActor,
      resourceID: childResourceID, policyClass: "general", parentFolderID: folderResourceID });
    assert.equal(childIdentity.parent_folder_id, folderResourceID);
    assert.equal((await store.getResourceIdentity({ ...resourceActor, resourceID: childResourceID })).id,
      childResourceID);
    await pool.query(
      `INSERT INTO team_membership_device_admissions
       (membership_id, membership_epoch, device_id) VALUES ($1, $2, $3)
       ON CONFLICT DO NOTHING`,
      [created.membership.id, created.membership.epoch, ownerDeviceID],
    );
    const identity = await generateTeamDeviceIdentity(webcrypto);
    await pool.query(
      `INSERT INTO devices
       (id, user_id, name, platform, public_key, public_key_algorithm,
        key_registered_at, key_approved_at)
       VALUES ($1, $2, 'Second owner device', 'web', $3, 'p256-ecdh-v1', now(), now())`,
      [ownerSecondDeviceID, byEmail["owner@example.com"], JSON.stringify(identity.publicKey)],
    );
    await pool.query(
      `INSERT INTO team_membership_device_admissions
       (membership_id, membership_epoch, device_id) VALUES ($1, $2, $3)`,
      [created.membership.id, created.membership.epoch, ownerSecondDeviceID],
    );
    const cryptoContext = { teamID: created.team.id, vaultID: shared.vault.id,
      resourceID: childResourceID, part: "GENERAL", keyVersion: 1,
      policyVersion: 1, registryVersion: 1, resourceVersion: 1, manifestVersion: 1 };
    const firstCEK = generateResourceCEK(webcrypto);
    const firstCiphertext = await encryptResourcePart({ plaintext: new TextEncoder().encode("fixture"),
      cek: firstCEK, context: cryptoContext, cryptoValue: webcrypto });
    const firstWrapper = await wrapResourceCEK({ cek: firstCEK,
      context: { ...cryptoContext, membershipID: created.membership.id,
        membershipEpoch: Number(created.membership.epoch), deviceID: ownerDeviceID },
      recipientPublicKey: identity.publicKey, cryptoValue: webcrypto });
    const secondDeviceWrapper = await wrapResourceCEK({ cek: firstCEK,
      context: { ...cryptoContext, membershipID: created.membership.id,
        membershipEpoch: Number(created.membership.epoch), deviceID: ownerSecondDeviceID },
      recipientPublicKey: identity.publicKey, cryptoValue: webcrypto });
    const publish = { ...resourceActor, resourceID: childResourceID,
      expectedManifestVersion: 0, ciphertext: firstCiphertext,
      wrappers: [firstWrapper, secondDeviceWrapper] };
    await assert.rejects(store.publishResourceCryptoVersion({ ...publish, wrappers: [{
      ...firstWrapper, context: { ...firstWrapper.context,
        membershipID: "7f49f2e1-03bc-4218-9c34-d7629b686160" },
    }] }), /resource_v2_current_epoch_admission_required/u);
    assert.equal((await pool.query(
      `SELECT count(*)::integer AS count FROM vault_resource_ciphertext_versions
       WHERE resource_id = $1`, [childResourceID])).rows[0].count, 0);
    assert.equal(Number((await store.publishResourceCryptoVersion(publish)).manifest_version), 1);
    await pool.query("UPDATE devices SET revoked_at = now() WHERE id = $1", [ownerSecondDeviceID]);
    const nextContext = { ...cryptoContext, keyVersion: 2, manifestVersion: 2 };
    const nextCEK = generateResourceCEK(webcrypto);
    const nextCiphertext = await encryptResourcePart({ plaintext: new TextEncoder().encode("fixture-v2"),
      cek: nextCEK, context: nextContext, cryptoValue: webcrypto });
    const nextWrapper = await wrapResourceCEK({ cek: nextCEK,
      context: { ...nextContext, membershipID: created.membership.id,
        membershipEpoch: Number(created.membership.epoch), deviceID: ownerDeviceID },
      recipientPublicKey: identity.publicKey, cryptoValue: webcrypto });
    const nextPublish = { ...publish, expectedManifestVersion: 1,
      ciphertext: nextCiphertext, wrappers: [nextWrapper] };
    const races = await Promise.allSettled([
      store.publishResourceCryptoVersion(nextPublish),
      store.publishResourceCryptoVersion(nextPublish),
    ]);
    assert.deepEqual(races.map((item) => item.status).sort(), ["fulfilled", "rejected"]);
    assert.match(String(races.find((item) => item.status === "rejected").reason), /resource_manifest_conflict/u);
    const pointer = await pool.query(
      `SELECT key_version, manifest_version FROM vault_resource_manifest_pointers_v2
       WHERE resource_id = $1`, [childResourceID]);
    assert.equal(Number(pointer.rows[0].key_version), 2);
    assert.equal(Number(pointer.rows[0].manifest_version), 2);
    await assert.rejects(pool.query(
      `UPDATE vault_resource_ciphertext_versions
       SET lifecycle = 'OBSOLETE', obsolete_at = now()
       WHERE resource_id = $1 AND key_version = 2`, [childResourceID],
    ), /resource_v2_published_ciphertext_in_use/u);
    await assert.rejects(pool.query(
      `UPDATE vault_resource_key_wrappers_v2 SET obsolete_at = now()
       WHERE resource_id = $1 AND key_version = 2`, [childResourceID],
    ), /resource_v2_last_published_wrapper/u);
    assert.equal((await pool.query(
      `SELECT count(*)::integer AS count FROM vault_resource_key_wrappers_v2
       WHERE resource_id = $1 AND key_version = 1 AND obsolete_at IS NULL`,
      [childResourceID],
    )).rows[0].count, 0);
    await assert.rejects(store.getResourceIdentity({ ...resourceActor,
      teamID: "2da9bfce-9882-4edc-9303-04cebdb31323", resourceID: childResourceID }),
    /team_not_found/u);
    await assert.rejects(store.getResourceIdentity({ ...resourceActor,
      vaultID: "4f90fbb7-7f1b-42e2-b8eb-159401a27468", resourceID: childResourceID }),
    /team_not_found/u);
    await assert.rejects(store.registerResourceIdentity({ ...resourceActor,
      resourceID: childResourceID, policyClass: "general", parentFolderID: null }),
    /resource_id_exists/u);
    await assert.rejects(store.tombstoneResourceIdentity({ ...resourceActor,
      resourceID: folderResourceID, expectedVersion: 1 }), /active_resource_children/u);
    const moved = await store.moveResourceIdentity({ ...resourceActor,
      resourceID: childResourceID, parentFolderID: null, expectedVersion: 1 });
    assert.equal(moved.id, childResourceID);
    assert.equal(moved.parent_folder_id, null);
    await store.tombstoneResourceIdentity({ ...resourceActor,
      resourceID: childResourceID, expectedVersion: 2 });
    await assert.rejects(store.registerResourceIdentity({ ...resourceActor,
      resourceID: childResourceID, policyClass: "general", parentFolderID: null }),
    /resource_id_exists/u);
    await pool.query(
      "UPDATE shared_vaults SET format_state = 'V1_ACTIVE', format_schema_version = 1 WHERE id = $1",
      [shared.vault.id],
    );
    await assert.rejects(pool.query(
      `INSERT INTO vault_resource_ciphertext_versions
       (team_id, vault_id, resource_id, part, key_version, policy_version,
        registry_version, resource_version, manifest_version, nonce, ciphertext, auth_tag)
       VALUES ($1, $2, $3, 'GENERAL', 1, 1, 1, 1, 1, $4, $5, $6)`,
      [created.team.id, shared.vault.id, folderResourceID,
        firstCiphertext.nonce, firstCiphertext.ciphertext, firstCiphertext.authTag],
    ), /resource_v2_preparing_required/u);

    const adminInvite = await store.createTeamInvitation({
      actorUserID: byEmail["owner@example.com"],
      teamID: created.team.id,
      invitationType: "username",
      email: null,
      username: "admin",
      role: "admin",
      tokenHash: "a".repeat(64),
      expiresAt: new Date(Date.now() + 48 * 3_600_000),
      outboxEnvelope: null,
      linkSecretEnvelope: null,
      idempotencyKey: "integration:invite-admin-01",
    });
    const pendingAdminInvitations = await store.listPendingTeamInvitations(byEmail["admin@example.com"]);
    assert.equal(pendingAdminInvitations[0].target_username, "admin");
    const accepted = await store.acceptTeamInvitation({
      actorUserID: byEmail["admin@example.com"],
      actorDeviceID: adminDeviceID,
      actorEmail: "admin@example.com",
      invitationID: adminInvite.invitation.id,
      tokenHash: null,
      idempotencyKey: "integration:accept-admin-01",
    });
    assert.equal(accepted.membership.role, "admin");
    assert.equal(accepted.membership.username, "admin");
    assert.equal(accepted.membership.display_name, "Admin");
    assert.equal(Number(accepted.membership.epoch), 1);
    const admittedAdminDevice = await pool.query(
      "SELECT key_approved_at, key_approved_by_device_id FROM devices WHERE id = $1",
      [adminDeviceID],
    );
    assert.equal(admittedAdminDevice.rows[0].key_approved_at, null);
    assert.equal(admittedAdminDevice.rows[0].key_approved_by_device_id, null);
    const scopedAdmission = await pool.query(
      `SELECT membership_id, membership_epoch, device_id, invitation_id
       FROM team_membership_device_admissions
       WHERE membership_id = $1 AND membership_epoch = $2 AND device_id = $3`,
      [accepted.membership.id, accepted.membership.epoch, adminDeviceID],
    );
    assert.equal(scopedAdmission.rows[0].membership_id, accepted.membership.id);
    assert.equal(Number(scopedAdmission.rows[0].membership_epoch), 1);
    assert.equal(scopedAdmission.rows[0].device_id, adminDeviceID);
    assert.equal(scopedAdmission.rows[0].invitation_id, adminInvite.invitation.id);
    await assert.rejects(store.acceptTeamInvitation({
      actorUserID: byEmail["admin@example.com"],
      actorDeviceID: adminDeviceID,
      actorEmail: "admin@example.com",
      invitationID: adminInvite.invitation.id,
      tokenHash: null,
      idempotencyKey: "integration:accept-admin-02",
    }), /invalid_team_invitation/);

    await assert.rejects(store.createTeamInvitation({
      actorUserID: byEmail["admin@example.com"],
      teamID: created.team.id,
      invitationType: "email",
      email: "other@example.com",
      username: null,
      role: "admin",
      tokenHash: "b".repeat(64),
      expiresAt: new Date(Date.now() + 48 * 3_600_000),
      outboxEnvelope: { ciphertext: "AA", nonce: "B".repeat(16), authTag: "C".repeat(22) },
      linkSecretEnvelope: null,
      idempotencyKey: "integration:admin-escalation-01",
    }), /team_access_denied/);

    const viewerTokenHash = "c".repeat(64);
    await store.createTeamInvitation({
      actorUserID: byEmail["admin@example.com"],
      teamID: created.team.id,
      invitationType: "email",
      email: "viewer@example.com",
      username: null,
      role: "viewer",
      tokenHash: viewerTokenHash,
      expiresAt: new Date(Date.now() + 48 * 3_600_000),
      outboxEnvelope: { ciphertext: "AA", nonce: "B".repeat(16), authTag: "C".repeat(22) },
      linkSecretEnvelope: null,
      idempotencyKey: "integration:invite-viewer-01",
    });
    await assert.rejects(store.acceptTeamInvitation({
      actorUserID: byEmail["other@example.com"],
      actorDeviceID: ownerDeviceID,
      actorEmail: "other@example.com",
      invitationID: null,
      tokenHash: viewerTokenHash,
      idempotencyKey: "integration:accept-wrong-email-01",
    }), /invalid_team_invitation/);
    const viewer = await store.acceptTeamInvitation({
      actorUserID: byEmail["viewer@example.com"],
      actorDeviceID: viewerDeviceID,
      actorEmail: "viewer@example.com",
      invitationID: null,
      tokenHash: viewerTokenHash,
      idempotencyKey: "integration:accept-viewer-01",
    });
    const keyDevices = await store.listTeamKeyDevices(
      created.team.id,
      shared.vault.id,
      byEmail["owner@example.com"],
      ownerDeviceID,
    );
    assert.equal(keyDevices.length, 3);
    await store.grantSharedVaultWrapper({
      actorUserID: byEmail["owner@example.com"],
      actorDeviceID: ownerDeviceID,
      teamID: created.team.id,
      vaultID: shared.vault.id,
      wrapper: integrationWrapper(
        viewer.membership, viewerDeviceID, "F", created.team.id, shared.vault.id, 1,
      ),
      keyGeneration: 1,
      idempotencyKey: "integration:vault-wrapper-viewer-01",
    });
    const viewerVault = await store.getSharedVault(
      created.team.id,
      shared.vault.id,
      byEmail["viewer@example.com"],
      viewerDeviceID,
    );
    assert.equal(viewerVault.wrapper_ciphertext, "F".repeat(43));
    await assert.rejects(store.putSharedVault({
      actorUserID: byEmail["viewer@example.com"],
      actorDeviceID: viewerDeviceID,
      teamID: created.team.id,
      vaultID: shared.vault.id,
      envelope: {
        baseRevision: 1, keyGeneration: 1, envelopeVersion: 1, ciphertext: "XX",
        nonce: "B".repeat(16), authTag: "C".repeat(22), contentHash: "D".repeat(43), wrappers: null,
      },
      idempotencyKey: "integration:viewer-write-01",
    }), /team_access_denied/);
    await assert.rejects(store.createSharedVault({
      actorUserID: byEmail["viewer@example.com"],
      teamID: created.team.id,
      name: "Forbidden",
      idempotencyKey: "integration:viewer-vault-01",
    }), /team_access_denied/);

    const cancelled = await store.createTeamInvitation({
      actorUserID: byEmail["owner@example.com"],
      teamID: created.team.id,
      invitationType: "email",
      email: "other@example.com",
      username: null,
      role: "editor",
      tokenHash: "d".repeat(64),
      expiresAt: new Date(Date.now() + 48 * 3_600_000),
      outboxEnvelope: { ciphertext: "AA", nonce: "B".repeat(16), authTag: "C".repeat(22) },
      linkSecretEnvelope: null,
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
    const rotated = await store.putSharedVault({
      actorUserID: byEmail["owner@example.com"],
      actorDeviceID: ownerDeviceID,
      teamID: created.team.id,
      vaultID: shared.vault.id,
      envelope: {
        baseRevision: 1,
        keyGeneration: 2,
        envelopeVersion: 1,
        ciphertext: "RR",
        nonce: "S".repeat(16),
        authTag: "T".repeat(22),
        contentHash: "U".repeat(43),
        wrappers: [
          integrationWrapper(
            created.membership, ownerDeviceID, "V", created.team.id, shared.vault.id, 2,
          ),
          integrationWrapper(
            viewer.membership, viewerDeviceID, "W", created.team.id, shared.vault.id, 2,
          ),
        ],
      },
      idempotencyKey: "integration:vault-rotate-01",
    });
    assert.deepEqual(rotated, {
      conflict: false,
      revision: 2,
      keyGeneration: 2,
      rotationCompleted: true,
    });
    const completed = await pool.query(
      "SELECT rotation_required, key_generation FROM shared_vaults WHERE id = $1",
      [shared.vault.id],
    );
    assert.deepEqual(completed.rows[0], { rotation_required: false, key_generation: "2" });

    await pool.query(
      `INSERT INTO devices
        (id, user_id, name, platform, public_key, public_key_algorithm,
         key_registered_at, key_approved_at)
       VALUES ($1, $2, 'Viewer second browser', 'web', $3, 'p256-ecdh-v1', now(), now())`,
      [viewerSecondDeviceID, byEmail["viewer@example.com"], publicKey],
    );
    const viewerVisibleDevices = await store.listTeamKeyDevices(
      created.team.id,
      shared.vault.id,
      byEmail["viewer@example.com"],
      viewerDeviceID,
    );
    assert.ok(viewerVisibleDevices.some((device) => device.device_id === viewerSecondDeviceID
      && device.has_wrapper === false));
    assert.deepEqual(await store.grantSharedVaultWrapper({
      actorUserID: byEmail["viewer@example.com"],
      actorDeviceID: viewerDeviceID,
      teamID: created.team.id,
      vaultID: shared.vault.id,
      wrapper: integrationWrapper(
        viewer.membership, viewerSecondDeviceID, "Y", created.team.id, shared.vault.id, 2,
      ),
      keyGeneration: 2,
      idempotencyKey: "integration:viewer-wrapper-second-device-01",
    }), { granted: true, keyGeneration: 2, deviceID: viewerSecondDeviceID });
    const secondViewerVault = await store.getSharedVault(
      created.team.id,
      shared.vault.id,
      byEmail["viewer@example.com"],
      viewerSecondDeviceID,
    );
    assert.equal(secondViewerVault.wrapper_ciphertext, "Y".repeat(43));

    const stale = await store.putSharedVault({
      actorUserID: byEmail["owner@example.com"],
      actorDeviceID: ownerDeviceID,
      teamID: created.team.id,
      vaultID: shared.vault.id,
      envelope: {
        baseRevision: 1, keyGeneration: 2, envelopeVersion: 1, ciphertext: "SS",
        nonce: "B".repeat(16), authTag: "C".repeat(22), contentHash: "D".repeat(43), wrappers: null,
      },
      idempotencyKey: "integration:vault-stale-01",
    });
    assert.deepEqual(stale, { conflict: true, revision: 2, keyGeneration: 2 });
    assert.equal(await store.revokeDevice(byEmail["viewer@example.com"], viewerDeviceID), true);
    await assert.rejects(
      store.getSharedVault(
        created.team.id,
        shared.vault.id,
        byEmail["viewer@example.com"],
        viewerDeviceID,
      ),
      /team_not_found/,
    );
    const deviceRotation = await pool.query(
      `SELECT vault.rotation_required, task.removed_device_id
       FROM shared_vaults AS vault
       JOIN shared_vault_rotation_tasks AS task ON task.vault_id = vault.id
       WHERE vault.id = $1 AND task.removed_device_id = $2 AND task.status = 'pending'`,
      [shared.vault.id, viewerDeviceID],
    );
    assert.deepEqual(deviceRotation.rows, [{ rotation_required: true, removed_device_id: viewerDeviceID }]);

    const pendingLifecycleInvite = await store.createTeamInvitation({
      actorUserID: byEmail["owner@example.com"],
      teamID: created.team.id,
      invitationType: "email",
      email: "other@example.com",
      username: null,
      role: "viewer",
      tokenHash: "e".repeat(64),
      expiresAt: new Date(Date.now() + 48 * 3_600_000),
      outboxEnvelope: { ciphertext: "AA", nonce: "B".repeat(16), authTag: "C".repeat(22) },
      linkSecretEnvelope: null,
      idempotencyKey: "integration:invite-lifecycle-01",
    });
    const renamed = await store.renameTeam({
      actorUserID: byEmail["owner@example.com"],
      teamID: created.team.id,
      name: "Platform",
      idempotencyKey: "integration:team-rename-01",
    });
    assert.equal(renamed.team.name, "Platform");
    assert.deepEqual(await store.transferTeamOwnership({
      actorUserID: byEmail["owner@example.com"],
      teamID: created.team.id,
      membershipID: viewer.membership.id,
      idempotencyKey: "integration:team-transfer-01",
    }), {
      transferred: true,
      teamID: created.team.id,
      previousOwnerMembershipID: created.membership.id,
      ownerMembershipID: viewer.membership.id,
    });
    const transferredRoles = await pool.query(
      `SELECT user_id, role FROM team_memberships
       WHERE id IN ($1, $2) ORDER BY user_id`,
      [created.membership.id, viewer.membership.id],
    );
    const roleByUser = Object.fromEntries(transferredRoles.rows.map((row) => [row.user_id, row.role]));
    assert.equal(roleByUser[byEmail["owner@example.com"]], "admin");
    assert.equal(roleByUser[byEmail["viewer@example.com"]], "owner");
    assert.deepEqual(await store.deleteAccount(byEmail["owner@example.com"]), { deleted: true });
    const deletedAccountState = await pool.query(
      `SELECT
         (SELECT count(*)::int FROM users WHERE id = $1) AS users,
         (SELECT count(*)::int FROM devices WHERE user_id = $1) AS devices,
         (SELECT count(*)::int FROM sessions WHERE user_id = $1) AS sessions,
         (SELECT count(*)::int FROM personal_vaults WHERE user_id = $1) AS personal_vaults,
         (SELECT count(*)::int FROM team_memberships WHERE id = $2 AND user_id IS NULL AND revoked_at IS NOT NULL) AS retained_memberships,
         (SELECT count(*)::int FROM shared_vaults WHERE team_id = $3 AND rotation_required) AS frozen_vaults,
         (SELECT count(*)::int FROM shared_vault_rotation_tasks WHERE removed_membership_id = $2 AND status = 'pending') AS rotation_tasks`,
      [byEmail["owner@example.com"], created.membership.id, created.team.id],
    );
    assert.deepEqual(deletedAccountState.rows[0], {
      users: 0, devices: 0, sessions: 0, personal_vaults: 0,
      retained_memberships: 1, frozen_vaults: 1, rotation_tasks: 1,
    });
    await assert.rejects(store.archiveTeam({
      actorUserID: byEmail["viewer@example.com"],
      teamID: created.team.id,
      expectedName: "Operations",
      idempotencyKey: "integration:team-archive-mismatch-01",
    }), /team_name_mismatch/);
    assert.deepEqual(await store.archiveTeam({
      actorUserID: byEmail["viewer@example.com"],
      teamID: created.team.id,
      expectedName: "Platform",
      idempotencyKey: "integration:team-archive-01",
    }), { archived: true, teamID: created.team.id });
    assert.deepEqual(await store.listTeams(byEmail["owner@example.com"]), []);
    assert.deepEqual(await store.listTeams(byEmail["viewer@example.com"]), []);
    await assert.rejects(
      store.listSharedVaults(created.team.id, byEmail["owner@example.com"]),
      /team_not_found/,
    );
    const lifecycleState = await pool.query(
      `SELECT team.archived_at AS team_archived_at, vault.archived_at AS vault_archived_at,
         invitation.cancelled_at, job.delivered_at
       FROM teams AS team
       JOIN shared_vaults AS vault ON vault.team_id = team.id
       JOIN team_invitations AS invitation ON invitation.id = $2
       JOIN team_outbox_jobs AS job ON job.aggregate_id = invitation.id
       WHERE team.id = $1 AND vault.id = $3`,
      [created.team.id, pendingLifecycleInvite.invitation.id, shared.vault.id],
    );
    assert.ok(lifecycleState.rows[0].team_archived_at);
    assert.ok(lifecycleState.rows[0].vault_archived_at);
    assert.ok(lifecycleState.rows[0].cancelled_at);
    assert.ok(lifecycleState.rows[0].delivered_at);
    const pendingAfterArchive = await pool.query(
      `SELECT count(*)::int AS count FROM shared_vault_rotation_tasks AS task
       JOIN shared_vaults AS vault ON vault.id = task.vault_id
       WHERE vault.team_id = $1 AND task.status = 'pending'`,
      [created.team.id],
    );
    assert.equal(pendingAfterArchive.rows[0].count, 0);
    const auditActions = await pool.query(
      `SELECT action FROM team_audit_events WHERE team_id = $1
       AND action IN ('team.renamed', 'team.ownership_transferred', 'team.archived')
       ORDER BY id`,
      [created.team.id],
    );
    assert.deepEqual(auditActions.rows.map((row) => row.action), [
      "team.renamed", "team.ownership_transferred", "team.archived",
    ]);
    assert.equal(viewer.membership.role, "viewer");
    assert.equal(adminInvite.invitation.invitation_type, "username");
  } finally {
    await pool.end();
  }
});
