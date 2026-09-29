import { generateTeamDeviceIdentity, teamDevicePublicKeyFingerprint } from "./team-vault-crypto.js";
import {
  advancePinnedTrust, answerPossessionChallenge, createPossessionChallenge,
  createTrustRoot, deviceCertificateDigest, deviceDirectoryDigest,
  devicePossessionChallengeBytes,
  issueDeviceCertificate, signDeviceDirectory, verifyPossessionAnswer,
  verifySignedDeviceDirectory, verifyDeviceForWrapping,
} from "./device-trust-v1.js";

function fail(code = "device_trust_invalid") { throw new Error(code); }
function sameKey(left, right) {
  return !!left && !!right && left.x === right.x && left.y === right.y;
}
async function rootFingerprint(rootPublicKey, cryptoValue) {
  if (typeof rootPublicKey !== "string") fail();
  const raw = atob(rootPublicKey.replaceAll("-", "+").replaceAll("_", "/")
    + "=".repeat((4 - rootPublicKey.length % 4) % 4));
  const bytes = Uint8Array.from(raw, (character) => character.charCodeAt(0));
  if (bytes.length !== 65 || bytes[0] !== 4) fail();
  return [...new Uint8Array(await cryptoValue.subtle.digest("SHA-256", bytes))]
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
function mutationKey(action) { return `web:trust:${action}:${globalThis.crypto.randomUUID()}`; }

export function createBrowserDeviceTrustFlow({ client, repository, endpoint, accountID,
  identity, identityRepository = null, cryptoValue = globalThis.crypto }) {
  if (!client || !repository || identity?.deviceID !== client.deviceID()) fail();

  async function signedSnapshot() {
    const snapshot = await client.deviceTrustSnapshot();
    const pin = await repository.loadPin(endpoint, accountID);
    const root = await repository.loadRoot(endpoint, accountID);
    if (snapshot.state === "UNINITIALIZED") {
      if (pin && !root) fail("device_trust_recovery_required");
      return { snapshot, pin, root, state: root ? "PUBLISH_PENDING" : "FIRST_DEVICE" };
    }
    if (!pin) return { snapshot, pin: null, root,
      state: root ? "LOCAL_PIN_MISSING" : "PAIRING_REQUIRED" };
    if (root && root.publicKey !== snapshot.rootPublicKey) fail("device_trust_root_conflict");
    const actualRootFingerprint = await rootFingerprint(snapshot.rootPublicKey, cryptoValue);
    if (snapshot.rootFingerprint !== actualRootFingerprint) fail("device_trust_root_conflict");
    const verified = await verifySignedDeviceDirectory({ rootPublicKey: snapshot.rootPublicKey,
      checkpoint: snapshot.checkpoint, accountID, cryptoValue });
    const candidate = { endpoint, accountID,
      rootFingerprint: actualRootFingerprint, highWater: verified.version,
      checkpointDigest: verified.checkpointDigest };
    const next = advancePinnedTrust(pin, candidate);
    if (next.highWater > pin.highWater) await repository.advancePin(pin, next);
    let state = snapshot.custodianDeviceID === identity.deviceID && root
      ? "CUSTODIAN" : "PAIRED";
    let rekeyCommitted = false;
    if (state === "PAIRED" || state === "CUSTODIAN") {
      const entry = snapshot.checkpoint.payload.entries.find(
        (item) => item.deviceID === identity.deviceID);
      const certificate = snapshot.certificates.find((item) =>
        item?.payload?.deviceID === identity.deviceID
        && item.payload.keyVersion === entry?.keyVersion);
      if (certificate) {
        const verifiedDevice = await verifyDeviceForWrapping({
          rootPublicKey: snapshot.rootPublicKey, certificate,
          checkpoint: snapshot.checkpoint, trust: next,
          expectedDeviceID: identity.deviceID, cryptoValue });
        if (!sameKey(verifiedDevice.publicKey, identity.publicKey)) {
          const pending = await identityRepository?.loadPendingRekey?.(identity.deviceID);
          if (!sameKey(verifiedDevice.publicKey, pending?.publicKey)) {
            fail("device_trust_key_substitution");
          }
          identity = await identityRepository.commitPendingRekey(identity.deviceID,
            verifiedDevice.publicKey);
          rekeyCommitted = true;
        }
        if (state === "PAIRED") state = "CERTIFIED";
      } else if (snapshot.certificates.some((item) =>
        item?.payload?.deviceID === identity.deviceID)) {
        if (state === "CUSTODIAN") fail("device_trust_root_conflict");
        state = "REVOKED";
      } else if (state === "CUSTODIAN") {
        fail("device_trust_root_conflict");
      }
    }
    return { snapshot, pin: next, root, state, rekeyCommitted };
  }

  async function bootstrap(password) {
    if (typeof password !== "string" || password.length === 0) fail();
    const current = await signedSnapshot();
    if (current.state !== "FIRST_DEVICE" && current.state !== "PUBLISH_PENDING") {
      fail("device_trust_conflict");
    }
    const root = current.root ?? await createTrustRoot({ endpoint, accountID, cryptoValue });
    if (!current.root) await repository.saveRootIfAbsent(root);
    let bundle = await repository.loadBootstrapBundle(endpoint, accountID);
    if (!bundle) {
      const certificate = await issueDeviceCertificate({ root, accountID,
        deviceID: identity.deviceID, publicKey: identity.publicKey, keyVersion: 1,
        issuedAt: Math.floor(Date.now() / 1000), serial: cryptoValue.randomUUID(), cryptoValue });
      const checkpoint = await signDeviceDirectory({ root, accountID, version: 1,
        certificates: [certificate], cryptoValue });
      bundle = { rootPublicKey: root.publicKey, certificate, checkpoint };
      await repository.saveBootstrapBundleIfAbsent(endpoint, accountID, bundle);
    }
    const pin = { endpoint, accountID, rootFingerprint: root.fingerprint, highWater: 1,
      checkpointDigest: await deviceDirectoryDigest(bundle.checkpoint, cryptoValue) };
    await repository.savePinIfAbsent(pin);
    await client.deviceTrustMutation("/v1/device-trust",
      { ...bundle, password }, mutationKey("root"));
    const checked = await signedSnapshot();
    if (checked.state !== "CUSTODIAN" || checked.pin.checkpointDigest !== pin.checkpointDigest) {
      fail("device_trust_root_conflict");
    }
    return checked;
  }

  async function pair({ trustedFingerprint, trustedCheckpointDigest }) {
    const current = await signedSnapshot();
    if (current.state !== "PAIRING_REQUIRED") fail("device_trust_conflict");
    const snapshot = current.snapshot;
    const verified = await verifySignedDeviceDirectory({ rootPublicKey: snapshot.rootPublicKey,
      checkpoint: snapshot.checkpoint, accountID, cryptoValue });
    const fingerprint = await rootFingerprint(snapshot.rootPublicKey, cryptoValue);
    if (fingerprint !== trustedFingerprint?.trim().toLowerCase()
      || verified.checkpointDigest !== trustedCheckpointDigest?.trim()) {
      fail("device_trust_pairing_mismatch");
    }
    await repository.savePinIfAbsent({ endpoint, accountID,
      rootFingerprint: fingerprint, highWater: verified.version,
      checkpointDigest: verified.checkpointDigest });
    return signedSnapshot();
  }

  async function requestApproval() {
    const current = await signedSnapshot();
    if (current.state !== "PAIRED" || current.snapshot.certificates.some(
      (item) => item?.payload?.deviceID === identity.deviceID)) fail("device_trust_conflict");
    return client.deviceTrustMutation("/v1/device-trust/requests",
      { publicKey: identity.publicKey, keyVersion: 1 }, mutationKey("request"));
  }

  async function requestRekey() {
    const current = await signedSnapshot();
    if (!["CERTIFIED", "CUSTODIAN"].includes(current.state)
      || !identityRepository?.savePendingRekeyIfAbsent) fail("device_trust_conflict");
    const active = current.snapshot.checkpoint.payload.entries.find(
      (entry) => entry.deviceID === identity.deviceID);
    if (!active) fail("device_trust_conflict");
    const generated = { deviceID: identity.deviceID,
      ...await generateTeamDeviceIdentity(cryptoValue) };
    const pending = await identityRepository.savePendingRekeyIfAbsent(generated);
    return client.deviceTrustMutation("/v1/device-trust/requests",
      { publicKey: pending.publicKey, keyVersion: active.keyVersion + 1 },
      mutationKey("rekey"));
  }

  async function answerRequestChallenge(request) {
    if (request.deviceID !== identity.deviceID || !request.challengeID
      || !["challenged", "answered"].includes(request.status)) fail();
    await signedSnapshot();
    const answeringIdentity = request.keyVersion > 1
      ? await identityRepository?.loadPendingRekey?.(identity.deviceID) : identity;
    if (!answeringIdentity) fail("device_trust_recovery_required");
    const result = await client.deviceTrustChallenge(request.requestID, request.challengeID);
    if (result.state !== "offered" || result.challenge.accountID !== accountID
      || result.challenge.deviceID !== identity.deviceID
      || !sameKey(result.challenge.publicKey, answeringIdentity.publicKey)) fail("device_trust_conflict");
    const answer = await answerPossessionChallenge({ challenge: result.challenge,
      devicePrivateKey: answeringIdentity.privateKey,
      devicePublicKey: answeringIdentity.publicKey, cryptoValue });
    return client.deviceTrustMutation(
      `/v1/device-trust/requests/${request.requestID}/challenges/${request.challengeID}`,
      { proof: answer.proof }, mutationKey("answer"));
  }

  async function startApproval(request, confirmedFingerprint) {
    const current = await signedSnapshot();
    if (current.state !== "CUSTODIAN"
      || !["pending", "challenged", "answered"].includes(request.status)
      || request.challengeState
      || (request.deviceID === identity.deviceID && request.keyVersion === 1)) {
      fail("device_trust_conflict");
    }
    const actual = await teamDevicePublicKeyFingerprint(request.publicKey, cryptoValue);
    if (actual !== confirmedFingerprint?.trim().toLowerCase()) {
      fail("device_trust_fingerprint_mismatch");
    }
    const { challenge, privateKey } = await createPossessionChallenge({ accountID,
      requestID: request.requestID, deviceID: request.deviceID,
      publicKey: request.publicKey, issuedAt: Math.floor(Date.now() / 1000), cryptoValue });
    const result = await client.deviceTrustMutation(
      `/v1/device-trust/requests/${request.requestID}/challenges`,
      { challenge }, mutationKey("challenge"));
    return { challenge, privateKey, challengeID: result.challengeID,
      requestID: request.requestID, requestPublicKey: request.publicKey,
      deviceID: request.deviceID, keyVersion: request.keyVersion };
  }

  async function finishApproval(pending) {
    const current = await signedSnapshot();
    if (current.state !== "CUSTODIAN") fail("device_trust_forbidden");
    const challengeResult = await client.deviceTrustChallenge(
      pending.requestID, pending.challengeID);
    if (challengeResult.state !== "answered" || !challengeResult.proof
      || !equalBytes(devicePossessionChallengeBytes(challengeResult.challenge),
        devicePossessionChallengeBytes(pending.challenge))) {
      fail("device_trust_conflict");
    }
    await verifyPossessionAnswer({ challenge: pending.challenge,
      answer: { requestID: pending.requestID, proof: challengeResult.proof },
      approverPrivateKey: pending.privateKey, now: Math.floor(Date.now() / 1000),
      cryptoValue });
    const requests = await client.deviceTrustRequests();
    const request = requests.find((item) => item.requestID === pending.requestID);
    if (!request || request.status !== "answered"
      || request.deviceID !== pending.deviceID || request.keyVersion !== pending.keyVersion
      || !sameKey(request.publicKey, pending.requestPublicKey)) fail("device_trust_conflict");
    const certificate = await issueDeviceCertificate({ root: current.root, accountID,
      deviceID: pending.deviceID, publicKey: pending.requestPublicKey,
      keyVersion: pending.keyVersion, issuedAt: Math.floor(Date.now() / 1000),
      serial: cryptoValue.randomUUID(), cryptoValue });
    const certificates = await activeCertificates(current, pending.deviceID);
    certificates.push(certificate);
    const checkpoint = await signDeviceDirectory({ root: current.root, accountID,
      version: current.snapshot.checkpoint.payload.version + 1, certificates, cryptoValue });
    const result = await client.deviceTrustMutation(
      `/v1/device-trust/requests/${pending.requestID}/approve`,
      { challengeID: pending.challengeID, rootPublicKey: current.root.publicKey,
        certificate, checkpoint }, mutationKey("approve"));
    await signedSnapshot();
    return result;
  }

  async function activeCertificates(current, exceptID) {
    const certificates = [];
    for (const entry of current.snapshot.checkpoint.payload.entries) {
      if (entry.deviceID === exceptID) continue;
      const matching = await Promise.all(current.snapshot.certificates.map(async (item) =>
        item?.payload?.deviceID === entry.deviceID
          && item.payload.keyVersion === entry.keyVersion
          && await deviceCertificateDigest(item, cryptoValue) === entry.certificateDigest
          ? item : null));
      const prior = matching.find(Boolean);
      if (!prior) fail("device_trust_invalid");
      certificates.push(prior);
    }
    return certificates;
  }

  async function revokeDevice(deviceID) {
    const current = await signedSnapshot();
    if (current.state !== "CUSTODIAN" || deviceID === identity.deviceID
      || !current.snapshot.checkpoint.payload.entries.some((entry) => entry.deviceID === deviceID)) {
      fail("device_trust_conflict");
    }
    const certificates = await activeCertificates(current, deviceID);
    const checkpoint = await signDeviceDirectory({ root: current.root, accountID,
      version: current.snapshot.checkpoint.payload.version + 1, certificates, cryptoValue });
    const result = await client.deviceTrustMutation(
      `/v1/device-trust/devices/${deviceID}/revoke`,
      { rootPublicKey: current.root.publicKey, checkpoint }, mutationKey("revoke"));
    await signedSnapshot();
    return result;
  }

  async function reject(requestID) {
    return client.deviceTrustMutation(`/v1/device-trust/requests/${requestID}/reject`,
      null, mutationKey("reject"));
  }

  return { status: signedSnapshot, bootstrap, pair, requestApproval,
    requestRekey, answerRequestChallenge, startApproval, finishApproval, reject,
    revokeDevice, currentIdentity: () => identity };
}

function equalBytes(left, right) {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference |= left[index] ^ right[index];
  return difference === 0;
}
