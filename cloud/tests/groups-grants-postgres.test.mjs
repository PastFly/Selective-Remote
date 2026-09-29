import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { randomUUID } from "node:crypto";
import { applyMigrations, loadMigrations } from "../src/migrations.mjs";
import { AccessStore } from "../src/access-store.mjs";

const directory = fileURLToPath(new URL("../migrations/", import.meta.url));
const databaseURL = process.env.TEST_DATABASE_URL;

test("migration 018 defines the dormant access-policy schema", async () => {
  const migrations = await loadMigrations(directory);
  assert.equal(migrations.at(-1)?.version, 18);
  const sql = migrations.at(-1)?.sql ?? "";
  for (const name of ["team_policy_revisions", "team_access_groups", "team_access_group_members", "vault_access_grants", "policy_kind", "access_policy_version", "team_access_mutation_receipts"]) {
    assert.match(sql, new RegExp(name));
  }
});

test("fresh PostgreSQL keeps legacy Vaults V1 and groups Team-scoped", {
  skip: databaseURL ? false : "TEST_DATABASE_URL is not configured",
}, async () => {
  const pool = new pg.Pool({ connectionString: databaseURL, max: 2 });
  try {
    await applyMigrations(pool, directory, { info() {} });
    const vaultColumn = await pool.query(`SELECT column_default FROM information_schema.columns
      WHERE table_name = 'shared_vaults' AND column_name = 'format_state'`);
    assert.match(vaultColumn.rows[0]?.column_default ?? "", /V1_ACTIVE/);
    const groupVaultColumn = await pool.query(`SELECT 1 FROM information_schema.columns
      WHERE table_name = 'team_access_groups' AND column_name = 'vault_id'`);
    assert.equal(groupVaultColumn.rowCount, 0);
    const tables = await pool.query(`SELECT to_regclass('team_access_groups') AS groups,
      to_regclass('vault_access_grants') AS grants`);
    assert.equal(tables.rows[0].groups, "team_access_groups");
    assert.equal(tables.rows[0].grants, "vault_access_grants");
  } finally {
    await pool.end();
  }
});


