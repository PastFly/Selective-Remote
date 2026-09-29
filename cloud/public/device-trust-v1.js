// Dormant device-key authenticity foundation. No production route calls this module.
import { normalizeTeamDevicePublicKey } from "./team-vault-crypto.js";
import { wrapResourceCEK } from "./resource-crypto-v2.js";

const encoder = new TextEncoder();
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const b64url = /^[A-Za-z0-9_-]+$/u;
const maxVersion = Number.MAX_SAFE_INTEGER;
const certificateDomain = "selective-remote/device-certificate/v1\0";
const directoryDomain = "selective-remote/device-directory/v1\0";
const possessionDomain = "selective-remote/device-possession/v1\0";

function fail() { throw new Error("device_trust_invalid"); }
function exact(value, names) {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || Object.keys(value).sort().join("\0") !== [...names].sort().join("\0")) fail();
}
function id(value) {
  if (typeof value !== "string" || !uuid.test(value)) fail();
  return value;
}
function version(value) {
  if (!Number.isSafeInteger(value) || value < 1 || value > maxVersion) fail();
  return value;
}
function bytes(value, expected) {
  if (typeof value !== "string" || value.length !== Math.ceil(expected * 4 / 3)
    || !b64url.test(value)) fail();
  let binary;
  try { binary = atob(value.replaceAll("-", "+").replaceAll("_", "/")
    + "=".repeat((4 - value.length % 4) % 4)); } catch { fail(); }
  const result = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  if (result.length !== expected || b64(result) !== value) fail();
  return result;
}
function b64(value) {
  let binary = "";
  for (const item of value) binary += String.fromCharCode(item);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}
function hex(value) { return Array.from(value, (item) => item.toString(16).padStart(2, "0")).join(""); }
function combine(parts) {
  const result = new Uint8Array(parts.reduce((size, part) => size + part.length, 0));
  let offset = 0;
  for (const part of parts) { result.set(part, offset); offset += part.length; }
  return result;
}
function record(domain, fields) {
  const parts = [encoder.encode(domain), Uint8Array.of(0, 1)];
  for (const value of fields) {
    const item = typeof value === "string" ? encoder.encode(value) : value;
    if (!(item instanceof Uint8Array) || item.length > 65535) fail();
    parts.push(Uint8Array.of(item.length >> 8, item.length & 255), item);
  }
  return combine(parts);
}
function keyBytes(publicKey) {
  const key = normalizeTeamDevicePublicKey(publicKey);
  return combine([Uint8Array.of(4), bytes(key.x, 32), bytes(key.y, 32)]);
}
function rootBytes(publicKey) {
  const value = bytes(publicKey, 65);
  if (value[0] !== 4) fail();
  return value;
}
function cryptoAPI(value) {
  if (!value?.subtle || typeof value.getRandomValues !== "function") fail();
  return value;
}
async function fingerprint(publicKey, crypto) {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", rootBytes(publicKey))));
}
function certificateBytes(payload) {
  exact(payload, ["accountID", "deviceID", "publicKey", "keyVersion",
    "issuerFingerprint", "issuedAt", "serial"]);
  if (typeof payload.issuerFingerprint !== "string"
    || !/^[0-9a-f]{64}$/u.test(payload.issuerFingerprint)
    || !Number.isSafeInteger(payload.issuedAt) || payload.issuedAt < 1) fail();
  return record(certificateDomain, [id(payload.accountID), id(payload.deviceID),
    keyBytes(payload.publicKey), String(version(payload.keyVersion)),
    payload.issuerFingerprint, String(payload.issuedAt), id(payload.serial)]);
}
export function deviceCertificateBytes(payload) { return certificateBytes(payload); }
function signedCertificateBytes(certificate) {
  exact(certificate, ["payload", "signature"]);
  return combine([certificateBytes(certificate.payload), bytes(certificate.signature, 64)]);
}
async function certificateDigest(certificate, crypto) {
  return b64(new Uint8Array(await crypto.subtle.digest("SHA-256", signedCertificateBytes(certificate))));
}
export async function deviceDirectoryDigest(checkpoint, cryptoValue = globalThis.crypto) {
  exact(checkpoint, ["payload", "signature"]);
  const crypto = cryptoAPI(cryptoValue);
  return b64(new Uint8Array(await crypto.subtle.digest("SHA-256", combine([
    directoryBytes(checkpoint.payload), bytes(checkpoint.signature, 64)]))));
}
function directoryBytes(payload) {
  exact(payload, ["accountID", "version", "entries"]);
  if (!Array.isArray(payload.entries) || payload.entries.length > 4096) fail();
  let previous = "";
  const fields = [id(payload.accountID), String(version(payload.version)),
    String(payload.entries.length)];
  for (const entry of payload.entries) {
    exact(entry, ["deviceID", "keyVersion", "certificateDigest"]);
    const device = id(entry.deviceID);
    if (device <= previous) fail();
    previous = device;
    fields.push(device, String(version(entry.keyVersion)), bytes(entry.certificateDigest, 32));
  }
  const encoded = record(directoryDomain, fields);
  if (encoded.length > 65535) fail();
  return encoded;
}
export function deviceDirectoryBytes(payload) { return directoryBytes(payload); }
export async function verifySignedDeviceDirectory({ rootPublicKey, checkpoint,
  accountID, cryptoValue = globalThis.crypto }) {
  const crypto = cryptoAPI(cryptoValue);
  exact(checkpoint, ["payload", "signature"]);
  if (checkpoint.payload.accountID !== id(accountID)) fail();
  await verifySignature(rootPublicKey, directoryBytes(checkpoint.payload),
    checkpoint.signature, crypto);
  return { version: checkpoint.payload.version,
    checkpointDigest: await deviceDirectoryDigest(checkpoint, crypto) };
}
async function verifySignature(rootPublicKey, payload, signature, crypto) {
  const key = await crypto.subtle.importKey("raw", rootBytes(rootPublicKey),
    { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  if (!await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" },
    key, bytes(signature, 64), payload)) fail();
}
function normalizedEndpoint(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash
      || url.pathname !== "/") fail();
    return url.origin;
  } catch { fail(); }
}

