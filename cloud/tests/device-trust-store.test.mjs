import assert from "node:assert/strict";
import test from "node:test";
import { DeviceTrustStore } from "../src/device-trust-store.mjs";

const accountID = "11111111-1111-4111-8111-111111111111";
const deviceID = "55555555-5555-4555-8555-555555555555";
const publicKey = JSON.stringify({ kty: "EC", crv: "P-256", x: "A".repeat(43),
  y: "B".repeat(43), ext: true, key_ops: [] });
const bundle = { rootBytes: Buffer.alloc(65, 1), fingerprint: Buffer.alloc(32, 2),
  certificateBytes: Buffer.from("certificate"), certificateSignature: Buffer.alloc(64, 3),
  directoryBytes: Buffer.from("directory"), directorySignature: Buffer.alloc(64, 4),
  publicKeyBytes: Buffer.alloc(65, 5), keyVersion: 1, directoryVersion: 1,
  serial: "88888888-8888-4888-8888-888888888888" };

function fixture(existingRoot = null) {
  const queries = [];
  const client = { async query(sql, values = []) {
    queries.push({ sql, values });
    if (sql.includes("FROM users") && sql.includes("FOR UPDATE")) return { rows: [{ id: accountID }] };
    if (sql.includes("INSERT INTO device_trust_mutation_receipts_v1")) return { rows: [{ account_id: accountID }] };
    if (sql.includes("FROM device_trust_roots_v1") && sql.includes("FOR UPDATE")) {
      return { rows: existingRoot ? [{ root_public_key: existingRoot }] : [] };
    }
    if (sql.includes("FROM devices") && sql.includes("FOR UPDATE")) {
      return { rows: [{ public_key: publicKey, revoked_at: null }] };
    }
    return { rows: [] };
  }, release() {} };
  return { store: new DeviceTrustStore({ async connect() { return client; } }), queries };
}

test("first root and signed initial records publish atomically under account lock", async () => {
  const { store, queries } = fixture();
  await store.publishRoot({ accountID, actorDeviceID: deviceID, bundle,
    expectedPublicKey: publicKey, certificate: { payload: { deviceID } },
    checkpoint: { payload: { version: 1, entries: [{ deviceID }] } },
    idempotencyKey: "bootstrap-1" });
  assert.ok(queries.some(({ sql }) => sql.includes("FROM users") && sql.includes("FOR UPDATE")));
  for (const table of ["device_trust_roots_v1", "device_trust_certificates_v1",
    "device_trust_directories_v1", "device_trust_account_events_v1"]) {
    assert.ok(queries.some(({ sql }) => sql.includes(`INSERT INTO ${table}`)), table);
  }
  assert.equal(queries.at(-1).sql, "COMMIT");
});

test("server root conflict rolls back rather than replacing local identity", async () => {
  const { store, queries } = fixture(Buffer.alloc(65, 9));
  await assert.rejects(store.publishRoot({ accountID, actorDeviceID: deviceID, bundle,
    expectedPublicKey: publicKey, certificate: { payload: { deviceID } },
    checkpoint: { payload: { version: 1, entries: [{ deviceID }] } },
    idempotencyKey: "bootstrap-2" }),
  /device_trust_conflict/u);
  assert.ok(queries.some(({ sql }) => sql === "ROLLBACK"));
  assert.ok(!queries.some(({ sql }) => sql.includes("INSERT INTO device_trust_roots_v1")));
});

test("pending request binds the session device and exact key before audit", async () => {
  const queries = [];
  const client = { async query(sql, values = []) {
    queries.push({ sql, values });
    if (sql.includes("FROM users") && sql.includes("FOR UPDATE")) return { rows: [{ id: accountID }] };
    if (sql.includes("INSERT INTO device_trust_mutation_receipts_v1")) return { rows: [{ account_id: accountID }] };
    if (sql.includes("FROM device_trust_roots_v1")) return { rows: [{ account_id: accountID }] };
    if (sql.includes("FROM devices") && sql.includes("FOR UPDATE")) {
      return { rows: [{ public_key: publicKey, revoked_at: null }] };
    }
    if (sql.includes("MAX(key_version)")) return { rows: [{ version: "0" }] };
    return { rows: [] };
  }, release() {} };
  const store = new DeviceTrustStore({ async connect() { return client; } });
  const requestID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  const input = { accountID, actorDeviceID: deviceID, deviceID, requestID,
    publicKeyBytes: Buffer.alloc(65, 5), publicKeyJSON: publicKey,
    keyDigest: Buffer.alloc(32, 6), keyVersion: 1, idempotencyKey: "request-1" };
  assert.deepEqual(await store.createRequest(input), { requestID, keyVersion: 1,
    status: "pending" });
  assert.ok(queries.some(({ sql }) => sql.includes("INSERT INTO device_trust_requests_v1")));
  assert.ok(queries.some(({ sql, values }) => sql.includes("'device.pending'")
    && values.includes(accountID) && values.includes(deviceID)));
  assert.equal(queries.at(-1).sql, "COMMIT");
  await assert.rejects(store.createRequest({ ...input, actorDeviceID: accountID,
    idempotencyKey: "request-2" }), /device_trust_invalid/u);
});

