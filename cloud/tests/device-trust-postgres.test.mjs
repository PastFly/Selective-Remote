import assert from "node:assert/strict";
import { createHash, randomUUID, webcrypto } from "node:crypto";
import test from "node:test";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { applyMigrations } from "../src/migrations.mjs";
import { DeviceTrustStore } from "../src/device-trust-store.mjs";
import { validateSignedDeviceBundle, validateSignedDeviceDirectory } from "../src/device-trust-policy.mjs";
import { generateTeamDeviceIdentity } from "../public/team-vault-crypto.js";
import { answerPossessionChallenge, createPossessionChallenge,
  devicePossessionChallengeBytes, issueDeviceCertificate, signDeviceDirectory,
  createTrustRoot, verifyPossessionAnswer } from "../public/device-trust-v1.js";

const databaseURL = process.env.TEST_DATABASE_URL;
const migrationsDirectory = fileURLToPath(new URL("../migrations/", import.meta.url));

test("signed device trust records are additive, unique and bounded in PostgreSQL", {
  skip: databaseURL ? false : "TEST_DATABASE_URL is not configured",
}, async () => {
  const pool = new pg.Pool({ connectionString: databaseURL, max: 2 });
  try {
    await applyMigrations(pool, migrationsDirectory, { info() {} });
    const v2Before = Number((await pool.query(`SELECT count(*) AS count FROM shared_vaults
      WHERE format_state = 'V2_ACTIVE'`)).rows[0].count);
    const suffix = randomUUID().replaceAll("-", "").slice(0, 12);
    const account = (await pool.query(`INSERT INTO users (email, username) VALUES ($1, $2) RETURNING id`,
      [`trust-${suffix}@example.test`, `trust_${suffix}`])).rows[0].id;
    const device = randomUUID();
    await pool.query(`INSERT INTO devices (id, user_id, name, platform)
      VALUES ($1, $2, 'Test', 'web')`, [device, account]);
    const root = Buffer.alloc(65, 7); root[0] = 4;
    const fingerprint = Buffer.alloc(32, 9);
    await pool.query(`INSERT INTO device_trust_roots_v1
      (account_id, root_public_key, fingerprint) VALUES ($1, $2, $3)`, [account, root, fingerprint]);
    await assert.rejects(pool.query(`INSERT INTO device_trust_roots_v1
      (account_id, root_public_key, fingerprint) VALUES ($1, $2, $3)`, [account, root, fingerprint]),
    (error) => error.code === "23505");
    const signature = Buffer.alloc(64, 1);
    await pool.query(`INSERT INTO device_trust_certificates_v1
      (account_id, device_id, key_version, certificate_bytes, signature, serial)
      VALUES ($1, $2, 1, $3, $4, $5)`, [account, device, Buffer.from("cert"), signature, randomUUID()]);
    await assert.rejects(pool.query(`INSERT INTO device_trust_certificates_v1
      (account_id, device_id, key_version, certificate_bytes, signature, serial)
      VALUES ($1, $2, 1, $3, $4, $5)`, [account, device, Buffer.from("cert"), signature, randomUUID()]),
    (error) => error.code === "23505");
    await assert.rejects(pool.query(`INSERT INTO device_trust_certificates_v1
      (account_id, device_id, key_version, certificate_bytes, signature, serial)
      VALUES ($1, $2, 2, $3, $4, $5)`, [account, device, Buffer.alloc(65536), signature, randomUUID()]),
    (error) => error.code === "23514");
    await pool.query(`INSERT INTO device_trust_directories_v1
      (account_id, version, directory_bytes, signature) VALUES ($1, 1, $2, $3)`,
    [account, Buffer.from("directory"), signature]);
    await assert.rejects(pool.query(`INSERT INTO device_trust_directories_v1
      (account_id, version, directory_bytes, signature) VALUES ($1, 1, $2, $3)`,
    [account, Buffer.from("directory"), signature]),
    (error) => error.message === "stale_device_directory");
    const vaultState = await pool.query(`SELECT count(*)::int AS count FROM shared_vaults
      WHERE format_state = 'V2_ACTIVE'`);
    assert.equal(vaultState.rows[0].count, v2Before);
  } finally { await pool.end(); }
});

