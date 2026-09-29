import { createHash } from "node:crypto";
import { requireAccessMutation, validateIdempotencyKey } from "./team-policy.mjs";

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

async function requirePreparingActor(client, { actorUserID, actorDeviceID, teamID, vaultID }) {
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
  const vault = await client.query(
    `SELECT id FROM shared_vaults WHERE id = $1 AND team_id = $2
       AND archived_at IS NULL AND format_state = 'V2_PREPARING'
       AND format_schema_version = 2 FOR UPDATE`,
    [vaultID, teamID],
  );
  if (!vault.rows[0]) throw new Error("access_v2_preparing_required");
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
  if (!current.rows[0] || current.rows[0].id !== actor.rows[0].id
    || current.rows[0].epoch !== actor.rows[0].epoch) throw new Error("team_not_found");
  requireAccessMutation(current.rows[0].role);
  return current.rows[0];
}

export class AccessStore {
  constructor(pool) { this.pool = pool; }

  async withMutation({ actorUserID, idempotencyKey, operation, request }, action) {
    validateIdempotencyKey(idempotencyKey);
    const client = await this.pool.connect();
    const hash = requestHash(request);
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
      throw error;
    } finally {
      client.release();
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
}
