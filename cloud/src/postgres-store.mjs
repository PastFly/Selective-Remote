import pg from "pg";
import {
  requireInvitationPermission,
  requireMembershipChange,
  requireTeamPermission,
} from "./team-policy.mjs";

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
        "INSERT INTO devices (id, user_id, name, platform, app_version, public_key) VALUES ($1, $2, $3, $4, $5, $6)",
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
      await client.query(
        `INSERT INTO devices (id, user_id, name, platform, app_version, public_key)
         VALUES ($1, $2, $3, $4, $5, $6)
         ON CONFLICT (user_id, id) DO UPDATE SET
           name = EXCLUDED.name, platform = EXCLUDED.platform,
           app_version = EXCLUDED.app_version, public_key = EXCLUDED.public_key,
           last_seen_at = now(), revoked_at = NULL`,
        [device.id, userID, device.name, device.platform, device.appVersion, device.publicKey],
      );
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
      `SELECT id, name, platform, app_version, created_at, last_seen_at, revoked_at
       FROM devices WHERE user_id = $1 ORDER BY last_seen_at DESC`,
      [userID],
    );
    return result.rows;
  }

  async revokeDevice(userID, deviceID) {
    const result = await this.pool.query(
      "UPDATE devices SET revoked_at = now() WHERE user_id = $1 AND id = $2 AND revoked_at IS NULL RETURNING id",
      [userID, deviceID],
    );
    if (result.rowCount === 0) return false;
    await this.pool.query("UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL", [userID, deviceID]);
    return true;
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
