// Account-scoped public device admission records. No private key is stored here.
export class DeviceTrustStore {
  constructor(pool) { this.pool = pool; }

  async getSnapshot(accountID) {
    const [root, directory, certificates] = await Promise.all([
      this.pool.query(
        `SELECT root_public_key, fingerprint, custodian_device_id, created_at
         FROM device_trust_roots_v1 WHERE account_id = $1`, [accountID]),
      this.pool.query(
        `SELECT version, directory_json FROM device_trust_directories_v1
         WHERE account_id = $1 ORDER BY version DESC LIMIT 1`, [accountID]),
      this.pool.query(
        `SELECT device_id, key_version, certificate_json
         FROM device_trust_certificates_v1 WHERE account_id = $1
         ORDER BY device_id, key_version DESC`, [accountID]),
    ]);
    if (!root.rows[0]) return { state: "UNINITIALIZED" };
    return { state: "ROOT_PUBLISHED",
      rootPublicKey: root.rows[0].root_public_key.toString("base64url"),
      rootFingerprint: root.rows[0].fingerprint.toString("hex"),
      custodianDeviceID: root.rows[0].custodian_device_id,
      createdAt: root.rows[0].created_at,
      checkpoint: directory.rows[0]?.directory_json ?? null,
      certificates: certificates.rows.map((row) => row.certificate_json) };
  }

  async listRequests(accountID, actorDeviceID, custodian) {
    const result = await this.pool.query(
      `SELECT request.id, request.device_id, request.key_version, request.public_key_json,
              request.state, request.created_at, request.expires_at, request.decided_at,
              device.name, device.platform, live_challenge.id AS challenge_id,
              live_challenge.state AS challenge_state
       FROM device_trust_requests_v1 AS request
       JOIN devices AS device ON device.user_id = request.account_id AND device.id = request.device_id
       LEFT JOIN LATERAL (
         SELECT id, state FROM device_trust_challenges_v1
         WHERE account_id = request.account_id AND request_id = request.id
           AND state IN ('offered', 'answered') AND expires_at > now()
         ORDER BY created_at DESC LIMIT 1
       ) AS live_challenge ON true
       WHERE request.account_id = $1 AND ($2::boolean OR request.device_id = $3)
       ORDER BY request.created_at DESC LIMIT 100`, [accountID, custodian, actorDeviceID]);
    return result.rows.map((row) => ({ requestID: row.id, deviceID: row.device_id,
      keyVersion: Number(row.key_version), publicKey: row.public_key_json,
      status: row.state, createdAt: row.created_at, expiresAt: row.expires_at,
      decidedAt: row.decided_at, name: row.name, platform: row.platform,
      challengeID: row.challenge_id, challengeState: row.challenge_state }));
  }

  async getChallenge(accountID, actorDeviceID, requestID, challengeID, custodian) {
    const result = await this.pool.query(
      `SELECT challenge.challenge_json, challenge.proof, challenge.state,
              challenge.expires_at, request.device_id
       FROM device_trust_challenges_v1 AS challenge
       JOIN device_trust_requests_v1 AS request
         ON request.account_id = challenge.account_id AND request.id = challenge.request_id
       WHERE challenge.account_id = $1 AND challenge.request_id = $2
         AND challenge.id = $3 AND ($4::boolean OR request.device_id = $5)`,
      [accountID, requestID, challengeID, custodian, actorDeviceID]);
    const row = result.rows[0];
    if (!row) throw new Error("device_trust_not_found");
    return { challenge: row.challenge_json, state: row.state,
      proof: custodian && row.proof ? row.proof.toString("base64url") : null,
      expiresAt: row.expires_at };
  }

  async requireCustodian(client, accountID, actorDeviceID) {
    const root = await client.query(
      `SELECT custodian_device_id, root_public_key FROM device_trust_roots_v1
       WHERE account_id = $1 FOR UPDATE`, [accountID]);
    if (!root.rows[0] || root.rows[0].custodian_device_id !== actorDeviceID) {
      throw new Error("device_trust_forbidden");
    }
    const device = await client.query(
      `SELECT revoked_at FROM devices WHERE user_id = $1 AND id = $2 FOR UPDATE`,
      [accountID, actorDeviceID]);
    if (!device.rows[0] || device.rows[0].revoked_at) throw new Error("device_trust_forbidden");
    return root.rows[0];
  }

