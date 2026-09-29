import { createHash, randomUUID } from "node:crypto";
import { normalizeTeamDevicePublicKey } from "../public/team-vault-crypto.js";
import { devicePossessionChallengeBytes } from "../public/device-trust-v1.js";
import { isUUID, validateDevicePublicKey } from "./security.mjs";
import { validateIdempotencyKey } from "./team-policy.mjs";
import { validateSignedDeviceBundle, validateSignedDeviceDirectory } from "./device-trust-policy.mjs";

function invalid() { throw new Error("device_trust_invalid"); }
function record(value, keys) {
  if (!value || typeof value !== "object" || Array.isArray(value)
    || Object.keys(value).sort().join("|") !== [...keys].sort().join("|")) invalid();
  return value;
}
function uuid(value) { if (!isUUID(value)) invalid(); return value; }
function keyBytes(value) {
  const key = normalizeTeamDevicePublicKey(value);
  const decode = (text) => Buffer.from(text, "base64url");
  return Buffer.concat([Buffer.from([4]), decode(key.x), decode(key.y)]);
}
function base64(value, length) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/u.test(value)) invalid();
  const bytes = Buffer.from(value, "base64url");
  if (bytes.length !== length || bytes.toString("base64url") !== value) invalid();
  return bytes;
}
function sessionIdentity(session) {
  if (!isUUID(session?.user_id) || !isUUID(session?.device_id)) invalid();
  return { accountID: session.user_id, actorDeviceID: session.device_id };
}

export class DeviceTrustService {
  constructor(store, reauthenticate = null) {
    this.store = store;
    this.reauthenticate = reauthenticate;
  }

  async snapshot(session) { return this.store.getSnapshot(sessionIdentity(session).accountID); }

  async requests(session) {
    const { accountID, actorDeviceID } = sessionIdentity(session);
    const snapshot = await this.store.getSnapshot(accountID);
    return { requests: await this.store.listRequests(accountID, actorDeviceID,
      snapshot.custodianDeviceID === actorDeviceID) };
  }

  async publishRoot(session, input, key) {
    const { accountID, actorDeviceID } = sessionIdentity(session);
    record(input, ["rootPublicKey", "certificate", "checkpoint", "password"]);
    if (!this.reauthenticate) invalid();
    await this.reauthenticate(session, input.password);
    const certificate = input.certificate;
    if (certificate?.payload?.accountID !== accountID
      || certificate.payload.deviceID !== actorDeviceID) invalid();
    const publicKey = certificate.payload.publicKey;
    const bundle = await validateSignedDeviceBundle({ rootPublicKey: input.rootPublicKey,
      certificate, checkpoint: input.checkpoint, accountID,
      deviceID: actorDeviceID, publicKey });
    return this.store.publishRoot({ accountID, actorDeviceID, bundle,
      expectedPublicKey: validateDevicePublicKey(publicKey), certificate,
      checkpoint: input.checkpoint, idempotencyKey: validateIdempotencyKey(key) });
  }

  async request(session, input, key) {
    const { accountID, actorDeviceID } = sessionIdentity(session);
    record(input, ["publicKey", "keyVersion"]);
    const publicKeyJSON = validateDevicePublicKey(input.publicKey);
    const publicKeyBytes = keyBytes(input.publicKey);
    if (!Number.isSafeInteger(input.keyVersion) || input.keyVersion < 1) invalid();
    return this.store.createRequest({ accountID, actorDeviceID, deviceID: actorDeviceID,
      requestID: randomUUID(), publicKeyBytes, publicKeyJSON,
      keyDigest: createHash("sha256").update(publicKeyBytes).digest(),
      keyVersion: input.keyVersion, idempotencyKey: validateIdempotencyKey(key) });
  }

  async startChallenge(session, requestID, input, key) {
    const { accountID, actorDeviceID } = sessionIdentity(session);
    uuid(requestID);
    record(input, ["challenge"]);
    const challenge = input.challenge;
    let challengeBytes;
    try { challengeBytes = Buffer.from(devicePossessionChallengeBytes(challenge)); }
    catch { invalid(); }
    const now = Math.floor(Date.now() / 1000);
    if (challenge.accountID !== accountID || challenge.requestID !== requestID
      || Math.abs(challenge.issuedAt - now) > 30) invalid();
    return this.store.startChallenge({ accountID, actorDeviceID, requestID,
      challengeID: randomUUID(), challengeBytes, challenge,
      idempotencyKey: validateIdempotencyKey(key) });
  }

  async challenge(session, requestID, challengeID) {
    const { accountID, actorDeviceID } = sessionIdentity(session);
    uuid(requestID); uuid(challengeID);
    const snapshot = await this.store.getSnapshot(accountID);
    return this.store.getChallenge(accountID, actorDeviceID, requestID, challengeID,
      snapshot.custodianDeviceID === actorDeviceID);
  }

  async answerChallenge(session, requestID, challengeID, input, key) {
    const { accountID, actorDeviceID } = sessionIdentity(session);
    uuid(requestID); uuid(challengeID);
    record(input, ["proof"]);
    return this.store.answerChallenge({ accountID, actorDeviceID, requestID,
      challengeID, proof: base64(input.proof, 32),
      idempotencyKey: validateIdempotencyKey(key) });
  }

  async reject(session, requestID, key) {
    const { accountID, actorDeviceID } = sessionIdentity(session);
    uuid(requestID);
    return this.store.rejectRequest({ accountID, actorDeviceID, requestID,
      idempotencyKey: validateIdempotencyKey(key) });
  }

  async approve(session, requestID, input, key) {
    const { accountID, actorDeviceID } = sessionIdentity(session);
    uuid(requestID);
    record(input, ["challengeID", "rootPublicKey", "certificate", "checkpoint"]);
    uuid(input.challengeID);
    const certificate = input.certificate;
    if (certificate?.payload?.accountID !== accountID) invalid();
    const bundle = await validateSignedDeviceBundle({ rootPublicKey: input.rootPublicKey,
      certificate, checkpoint: input.checkpoint, accountID,
      deviceID: certificate.payload.deviceID, publicKey: certificate.payload.publicKey });
    return this.store.approveRequest({ accountID, actorDeviceID, requestID,
      challengeID: input.challengeID, bundle, certificate, checkpoint: input.checkpoint,
      idempotencyKey: validateIdempotencyKey(key) });
  }

  async revoke(session, deviceID, input, key) {
    const { accountID, actorDeviceID } = sessionIdentity(session);
    uuid(deviceID);
    record(input, ["rootPublicKey", "checkpoint"]);
    const bundle = await validateSignedDeviceDirectory({
      rootPublicKey: input.rootPublicKey, checkpoint: input.checkpoint, accountID });
    return this.store.revokeDevice({ accountID, actorDeviceID, deviceID,
      checkpoint: input.checkpoint, bundle,
      idempotencyKey: validateIdempotencyKey(key) });
  }
}
