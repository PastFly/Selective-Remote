import assert from "node:assert/strict";
import { randomUUID, webcrypto } from "node:crypto";
import test from "node:test";
import { generateTeamDeviceIdentity, teamDevicePublicKeyFingerprint } from "../public/team-vault-crypto.js";
import { deviceDirectoryDigest } from "../public/device-trust-v1.js";
import { createBrowserDeviceTrustFlow } from "../public/device-trust-flow.js";

const accountID = "11111111-1111-4111-8111-111111111111";
const firstID = "55555555-5555-4555-8555-555555555555";
const secondID = "66666666-6666-4666-8666-666666666666";
const endpoint = "https://cloud.example.test";

function memoryRepository() {
  let root = null; let pin = null; let bundle = null;
  return {
    async loadRoot() { return root; },
    async saveRootIfAbsent(value) { if (root && root.publicKey !== value.publicKey) throw Error("conflict"); root = value; },
    async loadPin() { return pin; },
    async savePinIfAbsent(value) { if (pin && JSON.stringify(pin) !== JSON.stringify(value)) throw Error("conflict"); pin = value; },
    async advancePin(old, next) { assert.deepEqual(pin, old); pin = next; },
    async loadBootstrapBundle() { return bundle; },
    async saveBootstrapBundleIfAbsent(_endpoint, _account, value) { if (bundle) throw Error("conflict"); bundle = value; },
  };
}

test("first browser pins before publication; a new browser requires out-of-band pairing", async () => {
  const firstIdentity = { deviceID: firstID, ...await generateTeamDeviceIdentity(webcrypto) };
  const secondIdentity = { deviceID: secondID, ...await generateTeamDeviceIdentity(webcrypto) };
  let published = null;
  const calls = [];
  const server = {
    async snapshot() { return published ? { state: "ROOT_PUBLISHED",
      rootPublicKey: published.rootPublicKey,
      rootFingerprint: firstPin.rootFingerprint,
      custodianDeviceID: firstID, checkpoint: published.checkpoint,
      certificates: [published.certificate] } : { state: "UNINITIALIZED" }; },
  };
  const firstRepo = memoryRepository();
  let firstPin;
  const firstClient = { deviceID: () => firstID, deviceTrustSnapshot: () => server.snapshot(),
    async deviceTrustMutation(path, body) {
      assert.equal(path, "/v1/device-trust");
      assert.equal(body.password, "correct-password");
      firstPin = await firstRepo.loadPin(endpoint, accountID);
      assert.ok(firstPin, "pin persisted before publication");
      published = body; calls.push(path);
      return { published: true };
    } };
  const first = createBrowserDeviceTrustFlow({ client: firstClient,
    repository: firstRepo, endpoint, accountID, identity: firstIdentity, cryptoValue: webcrypto });
  assert.equal((await first.status()).state, "FIRST_DEVICE");
  assert.equal((await first.bootstrap("correct-password")).state, "CUSTODIAN");
  assert.deepEqual(calls, ["/v1/device-trust"]);
  assert.equal((await first.status()).state, "CUSTODIAN");
  const secondRepo = memoryRepository();
  const secondClient = { deviceID: () => secondID, deviceTrustSnapshot: () => server.snapshot() };
  const second = createBrowserDeviceTrustFlow({ client: secondClient,
    repository: secondRepo, endpoint, accountID, identity: secondIdentity, cryptoValue: webcrypto });
  assert.equal((await second.status()).state, "PAIRING_REQUIRED");
  await assert.rejects(second.pair({ trustedFingerprint: "0".repeat(64),
    trustedCheckpointDigest: firstPin.checkpointDigest }), /pairing_mismatch/u);
  assert.equal((await second.status()).state, "PAIRING_REQUIRED");
  assert.equal((await second.pair({ trustedFingerprint: firstPin.rootFingerprint,
    trustedCheckpointDigest: await deviceDirectoryDigest(published.checkpoint, webcrypto) })).state,
  "PAIRED");
  const changed = { ...published, rootPublicKey: (await firstRepo.loadRoot(endpoint, accountID)).publicKey };
  published = { ...changed, checkpoint: { ...published.checkpoint,
    payload: { ...published.checkpoint.payload, version: 2 } } };
  await assert.rejects(second.status(), /device_trust/u);
});