function normalizedPin(pin) {
  exact(pin, ["endpoint", "accountID", "rootFingerprint", "highWater", "checkpointDigest"]);
  if (typeof pin.rootFingerprint !== "string" || !/^[0-9a-f]{64}$/u.test(pin.rootFingerprint)) fail();
  bytes(pin.checkpointDigest, 32);
  return { endpoint: normalizedEndpoint(pin.endpoint), accountID: id(pin.accountID),
    rootFingerprint: pin.rootFingerprint, highWater: version(pin.highWater),
    checkpointDigest: pin.checkpointDigest };
}

export function advancePinnedTrust(current, candidate) {
  const old = normalizedPin(current);
  const next = normalizedPin(candidate);
  if (old.endpoint !== next.endpoint || old.accountID !== next.accountID
    || old.rootFingerprint !== next.rootFingerprint || next.highWater < old.highWater
    || (next.highWater === old.highWater && next.checkpointDigest !== old.checkpointDigest)) fail();
  return next;
}

// Stores non-extractable signing CryptoKeys and trust pins in a single IndexedDB object store.
// An absent pin must be paired out of band; a server response must never initialize it.
export function createIndexedDBDeviceTrustRepository(indexedDBValue = globalThis.indexedDB) {
  if (!indexedDBValue?.open) fail();
  async function transact(mode, operation) {
    const database = await new Promise((resolve, reject) => {
      const request = indexedDBValue.open("selective-remote-device-trust-v1", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("records");
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(new Error("device_trust_storage_failed"));
      request.onblocked = () => reject(new Error("device_trust_storage_failed"));
    });
    try {
      return await new Promise((resolve, reject) => {
        const tx = database.transaction("records", mode);
        let result;
        try { operation(tx.objectStore("records"), (value) => { result = value; }); }
        catch (error) { tx.abort(); reject(error); }
        tx.onerror = () => reject(new Error("device_trust_storage_failed"));
        tx.onabort = () => reject(new Error("device_trust_storage_failed"));
        tx.oncomplete = () => resolve(result);
      });
    } finally { database.close(); }
  }
  const key = (endpoint, accountID) => `${normalizedEndpoint(endpoint)}|${id(accountID)}`;
  return {
    async loadPin(endpoint, accountID) {
      const result = await transact("readonly", (store, done) => {
        const request = store.get(`pin:${key(endpoint, accountID)}`);
        request.onsuccess = () => done(request.result ?? null);
      });
      return result === null ? null : normalizedPin(result);
    },
    async savePinIfAbsent(pin) {
      const value = normalizedPin(pin);
      return transact("readwrite", (store, done) => {
        const recordKey = `pin:${key(value.endpoint, value.accountID)}`;
        const read = store.get(recordKey);
        read.onsuccess = () => {
          if (read.result) {
            try {
              const stored = normalizedPin(read.result);
              if (JSON.stringify(stored) !== JSON.stringify(value)) fail();
              done(stored);
            } catch { store.transaction.abort(); }
            return;
          }
          const write = store.add(value, recordKey);
          write.onsuccess = () => done(value);
        };
      });
    },
    async advancePin(current, candidate) {
      const expected = normalizedPin(current);
      const next = advancePinnedTrust(expected, candidate);
      return transact("readwrite", (store, done) => {
        const recordKey = `pin:${key(expected.endpoint, expected.accountID)}`;
        const read = store.get(recordKey);
        read.onsuccess = () => {
          try {
            const stored = normalizedPin(read.result);
            if (JSON.stringify(stored) !== JSON.stringify(expected)) fail();
            const write = store.put(next, recordKey);
            write.onsuccess = () => done(next);
          } catch { store.transaction.abort(); }
        };
      });
    },
    async saveRootIfAbsent(root) {
      rootForSigning(root, root.accountID);
      return transact("readwrite", (store, done) => {
        const recordKey = `root:${key(root.endpoint, root.accountID)}`;
        const read = store.get(recordKey);
        read.onsuccess = () => {
          if (read.result) {
            if (read.result.publicKey !== root.publicKey
              || read.result.fingerprint !== root.fingerprint) store.transaction.abort();
            else done(read.result);
            return;
          }
          const write = store.add(root, recordKey);
          write.onsuccess = () => done(root);
        };
      });
    },
    async loadRoot(endpoint, accountID) {
      return transact("readonly", (store, done) => {
        const read = store.get(`root:${key(endpoint, accountID)}`);
        read.onsuccess = () => done(read.result ?? null);
      });
    },
  };
}

export async function createTrustRoot({ endpoint, accountID, cryptoValue = globalThis.crypto }) {
  const crypto = cryptoAPI(cryptoValue);
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" },
    false, ["sign", "verify"]);
  const publicKey = b64(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey)));
  return { endpoint: normalizedEndpoint(endpoint), accountID: id(accountID),
    privateKey: pair.privateKey, publicKey, fingerprint: await fingerprint(publicKey, crypto) };
}

