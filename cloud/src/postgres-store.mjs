import pg from "pg";
import {
  requireInvitationPermission,
  requireMembershipChange,
  requireTeamPermission,
} from "./team-policy.mjs";
import { teamVaultWrapperContextHash } from "./security.mjs";

const { Pool } = pg;

export class PostgresStore {
  constructor(databaseURL, pool = null) {
    this.pool = pool ?? new Pool({ connectionString: databaseURL, max: 10 });
  }

  async close() { await this.pool.end(); }
  async ready() { await this.pool.query("SELECT 1"); }

  async createUser({ email, displayName, passwordHash, device, verificationHash, verificationExpiresAt }) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const userResult = await client.query(
        "INSERT INTO users (email, display_name) VALUES ($1, $2) RETURNING id, email, display_name, created_at",
        [email, displayName],
      );
      const user = userResult.rows[0];
      await client.query(
        "INSERT INTO account_identities (user_id, provider, subject, password_hash) VALUES ($1, 'password', $2, $3)",
        [user.id, email, passwordHash],
      );
      await client.query(
        `INSERT INTO devices
          (id, user_id, name, platform, app_version, public_key, public_key_algorithm,
           key_registered_at, key_approved_at)
         VALUES ($1, $2, $3, $4, $5, $6,
           CASE WHEN $6::text IS NULL THEN NULL ELSE 'p256-ecdh-v1' END,
           CASE WHEN $6::text IS NULL THEN NULL ELSE now() END,
           CASE WHEN $6::text IS NULL THEN NULL ELSE now() END)`,
        [device.id, user.id, device.name, device.platform, device.appVersion, device.publicKey],
      );
      await client.query("INSERT INTO personal_vaults (user_id) VALUES ($1)", [user.id]);
      await client.query(
        `INSERT INTO email_verification_tokens (user_id, token_hash, expires_at)
         VALUES ($1, $2, $3)`,
        [user.id, verificationHash, verificationExpiresAt],
      );
      await client.query("COMMIT");
      return user;
    } catch (error) {
      await client.query("ROLLBACK");
      if (error?.code === "23505") throw new Error("email_exists");
      throw error;
    } finally {
      client.release();
    }
  }

  async passwordIdentity(email) {
    const result = await this.pool.query(
      `SELECT u.id, u.email, u.display_name, u.disabled_at, u.email_verified_at, i.password_hash
       FROM users u JOIN account_identities i ON i.user_id = u.id
       WHERE i.provider = 'password' AND i.subject = $1`,
      [email],
    );
    return result.rows[0] ?? null;
  }

  async replaceEmailVerificationToken({ userID, tokenHash, expiresAt }) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const owner = await client.query(
        `SELECT id FROM users
         WHERE id = $1 AND disabled_at IS NULL AND email_verified_at IS NULL
         FOR UPDATE`,
        [userID],
      );
      if (!owner.rows[0]) {
        await client.query("COMMIT");
        return false;
      }
      await client.query(
        `UPDATE email_verification_tokens SET invalidated_at = now()
         WHERE user_id = $1 AND consumed_at IS NULL AND invalidated_at IS NULL`,
        [userID],
      );
      await client.query(
        `INSERT INTO email_verification_tokens (user_id, token_hash, expires_at)
         VALUES ($1, $2, $3)`,
        [userID, tokenHash, expiresAt],
      );
      await client.query("COMMIT");
      return true;
    } catch (error) {
      try { await client.query("ROLLBACK"); } catch {}
      throw error;
    } finally {
      client.release();
    }
  }

  async consumeEmailVerificationToken(tokenHash) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const token = await client.query(
        `UPDATE email_verification_tokens AS token SET consumed_at = now()
         FROM users AS owner
         WHERE token.token_hash = $1
           AND token.user_id = owner.id
           AND owner.disabled_at IS NULL
           AND token.consumed_at IS NULL
           AND token.invalidated_at IS NULL
           AND token.expires_at > now()
         RETURNING token.user_id`,
        [tokenHash],
      );
      if (!token.rows[0]) {
        await client.query("COMMIT");
        return null;
      }
      const user = await client.query(
        `UPDATE users SET email_verified_at = COALESCE(email_verified_at, now()), updated_at = now()
         WHERE id = $1
         RETURNING id, email, display_name, email_verified_at, created_at`,
        [token.rows[0].user_id],
      );
      await client.query("COMMIT");
      return user.rows[0] ?? null;
    } catch (error) {
      try { await client.query("ROLLBACK"); } catch {}
      throw error;
    } finally {
      client.release();
    }
  }

  async consumeRateLimit({ scope, keyHash, limit, windowSeconds }) {
    if (!/^[a-z][a-z0-9_-]{0,63}$/.test(scope)
      || !/^[0-9a-f]{64}$/.test(keyHash)
      || !Number.isInteger(limit) || limit < 1 || limit > 10_000
      || !Number.isInteger(windowSeconds) || windowSeconds < 1 || windowSeconds > 86_400) {
      throw new Error("invalid_rate_limit_policy");
    }
    const result = await this.pool.query(
      `WITH pruned AS (
         DELETE FROM auth_rate_limits
         WHERE (scope, key_hash) IN (
           SELECT scope, key_hash FROM auth_rate_limits
           WHERE expires_at <= now()
             AND (scope <> $1 OR key_hash <> $2)
           ORDER BY expires_at
           LIMIT 100
         )
       ), upserted AS (
         INSERT INTO auth_rate_limits
           (scope, key_hash, window_started_at, request_count, expires_at)
         VALUES
           ($1, $2, now(), 1, now() + ($4 * 2) * interval '1 second')
         ON CONFLICT (scope, key_hash) DO UPDATE SET
           window_started_at = CASE
             WHEN auth_rate_limits.window_started_at + $4 * interval '1 second' <= now() THEN now()
             ELSE auth_rate_limits.window_started_at
           END,
           request_count = CASE
             WHEN auth_rate_limits.window_started_at + $4 * interval '1 second' <= now() THEN 1
             ELSE LEAST(auth_rate_limits.request_count + 1, $3::bigint + 1)
           END,
           expires_at = now() + ($4 * 2) * interval '1 second'
         RETURNING request_count, window_started_at
       )
       SELECT request_count <= $3 AS allowed,
         GREATEST(1, CEIL(EXTRACT(EPOCH FROM
           (window_started_at + $4 * interval '1 second' - now())
         )))::integer AS retry_after_seconds
       FROM upserted`,
      [scope, keyHash, limit, windowSeconds],
    );
    const row = result.rows[0];
    return {
      allowed: row?.allowed === true,
      retryAfterSeconds: Math.max(1, Number(row?.retry_after_seconds ?? windowSeconds)),
    };
  }

  async replacePasswordResetToken({ userID, tokenHash, expiresAt }) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const owner = await client.query(
        `SELECT id FROM users
         WHERE id = $1 AND disabled_at IS NULL AND email_verified_at IS NOT NULL
         FOR UPDATE`,
        [userID],
      );
      if (!owner.rows[0]) {
        await client.query("COMMIT");
        return false;
      }
      await client.query(
        `UPDATE password_reset_tokens SET invalidated_at = now()
         WHERE user_id = $1 AND consumed_at IS NULL AND invalidated_at IS NULL`,
        [userID],
      );
      await client.query(
        `INSERT INTO password_reset_tokens (user_id, token_hash, expires_at)
         VALUES ($1, $2, $3)`,
        [userID, tokenHash, expiresAt],
      );
      await client.query("COMMIT");
      return true;
    } catch (error) {
      try { await client.query("ROLLBACK"); } catch {}
      throw error;
    } finally {
      client.release();
    }
  }

  async passwordResetIdentity(tokenHash) {
    const result = await this.pool.query(
      `SELECT token.user_id
       FROM password_reset_tokens AS token
       JOIN users AS owner ON owner.id = token.user_id
       WHERE token.token_hash = $1
         AND owner.disabled_at IS NULL
         AND owner.email_verified_at IS NOT NULL
         AND token.consumed_at IS NULL
         AND token.invalidated_at IS NULL
         AND token.expires_at > now()`,
      [tokenHash],
    );
    return result.rows[0] ?? null;
  }

  async consumePasswordResetToken({ userID, tokenHash, passwordHash }) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const consumed = await client.query(
        `UPDATE password_reset_tokens AS token SET consumed_at = now()
         FROM users AS owner
         WHERE token.token_hash = $1 AND token.user_id = $2
           AND token.user_id = owner.id
           AND owner.disabled_at IS NULL AND owner.email_verified_at IS NOT NULL
           AND token.consumed_at IS NULL AND token.invalidated_at IS NULL
           AND token.expires_at > now()
         RETURNING token.user_id`,
        [tokenHash, userID],
      );
      if (!consumed.rows[0]) {
        await client.query("COMMIT");
        return false;
      }
      const password = await client.query(
        `UPDATE account_identities SET password_hash = $2, last_used_at = NULL
         WHERE user_id = $1 AND provider = 'password'
         RETURNING id`,
        [userID, passwordHash],
      );
      if (!password.rows[0]) throw new Error("password_identity_missing");
      await client.query(
        "UPDATE sessions SET revoked_at = COALESCE(revoked_at, now()) WHERE user_id = $1",
        [userID],
      );
      await client.query("UPDATE users SET updated_at = now() WHERE id = $1", [userID]);
      await client.query("COMMIT");
      return true;
    } catch (error) {
      try { await client.query("ROLLBACK"); } catch {}
      throw error;
    } finally {
      client.release();
    }
  }

  async createSession({ userID, device, sessionHash, expiresAt }) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const deviceResult = await client.query(
        `INSERT INTO devices
          (id, user_id, name, platform, app_version, public_key, public_key_algorithm, key_registered_at)
         VALUES ($1, $2, $3, $4, $5, $6,
           CASE WHEN $6::text IS NULL THEN NULL ELSE 'p256-ecdh-v1' END,
           CASE WHEN $6::text IS NULL THEN NULL ELSE now() END)
         ON CONFLICT (user_id, id) DO UPDATE SET
           name = EXCLUDED.name, platform = EXCLUDED.platform,
           app_version = EXCLUDED.app_version,
           public_key = CASE WHEN devices.public_key_algorithm IS NULL AND EXCLUDED.public_key IS NOT NULL
             THEN EXCLUDED.public_key ELSE devices.public_key END,
           public_key_algorithm = CASE WHEN devices.public_key_algorithm IS NULL AND EXCLUDED.public_key IS NOT NULL
             THEN EXCLUDED.public_key_algorithm ELSE devices.public_key_algorithm END,
           key_registered_at = CASE WHEN devices.public_key_algorithm IS NULL AND EXCLUDED.public_key IS NOT NULL
             THEN EXCLUDED.key_registered_at ELSE devices.key_registered_at END,
           last_seen_at = now()
         WHERE devices.revoked_at IS NULL
           AND (devices.public_key_algorithm IS NULL OR EXCLUDED.public_key IS NULL
             OR devices.public_key = EXCLUDED.public_key)
         RETURNING id`,
        [device.id, userID, device.name, device.platform, device.appVersion, device.publicKey],
      );
      if (!deviceResult.rows[0]) throw new Error("invalid_device");
      await client.query(
        "INSERT INTO sessions (user_id, device_id, token_hash, expires_at) VALUES ($1, $2, $3, $4)",
        [userID, device.id, sessionHash, expiresAt],
      );
      await client.query("UPDATE account_identities SET last_used_at = now() WHERE user_id = $1 AND provider = 'password'", [userID]);
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async session(tokenHash) {
    const result = await this.pool.query(
      `SELECT s.id AS session_id, s.user_id, s.device_id, u.email, u.display_name
       FROM sessions s JOIN users u ON u.id = s.user_id JOIN devices d ON d.id = s.device_id
       WHERE s.token_hash = $1 AND s.revoked_at IS NULL AND s.expires_at > now()
         AND u.disabled_at IS NULL AND u.email_verified_at IS NOT NULL AND d.revoked_at IS NULL`,
      [tokenHash],
    );
    if (!result.rows[0]) return null;
    await this.pool.query("UPDATE sessions SET last_used_at = now() WHERE id = $1", [result.rows[0].session_id]);
    return result.rows[0];
  }

  async revokeSession(sessionID) {
    await this.pool.query("UPDATE sessions SET revoked_at = now() WHERE id = $1", [sessionID]);
  }

  async listDevices(userID) {
    const result = await this.pool.query(
      `SELECT id, name, platform, app_version, created_at, last_seen_at, revoked_at,
         public_key IS NOT NULL AS key_registered, public_key_algorithm, public_key,
         key_approved_at
       FROM devices WHERE user_id = $1 ORDER BY last_seen_at DESC`,
      [userID],
    );
    return result.rows;
  }

  async revokeDevice(userID, deviceID) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const result = await client.query(
        `UPDATE devices SET revoked_at = now()
         WHERE user_id = $1 AND id = $2 AND revoked_at IS NULL
         RETURNING id, key_approved_at`,
        [userID, deviceID],
      );
      if (!result.rows[0]) {
        await client.query("COMMIT");
        return false;
      }
      await client.query(
        "UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL",
        [userID, deviceID],
      );
      if (result.rows[0].key_approved_at) {
        await client.query(
          `WITH affected AS (
             UPDATE shared_vaults AS vault SET rotation_required = true, updated_at = now()
             FROM team_memberships AS membership
             WHERE membership.user_id = $1 AND membership.revoked_at IS NULL
               AND vault.team_id = membership.team_id AND vault.archived_at IS NULL
             RETURNING vault.id, vault.key_generation
           )
           INSERT INTO shared_vault_rotation_tasks
             (vault_id, from_generation, removed_device_id)
           SELECT id, key_generation, $2 FROM affected
           ON CONFLICT (vault_id, from_generation, removed_device_id)
             WHERE removed_device_id IS NOT NULL DO NOTHING`,
          [userID, deviceID],
        );
      }
      await client.query("COMMIT");
      return true;
    } catch (error) {
      try { await client.query("ROLLBACK"); } catch {}
      throw error;
    } finally {
      client.release();
    }
  }

  async approveDeviceKey({ actorUserID, actorDeviceID, deviceID, expectedPublicKey, idempotencyKey }) {
    return this.withTeamMutation(actorUserID, "device.key.approve", idempotencyKey, async (client) => {
      const actor = await client.query(
        `SELECT id FROM devices
         WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL
           AND public_key IS NOT NULL AND public_key_algorithm = 'p256-ecdh-v1'
           AND key_approved_at IS NOT NULL
         FOR UPDATE`,
        [actorDeviceID, actorUserID],
      );
      if (!actor.rows[0]) throw new Error("device_approval_required");
      const target = await client.query(
        `SELECT id, public_key FROM devices
         WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL
           AND public_key IS NOT NULL AND public_key_algorithm = 'p256-ecdh-v1'
         FOR UPDATE`,
        [deviceID, actorUserID],
      );
      if (!target.rows[0]) throw new Error("device_not_found");
      if (target.rows[0].public_key !== expectedPublicKey) throw new Error("device_public_key_mismatch");
      const approved = await client.query(
        `UPDATE devices SET key_approved_at = COALESCE(key_approved_at, now()),
           key_approved_by_device_id = COALESCE(key_approved_by_device_id, $1)
         WHERE id = $2 AND user_id = $3
         RETURNING id, key_approved_at`,
        [actorDeviceID, deviceID, actorUserID],
      );
      return { approved: true, deviceID: approved.rows[0].id };
    });
  }

  async bootstrapDeviceKey({ actorUserID, actorDeviceID, expectedPublicKey, idempotencyKey }) {
    return this.withTeamMutation(actorUserID, "device.key.bootstrap", idempotencyKey, async (client) => {
      const owner = await client.query(
        "SELECT id FROM users WHERE id = $1 AND disabled_at IS NULL FOR UPDATE",
        [actorUserID],
      );
      if (!owner.rows[0]) throw new Error("invalid_device");
      const target = await client.query(
        `SELECT id, public_key, public_key_algorithm, key_approved_at
         FROM devices
         WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL
         FOR UPDATE`,
        [actorDeviceID, actorUserID],
      );
      const device = target.rows[0];
      if (!device) throw new Error("invalid_device");
      if (device.public_key_algorithm !== "p256-ecdh-v1" || device.public_key !== expectedPublicKey) {
        throw new Error("device_public_key_mismatch");
      }
      if (device.key_approved_at) {
        return { approved: true, deviceID: device.id, bootstrapped: false };
      }
      const approved = await client.query(
        `SELECT id FROM devices
         WHERE user_id = $1 AND revoked_at IS NULL AND key_approved_at IS NOT NULL
         LIMIT 1`,
        [actorUserID],
      );
      if (approved.rows[0]) throw new Error("device_approval_required");
      await client.query(
        `UPDATE devices SET key_approved_at = now(), key_approved_by_device_id = NULL
         WHERE id = $1 AND user_id = $2`,
        [actorDeviceID, actorUserID],
      );
      return { approved: true, deviceID: device.id, bootstrapped: true };
    });
  }

  async getVault(userID) {
    const result = await this.pool.query(
      `SELECT id, revision, envelope_version, wrapped_key, ciphertext, nonce, auth_tag, content_hash, updated_at
       FROM personal_vaults WHERE user_id = $1`,
      [userID],
    );
    return result.rows[0] ?? null;
  }

  async putVault(userID, deviceID, envelope) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const locked = await client.query("SELECT id, revision FROM personal_vaults WHERE user_id = $1 FOR UPDATE", [userID]);
      const vault = locked.rows[0];
      if (!vault) throw new Error("vault_missing");
      if (Number(vault.revision) !== envelope.baseRevision) {
        await client.query("ROLLBACK");
        return { conflict: true, revision: Number(vault.revision) };
      }
      const revision = envelope.baseRevision + 1;
      await client.query(
        `INSERT INTO vault_revisions
          (vault_id, revision, envelope_version, wrapped_key, ciphertext, nonce, auth_tag, content_hash, updated_by_device_id)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
        [vault.id, revision, envelope.envelopeVersion, envelope.wrappedKey ?? null, envelope.ciphertext,
          envelope.nonce, envelope.authTag, envelope.contentHash, deviceID],
      );
      await client.query(
        `UPDATE personal_vaults SET revision=$2, envelope_version=$3, wrapped_key=$4, ciphertext=$5,
          nonce=$6, auth_tag=$7, content_hash=$8, updated_by_device_id=$9, updated_at=now() WHERE id=$1`,
        [vault.id, revision, envelope.envelopeVersion, envelope.wrappedKey ?? null, envelope.ciphertext,
          envelope.nonce, envelope.authTag, envelope.contentHash, deviceID],
      );
      await client.query("COMMIT");
      return { conflict: false, revision };
    } catch (error) {
      try { await client.query("ROLLBACK"); } catch {}
      throw error;
    } finally {
      client.release();
    }
  }

  async listTeams(userID) {
    const result = await this.pool.query(
      `SELECT team.id, team.name, membership.id AS membership_id,
         membership.role, membership.epoch, team.created_at, team.updated_at
       FROM team_memberships AS membership
       JOIN teams AS team ON team.id = membership.team_id
       WHERE membership.user_id = $1 AND membership.revoked_at IS NULL
         AND team.archived_at IS NULL
       ORDER BY lower(team.name), team.id`,
      [userID],
    );
    return result.rows;
  }

  async createTeam({ actorUserID, name, idempotencyKey }) {
    return this.withTeamMutation(actorUserID, "team.create", idempotencyKey, async (client) => {
      const teamResult = await client.query(
        `INSERT INTO teams (name, created_by_user_id)
         VALUES ($1, $2)
         RETURNING id, name, created_at, updated_at`,
        [name, actorUserID],
      );
      const team = teamResult.rows[0];
      const membershipResult = await client.query(
        `INSERT INTO team_memberships (team_id, user_id, role)
         VALUES ($1, $2, 'owner')
         RETURNING id, role, epoch, joined_at`,
        [team.id, actorUserID],
      );
      const membership = membershipResult.rows[0];
      await writeTeamAudit(client, {
        teamID: team.id,
        actorUserID,
        action: "team.created",
        targetUserID: actorUserID,
        targetMembershipID: membership.id,
      });
      return { team, membership };
    });
  }

  async listTeamMembers(teamID, actorUserID) {
    const result = await this.pool.query(
      `SELECT member.id, member.user_id, member.role, member.epoch,
         member.joined_at, account.email, account.display_name
       FROM team_memberships AS actor
       JOIN teams AS team ON team.id = actor.team_id AND team.archived_at IS NULL
       JOIN team_memberships AS member ON member.team_id = team.id AND member.revoked_at IS NULL
       JOIN users AS account ON account.id = member.user_id AND account.disabled_at IS NULL
       WHERE actor.team_id = $1 AND actor.user_id = $2 AND actor.revoked_at IS NULL
       ORDER BY CASE member.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 WHEN 'editor' THEN 2 ELSE 3 END,
         lower(account.email), member.id`,
      [teamID, actorUserID],
    );
    if (result.rows.length === 0) throw new Error("team_not_found");
    return result.rows;
  }

  async createTeamInvitation({
    actorUserID,
    teamID,
    email,
    role,
    tokenHash,
    expiresAt,
    outboxEnvelope,
    idempotencyKey,
  }) {
    return this.withTeamMutation(actorUserID, "team.invitation.create", idempotencyKey, async (client) => {
      const actor = await lockTeamActor(client, teamID, actorUserID);
      if (!actor) throw new Error("team_not_found");
      requireInvitationPermission(actor.role, role);

      const existingMember = await client.query(
        `SELECT membership.id FROM team_memberships AS membership
         JOIN users AS account ON account.id = membership.user_id
         WHERE membership.team_id = $1 AND membership.revoked_at IS NULL AND account.email = $2
         FOR UPDATE OF membership`,
        [teamID, email],
      );
      if (existingMember.rows[0]) throw new Error("team_member_exists");

      await client.query(
        `WITH cancelled AS (
           UPDATE team_invitations SET cancelled_at = now(), cancelled_by_user_id = $3
           WHERE team_id = $1 AND email = $2 AND accepted_at IS NULL AND cancelled_at IS NULL
           RETURNING id
         )
         UPDATE team_outbox_jobs AS job SET delivered_at = now(), claimed_at = NULL, claim_owner = NULL
         FROM cancelled WHERE job.aggregate_id = cancelled.id AND job.delivered_at IS NULL`,
        [teamID, email, actorUserID],
      );
      const invitationResult = await client.query(
        `INSERT INTO team_invitations
          (team_id, email, role, token_hash, invited_by_user_id, expires_at)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING id, team_id, email, role, created_at, expires_at`,
        [teamID, email, role, tokenHash, actorUserID, expiresAt],
      );
      const invitation = invitationResult.rows[0];
      await client.query(
        `INSERT INTO team_outbox_jobs
          (kind, aggregate_id, idempotency_key, payload_ciphertext, nonce, auth_tag)
         VALUES ('team_invitation_email', $1, $2, $3, $4, $5)`,
        [invitation.id, `team-invitation:${invitation.id}`, outboxEnvelope.ciphertext,
          outboxEnvelope.nonce, outboxEnvelope.authTag],
      );
      await writeTeamAudit(client, {
        teamID,
        actorUserID,
        action: "team.invitation_created",
        metadata: { role },
      });
      return { invitation };
    });
  }

  async acceptTeamInvitation({ actorUserID, actorEmail, tokenHash, idempotencyKey }) {
    return this.withTeamMutation(actorUserID, "team.invitation.accept", idempotencyKey, async (client) => {
      const invitationResult = await client.query(
        `SELECT invitation.id, invitation.team_id, invitation.email, invitation.role
         FROM team_invitations AS invitation
         JOIN teams AS team ON team.id = invitation.team_id
         WHERE invitation.token_hash = $1 AND invitation.email = $2
           AND invitation.accepted_at IS NULL AND invitation.cancelled_at IS NULL
           AND invitation.expires_at > now() AND team.archived_at IS NULL
         FOR UPDATE OF invitation, team`,
        [tokenHash, actorEmail],
      );
      const invitation = invitationResult.rows[0];
      if (!invitation) throw new Error("invalid_team_invitation");

      const priorResult = await client.query(
        `SELECT id, epoch, revoked_at FROM team_memberships
         WHERE team_id = $1 AND user_id = $2
         ORDER BY epoch DESC FOR UPDATE`,
        [invitation.team_id, actorUserID],
      );
      if (priorResult.rows.some((row) => row.revoked_at === null)) {
        throw new Error("invalid_team_invitation");
      }
      const nextEpoch = priorResult.rows.reduce((maximum, row) => Math.max(maximum, Number(row.epoch)), 0) + 1;
      const membershipResult = await client.query(
        `INSERT INTO team_memberships (team_id, user_id, role, epoch)
         VALUES ($1, $2, $3, $4)
         RETURNING id, team_id, user_id, role, epoch, joined_at`,
        [invitation.team_id, actorUserID, invitation.role, nextEpoch],
      );
      const membership = membershipResult.rows[0];
      const accepted = await client.query(
        `UPDATE team_invitations SET accepted_at = now(), accepted_by_user_id = $2
         WHERE id = $1 AND accepted_at IS NULL AND cancelled_at IS NULL
         RETURNING id`,
        [invitation.id, actorUserID],
      );
      if (!accepted.rows[0]) throw new Error("invalid_team_invitation");
      await writeTeamAudit(client, {
        teamID: invitation.team_id,
        actorUserID,
        action: "team.invitation_accepted",
        targetUserID: actorUserID,
        targetMembershipID: membership.id,
        metadata: { role: membership.role, epoch: nextEpoch },
      });
      return { membership };
    });
  }

  async cancelTeamInvitation({ actorUserID, teamID, invitationID, idempotencyKey }) {
    return this.withTeamMutation(actorUserID, "team.invitation.cancel", idempotencyKey, async (client) => {
      const actor = await lockTeamActor(client, teamID, actorUserID);
      if (!actor) throw new Error("team_not_found");
      const invitationResult = await client.query(
        `SELECT id, role FROM team_invitations
         WHERE id = $1 AND team_id = $2 AND accepted_at IS NULL AND cancelled_at IS NULL
         FOR UPDATE`,
        [invitationID, teamID],
      );
      const invitation = invitationResult.rows[0];
      if (!invitation) throw new Error("team_not_found");
      requireInvitationPermission(actor.role, invitation.role);
      await client.query(
        `UPDATE team_invitations SET cancelled_at = now(), cancelled_by_user_id = $3
         WHERE id = $1 AND team_id = $2 AND accepted_at IS NULL AND cancelled_at IS NULL`,
        [invitationID, teamID, actorUserID],
      );
      await client.query(
        `UPDATE team_outbox_jobs SET delivered_at = now(), claimed_at = NULL, claim_owner = NULL
         WHERE aggregate_id = $1 AND delivered_at IS NULL`,
        [invitationID],
      );
      await writeTeamAudit(client, {
        teamID,
        actorUserID,
        action: "team.invitation_cancelled",
        metadata: { role: invitation.role },
      });
      return { cancelled: true };
    });
  }

  async updateTeamMembershipRole({ actorUserID, teamID, membershipID, role, idempotencyKey }) {
    return this.withTeamMutation(actorUserID, "team.membership.role", idempotencyKey, async (client) => {
      const actor = await lockTeamActor(client, teamID, actorUserID);
      const target = await lockTeamMembership(client, teamID, membershipID);
      if (!actor || !target) throw new Error("team_not_found");
      requireMembershipChange(actor, target, role);
      if (target.role === "owner" && role !== "owner") await requireAnotherOwner(client, teamID, target.id);
      const updated = await client.query(
        `UPDATE team_memberships SET role = $3
         WHERE id = $1 AND team_id = $2 AND revoked_at IS NULL
         RETURNING id, team_id, user_id, role, epoch, joined_at`,
        [membershipID, teamID, role],
      );
      await writeTeamAudit(client, {
        teamID,
        actorUserID,
        action: "team.membership_role_changed",
        targetUserID: target.user_id,
        targetMembershipID: target.id,
        metadata: { previousRole: target.role, role },
      });
      return { membership: updated.rows[0] };
    });
  }

  async revokeTeamMembership({ actorUserID, teamID, membershipID, idempotencyKey }) {
    return this.withTeamMutation(actorUserID, "team.membership.revoke", idempotencyKey, async (client) => {
      const actor = await lockTeamActor(client, teamID, actorUserID);
      const target = await lockTeamMembership(client, teamID, membershipID);
      if (!actor || !target) throw new Error("team_not_found");
      requireMembershipChange(actor, target);
      if (target.role === "owner") await requireAnotherOwner(client, teamID, target.id);
      const revoked = await client.query(
        `UPDATE team_memberships SET revoked_at = now(), revoked_by_user_id = $3
         WHERE id = $1 AND team_id = $2 AND revoked_at IS NULL
         RETURNING id, user_id, role, epoch, revoked_at`,
        [membershipID, teamID, actorUserID],
      );
      if (!revoked.rows[0]) throw new Error("team_not_found");
      const affectedVaults = await client.query(
        `WITH affected AS (
           UPDATE shared_vaults SET rotation_required = true, updated_at = now()
           WHERE team_id = $1 AND archived_at IS NULL
           RETURNING id, key_generation
         )
         INSERT INTO shared_vault_rotation_tasks
           (vault_id, from_generation, removed_membership_id)
         SELECT id, key_generation, $2 FROM affected
         ON CONFLICT (vault_id, from_generation, removed_membership_id) DO NOTHING
         RETURNING vault_id AS id`,
        [teamID, target.id],
      );
      await writeTeamAudit(client, {
        teamID,
        actorUserID,
        action: "team.membership_revoked",
        targetUserID: target.user_id,
        targetMembershipID: target.id,
        metadata: { role: target.role, epoch: Number(target.epoch), affectedVaults: affectedVaults.rowCount },
      });
      return { revoked: true, rotationRequiredVaults: affectedVaults.rowCount };
    });
  }

  async listSharedVaults(teamID, actorUserID) {
    const result = await this.pool.query(
      `SELECT vault.id, vault.team_id, vault.name, vault.revision, vault.key_generation,
         vault.rotation_required, vault.created_at, vault.updated_at
       FROM team_memberships AS actor
       JOIN teams AS team ON team.id = actor.team_id AND team.archived_at IS NULL
       JOIN shared_vaults AS vault ON vault.team_id = team.id AND vault.archived_at IS NULL
       WHERE actor.team_id = $1 AND actor.user_id = $2 AND actor.revoked_at IS NULL
       ORDER BY lower(vault.name), vault.id`,
      [teamID, actorUserID],
    );
    const access = await this.pool.query(
      `SELECT 1 FROM team_memberships AS membership
       JOIN teams AS team ON team.id = membership.team_id
       WHERE membership.team_id = $1 AND membership.user_id = $2
         AND membership.revoked_at IS NULL AND team.archived_at IS NULL`,
      [teamID, actorUserID],
    );
    if (!access.rows[0]) throw new Error("team_not_found");
    return result.rows;
  }

  async createSharedVault({ actorUserID, teamID, name, idempotencyKey }) {
    return this.withTeamMutation(actorUserID, "team.vault.create", idempotencyKey, async (client) => {
      const actor = await lockTeamActor(client, teamID, actorUserID);
      if (!actor) throw new Error("team_not_found");
      requireTeamPermission(actor.role, "create_vault");
      let vault;
      try {
        const result = await client.query(
          `INSERT INTO shared_vaults (team_id, name, created_by_user_id)
           VALUES ($1, $2, $3)
           RETURNING id, team_id, name, revision, key_generation, rotation_required, created_at, updated_at`,
          [teamID, name, actorUserID],
        );
        vault = result.rows[0];
      } catch (error) {
        if (error?.code === "23505") throw new Error("shared_vault_exists");
        throw error;
      }
      await writeTeamAudit(client, {
        teamID,
        actorUserID,
        action: "team.vault_created",
        targetVaultID: vault.id,
      });
      return { vault };
    });
  }

  async listTeamKeyDevices(teamID, vaultID, actorUserID) {
    const access = await this.pool.query(
      `SELECT membership.role
       FROM team_memberships AS membership
       JOIN teams AS team ON team.id = membership.team_id AND team.archived_at IS NULL
       JOIN shared_vaults AS vault ON vault.team_id = team.id AND vault.archived_at IS NULL
       WHERE membership.team_id = $1 AND vault.id = $2 AND membership.user_id = $3
         AND membership.revoked_at IS NULL`,
      [teamID, vaultID, actorUserID],
    );
    if (!access.rows[0]) throw new Error("team_not_found");
    requireTeamPermission(access.rows[0].role, "manage_vault_keys");
    const result = await this.pool.query(
      `SELECT membership.id AS membership_id, membership.epoch AS membership_epoch,
         device.id AS device_id, device.public_key_algorithm, device.public_key
       FROM team_memberships AS membership
       JOIN devices AS device ON device.user_id = membership.user_id
       WHERE membership.team_id = $1 AND membership.revoked_at IS NULL
         AND device.revoked_at IS NULL AND device.key_approved_at IS NOT NULL
         AND device.public_key IS NOT NULL
       ORDER BY membership.id, device.id`,
      [teamID],
    );
    return result.rows;
  }

  async getSharedVault(teamID, vaultID, actorUserID, actorDeviceID) {
    const result = await this.pool.query(
      `SELECT vault.id, vault.team_id, vault.name, vault.revision, vault.key_generation,
         vault.rotation_required, vault.envelope_version, vault.ciphertext, vault.nonce,
         vault.auth_tag, vault.content_hash, vault.created_at, vault.updated_at,
         membership.id AS membership_id, membership.epoch AS membership_epoch,
         device.id AS device_id, device.key_approved_at,
         wrapper.wrapper_version, wrapper.ephemeral_public_key,
         wrapper.ciphertext AS wrapper_ciphertext, wrapper.nonce AS wrapper_nonce,
         wrapper.auth_tag AS wrapper_auth_tag, wrapper.context_hash
       FROM team_memberships AS membership
       JOIN teams AS team ON team.id = membership.team_id AND team.archived_at IS NULL
       JOIN shared_vaults AS vault ON vault.team_id = team.id AND vault.archived_at IS NULL
       JOIN devices AS device ON device.id = $4 AND device.user_id = membership.user_id
         AND device.revoked_at IS NULL
       LEFT JOIN shared_vault_key_wrappers AS wrapper
         ON wrapper.vault_id = vault.id AND wrapper.key_generation = vault.key_generation
         AND wrapper.membership_id = membership.id AND wrapper.membership_epoch = membership.epoch
         AND wrapper.device_id = device.id
       WHERE membership.team_id = $1 AND vault.id = $2 AND membership.user_id = $3
         AND membership.revoked_at IS NULL`,
      [teamID, vaultID, actorUserID, actorDeviceID],
    );
    const row = result.rows[0];
    if (!row) throw new Error("team_not_found");
    if (!row.key_approved_at) throw new Error("device_approval_required");
    return row;
  }

  async putSharedVault({
    actorUserID,
    actorDeviceID,
    teamID,
    vaultID,
    envelope,
    idempotencyKey,
  }) {
    return this.withTeamMutation(actorUserID, "team.vault.put", idempotencyKey, async (client) => {
      const context = await lockSharedVaultActor(client, teamID, vaultID, actorUserID, actorDeviceID);
      if (!context) throw new Error("team_not_found");
      if (!context.key_approved_at) throw new Error("device_approval_required");
      requireTeamPermission(context.role, "write_vault");
      const currentRevision = Number(context.revision);
      const currentGeneration = Number(context.key_generation);
      if (currentRevision !== envelope.baseRevision) {
        return { conflict: true, revision: currentRevision, keyGeneration: currentGeneration };
      }

      const initializing = currentRevision === 0;
      const rotating = context.rotation_required === true;
      if (initializing || rotating) requireTeamPermission(context.role, "manage_vault_keys");
      if (rotating && envelope.keyGeneration !== currentGeneration + 1) {
        throw new Error("invalid_key_generation");
      }
      if (!rotating && envelope.keyGeneration !== currentGeneration) {
        throw new Error("invalid_key_generation");
      }
      if ((initializing || rotating) !== (envelope.wrappers !== null)) {
        throw new Error(initializing || rotating ? "incomplete_team_vault_wrappers" : "unexpected_team_vault_wrappers");
      }
      if (!initializing && !rotating) {
        const actorWrapper = await client.query(
          `SELECT 1 FROM shared_vault_key_wrappers
           WHERE vault_id = $1 AND key_generation = $2 AND membership_id = $3
             AND membership_epoch = $4 AND device_id = $5`,
          [vaultID, currentGeneration, context.membership_id, context.epoch, actorDeviceID],
        );
        if (!actorWrapper.rows[0]) throw new Error("team_vault_key_unavailable");
      }

      const nextGeneration = envelope.keyGeneration;
      if (envelope.wrappers) {
        const eligible = await lockEligibleTeamDevices(client, teamID);
        requireCompleteWrapperSet(eligible, envelope.wrappers);
        requireWrapperContextHashes(teamID, vaultID, nextGeneration, envelope.wrappers);
        await insertSharedVaultWrappers(
          client,
          vaultID,
          nextGeneration,
          actorDeviceID,
          envelope.wrappers,
        );
      }

      const revision = currentRevision + 1;
      await client.query(
        `INSERT INTO shared_vault_revisions
          (vault_id, revision, key_generation, envelope_version, ciphertext, nonce,
           auth_tag, content_hash, updated_by_device_id)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
        [vaultID, revision, nextGeneration, envelope.envelopeVersion, envelope.ciphertext,
          envelope.nonce, envelope.authTag, envelope.contentHash, actorDeviceID],
      );
      await client.query(
        `UPDATE shared_vaults SET revision = $2, key_generation = $3, envelope_version = $4,
           ciphertext = $5, nonce = $6, auth_tag = $7, content_hash = $8,
           updated_by_device_id = $9, rotation_required = false, updated_at = now()
         WHERE id = $1`,
        [vaultID, revision, nextGeneration, envelope.envelopeVersion, envelope.ciphertext,
          envelope.nonce, envelope.authTag, envelope.contentHash, actorDeviceID],
      );
      if (rotating) {
        await client.query(
          `UPDATE shared_vault_rotation_tasks SET status = 'completed', completed_at = now()
           WHERE vault_id = $1 AND from_generation = $2 AND status = 'pending'`,
          [vaultID, currentGeneration],
        );
      }
      await writeTeamAudit(client, {
        teamID,
        actorUserID,
        action: rotating ? "team.vault_rotated" : "team.vault_revision_created",
        targetVaultID: vaultID,
        metadata: { revision, keyGeneration: nextGeneration },
      });
      return { conflict: false, revision, keyGeneration: nextGeneration, rotationCompleted: rotating };
    });
  }

  async grantSharedVaultWrapper({
    actorUserID,
    actorDeviceID,
    teamID,
    vaultID,
    wrapper,
    keyGeneration,
    idempotencyKey,
  }) {
    return this.withTeamMutation(actorUserID, "team.vault.wrapper.grant", idempotencyKey, async (client) => {
      const context = await lockSharedVaultActor(client, teamID, vaultID, actorUserID, actorDeviceID);
      if (!context) throw new Error("team_not_found");
      if (!context.key_approved_at) throw new Error("device_approval_required");
      requireTeamPermission(context.role, "manage_vault_keys");
      if (!Number.isSafeInteger(keyGeneration) || keyGeneration !== Number(context.key_generation)
        || Number(context.revision) === 0 || context.rotation_required === true) {
        throw new Error("invalid_key_generation");
      }
      const eligible = await lockEligibleTeamDevices(client, teamID);
      const target = eligible.find((row) => row.device_id === wrapper.deviceID);
      if (!target || target.membership_id !== wrapper.membershipID
        || Number(target.membership_epoch) !== wrapper.membershipEpoch) {
        throw new Error("team_not_found");
      }
      requireWrapperContextHashes(teamID, vaultID, keyGeneration, [wrapper]);
      try {
        await insertSharedVaultWrappers(client, vaultID, keyGeneration, actorDeviceID, [wrapper]);
      } catch (error) {
        if (error?.code === "23505") throw new Error("shared_vault_wrapper_exists");
        throw error;
      }
      await writeTeamAudit(client, {
        teamID,
        actorUserID,
        action: "team.vault_wrapper_granted",
        targetMembershipID: wrapper.membershipID,
        targetVaultID: vaultID,
        metadata: { deviceID: wrapper.deviceID, keyGeneration },
      });
      return { granted: true, keyGeneration, deviceID: wrapper.deviceID };
    });
  }

  async claimTeamInvitationOutbox(claimOwner) {
    const result = await this.pool.query(
      `WITH candidate AS (
         SELECT id FROM team_outbox_jobs
         WHERE delivered_at IS NULL AND attempts < 25 AND available_at <= now()
           AND (claimed_at IS NULL OR claimed_at < now() - interval '5 minutes')
         ORDER BY available_at, created_at
         LIMIT 1 FOR UPDATE SKIP LOCKED
       )
       UPDATE team_outbox_jobs AS job SET
         claimed_at = now(), claim_owner = $1, attempts = attempts + 1
       FROM candidate WHERE job.id = candidate.id
       RETURNING job.*`,
      [claimOwner],
    );
    return result.rows[0] ?? null;
  }

  async completeTeamInvitationOutbox(jobID, claimOwner) {
    const result = await this.pool.query(
      `UPDATE team_outbox_jobs SET delivered_at = now(), claimed_at = NULL, claim_owner = NULL
       WHERE id = $1 AND claim_owner = $2 AND delivered_at IS NULL RETURNING id`,
      [jobID, claimOwner],
    );
    return result.rowCount === 1;
  }

  async retryTeamInvitationOutbox(jobID, claimOwner, retrySeconds) {
    const result = await this.pool.query(
      `UPDATE team_outbox_jobs SET claimed_at = NULL, claim_owner = NULL,
         available_at = now() + $3 * interval '1 second'
       WHERE id = $1 AND claim_owner = $2 AND delivered_at IS NULL RETURNING id`,
      [jobID, claimOwner, retrySeconds],
    );
    return result.rowCount === 1;
  }

  async withTeamMutation(actorUserID, operation, idempotencyKey, mutation) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const reservation = await client.query(
        `INSERT INTO team_mutation_receipts (actor_user_id, operation, idempotency_key, response)
         VALUES ($1, $2, $3, '{}'::jsonb)
         ON CONFLICT (actor_user_id, operation, idempotency_key) DO NOTHING
         RETURNING actor_user_id`,
        [actorUserID, operation, idempotencyKey],
      );
      if (!reservation.rows[0]) {
        const replay = await client.query(
          `SELECT response FROM team_mutation_receipts
           WHERE actor_user_id = $1 AND operation = $2 AND idempotency_key = $3`,
          [actorUserID, operation, idempotencyKey],
        );
        await client.query("COMMIT");
        return replay.rows[0]?.response ?? {};
      }
      const response = await mutation(client);
      await client.query(
        `UPDATE team_mutation_receipts SET response = $4::jsonb
         WHERE actor_user_id = $1 AND operation = $2 AND idempotency_key = $3`,
        [actorUserID, operation, idempotencyKey, JSON.stringify(response)],
      );
      await client.query("COMMIT");
      return response;
    } catch (error) {
      try { await client.query("ROLLBACK"); } catch {}
      throw error;
    } finally {
      client.release();
    }
  }
}

