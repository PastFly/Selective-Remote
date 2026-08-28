import pg from "pg";

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
      await client.query("SELECT id FROM users WHERE id = $1 FOR UPDATE", [userID]);
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
}