function rootForSigning(root, accountID) {
  if (root?.accountID !== id(accountID) || root.privateKey?.type !== "private"
    || root.privateKey?.algorithm?.name !== "ECDSA"
    || root.privateKey?.algorithm?.namedCurve !== "P-256"
    || root.privateKey?.extractable !== false) fail();
}

export async function issueDeviceCertificate({ root, accountID, deviceID, publicKey,
  keyVersion, issuedAt, serial, cryptoValue = globalThis.crypto }) {
  rootForSigning(root, accountID);
  const crypto = cryptoAPI(cryptoValue);
  const payload = { accountID: id(accountID), deviceID: id(deviceID),
    publicKey: normalizeTeamDevicePublicKey(publicKey), keyVersion: version(keyVersion),
    issuerFingerprint: root.fingerprint, issuedAt, serial: id(serial) };
  const signature = b64(new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, root.privateKey, certificateBytes(payload))));
  return { payload, signature };
}

export async function signDeviceDirectory({ root, accountID, version: directoryVersion,
  certificates, cryptoValue = globalThis.crypto }) {
  rootForSigning(root, accountID);
  if (!Array.isArray(certificates) || certificates.length > 4096) fail();
  const crypto = cryptoAPI(cryptoValue);
  const entries = [];
  for (const certificate of certificates) {
    if (certificate?.payload?.accountID !== accountID
      || certificate.payload.issuerFingerprint !== root.fingerprint) fail();
    await verifySignature(root.publicKey, certificateBytes(certificate.payload),
      certificate.signature, crypto);
    entries.push({ deviceID: certificate.payload.deviceID,
      keyVersion: certificate.payload.keyVersion,
      certificateDigest: await certificateDigest(certificate, crypto) });
  }
  entries.sort((a, b) => a.deviceID.localeCompare(b.deviceID, "en"));
  const payload = { accountID: id(accountID), version: version(directoryVersion), entries };
  const signature = b64(new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, root.privateKey, directoryBytes(payload))));
  return { payload, signature };
}

