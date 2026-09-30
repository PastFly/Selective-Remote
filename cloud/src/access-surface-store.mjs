import {
  AccessStore,
  readAccessActor,
  requirePreparingActor,
} from "./access-store.mjs";
import {
  createPreviewToken,
  verifyPreviewToken,
  hashAccessRequest,
  validateAccessGroupRequest,
} from "./access-preview.mjs";
import { requireAccessMutation } from "./team-policy.mjs";

const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
function pageInput({ limit = 50, cursor = null }) {
  if (
    !Number.isSafeInteger(limit) ||
    limit < 1 ||
    limit > 50 ||
    (cursor !== null && !uuid.test(cursor))
  )
    throw new Error("invalid_access_page");
  return { limit, cursor };
}
function page(rows, limit) {
  return {
    rows: rows.slice(0, limit),
    nextCursor: rows.length > limit ? rows[limit - 1].id : null,
  };
}
export async function preparingContext(client, { teamID, vaultID }) {
  const row = (
    await client.query(
      `SELECT id,format_state,format_schema_version,access_policy_version
    FROM shared_vaults WHERE team_id=$1 AND id=$2 AND archived_at IS NULL`,
      [teamID, vaultID],
    )
  ).rows[0];
  if (!row) throw new Error("team_not_found");
  if (["V2_READY", "V2_ACTIVE"].includes(row.format_state))
    throw new Error("crypto_publication_required");
  if (row.format_state !== "V2_PREPARING" || row.format_schema_version !== 2)
    throw new Error("access_v2_preparing_required");
  return row;
}

async function hasFrozenTeamGroupPolicy(client, teamID) {
  // Active reads compare the entire Team groups/edges/revision snapshot, including
  // unrelated groups. Only current ACTIVE pointers and live READY attempts count.
  const result = await client.query(
    `SELECT 1 FROM shared_vaults AS vault
    JOIN vault_migration_attempts AS attempt ON attempt.team_id=vault.team_id AND attempt.vault_id=vault.id
    WHERE vault.team_id=$1 AND vault.archived_at IS NULL
      AND ((vault.format_state='V2_ACTIVE' AND vault.active_publication_attempt_id=attempt.id AND attempt.state='V2_ACTIVE')
        OR attempt.state='V2_READY') LIMIT 1`,
    [teamID],
  );
  return Boolean(result.rows[0]);
}

