import { createHash } from "node:crypto";
import { requireAccessMutation, validateIdempotencyKey } from "./team-policy.mjs";
import { compileEffectiveAccess } from "./effective-access.mjs";
import { permissionBits } from "./access-policy.mjs";

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
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 50) {
      throw new Error("invalid_access_page");
    }
    const actor = await this.pool.query(
      `SELECT 1 FROM team_memberships AS membership
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
    const page = await this.pool.query(
      `SELECT id, team_id, name, version, created_at, updated_at
       FROM team_access_groups WHERE team_id = $1 AND deleted_at IS NULL
         AND ($2::uuid IS NULL OR id > $2::uuid)
       ORDER BY id LIMIT $3`,
      [teamID, cursor, limit + 1],
    );
    const rows = page.rows.slice(0, limit);
    return { rows, nextCursor: page.rows.length > limit ? rows.at(-1).id : null };
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
      await requirePreparingActor(client, input, relatedVaultIDs);
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
    const { actorUserID, teamID, vaultID, resourceID, subjectUserID } = input;
    if (!uuidPattern.test(resourceID ?? "")) throw new Error("invalid_access_resource");
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY");
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
        parentFolderID: row.rows[0].parent_folder_id,
        deletedAt: row.rows[0].deleted_at };
      const ancestorRows = await client.query(
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
      const grants = grantRows.rows.map((item) => ({ id: item.id,
        teamID: item.team_id, vaultID: item.vault_id,
        principalKind: item.principal_kind, principalID: item.principal_id,
        membershipID: item.membership_id, membershipEpoch: item.membership_epoch,
        targetKind: item.target_kind, targetID: item.target_id,
        mask: item.permission_mask, revokedAt: item.revoked_at }));
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
      // A management bit is policy-only; content bits need current eligible wraps.
      const requiredPart = target.kind === "FOLDER" ? null
        : target.kind === "CREDENTIAL" ? "METADATA" : "GENERAL";
      const cryptoStatus = requiredPart && availableParts.has(requiredPart)
        ? "WRAP_PRESENT_UNVERIFIED" : "NO";
      const result = compileEffectiveAccess({ target, ancestors, membership,
        groupIDs, grants, cryptoStatus, requiresCrypto: requiredPart !== null });
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
      await client.query("COMMIT");
      return { ...result, cryptoAvailableByPermission };
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }
}