async function lockTeamActor(client, teamID, actorUserID) {
  const result = await client.query(
    `SELECT membership.id, membership.user_id, membership.role, membership.epoch
     FROM team_memberships AS membership
     JOIN teams AS team ON team.id = membership.team_id
     WHERE membership.team_id = $1 AND membership.user_id = $2
       AND membership.revoked_at IS NULL AND team.archived_at IS NULL
     FOR UPDATE OF membership, team`,
    [teamID, actorUserID],
  );
  return result.rows[0] ?? null;
}

async function lockTeamMembership(client, teamID, membershipID) {
  const result = await client.query(
    `SELECT id, user_id, role, epoch FROM team_memberships
     WHERE team_id = $1 AND id = $2 AND revoked_at IS NULL FOR UPDATE`,
    [teamID, membershipID],
  );
  return result.rows[0] ?? null;
}

async function lockSharedVaultActor(client, teamID, vaultID, actorUserID, actorDeviceID) {
  const result = await client.query(
    `SELECT membership.id AS membership_id, membership.role, membership.epoch,
       device.key_approved_at, vault.revision, vault.key_generation, vault.rotation_required
     FROM team_memberships AS membership
     JOIN teams AS team ON team.id = membership.team_id AND team.archived_at IS NULL
     JOIN shared_vaults AS vault ON vault.team_id = team.id AND vault.archived_at IS NULL
     JOIN devices AS device ON device.id = $4 AND device.user_id = membership.user_id
       AND device.revoked_at IS NULL
     WHERE membership.team_id = $1 AND vault.id = $2 AND membership.user_id = $3
       AND membership.revoked_at IS NULL
     FOR UPDATE OF membership, team, vault, device`,
    [teamID, vaultID, actorUserID, actorDeviceID],
  );
  return result.rows[0] ?? null;
}

