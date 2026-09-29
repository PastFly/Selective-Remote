import { createHash } from "node:crypto";
import { requireAccessMutation, validateIdempotencyKey } from "./team-policy.mjs";
import { applyGrantChanges, compileEffectiveAccess } from "./effective-access.mjs";
import { permissionBits, requiredCryptoParts, usabilityByPermission, validateGrant } from "./access-policy.mjs";
import { createPreviewToken, hashAccessRequest, validateAccessChangeRequest,
  verifyPreviewToken } from "./access-preview.mjs";

function accessGroupName(value) {
  const name = String(value ?? "").trim();
  if (!name || name.length > 120 || /[\u0000-\u001f\u007f]/u.test(name)) {
    throw new Error("invalid_access_group_name");
  }
  return name;
}

function requestHash(value) {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;

async function readAccessActor(client, { actorUserID, actorDeviceID, teamID }) {
  // Read actor first so outsiders cannot distinguish an existing V1 Vault from an absent one.
  const actor = await client.query(
    `SELECT membership.id, membership.role, membership.epoch
     FROM team_memberships AS membership
     JOIN teams AS team ON team.id = membership.team_id AND team.archived_at IS NULL
     JOIN devices AS device ON device.id = $3 AND device.user_id = membership.user_id
       AND device.revoked_at IS NULL AND device.public_key IS NOT NULL
       AND device.public_key_algorithm = 'p256-ecdh-v1'
     LEFT JOIN team_membership_device_admissions AS admission
       ON admission.membership_id = membership.id
      AND admission.membership_epoch = membership.epoch AND admission.device_id = device.id
     WHERE membership.team_id = $1 AND membership.user_id = $2
       AND membership.revoked_at IS NULL
       AND (device.key_approved_at IS NOT NULL OR admission.device_id IS NOT NULL)`,
    [teamID, actorUserID, actorDeviceID],
  );
  if (!actor.rows[0]) throw new Error("team_not_found");
  requireAccessMutation(actor.rows[0].role);
  return actor.rows[0];
}

async function requirePreparingActor(client, input, relatedVaultIDs = []) {
  const { actorUserID, actorDeviceID, teamID, vaultID } = input;
  const actor = await readAccessActor(client, input);
  const vaultIDs = [...new Set([vaultID, ...relatedVaultIDs])].sort();
  for (const id of vaultIDs) {
    const vault = await client.query(
      `SELECT id, format_state, format_schema_version FROM shared_vaults
       WHERE id = $1 AND team_id = $2 AND archived_at IS NULL FOR UPDATE`,
      [id, teamID],
    );
    if (!vault.rows[0]) throw new Error("access_policy_conflict");
    if (id === vaultID && (vault.rows[0].format_state !== "V2_PREPARING"
      || Number(vault.rows[0].format_schema_version) !== 2)) {
      throw new Error("access_v2_preparing_required");
    }
  }
  const current = await client.query(
    `SELECT membership.id, membership.role, membership.epoch
     FROM team_memberships AS membership
     JOIN teams AS team ON team.id = membership.team_id AND team.archived_at IS NULL
     JOIN devices AS device ON device.id = $3 AND device.user_id = membership.user_id
       AND device.revoked_at IS NULL AND device.public_key IS NOT NULL
       AND device.public_key_algorithm = 'p256-ecdh-v1'
     LEFT JOIN team_membership_device_admissions AS admission
       ON admission.membership_id = membership.id
      AND admission.membership_epoch = membership.epoch AND admission.device_id = device.id
     WHERE membership.team_id = $1 AND membership.user_id = $2
       AND membership.revoked_at IS NULL
       AND (device.key_approved_at IS NOT NULL OR admission.device_id IS NOT NULL)
     FOR UPDATE OF membership, team, device`,
    [teamID, actorUserID, actorDeviceID],
  );
  if (!current.rows[0] || current.rows[0].id !== actor.id
    || current.rows[0].epoch !== actor.epoch) throw new Error("team_not_found");
  requireAccessMutation(current.rows[0].role);
  return current.rows[0];
}

export class AccessStore {
  constructor(pool) { this.pool = pool; }

  async withMutation({ actorUserID, idempotencyKey, operation, request }, action,
    attempt = 0) {
    validateIdempotencyKey(idempotencyKey);
    const client = await this.pool.connect();
    const hash = requestHash(request);
    let retry = false;
    try {
      await client.query("BEGIN");
      const reservation = await client.query(
        `INSERT INTO team_access_mutation_receipts
           (actor_user_id, operation, idempotency_key, request_sha256)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (actor_user_id, operation, idempotency_key) DO NOTHING
         RETURNING actor_user_id`,
        [actorUserID, operation, idempotencyKey, hash],
      );
      if (!reservation.rows[0]) {
        const replay = await client.query(
          `SELECT request_sha256, response FROM team_access_mutation_receipts
           WHERE actor_user_id = $1 AND operation = $2 AND idempotency_key = $3`,
          [actorUserID, operation, idempotencyKey],
        );
        if (replay.rows[0]?.request_sha256 !== hash) {
          throw new Error("access_idempotency_conflict");
        }
        await requirePreparingActor(client, request);
        await client.query("COMMIT");
        return replay.rows[0].response;
      }
      const result = await action(client);
      await client.query(
        `UPDATE team_access_mutation_receipts SET response = $4::jsonb
         WHERE actor_user_id = $1 AND operation = $2 AND idempotency_key = $3`,
        [actorUserID, operation, idempotencyKey, JSON.stringify(result)],
      );
      await client.query("COMMIT");
      return result;
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      if (["40P01", "40001"].includes(error?.code) && attempt < 2) retry = true;
      else throw error;
    } finally {
      client.release();
    }
    if (retry) {
      return this.withMutation({ actorUserID, idempotencyKey, operation, request },
        action, attempt + 1);
    }
  }

  async createAccessGroup(input) {
    const name = accessGroupName(input?.name);
    const { actorUserID, actorDeviceID, teamID, vaultID, idempotencyKey } = input;
    const request = { actorUserID, actorDeviceID, teamID, vaultID, name };
    return this.withMutation({ actorUserID, idempotencyKey,
      operation: "access.group.create", request }, async (client) => {
      await requirePreparingActor(client, input);
      const inserted = await client.query(
        `INSERT INTO team_access_groups (team_id, name, created_by_user_id)
         VALUES ($1, $2, $3)
         RETURNING id, team_id, name, version, created_at`,
        [teamID, name, actorUserID],
      );
      const group = inserted.rows[0];
      await client.query(
        `INSERT INTO team_audit_events
           (team_id, actor_user_id, action, metadata)
         VALUES ($1, $2, 'group.created', $3::jsonb)`,
        [teamID, actorUserID, JSON.stringify({ groupID: group.id })],
      );
      return { group };
    });
  }

  async listAccessGroups({ actorUserID, actorDeviceID, teamID, limit = 50, cursor = null }) {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 50
      || (cursor !== null && !uuidPattern.test(cursor))) {
      throw new Error("invalid_access_page");
    }
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY");
      await readAccessActor(client, { actorUserID, actorDeviceID, teamID });
      const page = await client.query(
        `SELECT id, team_id, name, version, created_at, updated_at
         FROM team_access_groups WHERE team_id = $1 AND deleted_at IS NULL
           AND ($2::uuid IS NULL OR id > $2::uuid)
         ORDER BY id LIMIT $3`,
        [teamID, cursor, limit + 1],
      );
      await client.query("COMMIT");
      const rows = page.rows.slice(0, limit);
      return { rows, nextCursor: page.rows.length > limit ? rows.at(-1).id : null };
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  async listAccessGrants({ actorUserID, actorDeviceID, teamID, vaultID,
    limit = 50, cursor = null }) {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 50
      || (cursor !== null && !uuidPattern.test(cursor))) {
      throw new Error("invalid_access_page");
    }
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY");
      await readAccessActor(client, { actorUserID, actorDeviceID, teamID });
      const vault = await client.query(
        `SELECT 1 FROM shared_vaults WHERE id = $1 AND team_id = $2
           AND archived_at IS NULL AND format_state = 'V2_PREPARING'
           AND format_schema_version = 2`,
        [vaultID, teamID],
      );
      if (!vault.rows[0]) throw new Error("access_v2_preparing_required");
      const page = await client.query(
        `SELECT id, principal_kind, principal_id, target_kind, target_id,
           permission_mask, version, created_at, updated_at
         FROM vault_access_grants WHERE team_id = $1 AND vault_id = $2
           AND revoked_at IS NULL AND ($3::uuid IS NULL OR id > $3::uuid)
         ORDER BY id LIMIT $4`,
        [teamID, vaultID, cursor, limit + 1],
      );
      const rows = page.rows.slice(0, limit);
      await client.query("COMMIT");
      return { rows, nextCursor: page.rows.length > limit ? rows.at(-1).id : null };
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  async listWhoHasAccess({ actorUserID, actorDeviceID, teamID, vaultID,
    resourceID, limit = 50, cursor = null }) {
    if (!uuidPattern.test(resourceID ?? "")) throw new Error("invalid_access_resource");
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 50
      || (cursor !== null && !uuidPattern.test(cursor))) {
      throw new Error("invalid_access_page");
    }
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY");
      await readAccessActor(client, { actorUserID, actorDeviceID, teamID });
      const vault = await client.query(
        `SELECT 1 FROM shared_vaults WHERE id = $1 AND team_id = $2
           AND archived_at IS NULL AND format_state = 'V2_PREPARING'
           AND format_schema_version = 2`,
        [vaultID, teamID],
      );
      if (!vault.rows[0]) throw new Error("access_v2_preparing_required");
      const members = await client.query(
        `SELECT user_id FROM team_memberships WHERE team_id = $1
           AND revoked_at IS NULL AND ($2::uuid IS NULL OR user_id > $2::uuid)
         ORDER BY user_id LIMIT $3`,
        [teamID, cursor, limit + 1],
      );
      const rows = [];
      for (const member of members.rows.slice(0, limit)) {
        const access = await this.readEffectiveAccessInSnapshot(client, {
          actorUserID, actorDeviceID, teamID, vaultID, resourceID,
          subjectUserID: member.user_id,
        });
        if (access.policyAllowed) rows.push({ userID: member.user_id,
          policyMask: access.policyMask, effectiveUsable: access.effectiveUsable,
          paths: access.paths });
      }
      await client.query("COMMIT");
      return { rows, nextCursor: members.rows.length > limit
        ? members.rows[limit - 1].user_id : null };
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  async listResourcesByPrincipal({ actorUserID, actorDeviceID, teamID, vaultID,
    principalKind, principalID, limit = 50, cursor = null }) {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 50
      || (cursor !== null && !uuidPattern.test(cursor))) {
      throw new Error("invalid_access_page");
    }
    if (!["USER", "GROUP"].includes(principalKind)
      || !uuidPattern.test(principalID ?? "")) throw new Error("invalid_access_request");
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY");
      await readAccessActor(client, { actorUserID, actorDeviceID, teamID });
      const vault = await client.query(
        `SELECT 1 FROM shared_vaults WHERE id = $1 AND team_id = $2
           AND archived_at IS NULL AND format_state = 'V2_PREPARING'
           AND format_schema_version = 2`,
        [vaultID, teamID],
      );
      if (!vault.rows[0]) throw new Error("access_v2_preparing_required");
      if (principalKind === "GROUP") {
        const group = await client.query(
          `SELECT 1 FROM team_access_groups WHERE id = $1 AND team_id = $2
             AND deleted_at IS NULL`, [principalID, teamID],
        );
        if (!group.rows[0]) throw new Error("access_group_not_found");
      }
      const page = await client.query(
        `SELECT id, team_id, vault_id, policy_kind, parent_folder_id, deleted_at
         FROM vault_resource_registry WHERE team_id = $1 AND vault_id = $2
           AND deleted_at IS NULL AND policy_kind IS NOT NULL
           AND ($3::uuid IS NULL OR id > $3::uuid)
         ORDER BY id LIMIT $4`,
        [teamID, vaultID, cursor, limit + 1],
      );
      const rows = [];
      for (const resource of page.rows.slice(0, limit)) {
        if (principalKind === "USER") {
          const access = await this.readEffectiveAccessInSnapshot(client, {
            actorUserID, actorDeviceID, teamID, vaultID,
            resourceID: resource.id, subjectUserID: principalID,
          });
          if (access.policyAllowed) rows.push({ resourceID: resource.id,
            policyMask: access.policyMask, paths: access.paths,
            effectiveUsable: access.effectiveUsable });
          continue;
        }
        const ancestorRows = await client.query(
          `WITH RECURSIVE path AS (
             SELECT id, team_id, vault_id, policy_kind, parent_folder_id,
               deleted_at, 1 AS depth, ARRAY[id] AS seen
             FROM vault_resource_registry WHERE team_id = $1 AND vault_id = $2
               AND id = $3
             UNION ALL
             SELECT parent.id, parent.team_id, parent.vault_id, parent.policy_kind,
               parent.parent_folder_id, parent.deleted_at, path.depth + 1,
               path.seen || parent.id
             FROM vault_resource_registry AS parent
             JOIN path ON parent.id = path.parent_folder_id
             WHERE parent.team_id = $1 AND parent.vault_id = $2 AND path.depth < 64
               AND NOT parent.id = ANY(path.seen)
           ) SELECT id, team_id, vault_id, policy_kind, parent_folder_id,
               deleted_at FROM path ORDER BY depth`,
          [teamID, vaultID, resource.parent_folder_id],
        );
        const target = { id: resource.id, teamID, vaultID,
          kind: resource.policy_kind, parentFolderID: resource.parent_folder_id,
          deletedAt: resource.deleted_at };
        const ancestors = ancestorRows.rows.map((item) => ({ id: item.id,
          teamID: item.team_id, vaultID: item.vault_id,
          kind: item.policy_kind, parentFolderID: item.parent_folder_id,
          deletedAt: item.deleted_at }));
        const grants = await client.query(
          `SELECT id, team_id, vault_id, principal_kind, principal_id,
             target_kind, target_id, permission_mask, revoked_at
           FROM vault_access_grants WHERE team_id = $1 AND vault_id = $2
             AND principal_kind = 'GROUP' AND principal_id = $3
             AND revoked_at IS NULL
             AND ((target_kind = 'VAULT' AND target_id = $2)
               OR (target_kind = 'FOLDER' AND target_id = ANY($4::uuid[]))
               OR (target_kind = $5 AND target_id = $6))
           ORDER BY id LIMIT 1001`,
          [teamID, vaultID, principalID, ancestors.map((item) => item.id),
            resource.policy_kind === "FOLDER" ? "FOLDER" : "RESOURCE", resource.id],
        );
        if (grants.rows.length > 1000) throw new Error("access_result_too_large");
        const access = compileEffectiveAccess({ target, ancestors,
          membership: { id: "group-policy", userID: "group-policy", epoch: 1 },
          groupIDs: [principalID], cryptoStatus: "NO", requiresCrypto: true,
          grants: grants.rows.map((item) => ({ id: item.id, teamID: item.team_id,
            vaultID: item.vault_id, principalKind: item.principal_kind,
            principalID: item.principal_id, targetKind: item.target_kind,
            targetID: item.target_id, mask: item.permission_mask,
            revokedAt: item.revoked_at })) });
        if (access.policyAllowed) rows.push({ resourceID: resource.id,
          policyMask: access.policyMask, paths: access.paths });
      }
      await client.query("COMMIT");
      return { rows, nextCursor: page.rows.length > limit
        ? page.rows[limit - 1].id : null };
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  async renameAccessGroup(input) {
    const name = accessGroupName(input?.name);
    const { actorUserID, actorDeviceID, teamID, vaultID, groupID,
      expectedVersion, idempotencyKey } = input;
    if (!Number.isSafeInteger(expectedVersion) || expectedVersion < 1) {
      throw new Error("invalid_access_version");
    }
    const request = { actorUserID, actorDeviceID, teamID, vaultID, groupID,
      expectedVersion, name };
    return this.withMutation({ actorUserID, idempotencyKey,
      operation: "access.group.rename", request }, async (client) => {
      await requirePreparingActor(client, input);
      const changed = await client.query(
        `UPDATE team_access_groups SET name = $3, version = version + 1, updated_at = now()
         WHERE id = $1 AND team_id = $2 AND deleted_at IS NULL AND version = $4
         RETURNING id, team_id, name, version, created_at, updated_at`,
        [groupID, teamID, name, expectedVersion],
      );
      if (!changed.rows[0]) throw new Error("access_policy_conflict");
      await client.query(
        `INSERT INTO team_audit_events (team_id, actor_user_id, action, metadata)
         VALUES ($1, $2, 'group.renamed', $3::jsonb)`,
        [teamID, actorUserID, JSON.stringify({ groupID })],
      );
      return { group: changed.rows[0] };
    });
  }

  async addAccessGroupMember(input) {
    const { actorUserID, actorDeviceID, teamID, vaultID, groupID,
      targetMembershipID, idempotencyKey } = input;
    if (!uuidPattern.test(targetMembershipID ?? "")) {
      throw new Error("invalid_access_membership");
    }
    const request = { actorUserID, actorDeviceID, teamID, vaultID, groupID,
      targetMembershipID };
    return this.withMutation({ actorUserID, idempotencyKey,
      operation: "access.group.member.add", request }, async (client) => {
      const actor = await requirePreparingActor(client, input);
      const target = await client.query(
        `SELECT id, user_id, role, epoch FROM team_memberships
         WHERE id = $1 AND team_id = $2 AND revoked_at IS NULL FOR UPDATE`,
        [targetMembershipID, teamID],
      );
      if (!target.rows[0]) throw new Error("team_not_found");
      requireAccessMutation(actor.role, target.rows[0].role);
      const group = await client.query(
        `SELECT id FROM team_access_groups WHERE id = $1 AND team_id = $2
         AND deleted_at IS NULL FOR UPDATE`,
        [groupID, teamID],
      );
      if (!group.rows[0]) throw new Error("access_group_not_found");
      const member = (await client.query(
        `INSERT INTO team_access_group_members
           (team_id, group_id, user_id, membership_id, membership_epoch,
            created_by_user_id)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING id, group_id, user_id, membership_id, membership_epoch, version`,
        [teamID, groupID, target.rows[0].user_id, targetMembershipID,
          target.rows[0].epoch, actorUserID],
      )).rows[0];
      await client.query(
        `INSERT INTO team_audit_events
           (team_id, actor_user_id, action, target_user_id, target_membership_id, metadata)
         VALUES ($1, $2, 'group.member.added', $3, $4, $5::jsonb)`,
        [teamID, actorUserID, member.user_id, targetMembershipID,
          JSON.stringify({ groupID })],
      );
      return { member };
    });
  }

  async removeAccessGroupMember(input) {
    const { actorUserID, actorDeviceID, teamID, vaultID, groupID, edgeID,
      expectedVersion, idempotencyKey } = input;
    if (!uuidPattern.test(edgeID ?? "") || !Number.isSafeInteger(expectedVersion)
      || expectedVersion < 1) throw new Error("invalid_access_membership");
    const request = { actorUserID, actorDeviceID, teamID, vaultID, groupID,
      edgeID, expectedVersion };
    return this.withMutation({ actorUserID, idempotencyKey,
      operation: "access.group.member.remove", request }, async (client) => {
      const actor = await requirePreparingActor(client, input);
      const edge = await client.query(
        `SELECT edge.id, member.role FROM team_access_group_members AS edge
         JOIN team_memberships AS member ON member.id = edge.membership_id
         WHERE edge.id = $1 AND edge.group_id = $2 AND edge.team_id = $3
           AND edge.removed_at IS NULL AND edge.version = $4
         FOR UPDATE OF edge, member`,
        [edgeID, groupID, teamID, expectedVersion],
      );
      if (!edge.rows[0]) throw new Error("access_policy_conflict");
      requireAccessMutation(actor.role, edge.rows[0].role);
      await client.query(
        `UPDATE team_access_group_members
         SET removed_at = now(), version = version + 1 WHERE id = $1`,
        [edgeID],
      );
      await client.query(
        `INSERT INTO team_audit_events
           (team_id, actor_user_id, action, metadata)
         VALUES ($1, $2, 'group.member.removed', $3::jsonb)`,
        [teamID, actorUserID, JSON.stringify({ groupID, edgeID })],
      );
      return { removed: true, edgeID };
    });
  }

  async deleteAccessGroup(input) {
    const { actorUserID, actorDeviceID, teamID, vaultID, groupID,
      expectedVersion, idempotencyKey } = input;
    if (!Number.isSafeInteger(expectedVersion) || expectedVersion < 1) {
      throw new Error("invalid_access_version");
    }
    const request = { actorUserID, actorDeviceID, teamID, vaultID, groupID,
      expectedVersion };
    return this.withMutation({ actorUserID, idempotencyKey,
      operation: "access.group.delete", request }, async (client) => {
      await readAccessActor(client, input);
      const context = await client.query(
        `SELECT 1 FROM shared_vaults WHERE id = $1 AND team_id = $2
           AND archived_at IS NULL AND format_state = 'V2_PREPARING'
           AND format_schema_version = 2`,
        [vaultID, teamID],
      );
      if (!context.rows[0]) throw new Error("access_v2_preparing_required");
      const previewGrants = await client.query(
        `SELECT id, vault_id FROM vault_access_grants
         WHERE team_id = $1 AND principal_kind = 'GROUP'
           AND principal_id = $2 AND revoked_at IS NULL
         ORDER BY vault_id, id LIMIT 1001`,
        [teamID, groupID],
      );
      if (previewGrants.rows.length > 1000) {
        return { deleted: false, code: "group_grants_must_be_revoked_first",
          safeCount: "1001+" };
      }
      const relatedVaultIDs = [...new Set(previewGrants.rows.map((row) => row.vault_id))];
      const actor = await requirePreparingActor(client, input, relatedVaultIDs);
      await client.query(
        `INSERT INTO team_policy_revisions (team_id) VALUES ($1) ON CONFLICT DO NOTHING`,
        [teamID],
      );
      await client.query(
        `SELECT revision FROM team_policy_revisions WHERE team_id = $1 FOR UPDATE`,
        [teamID],
      );
      const currentGrants = await client.query(
        `SELECT id, vault_id FROM vault_access_grants
         WHERE team_id = $1 AND principal_kind = 'GROUP'
           AND principal_id = $2 AND revoked_at IS NULL
         ORDER BY vault_id, id LIMIT 1001`,
        [teamID, groupID],
      );
      if (currentGrants.rows.length > 1000) {
        return { deleted: false, code: "group_grants_must_be_revoked_first",
          safeCount: "1001+" };
      }
      if (currentGrants.rows.some((row) => !relatedVaultIDs.includes(row.vault_id))) {
        throw new Error("access_policy_conflict");
      }
      const affectedMembers = await client.query(
        `SELECT member.role FROM team_access_group_members AS edge
         JOIN team_memberships AS member ON member.id = edge.membership_id
           AND member.team_id = edge.team_id AND member.user_id = edge.user_id
           AND member.epoch = edge.membership_epoch AND member.revoked_at IS NULL
         WHERE edge.team_id = $1 AND edge.group_id = $2
           AND edge.removed_at IS NULL FOR SHARE OF member`,
        [teamID, groupID],
      );
      for (const member of affectedMembers.rows) {
        requireAccessMutation(actor.role, member.role);
      }
      const group = await client.query(
        `SELECT id FROM team_access_groups WHERE id = $1 AND team_id = $2
           AND deleted_at IS NULL AND version = $3 FOR UPDATE`,
        [groupID, teamID, expectedVersion],
      );
      if (!group.rows[0]) throw new Error("access_policy_conflict");
      await client.query(
        `UPDATE vault_access_grants SET revoked_at = now(), version = version + 1
         WHERE team_id = $1 AND principal_kind = 'GROUP'
           AND principal_id = $2 AND revoked_at IS NULL`,
        [teamID, groupID],
      );
      await client.query(
        `UPDATE team_access_group_members SET removed_at = now(), version = version + 1
         WHERE team_id = $1 AND group_id = $2 AND removed_at IS NULL`,
        [teamID, groupID],
      );
      await client.query(
        `UPDATE team_access_groups SET deleted_at = now(), updated_at = now(),
           version = version + 1 WHERE id = $1 AND team_id = $2`,
        [groupID, teamID],
      );
      await client.query(
        `INSERT INTO team_audit_events (team_id, actor_user_id, action, metadata)
         VALUES ($1, $2, 'group.deleted', $3::jsonb)`,
        [teamID, actorUserID, JSON.stringify({ groupID,
          revokedGrants: currentGrants.rows.length })],
      );
      return { deleted: true, groupID,
        revokedGrants: currentGrants.rows.length };
    });
  }

  async getEffectiveAccess(input) {
    if (!uuidPattern.test(input?.resourceID ?? "")) throw new Error("invalid_access_resource");
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY");
      const result = await this.readEffectiveAccessInSnapshot(client, input);
      await client.query("COMMIT");
      return result;
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  async readEffectiveAccessInSnapshot(client, input, changes = [], parentOverrides = new Map()) {
    const { teamID, vaultID, resourceID, subjectUserID } = input;
    await readAccessActor(client, input);
    const vault = await client.query(
      `SELECT id FROM shared_vaults WHERE id = $1 AND team_id = $2
         AND archived_at IS NULL AND format_state = 'V2_PREPARING'
         AND format_schema_version = 2`,
      [vaultID, teamID],
    );
    if (!vault.rows[0]) throw new Error("access_v2_preparing_required");
    const subject = await client.query(
      `SELECT id, user_id, epoch FROM team_memberships
       WHERE team_id = $1 AND user_id = $2 AND revoked_at IS NULL`,
      [teamID, subjectUserID],
    );
    if (!subject.rows[0]) throw new Error("team_not_found");
    const membership = { id: subject.rows[0].id,
      userID: subject.rows[0].user_id, epoch: Number(subject.rows[0].epoch) };
    const row = await client.query(
      `SELECT id, team_id, vault_id, policy_kind, parent_folder_id, deleted_at
       FROM vault_resource_registry WHERE id = $1 AND team_id = $2 AND vault_id = $3
         AND deleted_at IS NULL`,
      [resourceID, teamID, vaultID],
    );
    if (!row.rows[0]?.policy_kind) throw new Error("access_resource_not_found");
    const target = { id: row.rows[0].id, teamID: row.rows[0].team_id,
      vaultID: row.rows[0].vault_id, kind: row.rows[0].policy_kind,
      parentFolderID: parentOverrides.has(resourceID)
        ? parentOverrides.get(resourceID) : row.rows[0].parent_folder_id,
      deletedAt: row.rows[0].deleted_at };
    let ancestorRows;
    if (parentOverrides.size === 0) ancestorRows = await client.query(
      `WITH RECURSIVE path AS (
         SELECT id, team_id, vault_id, policy_kind, parent_folder_id, deleted_at,
           1 AS depth, ARRAY[id] AS seen
         FROM vault_resource_registry
         WHERE team_id = $1 AND vault_id = $2 AND id = $3
         UNION ALL
         SELECT parent.id, parent.team_id, parent.vault_id, parent.policy_kind,
           parent.parent_folder_id, parent.deleted_at, path.depth + 1,
           path.seen || parent.id
         FROM vault_resource_registry AS parent
         JOIN path ON parent.id = path.parent_folder_id
         WHERE parent.team_id = $1 AND parent.vault_id = $2
           AND path.depth < 64 AND NOT parent.id = ANY(path.seen)
       ) SELECT id, team_id, vault_id, policy_kind, parent_folder_id, deleted_at
         FROM path ORDER BY depth`,
      [teamID, vaultID, target.parentFolderID],
    );
    else {
      const rows = [];
      const seen = new Set([resourceID]);
      let nextID = target.parentFolderID;
      while (nextID !== null && rows.length < 64) {
        if (seen.has(nextID)) throw new Error("invalid_access_ancestry");
        seen.add(nextID);
        const parent = await client.query(
          `SELECT id, team_id, vault_id, policy_kind, parent_folder_id, deleted_at
           FROM vault_resource_registry WHERE id = $1 AND team_id = $2 AND vault_id = $3`,
          [nextID, teamID, vaultID],
        );
        if (!parent.rows[0]) throw new Error("invalid_access_ancestry");
        const item = { ...parent.rows[0], parent_folder_id:
          parentOverrides.has(nextID) ? parentOverrides.get(nextID)
            : parent.rows[0].parent_folder_id };
        rows.push(item);
        nextID = item.parent_folder_id;
      }
      if (nextID !== null) throw new Error("invalid_access_ancestry");
      ancestorRows = { rows };
    }
    const ancestors = ancestorRows.rows.map((item) => ({ id: item.id,
      teamID: item.team_id, vaultID: item.vault_id, kind: item.policy_kind,
      parentFolderID: item.parent_folder_id, deletedAt: item.deleted_at }));
    const groupRows = await client.query(
      `SELECT edge.group_id FROM team_access_group_members AS edge
       JOIN team_access_groups AS grp ON grp.id = edge.group_id
         AND grp.team_id = edge.team_id AND grp.deleted_at IS NULL
       WHERE edge.team_id = $1 AND edge.user_id = $2
         AND edge.membership_id = $3 AND edge.membership_epoch = $4
         AND edge.removed_at IS NULL`,
      [teamID, membership.userID, membership.id, membership.epoch],
    );
    const groupIDs = groupRows.rows.map((item) => item.group_id);
    const grantRows = await client.query(
      `SELECT id, team_id, vault_id, principal_kind, principal_id,
         membership_id, membership_epoch, target_kind, target_id,
         permission_mask, revoked_at
       FROM vault_access_grants WHERE team_id = $1 AND vault_id = $2
         AND revoked_at IS NULL
         AND ((principal_kind = 'USER' AND principal_id = $3
             AND membership_id = $4 AND membership_epoch = $5)
           OR (principal_kind = 'GROUP' AND principal_id = ANY($6::uuid[])))
         AND ((target_kind = 'VAULT' AND target_id = $2)
           OR (target_kind = 'FOLDER' AND target_id = ANY($7::uuid[]))
           OR (target_kind = $8 AND target_id = $9))
       ORDER BY id LIMIT 1001`,
      [teamID, vaultID, membership.userID, membership.id, membership.epoch,
        groupIDs, ancestors.map((item) => item.id),
        target.kind === "FOLDER" ? "FOLDER" : "RESOURCE", resourceID],
    );
    if (grantRows.rows.length > 1000) throw new Error("access_result_too_large");
    const storedGrants = grantRows.rows.map((item) => ({ id: item.id,
      teamID: item.team_id, vaultID: item.vault_id,
      principalKind: item.principal_kind, principalID: item.principal_id,
      membershipID: item.membership_id, membershipEpoch: item.membership_epoch,
      targetKind: item.target_kind, targetID: item.target_id,
      mask: item.permission_mask, revokedAt: item.revoked_at }));
    const grants = applyGrantChanges(storedGrants, changes, { strict: false });
    const wrapperRows = await client.query(
      `SELECT DISTINCT pointer.part FROM vault_resource_manifest_pointers_v2 AS pointer
       JOIN vault_resource_ciphertext_versions AS cipher
         ON cipher.team_id = pointer.team_id AND cipher.vault_id = pointer.vault_id
        AND cipher.resource_id = pointer.resource_id AND cipher.part = pointer.part
        AND cipher.key_version = pointer.key_version AND cipher.lifecycle = 'PUBLISHED'
       JOIN vault_resource_key_wrappers_v2 AS wrapper
         ON wrapper.team_id = pointer.team_id AND wrapper.vault_id = pointer.vault_id
        AND wrapper.resource_id = pointer.resource_id AND wrapper.part = pointer.part
        AND wrapper.key_version = pointer.key_version AND wrapper.obsolete_at IS NULL
       JOIN team_membership_device_admissions AS admission
         ON admission.membership_id = wrapper.membership_id
        AND admission.membership_epoch = wrapper.membership_epoch
        AND admission.device_id = wrapper.device_id
       JOIN devices AS device ON device.id = wrapper.device_id
         AND device.revoked_at IS NULL AND device.user_id = $4
       WHERE pointer.team_id = $1 AND pointer.vault_id = $2
         AND pointer.resource_id = $3 AND wrapper.membership_id = $5
         AND wrapper.membership_epoch = $6`,
      [teamID, vaultID, resourceID, membership.userID,
        membership.id, membership.epoch],
    );
    const availableParts = new Set(wrapperRows.rows.map((item) => item.part));
    // Derive crypto work from effective bits; ManageAccess alone needs no CEK.
    const policy = compileEffectiveAccess({ target, ancestors, membership,
      groupIDs, grants, cryptoStatus: "NO", requiresCrypto: false });
    const requiredParts = policy.policyMask
      ? requiredCryptoParts(target.kind, policy.policyMask) : [];
    const cryptoStatus = requiredParts.length > 0
      && requiredParts.every((part) => availableParts.has(part))
      ? "WRAP_PRESENT_UNVERIFIED" : "NO";
    const result = compileEffectiveAccess({ target, ancestors, membership,
      groupIDs, grants, cryptoStatus, requiresCrypto: requiredParts.length > 0 });
    const cryptoAvailableByPermission = {};
    for (const [name, bit] of Object.entries(permissionBits)) {
      if ((result.policyMask & bit) === 0) continue;
      const part = target.kind === "CREDENTIAL"
        ? (name === "Reveal" || name === "Edit" ? "SECRET"
          : name === "View" ? "METADATA" : null)
        : target.kind === "FOLDER" || ["ManageAccess", "Manage", "Create"].includes(name)
          ? null : "GENERAL";
      const label = name === "View" && target.kind === "CREDENTIAL"
        ? "ViewMetadata" : name;
      cryptoAvailableByPermission[label] = part === null ? "NOT_REQUIRED"
        : availableParts.has(part) ? "WRAP_PRESENT_UNVERIFIED" : "NO";
    }
    return { ...result, cryptoAvailableByPermission,
      effectiveUsableByPermission: usabilityByPermission(cryptoAvailableByPermission) };
  }

  async previewAccessChange(input) {
    validateAccessChangeRequest(input?.request);
    const rawCursor = input?.cursor ?? "0";
    if (!/^\d{1,4}$/u.test(String(rawCursor))
      || Number(rawCursor) > 1000) throw new Error("invalid_access_page");
    const offset = Number(rawCursor);
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY");
      const preview = await this.buildAccessPreview(client, input);
      const token = createPreviewToken(preview.binding, input.sessionSecret);
      await client.query("COMMIT");
      return { token, details: preview.details.slice(offset, offset + 50),
        counts: preview.counts,
        nextCursor: offset + 50 < preview.details.length
          ? String(offset + 50) : null };
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  async buildAccessPreview(client, input) {
    const { actorUserID, actorDeviceID, teamID, vaultID, request } = input;
    const changes = validateAccessChangeRequest(request);
    const actor = await readAccessActor(client, input);
    const vault = await client.query(
      `SELECT access_policy_version FROM shared_vaults
       WHERE id = $1 AND team_id = $2 AND archived_at IS NULL
         AND format_state = 'V2_PREPARING' AND format_schema_version = 2`,
      [vaultID, teamID],
    );
    if (!vault.rows[0]) throw new Error("access_v2_preparing_required");
    const teamRevision = await client.query(
      `SELECT revision FROM team_policy_revisions WHERE team_id = $1`, [teamID],
    );
    const resolved = [];
    const pairs = new Map();
    const allSubjects = new Map();
    const allResources = new Map();
    const explicitPrincipals = new Set();
    const parentOverrides = new Map();
    const extraRegistryIDs = new Set();
    for (const [index, change] of changes.entries()) {
      if (change.type === "RESOURCE_MOVE") {
        const moving = await client.query(
          `SELECT id, policy_kind, resource_version, parent_folder_id
           FROM vault_resource_registry WHERE id = $1 AND team_id = $2
             AND vault_id = $3 AND deleted_at IS NULL`,
          [change.resourceID, teamID, vaultID],
        );
        if (!moving.rows[0]?.policy_kind || Number(moving.rows[0].resource_version)
          !== change.expectedResourceVersion) throw new Error("access_policy_conflict");
        if (change.newParentFolderID === change.resourceID) {
          throw new Error("invalid_access_parent");
        }
        if (change.newParentFolderID !== null) {
          const parent = await client.query(
            `SELECT 1 FROM vault_resource_registry WHERE id = $1 AND team_id = $2
               AND vault_id = $3 AND policy_kind = 'FOLDER' AND deleted_at IS NULL`,
            [change.newParentFolderID, teamID, vaultID],
          );
          if (!parent.rows[0]) throw new Error("invalid_access_parent");
          extraRegistryIDs.add(change.newParentFolderID);
        }
        const subtree = await client.query(
          `WITH RECURSIVE descendants AS (
             SELECT id, parent_folder_id, resource_version, policy_kind
             FROM vault_resource_registry WHERE id = $1 AND team_id = $2
               AND vault_id = $3 AND deleted_at IS NULL
             UNION
             SELECT child.id, child.parent_folder_id, child.resource_version,
               child.policy_kind FROM vault_resource_registry AS child
             JOIN descendants ON child.parent_folder_id = descendants.id
             WHERE child.team_id = $2 AND child.vault_id = $3
               AND child.deleted_at IS NULL
           ) SELECT id, resource_version, policy_kind FROM descendants
             ORDER BY id LIMIT 51`,
          [change.resourceID, teamID, vaultID],
        );
        if (subtree.rows.length > 50) throw new Error("access_batch_too_large");
        if (subtree.rows.some((item) => !item.policy_kind)) {
          throw new Error("access_unclassified_resource");
        }
        if (subtree.rows.some((item) => item.id === change.newParentFolderID)) {
          throw new Error("invalid_access_parent");
        }
        const published = await client.query(
          `SELECT 1 FROM vault_resource_manifest_pointers_v2
           WHERE team_id = $1 AND vault_id = $2
             AND resource_id = ANY($3::uuid[]) LIMIT 1`,
          [teamID, vaultID, subtree.rows.map((item) => item.id)],
        );
        if (published.rows[0]) throw new Error("crypto_publication_required");
        const users = await client.query(
          `SELECT id, user_id, epoch, role FROM team_memberships
           WHERE team_id = $1 AND revoked_at IS NULL ORDER BY id LIMIT 1001`,
          [teamID],
        );
        if (users.rows.length > 1000) throw new Error("access_batch_too_large");
        for (const user of users.rows) {
          allSubjects.set(user.user_id, { userID: user.user_id,
            membershipID: user.id, epoch: Number(user.epoch), role: user.role });
        }
        for (const resource of subtree.rows) {
          allResources.set(resource.id, resource);
          for (const user of users.rows) {
            pairs.set(`${user.user_id}:${resource.id}`,
              { subjectUserID: user.user_id, resourceID: resource.id });
          }
        }
        parentOverrides.set(change.resourceID, change.newParentFolderID);
        resolved.push({ index, type: change.type, resourceID: change.resourceID,
          newParentFolderID: change.newParentFolderID,
          expectedResourceVersion: change.expectedResourceVersion,
          oldParentFolderID: moving.rows[0].parent_folder_id });
        continue;
      }
      let grant = null;
      if (change.type !== "GRANT_CREATE") {
        const existing = await client.query(
          `SELECT id, principal_kind, principal_id, membership_id,
             membership_epoch, target_kind, target_id, permission_mask, version
           FROM vault_access_grants WHERE id = $1 AND team_id = $2
             AND vault_id = $3 AND revoked_at IS NULL`,
          [change.grantID, teamID, vaultID],
        );
        if (!existing.rows[0] || Number(existing.rows[0].version)
          !== change.expectedVersion) throw new Error("access_policy_conflict");
        grant = existing.rows[0];
      }
      const principalKind = grant?.principal_kind ?? change.principalKind;
      const principalID = grant?.principal_id ?? change.principalID;
      const targetKind = grant?.target_kind ?? change.targetKind;
      const targetID = grant?.target_id ?? change.targetID;
      const mask = change.type === "GRANT_REVOKE"
        ? grant.permission_mask : change.permissionMask;
      explicitPrincipals.add(`${principalKind}:${principalID}`);
      if (explicitPrincipals.size > 20) throw new Error("access_batch_too_large");
      let targetPolicyKind = "VAULT";
      if (targetKind !== "VAULT") {
        const registry = await client.query(
          `SELECT policy_kind FROM vault_resource_registry
           WHERE id = $1 AND team_id = $2 AND vault_id = $3
             AND deleted_at IS NULL`,
          [targetID, teamID, vaultID],
        );
        targetPolicyKind = registry.rows[0]?.policy_kind;
        if (!targetPolicyKind || (targetKind === "FOLDER" && targetPolicyKind !== "FOLDER")
          || (targetKind === "RESOURCE" && targetPolicyKind === "FOLDER")) {
          throw new Error("access_resource_not_found");
        }
      } else if (targetID !== vaultID) {
        throw new Error("access_resource_not_found");
      }
      if (change.type !== "GRANT_REVOKE") validateGrant(targetPolicyKind, mask);
      if (change.type === "GRANT_CREATE") {
        const duplicate = await client.query(
          `SELECT 1 FROM vault_access_grants WHERE team_id = $1 AND vault_id = $2
             AND principal_kind = $3 AND principal_id = $4
             AND target_kind = $5 AND target_id = $6 AND revoked_at IS NULL`,
          [teamID, vaultID, principalKind, principalID, targetKind, targetID],
        );
        if (duplicate.rows[0]) throw new Error("access_policy_conflict");
      }
      let subjects;
      if (principalKind === "USER") {
        const rows = await client.query(
          `SELECT id, user_id, epoch, role FROM team_memberships
           WHERE team_id = $1 AND user_id = $2 AND revoked_at IS NULL`,
          [teamID, principalID],
        );
        subjects = rows.rows;
        if (change.type !== "GRANT_REVOKE" && !subjects[0]) {
          throw new Error("team_not_found");
        }
        if (grant && change.type !== "GRANT_REVOKE" && subjects[0]
          && (grant.membership_id !== subjects[0].id
            || Number(grant.membership_epoch) !== Number(subjects[0].epoch))) {
          throw new Error("access_policy_conflict");
        }
      } else {
        const group = await client.query(
          `SELECT deleted_at FROM team_access_groups WHERE id = $1 AND team_id = $2`,
          [principalID, teamID],
        );
        if ((!group.rows[0] || group.rows[0].deleted_at !== null)
          && change.type !== "GRANT_REVOKE") throw new Error("access_group_not_found");
        const rows = await client.query(
          `SELECT DISTINCT member.id, member.user_id, member.epoch, member.role
           FROM team_access_group_members AS edge
           JOIN team_memberships AS member ON member.id = edge.membership_id
             AND member.team_id = edge.team_id AND member.user_id = edge.user_id
             AND member.epoch = edge.membership_epoch AND member.revoked_at IS NULL
           WHERE edge.team_id = $1 AND edge.group_id = $2
             AND edge.removed_at IS NULL ORDER BY member.id LIMIT 1001`,
          [teamID, principalID],
        );
        if (rows.rows.length > 1000) throw new Error("access_batch_too_large");
        subjects = rows.rows;
      }
      for (const subject of subjects) {
        requireAccessMutation(actor.role, subject.role);
        allSubjects.set(subject.user_id, { userID: subject.user_id,
          membershipID: subject.id, epoch: Number(subject.epoch), role: subject.role });
      }
      let resourceRows;
      if (targetKind === "RESOURCE") {
        resourceRows = await client.query(
          `SELECT id, resource_version, policy_kind FROM vault_resource_registry
           WHERE id = $1 AND team_id = $2 AND vault_id = $3
             AND deleted_at IS NULL`,
          [targetID, teamID, vaultID],
        );
      } else if (targetKind === "FOLDER") {
        resourceRows = await client.query(
          `WITH RECURSIVE subtree AS (
             SELECT id, parent_folder_id, resource_version, policy_kind
             FROM vault_resource_registry WHERE id = $1 AND team_id = $2
               AND vault_id = $3 AND deleted_at IS NULL
             UNION
             SELECT child.id, child.parent_folder_id, child.resource_version,
               child.policy_kind FROM vault_resource_registry AS child
             JOIN subtree ON child.parent_folder_id = subtree.id
             WHERE child.team_id = $2 AND child.vault_id = $3
               AND child.deleted_at IS NULL
           ) SELECT id, resource_version, policy_kind FROM subtree ORDER BY id LIMIT 51`,
          [targetID, teamID, vaultID],
        );
      } else {
        resourceRows = await client.query(
          `SELECT id, resource_version, policy_kind FROM vault_resource_registry
           WHERE team_id = $1 AND vault_id = $2 AND deleted_at IS NULL
           ORDER BY id LIMIT 51`,
          [teamID, vaultID],
        );
      }
      if (resourceRows.rows.length > 50) throw new Error("access_batch_too_large");
      if (resourceRows.rows.some((row) => !row.policy_kind)) {
        throw new Error("access_unclassified_resource");
      }
      for (const resource of resourceRows.rows) {
        allResources.set(resource.id, resource);
        for (const subject of subjects) {
          pairs.set(`${subject.user_id}:${resource.id}`,
            { subjectUserID: subject.user_id, resourceID: resource.id });
        }
      }
      resolved.push({ index, type: change.type, grantID: grant?.id ?? null,
        expectedVersion: change.expectedVersion ?? null, principalKind, principalID,
        membershipID: principalKind === "USER"
          ? subjects[0]?.id ?? grant?.membership_id ?? null : null,
        membershipEpoch: principalKind === "USER"
          ? subjects[0]?.epoch ?? grant?.membership_epoch ?? null : null,
        targetKind, targetID, permissionMask: mask,
        oldMask: grant?.permission_mask ?? 0 });
    }
    if (allResources.size > 50 || pairs.size > 1000) {
      throw new Error("access_batch_too_large");
    }
    const hypothetical = resolved.filter((item) => item.type !== "RESOURCE_MOVE")
      .map((item) => item.type === "GRANT_CREATE"
      ? { type: item.type, grant: { id: `preview:${item.index}`,
        teamID, vaultID, principalKind: item.principalKind,
        principalID: item.principalID, membershipID: item.membershipID,
        membershipEpoch: item.membershipEpoch, targetKind: item.targetKind,
        targetID: item.targetID, mask: item.permissionMask, revokedAt: null } }
      : { type: item.type, grantID: item.grantID,
        permissionMask: item.permissionMask });
    const details = [];
    let widened = 0;
    let lost = 0;
    for (const pair of pairs.values()) {
      const accessInput = { actorUserID, actorDeviceID, teamID, vaultID,
        resourceID: pair.resourceID, subjectUserID: pair.subjectUserID };
      const before = await this.readEffectiveAccessInSnapshot(client, accessInput);
      const after = await this.readEffectiveAccessInSnapshot(client, accessInput,
        hypothetical, parentOverrides);
      const gainedMask = after.policyMask & ~before.policyMask;
      const lostMask = before.policyMask & ~after.policyMask;
      const pathIdentity = (access) => access.paths.map((path) =>
        [path.id, path.effectiveMask]);
      if (hashAccessRequest(pathIdentity(before)) !== hashAccessRequest(pathIdentity(after))) {
        requireAccessMutation(actor.role, allSubjects.get(pair.subjectUserID).role);
      }
      if (gainedMask) widened++;
      if (lostMask) lost++;
      details.push({ ...pair, before, after, gainedMask, lostMask });
    }
    const resourceIDs = [...allResources.keys()].sort();
    const registry = await client.query(
      `WITH RECURSIVE chain AS (
         SELECT id, parent_folder_id, resource_version
         FROM vault_resource_registry WHERE team_id = $1 AND vault_id = $2
           AND id = ANY($3::uuid[]) AND deleted_at IS NULL
         UNION
         SELECT parent.id, parent.parent_folder_id, parent.resource_version
         FROM vault_resource_registry AS parent
         JOIN chain ON parent.id = chain.parent_folder_id
         WHERE parent.team_id = $1 AND parent.vault_id = $2
           AND parent.deleted_at IS NULL
       ) SELECT DISTINCT id, resource_version FROM chain ORDER BY id`,
      [teamID, vaultID, [...new Set([...resourceIDs, ...extraRegistryIDs])]],
    );
    const binding = { actorMembershipID: actor.id, actorEpoch: Number(actor.epoch),
      actorDeviceID, teamID, vaultID, requestHash: hashAccessRequest(request),
      teamPolicyRevision: Number(teamRevision.rows[0]?.revision ?? 0),
      vaultPolicyVersion: Number(vault.rows[0].access_policy_version),
      registryVersionsHash: hashAccessRequest(registry.rows.map((row) =>
        [row.id, Number(row.resource_version)])),
      selectedDescendantsHash: hashAccessRequest(resourceIDs),
      subjectsHash: hashAccessRequest([...allSubjects.values()]
        .sort((left, right) => left.userID.localeCompare(right.userID))) };
    return { binding, resolved, details,
      subjectBindings: [...allSubjects.values()],
      counts: { pairs: pairs.size, widened, lost } };
  }

  async commitAccessChange(input) {
    const signed = verifyPreviewToken(input?.token, input?.sessionSecret);
    validateAccessChangeRequest(input?.request);
    const { actorUserID, actorDeviceID, teamID, vaultID, idempotencyKey } = input;
    if (signed.actorDeviceID !== actorDeviceID || signed.teamID !== teamID
      || signed.vaultID !== vaultID
      || signed.requestHash !== hashAccessRequest(input.request)) {
      throw new Error("access_preview_conflict");
    }
    const receiptRequest = { actorUserID, actorDeviceID, teamID, vaultID,
      tokenHash: hashAccessRequest(input.token),
      requestHash: signed.requestHash };
    return this.withMutation({ actorUserID, idempotencyKey,
      operation: "access.policy.commit", request: receiptRequest }, async (client) => {
      const actor = await requirePreparingActor(client, input);
      await client.query(
        `INSERT INTO team_policy_revisions (team_id) VALUES ($1) ON CONFLICT DO NOTHING`,
        [teamID],
      );
      await client.query(
        `SELECT revision FROM team_policy_revisions WHERE team_id = $1 FOR UPDATE`,
        [teamID],
      );
      let preview = await this.buildAccessPreview(client, input);
      if (preview.subjectBindings.length) {
        await client.query(
          `SELECT id FROM team_memberships WHERE team_id = $1
             AND id = ANY($2::uuid[]) ORDER BY id FOR SHARE`,
          [teamID, preview.subjectBindings.map((item) => item.membershipID)],
        );
        preview = await this.buildAccessPreview(client, input);
      }
      const { expiresAt, ...signedBinding } = signed;
      if (signed.actorMembershipID !== actor.id
        || Number(signed.actorEpoch) !== Number(actor.epoch)
        || hashAccessRequest(signedBinding) !== hashAccessRequest(preview.binding)) {
        throw new Error("access_preview_conflict");
      }
      const committed = [];
      for (const change of preview.resolved) {
        if (change.type === "RESOURCE_MOVE") {
          const row = await client.query(
            `UPDATE vault_resource_registry SET parent_folder_id = $4,
               resource_version = resource_version + 1
             WHERE id = $1 AND team_id = $2 AND vault_id = $3
               AND resource_version = $5 AND deleted_at IS NULL RETURNING id`,
            [change.resourceID, teamID, vaultID, change.newParentFolderID,
              change.expectedResourceVersion],
          );
          if (!row.rows[0]) throw new Error("access_policy_conflict");
          await client.query(
            `UPDATE shared_vaults SET access_policy_version = access_policy_version + 1
             WHERE id = $1 AND team_id = $2`,
            [vaultID, teamID],
          );
          await client.query(
            `INSERT INTO team_audit_events
               (team_id, actor_user_id, action, target_vault_id, metadata)
             VALUES ($1, $2, 'resource.move_access_changed', $3, $4::jsonb)`,
            [teamID, actorUserID, vaultID,
              JSON.stringify({ resourceID: change.resourceID,
                oldParentFolderID: change.oldParentFolderID,
                newParentFolderID: change.newParentFolderID })],
          );
          committed.push({ type: change.type, resourceID: change.resourceID });
          continue;
        }
        let grantID = change.grantID;
        if (change.type === "GRANT_CREATE") {
          const row = await client.query(
            `INSERT INTO vault_access_grants
               (team_id, vault_id, principal_kind, principal_id,
                membership_id, membership_epoch, target_kind, target_id,
                permission_mask, created_by_user_id)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
             RETURNING id`,
            [teamID, vaultID, change.principalKind, change.principalID,
              change.membershipID, change.membershipEpoch,
              change.targetKind, change.targetID, change.permissionMask, actorUserID],
          );
          grantID = row.rows[0].id;
        } else if (change.type === "GRANT_CHANGE") {
          const row = await client.query(
            `UPDATE vault_access_grants SET permission_mask = $4,
               version = version + 1, updated_at = now()
             WHERE id = $1 AND team_id = $2 AND vault_id = $3
               AND version = $5 AND revoked_at IS NULL RETURNING id`,
            [grantID, teamID, vaultID, change.permissionMask, change.expectedVersion],
          );
          if (!row.rows[0]) throw new Error("access_policy_conflict");
        } else {
          const row = await client.query(
            `UPDATE vault_access_grants SET revoked_at = now(),
               version = version + 1, updated_at = now()
             WHERE id = $1 AND team_id = $2 AND vault_id = $3
               AND version = $4 AND revoked_at IS NULL RETURNING id`,
            [grantID, teamID, vaultID, change.expectedVersion],
          );
          if (!row.rows[0]) throw new Error("access_policy_conflict");
        }
        const action = change.type === "GRANT_CREATE" ? "grant.created"
          : change.type === "GRANT_CHANGE" ? "grant.changed" : "grant.revoked";
        await client.query(
          `INSERT INTO team_audit_events
             (team_id, actor_user_id, action, target_vault_id, metadata)
           VALUES ($1, $2, $3, $4, $5::jsonb)`,
          [teamID, actorUserID, action, vaultID, JSON.stringify({ grantID,
            principalKind: change.principalKind, principalID: change.principalID,
            targetKind: change.targetKind, targetID: change.targetID,
            oldMask: change.oldMask, newMask:
              change.type === "GRANT_REVOKE" ? 0 : change.permissionMask })],
        );
        committed.push({ type: change.type, grantID });
      }
      const committedGrants = committed.filter((item) => item.type !== "RESOURCE_MOVE");
      if (committedGrants.length > 1) {
        await client.query(
          `INSERT INTO team_audit_events
             (team_id, actor_user_id, action, target_vault_id, metadata)
           VALUES ($1, $2, 'bulk_grant.applied', $3, $4::jsonb)`,
          [teamID, actorUserID, vaultID,
            JSON.stringify({ count: committedGrants.length })],
        );
      }
      // Candidates are returned only from a successful committed transaction.
      const notificationCandidates = preview.details
        .filter((item) => item.gainedMask !== 0 || item.lostMask !== 0)
        .map((item) => ({ userID: item.subjectUserID,
          resourceID: item.resourceID, gainedMask: item.gainedMask,
          lostMask: item.lostMask }));
      return { applied: committed.length, grants: committed,
        notificationCandidates, counts: preview.counts };
    });
  }

}