test("concurrent direct SQL cannot create two open approvals or reuse a directory version", {
  skip: databaseURL ? false : "TEST_DATABASE_URL is not configured",
}, async () => {
  const pool = new pg.Pool({ connectionString: databaseURL, max: 4 });
  try {
    await applyMigrations(pool, migrationsDirectory, { info() {} });
    const suffix = randomUUID().replaceAll("-", "").slice(0, 12);
    const account = (await pool.query(`INSERT INTO users (email, username)
      VALUES ($1, $2) RETURNING id`, [`approval-${suffix}@example.test`, `approval_${suffix}`])).rows[0].id;
    const device = randomUUID();
    await pool.query(`INSERT INTO devices (id, user_id, name, platform)
      VALUES ($1, $2, 'Test', 'web')`, [device, account]);
    const root = Buffer.alloc(65, 7); root[0] = 4;
    await pool.query(`INSERT INTO device_trust_roots_v1
      (account_id, root_public_key, fingerprint) VALUES ($1, $2, $3)`, [account, root, Buffer.alloc(32, 9)]);
    const directories = await Promise.allSettled([1, 2].map(() => pool.query(
      `INSERT INTO device_trust_directories_v1
        (account_id, version, directory_bytes, signature) VALUES ($1, 1, $2, $3)`,
      [account, Buffer.from("directory"), Buffer.alloc(64, 1)])));
    assert.equal(directories.filter((item) => item.status === "fulfilled").length, 1);
    const requestID = randomUUID();
    const requestValues = [requestID, account, device, root, Buffer.alloc(32, 1)];
    const requests = await Promise.allSettled([requestID, randomUUID()].map((id) => pool.query(
      `INSERT INTO device_trust_requests_v1
        (id, account_id, device_id, key_version, public_key, public_key_json,
         key_digest, expires_at)
       VALUES ($1, $2, $3, 1, $4, '{}'::jsonb, $5, now() + interval '15 minutes')`,
      [id, ...requestValues.slice(1)])));
    assert.equal(requests.filter((item) => item.status === "fulfilled").length, 1);
    const challenge = (id) => pool.query(`INSERT INTO device_trust_challenges_v1
      (id, account_id, request_id, challenge_bytes, challenge_json, expires_at)
      VALUES ($1, $2, $3, $4, '{}'::jsonb, now() + interval '4 minutes')`,
    [id, account, requestID, Buffer.from("challenge")]);
    const challenges = await Promise.allSettled([challenge(randomUUID()), challenge(randomUUID())]);
    assert.equal(challenges.filter((item) => item.status === "fulfilled").length, 1);
  } finally { await pool.end(); }
});