test("new device proof, signed approval, and before/after substitution fail closed", async () => {
  const firstIdentity = { deviceID: firstID, ...await generateTeamDeviceIdentity(webcrypto) };
  const secondIdentity = { deviceID: secondID, ...await generateTeamDeviceIdentity(webcrypto) };
  const attacker = await generateTeamDeviceIdentity(webcrypto);
  const firstRepo = memoryRepository();
  const secondRepo = memoryRepository();
  let pendingRekey = null;
  const identityRepository = {
    async loadPendingRekey() { return pendingRekey; },
    async savePendingRekeyIfAbsent(value) { pendingRekey ??= value; return pendingRekey; },
    async commitPendingRekey(_deviceID, publicKey) {
      assert.equal(pendingRekey.publicKey.x, publicKey.x);
      const committed = pendingRekey;
      pendingRekey = null;
      return committed;
    },
  };
  let bundle = null;
  let rootFingerprint = null;
  let request = null;
  let challenge = null;
  const server = {
    snapshot: () => bundle ? { state: "ROOT_PUBLISHED", rootPublicKey: bundle.rootPublicKey,
      rootFingerprint, custodianDeviceID: firstID, checkpoint: bundle.checkpoint,
      certificates: bundle.certificates } : { state: "UNINITIALIZED" },
    requests: () => request ? [{ ...request }] : [],
    challenge: () => ({ challenge: challenge.challenge, state: challenge.state,
      proof: challenge.proof ?? null }),
  };
  function client(deviceID) {
    return { deviceID: () => deviceID,
      deviceTrustSnapshot: async () => server.snapshot(),
      deviceTrustRequests: async () => server.requests(),
      deviceTrustChallenge: async () => server.challenge(),
      async deviceTrustMutation(path, body) {
        if (path === "/v1/device-trust") {
          rootFingerprint = (await firstRepo.loadPin(endpoint, accountID)).rootFingerprint;
          bundle = { rootPublicKey: body.rootPublicKey, checkpoint: body.checkpoint,
            certificates: [body.certificate] };
          return { published: true };
        }
        if (path === "/v1/device-trust/requests") {
          request = { requestID: randomUUID(), deviceID, keyVersion: body.keyVersion,
            publicKey: body.publicKey, status: "pending", challengeID: null };
          return request;
        }
        if (path.endsWith("/challenges") && body?.challenge) {
          challenge = { challenge: body.challenge, challengeID: randomUUID(),
            state: "offered" };
          request.status = "challenged";
          request.challengeID = challenge.challengeID;
          return { challengeID: challenge.challengeID };
        }
        if (path.endsWith(`/${challenge?.challengeID}`) && body?.proof) {
          challenge.proof = body.proof;
          challenge.state = "answered";
          request.status = "answered";
          return { status: "answered" };
        }
        if (path.endsWith("/approve")) {
          bundle = { ...bundle, checkpoint: body.checkpoint,
            certificates: [...bundle.certificates, body.certificate] };
          request.status = "approved";
          return { status: "approved" };
        }
        if (path.endsWith("/revoke")) {
          bundle = { ...bundle, checkpoint: body.checkpoint };
          return { status: "revoked" };
        }
        throw new Error(`unexpected ${path}`);
      },
    };
  }
  const first = createBrowserDeviceTrustFlow({ client: client(firstID),
    repository: firstRepo, endpoint, accountID, identity: firstIdentity, cryptoValue: webcrypto });
  const second = createBrowserDeviceTrustFlow({ client: client(secondID),
    repository: secondRepo, identityRepository,
    endpoint, accountID, identity: secondIdentity, cryptoValue: webcrypto });
  await first.bootstrap("correct-password");
  const pin = await firstRepo.loadPin(endpoint, accountID);
  await second.pair({ trustedFingerprint: pin.rootFingerprint,
    trustedCheckpointDigest: pin.checkpointDigest });
  await second.requestApproval();
  const realFingerprint = await teamDevicePublicKeyFingerprint(secondIdentity.publicKey, webcrypto);
  request.publicKey = attacker.publicKey;
  await assert.rejects(first.startApproval(request, realFingerprint), /fingerprint_mismatch/u);
  request.publicKey = secondIdentity.publicKey;
  const pending = await first.startApproval(request, realFingerprint);
  await second.answerRequestChallenge(request);
  await first.finishApproval(pending);
  assert.equal((await second.status()).state, "CERTIFIED");
  const realCertificate = bundle.certificates[1];
  bundle.certificates[1] = { ...bundle.certificates[1], payload: {
    ...bundle.certificates[1].payload, publicKey: attacker.publicKey } };
  await assert.rejects(second.status(), /device_trust/u);
  bundle.certificates[1] = realCertificate;
  await second.requestRekey();
  const rekeyFingerprint = await teamDevicePublicKeyFingerprint(request.publicKey, webcrypto);
  const rekeyChallenge = await first.startApproval(request, rekeyFingerprint);
  await second.answerRequestChallenge(request);
  await first.finishApproval(rekeyChallenge);
  const afterRekey = await second.status();
  assert.equal(afterRekey.state, "CERTIFIED");
  assert.equal(afterRekey.rekeyCommitted, true);
  assert.equal(pendingRekey, null);
  assert.equal(afterRekey.snapshot.checkpoint.payload.entries.find(
    (entry) => entry.deviceID === secondID).keyVersion, 2);
  await first.revokeDevice(secondID);
  assert.equal((await second.status()).state, "REVOKED");
});