test("PostgreSQL enforces scoped grants, Credential mask, and Team group lifetime", {
  skip: databaseURL ? false : "TEST_DATABASE_URL is not configured",
}, async () => {
  const pool = new pg.Pool({ connectionString: databaseURL, max: 2 });
  const client = await pool.connect();
  const suffix = randomUUID().slice(0, 12);
  async function rejectsStatement(sql, args, expected) {
    await client.query("SAVEPOINT invalid_policy_write");
    await assert.rejects(client.query(sql, args), expected);
    await client.query("ROLLBACK TO SAVEPOINT invalid_policy_write");
    await client.query("RELEASE SAVEPOINT invalid_policy_write");
  }
  try {
    await applyMigrations(pool, directory, { info() {} });
    await client.query("BEGIN");
    const user = (await client.query(`INSERT INTO users (email, username, display_name, email_verified_at)
      VALUES ($1, $2, 'Access fixture', now()) RETURNING id`,
    [`access-${suffix}@example.com`, `access_${suffix}`])).rows[0].id;
    const team = (await client.query("INSERT INTO teams (name, created_by_user_id) VALUES ('Access fixture', $1) RETURNING id", [user])).rows[0].id;
    const member = (await client.query("INSERT INTO team_memberships (team_id, user_id, role) VALUES ($1, $2, 'owner') RETURNING id, epoch", [team, user])).rows[0];
    const vault = (await client.query(`INSERT INTO shared_vaults
      (team_id, name, created_by_user_id, format_state, format_schema_version)
      VALUES ($1, 'Access fixture', $2, 'V2_PREPARING', 2) RETURNING id`, [team, user])).rows[0].id;
    const resource = randomUUID();
    await client.query(`INSERT INTO vault_resource_registry
      (id, team_id, vault_id, policy_class, policy_kind)
      VALUES ($1, $2, $3, 'secret', 'CREDENTIAL')`, [resource, team, vault]);
    const group = (await client.query(`INSERT INTO team_access_groups
      (team_id, name, created_by_user_id) VALUES ($1, 'Operators', $2) RETURNING id`, [team, user])).rows[0].id;
    const edge = (await client.query(`INSERT INTO team_access_group_members
      (team_id, group_id, user_id, membership_id, membership_epoch, created_by_user_id)
      VALUES ($1, $2, $3, $4, $5, $3) RETURNING id`,
    [team, group, user, member.id, member.epoch])).rows[0].id;
    const insertGrant = `INSERT INTO vault_access_grants
      (team_id, vault_id, principal_kind, principal_id, target_kind, target_id,
       permission_mask, created_by_user_id)
      VALUES ($1, $2, 'GROUP', $3, 'RESOURCE', $4, $5, $6) RETURNING id`;
    await rejectsStatement(insertGrant, [team, vault, group, resource, 4, user], /credential_edit_requires_reveal/);
    const grant = (await client.query(insertGrant, [team, vault, group, resource, 6, user])).rows[0].id;
    await rejectsStatement(insertGrant, [team, vault, group, resource, 6, user], /duplicate key/);
    await rejectsStatement("UPDATE team_access_groups SET deleted_at = now(), version = 2 WHERE id = $1", [group], /access_group_active_grants_or_tombstone/);
    const direct = (await client.query(`INSERT INTO vault_access_grants
      (team_id, vault_id, principal_kind, principal_id, membership_id,
       membership_epoch, target_kind, target_id, permission_mask, created_by_user_id)
      VALUES ($1, $2, 'USER', $3, $4, $5, 'RESOURCE', $6, 1, $3) RETURNING id`,
    [team, vault, user, member.id, member.epoch, resource])).rows[0].id;
    await client.query("UPDATE team_memberships SET revoked_at = now(), revoked_by_user_id = $2 WHERE id = $1", [member.id, user]);
    await client.query("UPDATE vault_access_grants SET revoked_at = now(), version = 2 WHERE id = $1", [direct]);
    await client.query("UPDATE vault_access_grants SET revoked_at = now(), version = 2 WHERE id = $1", [grant]);
    await client.query("UPDATE team_access_group_members SET removed_at = now(), version = 2 WHERE id = $1", [edge]);
    await client.query("UPDATE team_access_groups SET deleted_at = now(), version = 2 WHERE id = $1", [group]);
    assert.equal((await client.query("SELECT team_id FROM team_access_groups WHERE id = $1", [group])).rows[0].team_id, team);
    assert.equal((await client.query("SELECT access_policy_version FROM shared_vaults WHERE id = $1", [vault])).rows[0].access_policy_version, "4");
    await client.query("ROLLBACK");
  } finally {
    await client.query("ROLLBACK").catch(() => {});
    client.release();
    await pool.end();
  }
});


test("group names are validated before SQL", async () => {
  const access = new AccessStore({});
  await assert.rejects(access.createAccessGroup({ name: "" }), /invalid_access_group_name/);
  await assert.rejects(access.renameAccessGroup({ name: "\n" }), /invalid_access_group_name/);
  await assert.rejects(access.addAccessGroupMember({ targetMembershipID: "bad" }),
    /invalid_access_membership/);
  await assert.rejects(access.deleteAccessGroup({ expectedVersion: 0 }),
    /invalid_access_version/);
  await assert.rejects(access.getEffectiveAccess({ resourceID: "bad" }),
    /invalid_access_resource/);
  await assert.rejects(access.listAccessGrants({ limit: 51 }), /invalid_access_page/);
  await assert.rejects(access.listWhoHasAccess({ resourceID: "bad" }),
    /invalid_access_resource/);
  await assert.rejects(access.listResourcesByPrincipal({ limit: 51 }),
    /invalid_access_page/);
  await assert.rejects(access.previewAccessChange({ request: { changes: [] } }),
    /invalid_access_request/);
  await assert.rejects(access.commitAccessChange({ token: "unsigned",
    sessionSecret: "test", request: { changes: [] } }),
    /access_preview_conflict/);
});