  async lockedRequest(client, accountID, requestID) {
    const result = await client.query(
      `SELECT id, device_id, state, key_version, public_key, public_key_json,
              expires_at FROM device_trust_requests_v1
       WHERE account_id = $1 AND id = $2 FOR UPDATE`, [accountID, requestID]);
    if (!result.rows[0]) throw new Error("device_trust_not_found");
    return result.rows[0];
  }

  requireLiveRequest(request, states) {
    if (!states.includes(request.state) || new Date(request.expires_at).getTime() <= Date.now()) {
      throw new Error("device_trust_conflict");
    }
  }

  async mutate(accountID, operation, idempotencyKey, action) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const owner = await client.query(
        "SELECT id FROM users WHERE id = $1 AND disabled_at IS NULL FOR UPDATE", [accountID]);
      if (!owner.rows[0]) throw new Error("device_trust_not_found");
      const reservation = await client.query(
        `INSERT INTO device_trust_mutation_receipts_v1
          (account_id, operation, idempotency_key, response)
         VALUES ($1, $2, $3, '{}'::jsonb)
         ON CONFLICT (account_id, operation, idempotency_key) DO NOTHING
         RETURNING account_id`, [accountID, operation, idempotencyKey]);
      if (!reservation.rows[0]) {
        const replay = await client.query(
          `SELECT response FROM device_trust_mutation_receipts_v1
           WHERE account_id = $1 AND operation = $2 AND idempotency_key = $3`,
          [accountID, operation, idempotencyKey]);
        await client.query("COMMIT");
        return replay.rows[0]?.response ?? {};
      }
      const response = await action(client);
      await client.query(
        `UPDATE device_trust_mutation_receipts_v1 SET response = $4::jsonb
         WHERE account_id = $1 AND operation = $2 AND idempotency_key = $3`,
        [accountID, operation, idempotencyKey, JSON.stringify(response)]);
      await client.query("COMMIT");
      return response;
    } catch (error) {
      try { await client.query("ROLLBACK"); } catch {}
      if (["23505", "40001", "40P01"].includes(error?.code)
        || error?.message === "stale_device_directory") {
        throw new Error("device_trust_conflict");
      }
      if (["23503", "23514", "22P02"].includes(error?.code)) {
        throw new Error("device_trust_invalid");
      }
      throw error;
    } finally { client.release(); }
  }

  async publishRoot({ accountID, actorDeviceID, bundle, expectedPublicKey,
    certificate, checkpoint, idempotencyKey }) {
    if (bundle.keyVersion !== 1 || bundle.directoryVersion !== 1
      || certificate?.payload?.deviceID !== actorDeviceID
      || checkpoint?.payload?.version !== 1
      || checkpoint.payload.entries.length !== 1
      || checkpoint.payload.entries[0].deviceID !== actorDeviceID) {
      throw new Error("device_trust_invalid");
    }
    return this.mutate(accountID, "root.publish", idempotencyKey, async (client) => {
      const root = await client.query(
        `SELECT root_public_key, custodian_device_id FROM device_trust_roots_v1
         WHERE account_id = $1 FOR UPDATE`, [accountID]);
      if (root.rows[0]) {
        if (!root.rows[0].root_public_key.equals(bundle.rootBytes)
          || root.rows[0].custodian_device_id !== actorDeviceID) {
          throw new Error("device_trust_conflict");
        }
        return { published: true, existing: true, rootFingerprint: bundle.fingerprint.toString("hex") };
      }
      const device = await client.query(
        `SELECT public_key, revoked_at FROM devices
         WHERE user_id = $1 AND id = $2 FOR UPDATE`, [accountID, actorDeviceID]);
      if (!device.rows[0] || device.rows[0].revoked_at
        || device.rows[0].public_key !== expectedPublicKey) throw new Error("device_trust_invalid");
      await client.query(
        `INSERT INTO device_trust_roots_v1
          (account_id, root_public_key, fingerprint, custodian_device_id)
         VALUES ($1, $2, $3, $4)`,
        [accountID, bundle.rootBytes, bundle.fingerprint, actorDeviceID]);
      await client.query(
        `INSERT INTO device_trust_certificates_v1
          (account_id, device_id, key_version, certificate_bytes, signature,
           serial, certificate_json)
         VALUES ($1, $2, 1, $3, $4, $5, $6::jsonb)`,
        [accountID, actorDeviceID, bundle.certificateBytes,
          bundle.certificateSignature, bundle.serial, JSON.stringify(certificate)]);
      await client.query(
        `INSERT INTO device_trust_directories_v1
          (account_id, version, directory_bytes, signature, directory_json)
         VALUES ($1, 1, $2, $3, $4::jsonb)`,
        [accountID, bundle.directoryBytes, bundle.directorySignature,
          JSON.stringify(checkpoint)]);
      await client.query(
        `INSERT INTO device_trust_account_events_v1
          (account_id, actor_device_id, target_device_id, action, key_version)
         VALUES ($1, $2, $2, 'device.approved', 1)`, [accountID, actorDeviceID]);
      return { published: true, existing: false,
        rootFingerprint: bundle.fingerprint.toString("hex") };
    });
  }

  async createRequest({ accountID, actorDeviceID, deviceID, requestID,
    publicKeyBytes, publicKeyJSON, keyDigest, keyVersion, idempotencyKey }) {
    if (actorDeviceID !== deviceID || !Number.isSafeInteger(keyVersion) || keyVersion < 1
      || !Buffer.isBuffer(publicKeyBytes) || publicKeyBytes.length !== 65
      || !Buffer.isBuffer(keyDigest) || keyDigest.length !== 32
      || typeof publicKeyJSON !== "string") throw new Error("device_trust_invalid");
    return this.mutate(accountID, "device.request", idempotencyKey, async (client) => {
      const root = await client.query(
        `SELECT account_id FROM device_trust_roots_v1
         WHERE account_id = $1 FOR UPDATE`, [accountID]);
      if (!root.rows[0]) throw new Error("device_trust_pairing_required");
      const device = await client.query(
        `SELECT public_key, revoked_at FROM devices
         WHERE user_id = $1 AND id = $2 FOR UPDATE`, [accountID, deviceID]);
      if (!device.rows[0] || device.rows[0].revoked_at) throw new Error("device_trust_invalid");
      const latest = await client.query(
        `SELECT COALESCE(MAX(key_version), 0) AS version
         FROM device_trust_certificates_v1 WHERE account_id = $1 AND device_id = $2`,
        [accountID, deviceID]);
      const priorVersion = Number(latest.rows[0]?.version ?? 0);
      if (keyVersion !== priorVersion + 1
        || (priorVersion === 0 && device.rows[0].public_key !== publicKeyJSON)
        || (priorVersion > 0 && device.rows[0].public_key === publicKeyJSON)) {
        throw new Error("device_trust_invalid");
      }
      await client.query(
        `UPDATE device_trust_requests_v1 SET state = 'expired', decided_at = now()
         WHERE account_id = $1 AND device_id = $2
           AND state IN ('pending', 'challenged', 'answered') AND expires_at <= now()`,
        [accountID, deviceID]);
      await client.query(
        `INSERT INTO device_trust_requests_v1
          (id, account_id, device_id, key_version, public_key, public_key_json,
           key_digest, expires_at)
         VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, now() + interval '15 minutes')`,
        [requestID, accountID, deviceID, keyVersion, publicKeyBytes,
          publicKeyJSON, keyDigest]);
      const action = priorVersion === 0 ? "device.pending" : "device.rekey_requested";
      await client.query(
        `INSERT INTO device_trust_account_events_v1
          (account_id, actor_device_id, target_device_id, action, key_version)
         VALUES ($1, $2, $2, '${action}', $3)`,
        [accountID, deviceID, keyVersion]);
      return { requestID, keyVersion, status: "pending" };
    });
  }

  async startChallenge({ accountID, actorDeviceID, requestID, challengeID,
    challengeBytes, challenge, idempotencyKey }) {
    if (!Buffer.isBuffer(challengeBytes) || challengeBytes.length < 1
      || challengeBytes.length > 4096 || challenge?.accountID !== accountID
      || challenge.requestID !== requestID) throw new Error("device_trust_invalid");
    return this.mutate(accountID, "challenge.start", idempotencyKey, async (client) => {
      await this.requireCustodian(client, accountID, actorDeviceID);
      const request = await this.lockedRequest(client, accountID, requestID);
      this.requireLiveRequest(request, ["pending", "challenged"]);
      if (challenge.deviceID && challenge.deviceID !== request.device_id) {
        throw new Error("device_trust_invalid");
      }
      if (challenge.publicKey && (challenge.publicKey.x !== request.public_key_json?.x
        || challenge.publicKey.y !== request.public_key_json?.y)) {
        throw new Error("device_trust_invalid");
      }
      await client.query(
        `UPDATE device_trust_challenges_v1 SET state = 'expired'
         WHERE account_id = $1 AND request_id = $2
           AND state IN ('offered', 'answered') AND expires_at <= now()`,
        [accountID, requestID]);
      await client.query(
        `INSERT INTO device_trust_challenges_v1
          (id, account_id, request_id, challenge_bytes, challenge_json, expires_at)
         VALUES ($1, $2, $3, $4, $5::jsonb, now() + interval '5 minutes')`,
        [challengeID, accountID, requestID, challengeBytes, JSON.stringify(challenge)]);
      await client.query(
        `UPDATE device_trust_requests_v1 SET state = 'challenged'
         WHERE account_id = $1 AND id = $2`, [accountID, requestID]);
      return { requestID, challengeID, status: "challenged" };
    });
  }

  async answerChallenge({ accountID, actorDeviceID, requestID, challengeID,
    proof, idempotencyKey }) {
    if (!Buffer.isBuffer(proof) || proof.length !== 32) throw new Error("device_trust_invalid");
    return this.mutate(accountID, "challenge.answer", idempotencyKey, async (client) => {
      const request = await this.lockedRequest(client, accountID, requestID);
      if (request.device_id !== actorDeviceID) throw new Error("device_trust_not_found");
      this.requireLiveRequest(request, ["challenged"]);
      const result = await client.query(
        `SELECT id, state, expires_at FROM device_trust_challenges_v1
         WHERE account_id = $1 AND request_id = $2 AND id = $3 FOR UPDATE`,
        [accountID, requestID, challengeID]);
      const challenge = result.rows[0];
      if (!challenge || challenge.state !== "offered"
        || new Date(challenge.expires_at).getTime() <= Date.now()) {
        throw new Error("device_trust_conflict");
      }
      await client.query(
        `UPDATE device_trust_challenges_v1
         SET state = 'answered', proof = $4, answered_at = now()
         WHERE account_id = $1 AND request_id = $2 AND id = $3`,
        [accountID, requestID, challengeID, proof]);
      await client.query(
        `UPDATE device_trust_requests_v1 SET state = 'answered'
         WHERE account_id = $1 AND id = $2`, [accountID, requestID]);
      return { requestID, challengeID, status: "answered" };
    });
  }

  async rejectRequest({ accountID, actorDeviceID, requestID, idempotencyKey }) {
    return this.mutate(accountID, "device.reject", idempotencyKey, async (client) => {
      await this.requireCustodian(client, accountID, actorDeviceID);
      const request = await this.lockedRequest(client, accountID, requestID);
      this.requireLiveRequest(request, ["pending", "challenged", "answered"]);
      await client.query(
        `UPDATE device_trust_requests_v1 SET state = 'rejected', decided_at = now(),
           approver_device_id = $3 WHERE account_id = $1 AND id = $2`,
        [accountID, requestID, actorDeviceID]);
      await client.query(
        `UPDATE device_trust_challenges_v1 SET state = 'expired'
         WHERE account_id = $1 AND request_id = $2 AND state IN ('offered', 'answered')`,
        [accountID, requestID]);
      await client.query(
        `INSERT INTO device_trust_account_events_v1
          (account_id, actor_device_id, target_device_id, action, key_version)
         VALUES ($1, $2, $3, 'device.rejected', $4)`,
        [accountID, actorDeviceID, request.device_id, request.key_version]);
      return { requestID, status: "rejected" };
    });
  }

  async approveRequest({ accountID, actorDeviceID, requestID, challengeID,
    bundle, certificate, checkpoint, idempotencyKey }) {
    return this.mutate(accountID, "device.approve", idempotencyKey, async (client) => {
      const root = await this.requireCustodian(client, accountID, actorDeviceID);
      const request = await this.lockedRequest(client, accountID, requestID);
      this.requireLiveRequest(request, ["answered"]);
      if (!root.root_public_key.equals(bundle.rootBytes)
        || request.key_version !== bundle.keyVersion
        || !request.public_key.equals(bundle.publicKeyBytes)
        || certificate?.payload?.deviceID !== request.device_id
        || certificate.payload.keyVersion !== request.key_version
        || checkpoint?.payload?.version !== bundle.directoryVersion) {
        throw new Error("device_trust_invalid");
      }
      const result = await client.query(
        `SELECT id, state, expires_at, proof FROM device_trust_challenges_v1
         WHERE account_id = $1 AND request_id = $2 AND id = $3 FOR UPDATE`,
        [accountID, requestID, challengeID]);
      const challenge = result.rows[0];
      if (!challenge || challenge.state !== "answered"
        || new Date(challenge.expires_at).getTime() <= Date.now()) {
        throw new Error("device_trust_conflict");
      }
      const latest = await client.query(
        `SELECT COALESCE(MAX(version), 0) AS version FROM device_trust_directories_v1
         WHERE account_id = $1`, [accountID]);
      if (bundle.directoryVersion !== Number(latest.rows[0]?.version ?? 0) + 1) {
        throw new Error("device_trust_conflict");
      }
      const prior = await client.query(
        `SELECT directory_json FROM device_trust_directories_v1
         WHERE account_id = $1 ORDER BY version DESC LIMIT 1`, [accountID]);
      const oldEntries = prior.rows[0]?.directory_json?.payload?.entries;
      if (!Array.isArray(oldEntries)) throw new Error("device_trust_invalid");
      const nextEntries = checkpoint.payload.entries;
      const unaffected = (entries) => entries.filter((entry) => entry.deviceID !== request.device_id)
        .map((entry) => [entry.deviceID, entry.keyVersion, entry.certificateDigest]);
      if (JSON.stringify(unaffected(oldEntries)) !== JSON.stringify(unaffected(nextEntries))
        || nextEntries.filter((entry) => entry.deviceID === request.device_id).length !== 1) {
        throw new Error("device_trust_invalid");
      }
      await client.query(
        `INSERT INTO device_trust_certificates_v1
          (account_id, device_id, key_version, certificate_bytes, signature,
           serial, certificate_json) VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb)`,
        [accountID, request.device_id, bundle.keyVersion, bundle.certificateBytes,
          bundle.certificateSignature, bundle.serial, JSON.stringify(certificate)]);
      await client.query(
        `INSERT INTO device_trust_directories_v1
          (account_id, version, directory_bytes, signature, directory_json)
         VALUES ($1, $2, $3, $4, $5::jsonb)`,
        [accountID, bundle.directoryVersion, bundle.directoryBytes,
          bundle.directorySignature, JSON.stringify(checkpoint)]);
      await client.query(
        `UPDATE device_trust_challenges_v1 SET state = 'consumed', consumed_at = now()
         WHERE account_id = $1 AND request_id = $2 AND id = $3`,
        [accountID, requestID, challengeID]);
      await client.query(
        `UPDATE device_trust_requests_v1 SET state = 'approved', decided_at = now(),
           approver_device_id = $3, certificate_serial = $4
         WHERE account_id = $1 AND id = $2`,
        [accountID, requestID, actorDeviceID, bundle.serial]);
      const action = request.key_version === 1 ? "device.approved" : "device.rekey_approved";
      await client.query(
        `INSERT INTO device_trust_account_events_v1
          (account_id, actor_device_id, target_device_id, action, key_version)
         VALUES ($1, $2, $3, $4, $5)`,
        [accountID, actorDeviceID, request.device_id, action, request.key_version]);
      return { requestID, status: "approved", directoryVersion: bundle.directoryVersion };
    });
  }
}
