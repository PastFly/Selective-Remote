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
  await assert.rejects(access.getEffectiveAccess({ resourceID: randomUUID(),
    subjectDeviceID: "bad" }), /invalid_access_device/);
  await assert.rejects(access.listAccessGrants({ limit: 51 }), /invalid_access_page/);
  await assert.rejects(access.listAccessGroups({ cursor: "bad" }), /invalid_access_page/);
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
    const viewerDevice = randomUUID();
    await pool.query(`INSERT INTO devices (id, user_id, name, platform, public_key,
      public_key_algorithm, key_registered_at, key_approved_at)
      VALUES ($1, $2, 'Viewer browser', 'web', $3, 'p256-ecdh-v1', now(), now())`,
    [viewerDevice, viewer, JSON.stringify({ kty: "EC", crv: "P-256",
      x: "A".repeat(43), y: "B".repeat(43), ext: true, key_ops: [] })]);
    await pool.query(`INSERT INTO team_membership_device_admissions
      (membership_id, membership_epoch, device_id)
      SELECT id, epoch, $2 FROM team_memberships WHERE id = $1`,
    [viewerMembership, viewerDevice]);
    await assert.rejects(access.listAccessGroups({ actorUserID: viewer,
      actorDeviceID: viewerDevice, teamID: team }), /team_access_denied/);
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
    assert.equal(effectiveBefore.policyEffective.policyMask, 1);
    assert.equal(effectiveBefore.policyEffective.paths.length, 2);
    assert.equal(Object.hasOwn(effectiveBefore, "deviceUsability"), false);
    assert.equal(Object.hasOwn(effectiveBefore, "effectiveUsable"), false);
    const withoutWrap = await access.getEffectiveAccess({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, resourceID: host,
      subjectUserID: viewer, subjectDeviceID: viewerDevice });
    assert.deepEqual(withoutWrap.policyEffective, effectiveBefore.policyEffective);
    assert.equal(withoutWrap.deviceUsability.deviceID, viewerDevice);
    assert.equal(withoutWrap.deviceUsability.effectiveUsable, "NO");
    assert.equal(withoutWrap.deviceUsability.cryptoAvailableByPermission.View, "NO");
    const holders = await access.listWhoHasAccess({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, resourceID: host,
      limit: 50 });
    assert.equal(holders.rows.some((row) => row.userID === viewer), true);
    assert.equal(Object.hasOwn(holders.rows.find((row) => row.userID === viewer),
      "deviceUsability"), false);
    const groupResources = await access.listResourcesByPrincipal({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, principalKind: "GROUP",
      principalID: created.group.id, limit: 50 });
    assert.equal(groupResources.rows.some((row) => row.resourceID === host), true);
    assert.equal(Object.hasOwn(groupResources.rows.find((row) => row.resourceID === host),
      "effectiveUsable"), false);
    const removed = await access.removeAccessGroupMember({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, groupID: created.group.id,
      edgeID: edge.member.id, expectedVersion: 1,
      idempotencyKey: `access:member-remove:${suffix}` });
    assert.equal(removed.removed, true);
    const effectiveAfter = await access.getEffectiveAccess({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, resourceID: host,
      subjectUserID: viewer });
    assert.equal(effectiveAfter.policyEffective.policyMask, 1);
    assert.equal(effectiveAfter.policyEffective.paths.length, 1);
    const snippet = randomUUID();
    await pool.query(`INSERT INTO vault_resource_registry
      (id, team_id, vault_id, policy_class, policy_kind)
      VALUES ($1, $2, $3, 'general', 'SNIPPET')`, [snippet, team, vault]);
    const request = { changes: [{ type: "GRANT_CREATE", principalKind: "USER",
      principalID: viewer, targetKind: "RESOURCE", targetID: snippet,
      permissionMask: 1 }] };
    const previewInput = { actorUserID: user, actorDeviceID: device,
      teamID: team, vaultID: vault, request, sessionSecret: "test-session-secret" };
    let preview = await access.previewAccessChange(previewInput);
    assert.equal(preview.details.length, 1);
    assert.equal(preview.details[0].before.policyEffective.policyMask, 0);
    assert.equal(preview.details[0].after.policyEffective.policyMask, 1);
    const directGroup = (await pool.query(`INSERT INTO team_access_groups
      (team_id, name, created_by_user_id)
      VALUES ($1, 'Direct SQL revision', $2) RETURNING id`,
    [team, user])).rows[0].id;
    await assert.rejects(access.commitAccessChange({ ...previewInput,
      token: preview.token, idempotencyKey: `access:stale-preview:${suffix}` }),
    /access_preview_conflict/);
    preview = await access.previewAccessChange(previewInput);
    const directWriter = await pool.connect();
    try {
      await directWriter.query("BEGIN");
      await directWriter.query(`UPDATE team_access_groups
        SET name = 'Concurrent SQL revision', version = version + 1
        WHERE id = $1`, [directGroup]);
      const concurrentCommit = access.commitAccessChange({ ...previewInput,
        token: preview.token, idempotencyKey: `access:sql-race:${suffix}` });
      await new Promise((resolve) => setTimeout(resolve, 30));
      await directWriter.query("COMMIT");
      await assert.rejects(concurrentCommit, /access_preview_conflict/);
    } finally {
      await directWriter.query("ROLLBACK").catch(() => {});
      directWriter.release();
    }
    preview = await access.previewAccessChange(previewInput);
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
      subjectUserID: viewer })).policyEffective.policyMask, 1);
    const viewerResources = await access.listResourcesByPrincipal({ actorUserID: user,
      actorDeviceID: device, teamID: team, vaultID: vault, principalKind: "USER",
      principalID: viewer, limit: 50 });
    assert.equal(viewerResources.rows.some((row) => row.resourceID === host), true);
    assert.equal(viewerResources.rows.some((row) => row.resourceID === snippet), true);
    assert.equal(Object.hasOwn(viewerResources.rows.find((row) => row.resourceID === host),
      "deviceUsability"), false);
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
    assert.equal(viewerDelta.before.policyEffective.policyMask, 1);
    assert.equal(viewerDelta.after.policyEffective.policyMask, 0);
    const policyVersionBeforeMove = Number((await pool.query(
      `SELECT access_policy_version FROM shared_vaults WHERE id = $1`, [vault],
    )).rows[0].access_policy_version);
    const moved = await access.commitAccessChange({ ...moveInput,
      token: movePreview.token, idempotencyKey: `access:move:${suffix}` });
    assert.equal(moved.applied, 1);
    assert.equal(Number((await pool.query(
      `SELECT access_policy_version FROM shared_vaults WHERE id = $1`, [vault],
    )).rows[0].access_policy_version), policyVersionBeforeMove + 1);
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
    const ownerMembership = (await pool.query(`SELECT id FROM team_memberships
      WHERE team_id = $1 AND user_id = $2 AND revoked_at IS NULL`,
    [team, user])).rows[0].id;
    await access.addAccessGroupMember({ actorUserID: user, actorDeviceID: device,
      teamID: team, vaultID: vault, groupID: created.group.id,
      targetMembershipID: ownerMembership,
      idempotencyKey: `access:owner-member:${suffix}` });
    const admin = (await pool.query(`INSERT INTO users
      (email, username, display_name, email_verified_at)
      VALUES ($1, $2, 'Access admin', now()) RETURNING id`,
    [`access-admin-${suffix}@example.com`, `access_admin_${suffix}`])).rows[0].id;
    const adminDevice = randomUUID();
    await pool.query(`INSERT INTO devices (id, user_id, name, platform, public_key,
      public_key_algorithm, key_registered_at, key_approved_at)
      VALUES ($1, $2, 'Admin browser', 'web', $3, 'p256-ecdh-v1', now(), now())`,
    [adminDevice, admin, JSON.stringify({ kty: "EC", crv: "P-256",
      x: "A".repeat(43), y: "B".repeat(43), ext: true, key_ops: [] })]);
    const adminMembership = (await pool.query(`INSERT INTO team_memberships
      (team_id, user_id, role) VALUES ($1, $2, 'admin') RETURNING id`,
    [team, admin])).rows[0].id;
    const authorityProbe = randomUUID();
    await pool.query(`INSERT INTO vault_resource_registry
      (id, team_id, vault_id, policy_class, policy_kind)
      VALUES ($1, $2, $3, 'general', 'HOST')`,
    [authorityProbe, team, vault]);
    await pool.query(`INSERT INTO vault_access_grants
      (team_id, vault_id, principal_kind, principal_id, membership_id,
       membership_epoch, target_kind, target_id, permission_mask,
       created_by_user_id)
      SELECT $1, $2, 'USER', membership.user_id, membership.id,
        membership.epoch, 'RESOURCE', $3, 8, $4
      FROM team_memberships AS membership WHERE membership.id IN ($5, $6)`,
    [team, vault, authorityProbe, user, viewerMembership, adminMembership]);
    await assert.rejects(access.createAccessGroup({ actorUserID: viewer,
      actorDeviceID: viewerDevice, teamID: team, vaultID: vault,
      name: 'Unauthorized', idempotencyKey: `access:viewer-managed:${suffix}` }),
    /team_access_denied/);
    assert.equal((await access.listAccessGroups({ actorUserID: admin,
      actorDeviceID: adminDevice, teamID: team })).rows.some(
      (row) => row.id === created.group.id), true);
    await pool.query(`INSERT INTO vault_access_grants
      (team_id, vault_id, principal_kind, principal_id, membership_id,
       membership_epoch, target_kind, target_id, permission_mask,
       created_by_user_id)
      VALUES ($1, $2, 'USER', $3, $4, 1, 'FOLDER', $5, 1, $3)`,
    [team, vault, user, ownerMembership, folderA]);
    const adminMoveRequest = { changes: [{ type: "RESOURCE_MOVE",
      resourceID: forwarding, newParentFolderID: folderA,
      expectedResourceVersion: 2 }] };
    await assert.rejects(access.previewAccessChange({ actorUserID: admin,
      actorDeviceID: adminDevice, teamID: team, vaultID: vault,
      request: adminMoveRequest, sessionSecret: "test-session-secret" }),
    /team_access_denied/);
    assert.equal((await pool.query(`SELECT parent_folder_id
      FROM vault_resource_registry WHERE id = $1`,
    [forwarding])).rows[0].parent_folder_id, folderB);
    await assert.rejects(access.deleteAccessGroup({ actorUserID: admin,
      actorDeviceID: adminDevice, teamID: team, vaultID: vault,
      groupID: created.group.id, expectedVersion: 2,
      idempotencyKey: `access:admin-owner-delete:${suffix}` }),
    /team_access_denied/);
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
    const unadmittedDevice = randomUUID();
    await pool.query(`INSERT INTO devices (id, user_id, name, platform, public_key,
      public_key_algorithm, key_registered_at, key_approved_at)
      VALUES ($1, $2, 'Unadmitted viewer browser', 'web', $3,
        'p256-ecdh-v1', now(), now())`,
    [unadmittedDevice, viewer, JSON.stringify({ kty: "EC", crv: "P-256",
      x: "A".repeat(43), y: "B".repeat(43), ext: true, key_ops: [] })]);
    const policyVersion = (await pool.query(`SELECT access_policy_version
      FROM shared_vaults WHERE id = $1`, [vault])).rows[0].access_policy_version;
    const registryVersion = (await pool.query(`SELECT resource_version
      FROM vault_resource_registry WHERE id = $1`, [host])).rows[0].resource_version;
    await pool.query(`INSERT INTO vault_resource_ciphertext_versions
      (team_id, vault_id, resource_id, part, key_version, policy_version,
       registry_version, resource_version, manifest_version, nonce,
       ciphertext, auth_tag)
      VALUES ($1, $2, $3, 'GENERAL', 1, $4, $5, $5, 1, $6, $7, $8)`,
    [team, vault, host, policyVersion, registryVersion,
      "A".repeat(16), "B".repeat(24), "C".repeat(22)]);
    const admitted = await pool.query(`SELECT admission.membership_id,
      admission.membership_epoch, admission.device_id
      FROM team_membership_device_admissions AS admission
      JOIN team_memberships AS membership ON membership.id = admission.membership_id
        AND membership.epoch = admission.membership_epoch
        AND membership.team_id = $1 AND membership.revoked_at IS NULL
      JOIN devices AS device ON device.id = admission.device_id
        AND device.revoked_at IS NULL`, [team]);
    for (const recipient of admitted.rows) {
      await pool.query(`INSERT INTO vault_resource_key_wrappers_v2
        (team_id, vault_id, resource_id, part, key_version, membership_id,
         membership_epoch, device_id, ephemeral_public_key, nonce,
         ciphertext, auth_tag)
        VALUES ($1, $2, $3, 'GENERAL', 1, $4, $5, $6, $7, $8, $9, $10)`,
      [team, vault, host, recipient.membership_id, recipient.membership_epoch,
        recipient.device_id, JSON.stringify({ kty: "EC", crv: "P-256",
          x: "A".repeat(43), y: "B".repeat(43) }),
        "A".repeat(16), "B".repeat(43), "C".repeat(22)]);
    }
    await pool.query(`UPDATE vault_resource_ciphertext_versions
      SET lifecycle = 'PUBLISHED' WHERE vault_id = $1 AND resource_id = $2`,
    [vault, host]);
    await pool.query(`INSERT INTO vault_resource_manifest_pointers_v2
      (team_id, vault_id, resource_id, part, key_version, manifest_version)
      VALUES ($1, $2, $3, 'GENERAL', 1, 1)`, [team, vault, host]);
    const scope = { actorUserID: user, actorDeviceID: device,
      teamID: team, vaultID: vault, resourceID: host, subjectUserID: viewer };
    const principalOnly = await access.getEffectiveAccess(scope);
    const wrapped = await access.getEffectiveAccess({ ...scope,
      subjectDeviceID: viewerDevice });
    const unadmitted = await access.getEffectiveAccess({ ...scope,
      subjectDeviceID: unadmittedDevice });
    const foreignDevice = await access.getEffectiveAccess({ ...scope,
      subjectDeviceID: device });
    const missingDevice = await access.getEffectiveAccess({ ...scope,
      subjectDeviceID: randomUUID() });
    assert.deepEqual(wrapped.policyEffective, principalOnly.policyEffective);
    assert.deepEqual(unadmitted.policyEffective, principalOnly.policyEffective);
    assert.equal(wrapped.deviceUsability.effectiveUsable, "UNKNOWN");
    assert.equal(wrapped.deviceUsability.cryptoAvailableByPermission.View,
      "WRAP_PRESENT_UNVERIFIED");
    assert.equal(unadmitted.deviceUsability.effectiveUsable, "NO");
    assert.deepEqual(unadmitted.deviceUsability.blockedReasons,
      ["DEVICE_NOT_ADMITTED"]);
    assert.deepEqual(foreignDevice.deviceUsability.blockedReasons,
      ["DEVICE_NOT_ADMITTED"]);
    assert.deepEqual(missingDevice.deviceUsability.blockedReasons,
      ["DEVICE_NOT_ADMITTED"]);
  } finally {
    await pool.end();
  }
});