export async function verifyDeviceForWrapping({ rootPublicKey, certificate, checkpoint,
  trust, expectedDeviceID, cryptoValue = globalThis.crypto }) {
  const crypto = cryptoAPI(cryptoValue);
  if (!trust || trust.rootFingerprint !== await fingerprint(rootPublicKey, crypto)
    || !Number.isSafeInteger(trust.highWater) || trust.highWater < 1
    || normalizedEndpoint(trust.endpoint) !== trust.endpoint) fail();
  bytes(trust.checkpointDigest, 32);
  const accountID = id(trust.accountID);
  const deviceID = id(expectedDeviceID);
  if (certificate?.payload?.accountID !== accountID
    || certificate.payload.deviceID !== deviceID
    || certificate.payload.issuerFingerprint !== trust.rootFingerprint
    || checkpoint?.payload?.accountID !== accountID
    || version(checkpoint.payload.version) < trust.highWater) fail();
  await verifySignature(rootPublicKey, certificateBytes(certificate.payload),
    certificate.signature, crypto);
  await verifySignature(rootPublicKey, directoryBytes(checkpoint.payload),
    checkpoint.signature, crypto);
  const checkpointDigest = await deviceDirectoryDigest(checkpoint, crypto);
  if (checkpoint.payload.version === trust.highWater
    && trust.checkpointDigest !== checkpointDigest) fail();
  const entry = checkpoint.payload.entries.find((item) => item.deviceID === deviceID);
  if (!entry || entry.keyVersion !== certificate.payload.keyVersion
    || entry.certificateDigest !== await certificateDigest(certificate, crypto)) fail();
  return { publicKey: certificate.payload.publicKey,
    highWater: checkpoint.payload.version, checkpointDigest };
}

function possessionBytes(challenge) {
  exact(challenge, ["version", "accountID", "requestID", "deviceID", "publicKey",
    "approverPublicKey", "nonce", "issuedAt", "expiresAt"]);
  if (challenge.version !== 1 || !Number.isSafeInteger(challenge.issuedAt)
    || challenge.issuedAt < 1 || !Number.isSafeInteger(challenge.expiresAt)
    || challenge.expiresAt !== challenge.issuedAt + 300) fail();
  return record(possessionDomain, [id(challenge.accountID), id(challenge.requestID),
    id(challenge.deviceID), keyBytes(challenge.publicKey),
    keyBytes(challenge.approverPublicKey), bytes(challenge.nonce, 32),
    String(challenge.issuedAt), String(challenge.expiresAt)]);
}
export function devicePossessionChallengeBytes(challenge) { return possessionBytes(challenge); }