async function lockEligibleTeamDevices(client, teamID) {
  const result = await client.query(
    `SELECT membership.id AS membership_id, membership.epoch AS membership_epoch,
       device.id AS device_id
     FROM team_memberships AS membership
     JOIN devices AS device ON device.user_id = membership.user_id
     WHERE membership.team_id = $1 AND membership.revoked_at IS NULL
       AND device.revoked_at IS NULL AND device.key_approved_at IS NOT NULL
       AND device.public_key IS NOT NULL
     ORDER BY membership.id, device.id
     FOR UPDATE OF membership, device`,
    [teamID],
  );
  return result.rows;
}

function requireCompleteWrapperSet(eligible, wrappers) {
  if (eligible.length === 0 || wrappers.length !== eligible.length) {
    throw new Error("incomplete_team_vault_wrappers");
  }
  const byDevice = new Map(wrappers.map((wrapper) => [wrapper.deviceID, wrapper]));
  for (const row of eligible) {
    const wrapper = byDevice.get(row.device_id);
    if (!wrapper || wrapper.membershipID !== row.membership_id
      || wrapper.membershipEpoch !== Number(row.membership_epoch)) {
      throw new Error("incomplete_team_vault_wrappers");
    }
  }
}

function requireWrapperContextHashes(teamID, vaultID, keyGeneration, wrappers) {
  for (const wrapper of wrappers) {
    const expected = teamVaultWrapperContextHash({
      teamID,
      vaultID,
      keyGeneration,
      membershipID: wrapper.membershipID,
      membershipEpoch: wrapper.membershipEpoch,
      deviceID: wrapper.deviceID,
    });
    if (wrapper.contextHash !== expected) throw new Error("invalid_team_vault_wrapper_context");
  }
}