export class AccessSurfaceStore extends AccessStore {
  async withRead(input, action) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY");
      await readAccessActor(client, input);
      const result = await action(client);
      await client.query("COMMIT");
      return result;
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }
  async groupMutationAvailable(input) {
    return this.withRead(
      input,
      async (client) => !(await hasFrozenTeamGroupPolicy(client, input.teamID)),
    );
  }
  async listAccessVaults(input) {
    const { limit, cursor } = pageInput(input);
    return this.withRead(input, async (client) =>
      page(
        (
          await client.query(
            `SELECT id,team_id AS "teamID",name,format_state AS "formatState"
      FROM shared_vaults WHERE team_id=$1 AND archived_at IS NULL
      AND ($2::uuid IS NULL OR id>$2) ORDER BY id LIMIT $3`,
            [input.teamID, cursor, limit + 1],
          )
        ).rows,
        limit,
      ),
    );
  }
  async listAccessResources(input) {
    const { limit, cursor } = pageInput(input);
    const kind = input.kind ?? null;
    if (
      kind !== null &&
      !["HOST", "CREDENTIAL", "SNIPPET", "FORWARDING", "FOLDER"].includes(kind)
    )
      throw new Error("invalid_access_request");
    return this.withRead(input, async (client) => {
      await preparingContext(client, input);
      const rows = (
        await client.query(
          `SELECT id,team_id AS "teamID",vault_id AS "vaultID",policy_kind AS "policyKind",
        parent_folder_id AS "parentFolderID",resource_version AS "resourceVersion"
        FROM vault_resource_registry WHERE team_id=$1 AND vault_id=$2 AND deleted_at IS NULL
        AND policy_kind IS NOT NULL AND ($3::uuid IS NULL OR id>$3)
        AND ($4::text IS NULL OR policy_kind=$4) ORDER BY id LIMIT $5`,
          [input.teamID, input.vaultID, cursor, kind, limit + 1],
        )
      ).rows;
      return page(
        rows.map((row) => ({
          ...row,
          resourceVersion: Number(row.resourceVersion),
        })),
        limit,
      );
    });
  }
  async getAccessResource(input) {
    if (!uuid.test(input.resourceID ?? "")) throw new Error("invalid_access_resource");
    return this.withRead(input, async (client) => {
      await preparingContext(client, input);
      const row = (await client.query(
        `SELECT id,team_id AS "teamID",vault_id AS "vaultID",policy_kind AS "policyKind",
          parent_folder_id AS "parentFolderID",resource_version AS "resourceVersion"
         FROM vault_resource_registry WHERE team_id=$1 AND vault_id=$2 AND id=$3
           AND deleted_at IS NULL AND policy_kind IS NOT NULL`,
        [input.teamID, input.vaultID, input.resourceID],
      )).rows[0];
      if (!row) throw new Error("access_resource_not_found");
      return { ...row, resourceVersion: Number(row.resourceVersion) };
    });
  }
  async listAccessGroupMembers(input) {
    const { limit, cursor } = pageInput(input);
    return this.withRead(input, async (client) => {
      const group = await client.query(
        `SELECT id FROM team_access_groups WHERE team_id=$1 AND id=$2 AND deleted_at IS NULL`,
        [input.teamID, input.groupID],
      );
      if (!group.rows[0]) throw new Error("access_group_not_found");
      const rows = (
        await client.query(
          `SELECT edge.id,edge.group_id AS "groupID",edge.user_id AS "userID",edge.membership_id AS "membershipID",
        edge.membership_epoch AS "membershipEpoch",edge.version FROM team_access_group_members AS edge
        JOIN team_memberships AS member ON member.id=edge.membership_id AND member.team_id=edge.team_id
          AND member.user_id=edge.user_id AND member.epoch=edge.membership_epoch AND member.revoked_at IS NULL
        WHERE edge.team_id=$1 AND edge.group_id=$2 AND edge.removed_at IS NULL
        AND ($3::uuid IS NULL OR edge.id>$3) ORDER BY edge.id LIMIT $4`,
          [input.teamID, input.groupID, cursor, limit + 1],
        )
      ).rows;
      return page(
        rows.map((row) => ({
          ...row,
          membershipEpoch: Number(row.membershipEpoch),
          version: Number(row.version),
        })),
        limit,
      );
    });
  }
  async listAccessDevices(input) {
    const { limit, cursor } = pageInput(input);
    if (!uuid.test(input.subjectUserID ?? ""))
      throw new Error("invalid_access_request");
    return this.withRead(input, async (client) => {
      await preparingContext(client, input);
      const subject = (
        await client.query(
          `SELECT id,epoch FROM team_memberships WHERE team_id=$1 AND user_id=$2 AND revoked_at IS NULL`,
          [input.teamID, input.subjectUserID],
        )
      ).rows[0];
      if (!subject) throw new Error("team_not_found");
      const rows = (
        await client.query(
          `SELECT device.id,device.name,device.platform,
        (device.public_key IS NOT NULL AND device.public_key_algorithm='p256-ecdh-v1'
          AND admission.device_id IS NOT NULL) AS admitted
        FROM devices AS device LEFT JOIN team_membership_device_admissions AS admission
          ON admission.device_id=device.id AND admission.membership_id=$2 AND admission.membership_epoch=$3
        WHERE device.user_id=$1 AND device.revoked_at IS NULL AND ($4::uuid IS NULL OR device.id>$4)
        ORDER BY device.id LIMIT $5`,
          [input.subjectUserID, subject.id, subject.epoch, cursor, limit + 1],
        )
      ).rows;
      return page(rows, limit);
    });
  }

  async buildGroupPreview(client, input) {
    const request = validateAccessGroupRequest(input.request);
    const actor = await readAccessActor(client, input);
    const context = await preparingContext(client, input);
    if (await hasFrozenTeamGroupPolicy(client, input.teamID))
      throw new Error("crypto_publication_required");
    const { teamID, vaultID } = input;
    const revision =
      (
        await client.query(
          "SELECT revision FROM team_policy_revisions WHERE team_id=$1",
          [teamID],
        )
      ).rows[0]?.revision ?? "0";
    if (request.name !== undefined) {
      const duplicate = await client.query(
        `SELECT 1 FROM team_access_groups
        WHERE team_id=$1 AND deleted_at IS NULL AND lower(name)=lower($2)
          AND ($3::uuid IS NULL OR id<>$3) LIMIT 1`,
        [teamID, request.name.trim(), request.groupID ?? null],
      );
      if (duplicate.rows[0]) throw new Error("access_policy_conflict");
    }
    let group = null,
      edge = null,
      subjects = [],
      grants = [];
    if (request.groupID) {
      group = (
        await client.query(
          `SELECT id,version FROM team_access_groups WHERE team_id=$1 AND id=$2 AND deleted_at IS NULL`,
          [teamID, request.groupID],
        )
      ).rows[0];
      if (
        !group ||
        (["GROUP_RENAME", "GROUP_DELETE"].includes(request.type) &&
          Number(group.version) !== request.expectedVersion)
      )
        throw new Error("access_policy_conflict");
      grants =
        request.type === "GROUP_RENAME"
          ? []
          : (
              await client.query(
                `SELECT id,vault_id,target_kind,target_id,permission_mask,version FROM vault_access_grants
        WHERE team_id=$1 AND principal_kind='GROUP' AND principal_id=$2 AND revoked_at IS NULL
        ORDER BY vault_id,id LIMIT 1001`,
                [teamID, group.id],
              )
            ).rows;
      if (grants.length > 1000) {
        const error = new Error(
          request.type === "GROUP_DELETE"
            ? "group_grants_must_be_revoked_first"
            : "access_batch_too_large",
        );
        if (request.type === "GROUP_DELETE") error.safeCount = "1001+";
        throw error;
      }
    }
    if (request.type === "GROUP_MEMBER_ADD") {
      subjects = (
        await client.query(
          `SELECT id,user_id,role,epoch FROM team_memberships WHERE team_id=$1 AND id=$2 AND revoked_at IS NULL`,
          [teamID, request.targetMembershipID],
        )
      ).rows;
      if (!subjects[0]) throw new Error("team_not_found");
      if (
        (
          await client.query(
            `SELECT 1 FROM team_access_group_members WHERE team_id=$1 AND group_id=$2 AND membership_id=$3 AND membership_epoch=$4 AND removed_at IS NULL`,
            [teamID, group.id, subjects[0].id, subjects[0].epoch],
          )
        ).rows[0]
      )
        throw new Error("access_policy_conflict");
    } else if (request.type === "GROUP_MEMBER_REMOVE") {
      edge = (
        await client.query(
          `SELECT id,user_id,membership_id,membership_epoch,version FROM team_access_group_members WHERE team_id=$1 AND group_id=$2 AND id=$3 AND removed_at IS NULL`,
          [teamID, group.id, request.edgeID],
        )
      ).rows[0];
      if (!edge || Number(edge.version) !== request.expectedVersion)
        throw new Error("access_policy_conflict");
      subjects = (
        await client.query(
          `SELECT id,user_id,role,epoch FROM team_memberships WHERE team_id=$1 AND id=$2 AND user_id=$3 AND epoch=$4 AND revoked_at IS NULL`,
          [teamID, edge.membership_id, edge.user_id, edge.membership_epoch],
        )
      ).rows;
      if (!subjects[0]) throw new Error("access_policy_conflict");
    } else if (request.type === "GROUP_DELETE") {
      subjects = (
        await client.query(
          `SELECT member.id,member.user_id,member.role,member.epoch FROM team_access_group_members AS edge
        JOIN team_memberships AS member ON member.id=edge.membership_id AND member.team_id=edge.team_id
          AND member.user_id=edge.user_id AND member.epoch=edge.membership_epoch AND member.revoked_at IS NULL
        WHERE edge.team_id=$1 AND edge.group_id=$2 AND edge.removed_at IS NULL ORDER BY member.id LIMIT 1001`,
          [teamID, group.id],
        )
      ).rows;
    }
    if (subjects.length > 1000) throw new Error("access_batch_too_large");
    for (const subject of subjects)
      requireAccessMutation(actor.role, subject.role);
    const vaults = new Map([[vaultID, context]]),
      resources = new Map();
    // Team groups may affect several Vaults. Every affected policy must remain dormant.
    for (const grant of grants) {
      if (!vaults.has(grant.vault_id))
        vaults.set(
          grant.vault_id,
          await preparingContext(client, { teamID, vaultID: grant.vault_id }),
        );
      if (!subjects.length) continue;
      const rows = (
        await client.query(
          `WITH RECURSIVE affected AS (
        SELECT id,parent_folder_id,resource_version FROM vault_resource_registry
        WHERE team_id=$1 AND vault_id=$2 AND deleted_at IS NULL
          AND ($3='VAULT' OR id=$4)
        UNION
        SELECT child.id,child.parent_folder_id,child.resource_version FROM vault_resource_registry AS child
        JOIN affected ON child.parent_folder_id=affected.id
        WHERE child.team_id=$1 AND child.vault_id=$2 AND child.deleted_at IS NULL AND $3='FOLDER'
      ) SELECT id,resource_version FROM affected ORDER BY id LIMIT 51`,
          [teamID, grant.vault_id, grant.target_kind, grant.target_id],
        )
      ).rows;
      for (const row of rows)
        resources.set(row.id, { ...row, vaultID: grant.vault_id });
      if (resources.size > 50 || resources.size * subjects.length > 1000)
        throw new Error("access_batch_too_large");
    }
    const details = [];
    for (const resource of [...resources.values()].sort((a, b) =>
      a.id.localeCompare(b.id),
    )) {
      for (const subject of subjects) {
        const scoped = {
          ...input,
          vaultID: resource.vaultID,
          resourceID: resource.id,
          subjectUserID: subject.user_id,
        };
        const before = await this.readEffectiveAccessInSnapshot(client, scoped);
        const after = await this.readEffectiveAccessInSnapshot(
          client,
          scoped,
          [],
          new Map(),
          { groupID: group.id, present: request.type === "GROUP_MEMBER_ADD" },
        );
        details.push({
          vaultID: resource.vaultID,
          resourceID: resource.id,
          subjectUserID: subject.user_id,
          before,
          after,
          gainedMask:
            after.policyEffective.policyMask &
            ~before.policyEffective.policyMask,
          lostMask:
            before.policyEffective.policyMask &
            ~after.policyEffective.policyMask,
        });
      }
    }
    const affectedGrants = grants.map((grant) => ({
      grantID: grant.id,
      vaultID: grant.vault_id,
      targetKind: grant.target_kind,
      targetID: grant.target_id,
      permissionMask: Number(grant.permission_mask),
      version: Number(grant.version),
    }));
    const binding = {
      domain: "access-group-v1",
      actorUserID: input.actorUserID,
      actorMembershipID: actor.id,
      actorRole: actor.role,
      actorEpoch: Number(actor.epoch),
      actorDeviceID: input.actorDeviceID,
      teamID,
      vaultID,
      requestHash: hashAccessRequest(request),
      teamPolicyRevision: String(revision),
      groupHash: hashAccessRequest({ group, edge }),
      affectedGrantsHash: hashAccessRequest(affectedGrants),
      vaultPoliciesHash: hashAccessRequest(
        [...vaults.values()].sort((a, b) => a.id.localeCompare(b.id)),
      ),
      subjectsHash: hashAccessRequest(subjects),
      // Effective paths carry an optional undefined `permission` for multi-bit
      // masks. Sign exactly the JSON wire representation, where it is omitted.
      effectsHash: hashAccessRequest(JSON.parse(JSON.stringify(details))),
      resourcesHash: hashAccessRequest([...resources.values()]),
    };
    return {
      binding,
      details,
      affectedGrants,
      vaultIDs: [...vaults.keys()],
      subjects,
      counts: {
        affectedGrants: affectedGrants.length,
        pairs: details.length,
        widened: details.filter((d) => d.gainedMask).length,
        lost: details.filter((d) => d.lostMask).length,
      },
    };
  }
  async previewAccessGroupChange(input) {
    validateAccessGroupRequest(input.request);
    const raw = String(input.cursor ?? "0");
    if (!/^\d{1,4}$/u.test(raw) || Number(raw) > 1000)
      throw new Error("invalid_access_page");
    return this.withRead(input, async (client) => {
      const preview = await this.buildGroupPreview(client, input),
        offset = Number(raw);
      return {
        token: createPreviewToken(preview.binding, input.sessionSecret),
        snapshotID: hashAccessRequest(preview.binding),
        details: preview.details.slice(offset, offset + 50),
        affectedGrants: preview.affectedGrants.slice(offset, offset + 50),
        counts: preview.counts,
        nextCursor:
          offset + 50 <
          Math.max(preview.details.length, preview.affectedGrants.length)
            ? String(offset + 50)
            : null,
      };
    });
  }
  async commitAccessGroupChange(input) {
    const signed = verifyPreviewToken(input.token, input.sessionSecret);
    validateAccessGroupRequest(input.request);
    if (
      signed.domain !== "access-group-v1" ||
      signed.actorUserID !== input.actorUserID ||
      signed.actorDeviceID !== input.actorDeviceID ||
      signed.teamID !== input.teamID ||
      signed.vaultID !== input.vaultID ||
      signed.requestHash !== hashAccessRequest(input.request)
    )
      throw new Error("access_preview_conflict");
    return this.withMutation(
      {
        actorUserID: input.actorUserID,
        idempotencyKey: input.idempotencyKey,
        operation: "access.group.commit",
        request: {
          actorUserID: input.actorUserID,
          actorDeviceID: input.actorDeviceID,
          teamID: input.teamID,
          vaultID: input.vaultID,
          tokenHash: hashAccessRequest(input.token),
          request: input.request,
        },
      },
      async (client) => {
        // Publication takes SHARE ROW EXCLUSIVE on this table. Acquire the mode
        // every group write needs before freshness reads, including edge-only writes.
        // This serializes the gate with publication across all Vaults in the Team.
        await client.query(
          "LOCK TABLE team_access_groups IN ROW EXCLUSIVE MODE",
        );
        let preview = await this.buildGroupPreview(client, input);
        await requirePreparingActor(client, input, preview.vaultIDs);
        await client.query(
          "INSERT INTO team_policy_revisions(team_id) VALUES($1) ON CONFLICT DO NOTHING",
          [input.teamID],
        );
        await client.query(
          "SELECT revision FROM team_policy_revisions WHERE team_id=$1 FOR UPDATE",
          [input.teamID],
        );
        if (input.request.groupID)
          await client.query(
            "SELECT id FROM team_access_groups WHERE team_id=$1 AND id=$2 FOR UPDATE",
            [input.teamID, input.request.groupID],
          );
        if (preview.subjects.length)
          await client.query(
            "SELECT id FROM team_memberships WHERE team_id=$1 AND id=ANY($2::uuid[]) ORDER BY id FOR SHARE",
            [input.teamID, preview.subjects.map((s) => s.id)],
          );
        preview = await this.buildGroupPreview(client, input);
        verifyPreviewToken(input.token, input.sessionSecret);
        const { expiresAt, ...binding } = signed;
        if (hashAccessRequest(binding) !== hashAccessRequest(preview.binding))
          throw new Error("access_preview_conflict");
        // Reuse existing primitives on this transaction only; no second receipt/transaction.
        const primitive = {
          GROUP_CREATE: "createAccessGroup",
          GROUP_RENAME: "renameAccessGroup",
          GROUP_DELETE: "deleteAccessGroup",
          GROUP_MEMBER_ADD: "addAccessGroupMember",
          GROUP_MEMBER_REMOVE: "removeAccessGroupMember",
        }[input.request.type];
        const result = await AccessStore.prototype[primitive].call(
          { withMutation: async (_receipt, action) => action(client) },
          { ...input, ...input.request },
        );
        // A delegated primitive can still wait while upgrading a subject/edge
        // lock. Expiry after that wait must roll back its writes, audit and receipt.
        verifyPreviewToken(input.token, input.sessionSecret);
        if (result.code) {
          const error = new Error(result.code);
          error.safeCount = result.safeCount;
          throw error;
        }
        return {
          ...result,
          notificationCandidates: preview.details
            .filter((d) => d.gainedMask || d.lostMask)
            .map((d) => ({
              userID: d.subjectUserID,
              vaultID: d.vaultID,
              resourceID: d.resourceID,
              gainedMask: d.gainedMask,
              lostMask: d.lostMask,
            })),
          counts: preview.counts,
        };
      },
    );
  }
}