async function possessionKey(privateKey, otherPublicKey, crypto) {
  if (privateKey?.type !== "private" || privateKey.extractable !== false
    || privateKey.algorithm?.name !== "ECDH"
    || privateKey.algorithm?.namedCurve !== "P-256") fail();
  const other = await crypto.subtle.importKey("jwk",
    normalizeTeamDevicePublicKey(otherPublicKey),
    { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = await crypto.subtle.deriveBits({ name: "ECDH", public: other }, privateKey, 256);
  return crypto.subtle.importKey("raw", shared, { name: "HMAC", hash: "SHA-256" },
    false, ["sign", "verify"]);
}

export async function createPossessionChallenge({ accountID, requestID, deviceID,
  publicKey, issuedAt, cryptoValue = globalThis.crypto }) {
  const crypto = cryptoAPI(cryptoValue);
  const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" },
    false, ["deriveBits"]);
  const approverPublicKey = normalizeTeamDevicePublicKey(
    await crypto.subtle.exportKey("jwk", pair.publicKey));
  const challenge = { version: 1, accountID: id(accountID), requestID: id(requestID),
    deviceID: id(deviceID), publicKey: normalizeTeamDevicePublicKey(publicKey),
    approverPublicKey, nonce: b64(crypto.getRandomValues(new Uint8Array(32))),
    issuedAt, expiresAt: issuedAt + 300 };
  possessionBytes(challenge);
  return { challenge, privateKey: pair.privateKey };
}

export async function answerPossessionChallenge({ challenge, devicePrivateKey,
  devicePublicKey, cryptoValue = globalThis.crypto }) {
  const crypto = cryptoAPI(cryptoValue);
  const transcript = possessionBytes(challenge);
  if (!equalBytes(keyBytes(challenge.publicKey), keyBytes(devicePublicKey))) fail();
  const key = await possessionKey(devicePrivateKey, challenge.approverPublicKey, crypto);
  return { requestID: challenge.requestID,
    proof: b64(new Uint8Array(await crypto.subtle.sign("HMAC", key, transcript))) };
}

export async function verifyPossessionAnswer({ challenge, answer, approverPrivateKey,
  now, cryptoValue = globalThis.crypto }) {
  const crypto = cryptoAPI(cryptoValue);
  const transcript = possessionBytes(challenge);
  exact(answer, ["requestID", "proof"]);
  if (answer.requestID !== challenge.requestID || !Number.isSafeInteger(now)
    || now < challenge.issuedAt || now >= challenge.expiresAt) fail();
  const key = await possessionKey(approverPrivateKey, challenge.publicKey, crypto);
  if (!await crypto.subtle.verify("HMAC", key, bytes(answer.proof, 32), transcript)) fail();
  return true;
}

function equalBytes(left, right) {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference |= left[index] ^ right[index];
  return difference === 0;
}

export async function isDeviceEligibleForV2Wrapper({ proofEstablished, revoked, team,
  ...verification }) {
  if (proofEstablished !== true || revoked !== false || !team
    || team.membershipActive !== true || team.admitted !== true || team.capable !== true
    || !Number.isSafeInteger(team.membershipEpoch)
    || team.membershipEpoch < 1 || team.membershipEpoch !== team.expectedEpoch) {
    return { eligible: false };
  }
  try {
    const verified = await verifyDeviceForWrapping(verification);
    return { eligible: true, publicKey: verified.publicKey,
      highWater: verified.highWater, checkpointDigest: verified.checkpointDigest };
  } catch { return { eligible: false }; }
}

export async function wrapForVerifiedDevice({ cek, context, rootPublicKey, certificate,
  checkpoint, endpoint, pinRepository, cryptoValue = globalThis.crypto }) {
  if (context?.deviceID !== certificate?.payload?.deviceID) fail();
  if (typeof pinRepository?.loadPin !== "function"
    || typeof pinRepository?.advancePin !== "function") fail();
  const accountID = id(certificate.payload.accountID);
  const trust = await pinRepository.loadPin(normalizedEndpoint(endpoint), accountID);
  if (!trust || trust.endpoint !== normalizedEndpoint(endpoint)) fail();
  const verified = await verifyDeviceForWrapping({ rootPublicKey, certificate, checkpoint,
    trust, expectedDeviceID: context.deviceID, cryptoValue });
  await pinRepository.advancePin(trust, { ...trust, highWater: verified.highWater,
    checkpointDigest: verified.checkpointDigest });
  return { wrapper: await wrapResourceCEK({ cek, context,
    recipientPublicKey: verified.publicKey, cryptoValue }), highWater: verified.highWater,
    checkpointDigest: verified.checkpointDigest };
}