test("rekey cannot discard the sole decrypting key while a live Team Vault wrapper remains", async () => {
  const queries = [];
  const client = { async query(sql, values = []) {
    queries.push({ sql, values });
    if (sql.includes("FROM users") && sql.includes("FOR UPDATE")) return { rows: [{ id: accountID }] };
    if (sql.includes("INSERT INTO device_trust_mutation_receipts_v1")) {
      return { rows: [{ account_id: accountID }] };
    }
    if (sql.includes("FROM device_trust_roots_v1")) return { rows: [{ account_id: accountID }] };
    if (sql.includes("FROM devices") && sql.includes("FOR UPDATE")) {
      return { rows: [{ public_key: publicKey, revoked_at: null }] };
    }
    if (sql.includes("MAX(key_version)")) return { rows: [{ version: "1" }] };
    if (sql.includes("FROM shared_vault_key_wrappers AS wrapper")) {
      return { rows: [{ present: 1 }] };
    }
    return { rows: [] };
  }, release() {} };
  const store = new DeviceTrustStore({ async connect() { return client; } });
  await assert.rejects(store.createRequest({ accountID, actorDeviceID: deviceID,
    deviceID, requestID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    publicKeyBytes: Buffer.alloc(65, 5), publicKeyJSON: "new-public-key",
    keyDigest: Buffer.alloc(32, 6), keyVersion: 2, idempotencyKey: "rekey-1" }),
  /device_trust_rekey_vaults_active/u);
  assert.ok(queries.some(({ sql }) => sql.includes("vault.key_generation = wrapper.key_generation")));
  assert.ok(!queries.some(({ sql }) => sql.includes("INSERT INTO device_trust_requests_v1")));
  assert.equal(queries.at(-1).sql, "ROLLBACK");
});

test("challenge answer is one-use and approval cannot win against rejection", async () => {
  let requestState = "pending";
  let challengeState = "offered";
  const queries = [];
  const requestID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  const challengeID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  const client = { async query(sql, values = []) {
    queries.push({ sql, values });
    if (sql.includes("FROM users") && sql.includes("FOR UPDATE")) return { rows: [{ id: accountID }] };
    if (sql.includes("INSERT INTO device_trust_mutation_receipts_v1")) return { rows: [{ account_id: accountID }] };
    if (sql.includes("FROM device_trust_roots_v1")) {
      return { rows: [{ custodian_device_id: deviceID, root_public_key: bundle.rootBytes }] };
    }
    if (sql.includes("FROM devices") && sql.includes("FOR UPDATE")) {
      return { rows: [{ revoked_at: null }] };
    }
    if (sql.includes("FROM device_trust_requests_v1") && sql.includes("FOR UPDATE")) {
      return { rows: [{ id: requestID, device_id: deviceID, state: requestState,
        key_version: 1, public_key: bundle.publicKeyBytes, expires_at: new Date(Date.now() + 60_000) }] };
    }
    if (sql.includes("FROM device_trust_challenges_v1") && sql.includes("FOR UPDATE")) {
      return { rows: [{ id: challengeID, state: challengeState,
        expires_at: new Date(Date.now() + 60_000) }] };
    }
    if (sql.includes("UPDATE device_trust_requests_v1")) {
      if (sql.includes("'rejected'")) requestState = "rejected";
      if (sql.includes("'challenged'")) requestState = "challenged";
      if (sql.includes("'answered'")) requestState = "answered";
    }
    if (sql.includes("UPDATE device_trust_challenges_v1")
      && sql.includes("SET state = 'answered'")) {
      challengeState = "answered";
    }
    return { rows: [] };
  }, release() {} };
  const store = new DeviceTrustStore({ async connect() { return client; } });
  await store.startChallenge({ accountID, actorDeviceID: deviceID, requestID,
    challengeID, challengeBytes: Buffer.from("public challenge"),
    challenge: { version: 1, accountID, requestID, deviceID },
    idempotencyKey: "challenge-1" });
  assert.equal(requestState, "challenged");
  await store.answerChallenge({ accountID, actorDeviceID: deviceID, requestID,
    challengeID, proof: Buffer.alloc(32, 7), idempotencyKey: "answer-1" });
  assert.equal(requestState, "answered");
  assert.equal(challengeState, "answered");
  await store.rejectRequest({ accountID, actorDeviceID: deviceID, requestID,
    idempotencyKey: "reject-1" });
  await assert.rejects(store.approveRequest({ accountID, actorDeviceID: deviceID,
    requestID, challengeID, bundle, certificate: { payload: { deviceID } },
    checkpoint: { payload: { version: 2 } }, idempotencyKey: "approve-1" }),
  /device_trust_conflict/u);
  assert.ok(queries.some(({ sql }) => sql.includes("INSERT INTO device_trust_account_events_v1")
    && sql.includes("device.rejected")));
});
