import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import { generateTeamDeviceIdentity } from "../public/team-vault-crypto.js";
import { createTrustRoot, issueDeviceCertificate, signDeviceDirectory } from "../public/device-trust-v1.js";
import { DeviceTrustService } from "../src/device-trust-service.mjs";

const accountID = "11111111-1111-4111-8111-111111111111";
const deviceID = "55555555-5555-4555-8555-555555555555";

test("first root publication requires fresh account password before writing registry", async () => {
  const identity = await generateTeamDeviceIdentity(webcrypto);
  const root = await createTrustRoot({ endpoint: "https://cloud.example.test",
    accountID, cryptoValue: webcrypto });
  const certificate = await issueDeviceCertificate({ root, accountID, deviceID,
    publicKey: identity.publicKey, keyVersion: 1, issuedAt: 1_800_000_000,
    serial: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", cryptoValue: webcrypto });
  const checkpoint = await signDeviceDirectory({ root, accountID, version: 1,
    certificates: [certificate], cryptoValue: webcrypto });
  let writes = 0;
  const service = new DeviceTrustService({ async publishRoot() { writes += 1;
    return { published: true }; } }, async (session, password) => {
    assert.equal(session.user_id, accountID);
    if (password !== "correct-password") throw new Error("invalid_credentials");
  });
  const session = { user_id: accountID, device_id: deviceID };
  const body = { rootPublicKey: root.publicKey, certificate, checkpoint };
  await assert.rejects(service.publishRoot(session, { ...body, password: "wrong" }, "root-publish-0001"),
    /invalid_credentials/u);
  assert.equal(writes, 0);
  assert.deepEqual(await service.publishRoot(session,
    { ...body, password: "correct-password" }, "root-publish-0002"), { published: true });
  assert.equal(writes, 1);
});

test("request API binds account and device to session, refusing caller-selected identity", async () => {
  const identity = await generateTeamDeviceIdentity(webcrypto);
  const seen = [];
  const service = new DeviceTrustService({ async createRequest(value) {
    seen.push(value);
    return { requestID: value.requestID, status: "pending" };
  } });
  const session = { user_id: accountID, device_id: deviceID };
  const key = "device-trust-request-1";
  await service.request(session, { publicKey: identity.publicKey, keyVersion: 1 }, key);
  assert.equal(seen[0].accountID, accountID);
  assert.equal(seen[0].actorDeviceID, deviceID);
  assert.equal(seen[0].deviceID, deviceID);
  assert.equal(seen[0].keyDigest.length, 32);
  await assert.rejects(service.request(session, { publicKey: identity.publicKey,
    keyVersion: 1, deviceID: "66666666-6666-4666-8666-666666666666" }, key),
  /device_trust_invalid/u);
  await assert.rejects(service.request({ ...session, device_id: null },
    { publicKey: identity.publicKey, keyVersion: 1 }, key), /device_trust_invalid/u);
});

test("untrusted client cannot start a challenge with a different account or stale clock", async () => {
  const service = new DeviceTrustService({ async startChallenge() {
    throw new Error("must_not_reach_store");
  } });
  const session = { user_id: accountID, device_id: deviceID };
  const requestID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  const key = "device-trust-challenge-1";
  const identity = await generateTeamDeviceIdentity(webcrypto);
  const challenge = { version: 1, accountID,
    requestID, deviceID, publicKey: identity.publicKey,
    approverPublicKey: identity.publicKey, nonce: "A".repeat(43),
    issuedAt: 1_800_000_000, expiresAt: 1_800_000_300 };
  await assert.rejects(service.startChallenge(session, requestID,
    { challenge: { ...challenge, accountID: "22222222-2222-4222-8222-222222222222" } }, key),
  /device_trust_invalid/u);
  await assert.rejects(service.startChallenge(session, requestID,
    { challenge }, key), /device_trust_invalid/u);
});