test("Team group creation is gated by admitted Owner and exact idempotent request", {
  skip: databaseURL ? false : "TEST_DATABASE_URL is not configured",
}, async () => {
  const pool = new pg.Pool({ connectionString: databaseURL, max: 3 });
  const suffix = randomUUID().slice(0, 12);
  try {
    await applyMigrations(pool, directory, { info() {} });
    const user = (await pool.query(`INSERT INTO users (email, username, display_name, email_verified_at)
      VALUES ($1, $2, 'Access owner', now()) RETURNING id`,
    [`access-owner-${suffix}@example.com`, `access_owner_${suffix}`])).rows[0].id;
    const device = randomUUID();
    await pool.query(`INSERT INTO devices (id, user_id, name, platform, public_key,
      public_key_algorithm, key_registered_at, key_approved_at)
      VALUES ($1, $2, 'Test browser', 'web', $3, 'p256-ecdh-v1', now(), now())`,
    [device, user, JSON.stringify({ kty: "EC", crv: "P-256", x: "A".repeat(43), y: "B".repeat(43), ext: true, key_ops: [] })]);
    const team = (await pool.query(`INSERT INTO teams (name, created_by_user_id)
      VALUES ('Access owner fixture', $1) RETURNING id`, [user])).rows[0].id;
    await pool.query(`INSERT INTO team_memberships (team_id, user_id, role)
      VALUES ($1, $2, 'owner')`, [team, user]);
    const vault = (await pool.query(`INSERT INTO shared_vaults
      (team_id, name, created_by_user_id, format_state, format_schema_version)
      VALUES ($1, 'Preparing', $2, 'V2_PREPARING', 2) RETURNING id`, [team, user])).rows[0].id;
    const v1Vault = (await pool.query(`INSERT INTO shared_vaults
      (team_id, name, created_by_user_id) VALUES ($1, 'Legacy', $2) RETURNING id`,
    [team, user])).rows[0].id;
    const access = new AccessStore(pool);
    const input = { actorUserID: user, actorDeviceID: device, teamID: team, vaultID: vault,
      name: "Operators", idempotencyKey: `access:create:${suffix}` };
    const created = await access.createAccessGroup(input);
    assert.equal(created.group.name, "Operators");
    assert.equal(created.group.team_id, team);
    assert.equal((await access.createAccessGroup(input)).group.id, created.group.id);
    const page = await access.listAccessGroups({ actorUserID: user, actorDeviceID: device,
      teamID: team, limit: 50 });
    assert.equal(page.rows.some((row) => row.id === created.group.id), true);
    const renamed = await access.renameAccessGroup({ actorUserID: user, actorDeviceID: device,
      teamID: team, vaultID: vault, groupID: created.group.id, expectedVersion: 1,
      name: "On-call", idempotencyKey: `access:rename:${suffix}` });
    assert.equal(renamed.group.name, "On-call");
    assert.equal(Number(renamed.group.version), 2);
    const viewer = (await pool.query(`INSERT INTO users (email, username, display_name,
      email_verified_at) VALUES ($1, $2, 'Access viewer', now()) RETURNING id`,
    [`access-viewer-${suffix}@example.com`, `access_viewer_${suffix}`])).rows[0].id;
    const viewerMembership = (await pool.query(`INSERT INTO team_memberships
      (team_id, user_id, role) VALUES ($1, $2, 'viewer') RETURNING id`,
    [team, viewer])).rows[0].id;
    const edge = await access.addAccessGroupMember({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, groupID: created.group.id,
      targetMembershipID: viewerMembership, idempotencyKey: `access:member-add:${suffix}` });
    assert.equal(edge.member.user_id, viewer);
    const folder = randomUUID();
    const host = randomUUID();
    await pool.query(`INSERT INTO vault_resource_registry
      (id, team_id, vault_id, policy_class, policy_kind)
      VALUES ($1, $3, $4, 'folder', 'FOLDER'),
             ($2, $3, $4, 'general', 'HOST')`, [folder, host, team, vault]);
    await pool.query(`UPDATE vault_resource_registry SET parent_folder_id = $2,
      resource_version = 2 WHERE id = $1`, [host, folder]);
    await pool.query(`INSERT INTO vault_access_grants
      (team_id, vault_id, principal_kind, principal_id, target_kind,
       target_id, permission_mask, created_by_user_id)
      VALUES ($1, $2, 'GROUP', $3, 'FOLDER', $4, 1, $5)`,
    [team, vault, created.group.id, folder, user]);
    await pool.query(`INSERT INTO vault_access_grants
      (team_id, vault_id, principal_kind, principal_id, membership_id,
       membership_epoch, target_kind, target_id, permission_mask, created_by_user_id)
      VALUES ($1, $2, 'USER', $3, $4, 1, 'RESOURCE', $5, 1, $6)`,
    [team, vault, viewer, viewerMembership, host, user]);
    const effectiveBefore = await access.getEffectiveAccess({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, resourceID: host,
      subjectUserID: viewer });
    assert.equal(effectiveBefore.policyMask, 1);
    assert.equal(effectiveBefore.effectiveUsable, "NO");
    assert.equal(effectiveBefore.paths.length, 2);
    const holders = await access.listWhoHasAccess({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, resourceID: host,
      limit: 50 });
    assert.equal(holders.rows.some((row) => row.userID === viewer), true);
    const groupResources = await access.listResourcesByPrincipal({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, principalKind: "GROUP",
      principalID: created.group.id, limit: 50 });
    assert.equal(groupResources.rows.some((row) => row.resourceID === host), true);
    const removed = await access.removeAccessGroupMember({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, groupID: created.group.id,
      edgeID: edge.member.id, expectedVersion: 1,
      idempotencyKey: `access:member-remove:${suffix}` });
    assert.equal(removed.removed, true);
    const effectiveAfter = await access.getEffectiveAccess({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, resourceID: host,
      subjectUserID: viewer });
    assert.equal(effectiveAfter.policyMask, 1);
    assert.equal(effectiveAfter.paths.length, 1);
    const snippet = randomUUID();
    await pool.query(`INSERT INTO vault_resource_registry
      (id, team_id, vault_id, policy_class, policy_kind)
      VALUES ($1, $2, $3, 'general', 'SNIPPET')`, [snippet, team, vault]);
    const request = { changes: [{ type: "GRANT_CREATE", principalKind: "USER",
      principalID: viewer, targetKind: "RESOURCE", targetID: snippet,
      permissionMask: 1 }] };
    const previewInput = { actorUserID: user, actorDeviceID: device,
      teamID: team, vaultID: vault, request, sessionSecret: "test-session-secret" };
    const preview = await access.previewAccessChange(previewInput);
    assert.equal(preview.details.length, 1);
    assert.equal(preview.details[0].before.policyMask, 0);
    assert.equal(preview.details[0].after.policyMask, 1);
    await assert.rejects(access.commitAccessChange({ ...previewInput,
      token: preview.token + "x", idempotencyKey: `access:bad-token:${suffix}` }),
    /access_preview_conflict/);
    const applied = await access.commitAccessChange({ ...previewInput,
      token: preview.token, idempotencyKey: `access:commit:${suffix}` });
    assert.equal(applied.applied, 1);
    const listed = await access.listAccessGrants({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, limit: 50 });
    assert.equal(listed.rows.some((grant) => grant.id === applied.grants[0].grantID), true);
    assert.equal((await access.getEffectiveAccess({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, resourceID: snippet,
      subjectUserID: viewer })).policyMask, 1);
    const viewerResources = await access.listResourcesByPrincipal({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, principalKind: "USER",
      principalID: viewer, limit: 50 });
    assert.equal(viewerResources.rows.some((row) => row.resourceID === host), true);
    assert.equal(viewerResources.rows.some((row) => row.resourceID === snippet), true);
    const folderA = randomUUID();
    const folderB = randomUUID();
    const forwarding = randomUUID();
    await pool.query(`INSERT INTO vault_resource_registry
      (id, team_id, vault_id, policy_class, policy_kind)
      VALUES ($1, $3, $4, 'folder', 'FOLDER'),
             ($2, $3, $4, 'folder', 'FOLDER')`,
    [folderA, folderB, team, vault]);
    await pool.query(`INSERT INTO vault_resource_registry
      (id, team_id, vault_id, policy_class, policy_kind, parent_folder_id)
      VALUES ($1, $2, $3, 'general', 'FORWARDING', $4)`,
    [forwarding, team, vault, folderA]);
    await pool.query(`INSERT INTO vault_access_grants
      (team_id, vault_id, principal_kind, principal_id, membership_id,
       membership_epoch, target_kind, target_id, permission_mask, created_by_user_id)
      VALUES ($1, $2, 'USER', $3, $4, 1, 'FOLDER', $5, 1, $6)`,
    [team, vault, viewer, viewerMembership, folderA, user]);
    const moveRequest = { changes: [{ type: "RESOURCE_MOVE", resourceID: forwarding,
      newParentFolderID: folderB, expectedResourceVersion: 1 }] };
    const moveInput = { actorUserID: user, actorDeviceID: device,
      teamID: team, vaultID: vault, request: moveRequest,
      sessionSecret: "test-session-secret" };
    const movePreview = await access.previewAccessChange(moveInput);
    const viewerDelta = movePreview.details.find((item) => item.subjectUserID === viewer);
    assert.equal(viewerDelta.before.policyMask, 1);
    assert.equal(viewerDelta.after.policyMask, 0);
    const moved = await access.commitAccessChange({ ...moveInput,
      token: movePreview.token, idempotencyKey: `access:move:${suffix}` });
    assert.equal(moved.applied, 1);
    assert.equal((await pool.query(`SELECT parent_folder_id FROM vault_resource_registry
      WHERE id = $1`, [forwarding])).rows[0].parent_folder_id, folderB);
    assert.equal(moved.notificationCandidates.some((item) => item.userID === viewer
      && item.lostMask === 1), true);
    await assert.rejects(access.renameAccessGroup({ actorUserID: user, actorDeviceID: device,
      teamID: team, vaultID: vault, groupID: created.group.id, expectedVersion: 1,
      name: "Stale", idempotencyKey: `access:stale:${suffix}` }), /access_policy_conflict/);
    await assert.rejects(access.createAccessGroup({ ...input, name: "Changed" }),
      /access_idempotency_conflict/);
    await assert.rejects(access.createAccessGroup({ ...input, vaultID: v1Vault,
      idempotencyKey: `access:v1:${suffix}` }), /access_v2_preparing_required/);
    const deleted = await access.deleteAccessGroup({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, groupID: created.group.id,
      expectedVersion: 2, idempotencyKey: `access:delete:${suffix}` });
    assert.equal(deleted.deleted, true);
    assert.equal((await access.listAccessGroups({ actorUserID: user,
      actorDeviceID: device, teamID: team })).rows.some((row) => row.id === created.group.id), false);
    const fanoutGroup = (await access.createAccessGroup({ ...input, name: "Large group",
      idempotencyKey: `access:large:${suffix}` })).group.id;
    await pool.query(`WITH new_resources AS (
      INSERT INTO vault_resource_registry (id, team_id, vault_id, policy_class, policy_kind)
      SELECT gen_random_uuid(), $1, $2, 'general', 'HOST'
      FROM generate_series(1, 1001) RETURNING id
    ) INSERT INTO vault_access_grants
      (team_id, vault_id, principal_kind, principal_id, target_kind, target_id,
       permission_mask, created_by_user_id)
      SELECT $1, $2, 'GROUP', $3, 'RESOURCE', id, 1, $4 FROM new_resources`,
    [team, vault, fanoutGroup, user]);
    const overflow = await access.deleteAccessGroup({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, groupID: fanoutGroup,
      expectedVersion: 1, idempotencyKey: `access:large-overflow:${suffix}` });
    assert.deepEqual(overflow, { deleted: false,
      code: "group_grants_must_be_revoked_first", safeCount: "1001+" });
    assert.equal((await pool.query("SELECT deleted_at FROM team_access_groups WHERE id = $1",
      [fanoutGroup])).rows[0].deleted_at, null);
    await pool.query(`UPDATE vault_access_grants SET revoked_at = now(), version = version + 1
      WHERE id = (SELECT id FROM vault_access_grants WHERE principal_id = $1
        AND revoked_at IS NULL ORDER BY id LIMIT 1)`, [fanoutGroup]);
    const bounded = await access.deleteAccessGroup({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, groupID: fanoutGroup,
      expectedVersion: 1, idempotencyKey: `access:large-delete:${suffix}` });
    assert.equal(bounded.deleted, true);
    assert.equal(bounded.revokedGrants, 1000);
  } finally {
    await pool.end();
  }
});