async function insertSharedVaultWrappers(client, vaultID, keyGeneration, actorDeviceID, wrappers) {
  for (const wrapper of wrappers) {
    await client.query(
      `INSERT INTO shared_vault_key_wrappers
        (vault_id, key_generation, membership_id, membership_epoch, device_id,
         wrapper_version, ephemeral_public_key, ciphertext, nonce, auth_tag,
         context_hash, created_by_device_id)
       VALUES ($1,$2,$3,$4,$5,$6,$7::jsonb,$8,$9,$10,$11,$12)`,
      [vaultID, keyGeneration, wrapper.membershipID, wrapper.membershipEpoch,
        wrapper.deviceID, wrapper.wrapperVersion, JSON.stringify(wrapper.ephemeralPublicKey),
        wrapper.ciphertext, wrapper.nonce, wrapper.authTag, wrapper.contextHash, actorDeviceID],
    );
  }
}

async function requireAnotherOwner(client, teamID, excludedMembershipID) {
  const result = await client.query(
    `SELECT id FROM team_memberships
     WHERE team_id = $1 AND role = 'owner' AND revoked_at IS NULL AND id <> $2
     ORDER BY id FOR UPDATE`,
    [teamID, excludedMembershipID],
  );
  if (!result.rows[0]) throw new Error("team_last_owner");
}

async function writeTeamAudit(client, {
  teamID,
  actorUserID,
  action,
  targetUserID = null,
  targetMembershipID = null,
  targetVaultID = null,
  metadata = {},
}) {
  await client.query(
    `INSERT INTO team_audit_events
      (team_id, actor_user_id, action, target_user_id, target_membership_id, target_vault_id, metadata)
     VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb)`,
    [teamID, actorUserID, action, targetUserID, targetMembershipID, targetVaultID, JSON.stringify(metadata)],
  );
}