test("PostgreSQL serializes bootstrap, proof, approval, rekey and signed revocation", {
  skip: databaseURL ? false : "TEST_DATABASE_URL is not configured",
}, async () => {
  const pool = new pg.Pool({ connectionString: databaseURL, max: 4 });
  try {
    await applyMigrations(pool, migrationsDirectory, { info() {} });
    const suffix = randomUUID().replaceAll("-", "").slice(0, 12);
    const accountID = (await pool.query(`INSERT INTO users (email, username)
      VALUES ($1, $2) RETURNING id`, [`lifecycle-${suffix}@example.test`, `lifecycle_${suffix}`])).rows[0].id;
    const firstID = randomUUID();
    const secondID = randomUUID();
    const first = await generateTeamDeviceIdentity(webcrypto);
    const second = await generateTeamDeviceIdentity(webcrypto);
    const keyJSON = (key) => JSON.stringify(key);
    for (const [id, key] of [[firstID, first.publicKey], [secondID, second.publicKey]]) {
      await pool.query(`INSERT INTO devices
        (id, user_id, name, platform, public_key, public_key_algorithm, key_registered_at)
        VALUES ($1, $2, 'Test', 'web', $3, 'p256-ecdh-v1', now())`,
      [id, accountID, keyJSON(key)]);
    }
    const root = await createTrustRoot({ endpoint: "https://cloud.example.test", accountID,
      cryptoValue: webcrypto });
    const firstCertificate = await issueDeviceCertificate({ root, accountID,
      deviceID: firstID, publicKey: first.publicKey, keyVersion: 1,
      issuedAt: Math.floor(Date.now() / 1000), serial: randomUUID(), cryptoValue: webcrypto });
    const firstDirectory = await signDeviceDirectory({ root, accountID, version: 1,
      certificates: [firstCertificate], cryptoValue: webcrypto });
    const firstBundle = await validateSignedDeviceBundle({ rootPublicKey: root.publicKey,
      certificate: firstCertificate, checkpoint: firstDirectory,
      accountID, deviceID: firstID, publicKey: first.publicKey });
    const store = new DeviceTrustStore(pool);
    await store.publishRoot({ accountID, actorDeviceID: firstID, bundle: firstBundle,
      expectedPublicKey: keyJSON(first.publicKey), certificate: firstCertificate,
      checkpoint: firstDirectory, idempotencyKey: randomUUID() });
    const requestID = randomUUID();
    const secondKeyBytes = Buffer.concat([Buffer.from([4]),
      Buffer.from(second.publicKey.x, "base64url"),
      Buffer.from(second.publicKey.y, "base64url")]);
    await store.createRequest({ accountID, actorDeviceID: secondID, deviceID: secondID,
      requestID, publicKeyBytes: secondKeyBytes,
      publicKeyJSON: keyJSON(second.publicKey),
      keyDigest: createHash("sha256").update(secondKeyBytes).digest(),
      keyVersion: 1, idempotencyKey: randomUUID() });
    const offered = await createPossessionChallenge({ accountID, requestID, deviceID: secondID,
      publicKey: second.publicKey, issuedAt: Math.floor(Date.now() / 1000), cryptoValue: webcrypto });
    const challengeID = randomUUID();
    await store.startChallenge({ accountID, actorDeviceID: firstID, requestID, challengeID,
      challengeBytes: Buffer.from(devicePossessionChallengeBytes(offered.challenge)),
      challenge: offered.challenge, idempotencyKey: randomUUID() });
    const answer = await answerPossessionChallenge({ challenge: offered.challenge,
      devicePrivateKey: second.privateKey, devicePublicKey: second.publicKey, cryptoValue: webcrypto });
    await store.answerChallenge({ accountID, actorDeviceID: secondID, requestID, challengeID,
      proof: Buffer.from(answer.proof, "base64url"), idempotencyKey: randomUUID() });
    const relayed = await store.getChallenge(accountID, firstID, requestID, challengeID, true);
    assert.equal(await verifyPossessionAnswer({ challenge: relayed.challenge,
      answer: { requestID, proof: relayed.proof }, approverPrivateKey: offered.privateKey,
      now: Math.floor(Date.now() / 1000), cryptoValue: webcrypto }), true);
    const secondCertificate = await issueDeviceCertificate({ root, accountID,
      deviceID: secondID, publicKey: second.publicKey, keyVersion: 1,
      issuedAt: Math.floor(Date.now() / 1000), serial: randomUUID(), cryptoValue: webcrypto });
    const secondDirectory = await signDeviceDirectory({ root, accountID, version: 2,
      certificates: [firstCertificate, secondCertificate], cryptoValue: webcrypto });
    const secondBundle = await validateSignedDeviceBundle({ rootPublicKey: root.publicKey,
      certificate: secondCertificate, checkpoint: secondDirectory,
      accountID, deviceID: secondID, publicKey: second.publicKey });
    await store.approveRequest({ accountID, actorDeviceID: firstID, requestID, challengeID,
      bundle: secondBundle, certificate: secondCertificate, checkpoint: secondDirectory,
      idempotencyKey: randomUUID() });
    await assert.rejects(store.rejectRequest({ accountID, actorDeviceID: firstID,
      requestID, idempotencyKey: randomUUID() }), /device_trust_conflict/u);
    const revokedDirectory = await signDeviceDirectory({ root, accountID, version: 3,
      certificates: [firstCertificate], cryptoValue: webcrypto });
    const revocation = await validateSignedDeviceDirectory({ rootPublicKey: root.publicKey,
      checkpoint: revokedDirectory, accountID });
    await store.revokeDevice({ accountID, actorDeviceID: firstID, deviceID: secondID,
      checkpoint: revokedDirectory, bundle: revocation, idempotencyKey: randomUUID() });
    const device = await pool.query(`SELECT revoked_at FROM devices WHERE id = $1`, [secondID]);
    assert.ok(device.rows[0].revoked_at);
    const audit = await pool.query(`SELECT action FROM device_trust_account_events_v1
      WHERE account_id = $1 ORDER BY id`, [accountID]);
    assert.deepEqual(audit.rows.map((row) => row.action),
      ["device.approved", "device.pending", "device.approved", "device.revoked"]);
  } finally { await pool.end(); }
});
