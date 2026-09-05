export const teamVaultEnvelopeVersion = 1;
export const teamVaultWrapperVersion = 1;
export const teamDevicePublicKeyAlgorithm = "p256-ecdh-v1";

const wrapperContextLabel = "selective-remote/team-vault-wrapper/v1";
const wrapperKeyInfo = new TextEncoder().encode("selective-remote/team-vault-wrapper-key/v1");
const payloadContextLabel = "selective-remote/team-vault-payload/v1";
const databaseName = "selective-remote-cloud";
const storeName = "local-vault";
const identityKeyPrefix = "team-device-key:";
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const base64URLPattern = /^[A-Za-z0-9_-]+$/u;
const maxCiphertextCharacters = 32 * 1024 * 1024;
const textEncoder = new TextEncoder();

function webCrypto(cryptoValue) {
  if (!cryptoValue?.subtle || typeof cryptoValue.getRandomValues !== "function") {
    throw new Error("web_crypto_unavailable");
  }
  return cryptoValue;
}

function clone(value) {
  if (typeof globalThis.structuredClone !== "function") throw new Error("structured_clone_unavailable");
  return globalThis.structuredClone(value);
}

function exactKeys(value, expected, code) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(code);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error(code);
  }
}

function normalizedUUID(value, code = "invalid_team_vault_scope") {
  const normalized = String(value ?? "").toLowerCase();
  if (!uuidPattern.test(normalized)) throw new Error(code);
  return normalized;
}

function normalizedGeneration(value) {
  if (!Number.isSafeInteger(value) || value < 1) throw new Error("invalid_key_generation");
  return value;
}

function bytesToBase64URL(bytes) {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function base64URLToBytes(value, expectedLength, code) {
  if (typeof value !== "string" || !base64URLPattern.test(value)) throw new Error(code);
  const padded = value.replaceAll("-", "+").replaceAll("_", "/")
    + "=".repeat((4 - (value.length % 4)) % 4);
  let decoded;
  try {
    decoded = atob(padded);
  } catch {
    throw new Error(code);
  }
  const bytes = Uint8Array.from(decoded, (character) => character.charCodeAt(0));
  if (bytes.length !== expectedLength || bytesToBase64URL(bytes) !== value) throw new Error(code);
  return bytes;
}

function concatenate(...values) {
  const result = new Uint8Array(values.reduce((total, value) => total + value.length, 0));
  let offset = 0;
  for (const value of values) {
    result.set(value, offset);
    offset += value.length;
  }
  return result;
}

function validatedPayload(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid_vault_payload");
  let serialized;
  try {
    serialized = JSON.stringify(value);
  } catch {
    throw new Error("invalid_vault_payload");
  }
  if (!serialized) throw new Error("invalid_vault_payload");
  const bytes = textEncoder.encode(serialized);
  if (bytes.length > 24 * 1024 * 1024) throw new Error("vault_too_large");
  return bytes;
}

function validatedPrivateKey(value) {
  if (!value || value.type !== "private" || value.extractable !== false
    || value.algorithm?.name !== "ECDH" || value.algorithm?.namedCurve !== "P-256"
    || !Array.isArray(value.usages) || !value.usages.includes("deriveBits")) {
    throw new Error("invalid_team_device_private_key");
  }
  return value;
}

function equalBytes(left, right) {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference |= left[index] ^ right[index];
  return difference === 0;
}

export function normalizeTeamDevicePublicKey(value) {
  const allowed = new Set(["crv", "ext", "key_ops", "kty", "x", "y"]);
  if (!value || typeof value !== "object" || Array.isArray(value)
    || Object.keys(value).some((key) => !allowed.has(key)) || "d" in value
    || value.kty !== "EC" || value.crv !== "P-256"
    || typeof value.x !== "string" || value.x.length !== 43 || !base64URLPattern.test(value.x)
    || typeof value.y !== "string" || value.y.length !== 43 || !base64URLPattern.test(value.y)
    || ("ext" in value && value.ext !== true)
    || ("key_ops" in value && (!Array.isArray(value.key_ops) || value.key_ops.length !== 0))) {
    throw new Error("invalid_team_device_public_key");
  }
  return { kty: "EC", crv: "P-256", x: value.x, y: value.y, ext: true, key_ops: [] };
}

export function normalizeTeamVaultScope(value) {
  exactKeys(value, ["teamID", "type", "vaultID"], "invalid_team_vault_scope");
  if (value.type !== "team") throw new Error("invalid_team_vault_scope");
  return Object.freeze({
    type: "team",
    teamID: normalizedUUID(value.teamID),
    vaultID: normalizedUUID(value.vaultID),
  });
}

export function teamVaultWrapperContext({
  teamID,
  vaultID,
  keyGeneration,
  membershipID,
  membershipEpoch,
  deviceID,
}) {
  const generation = normalizedGeneration(keyGeneration);
  if (!Number.isSafeInteger(membershipEpoch) || membershipEpoch < 1) {
    throw new Error("invalid_team_vault_wrapper");
  }
  return [
    wrapperContextLabel,
    normalizedUUID(teamID, "invalid_team_vault_wrapper"),
    normalizedUUID(vaultID, "invalid_team_vault_wrapper"),
    String(generation),
    normalizedUUID(membershipID, "invalid_team_vault_wrapper"),
    String(membershipEpoch),
    normalizedUUID(deviceID, "invalid_team_vault_wrapper"),
  ].join("\0");
}

export async function teamVaultWrapperContextHash(value, cryptoValue = globalThis.crypto) {
  const digest = await webCrypto(cryptoValue).subtle.digest(
    "SHA-256",
    textEncoder.encode(teamVaultWrapperContext(value)),
  );
  return bytesToBase64URL(new Uint8Array(digest));
}

function normalizedWrapper(value) {
  exactKeys(value, [
    "authTag", "ciphertext", "contextHash", "deviceID", "ephemeralPublicKey",
    "membershipEpoch", "membershipID", "nonce", "wrapperVersion",
  ], "invalid_team_vault_wrapper");
  if (value.wrapperVersion !== teamVaultWrapperVersion
    || !Number.isSafeInteger(value.membershipEpoch) || value.membershipEpoch < 1) {
    throw new Error("invalid_team_vault_wrapper");
  }
  base64URLToBytes(value.ciphertext, 32, "invalid_team_vault_wrapper");
  base64URLToBytes(value.nonce, 12, "invalid_team_vault_wrapper");
  base64URLToBytes(value.authTag, 16, "invalid_team_vault_wrapper");
  base64URLToBytes(value.contextHash, 32, "invalid_team_vault_wrapper");
  return {
    membershipID: normalizedUUID(value.membershipID, "invalid_team_vault_wrapper"),
    membershipEpoch: value.membershipEpoch,
    deviceID: normalizedUUID(value.deviceID, "invalid_team_vault_wrapper"),
    wrapperVersion: teamVaultWrapperVersion,
    ephemeralPublicKey: normalizeTeamDevicePublicKey(value.ephemeralPublicKey),
    ciphertext: value.ciphertext,
    nonce: value.nonce,
    authTag: value.authTag,
    contextHash: value.contextHash,
  };
}

async function deriveWrapperKey(sharedSecret, contextBytes, usages, cryptoValue) {
  const crypto = webCrypto(cryptoValue);
  const material = await crypto.subtle.importKey("raw", sharedSecret, "HKDF", false, ["deriveKey"]);
  const salt = await crypto.subtle.digest("SHA-256", contextBytes);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt, info: wrapperKeyInfo },
    material,
    { name: "AES-GCM", length: 256 },
    false,
    usages,
  );
}

export async function generateTeamDeviceIdentity(cryptoValue = globalThis.crypto) {
  const crypto = webCrypto(cryptoValue);
  const pair = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    false,
    ["deriveBits"],
  );
  return {
    privateKey: validatedPrivateKey(pair.privateKey),
    publicKey: normalizeTeamDevicePublicKey(await crypto.subtle.exportKey("jwk", pair.publicKey)),
  };
}

async function validateIdentityKeyPair(identity, cryptoValue) {
  const crypto = webCrypto(cryptoValue);
  const privateKey = validatedPrivateKey(identity.privateKey);
  const publicKey = normalizeTeamDevicePublicKey(identity.publicKey);
  try {
    const importedPublicKey = await crypto.subtle.importKey(
      "jwk",
      publicKey,
      { name: "ECDH", namedCurve: "P-256" },
      false,
      [],
    );
    const verifier = await crypto.subtle.generateKey(
      { name: "ECDH", namedCurve: "P-256" },
      false,
      ["deriveBits"],
    );
    const [fromPrivate, fromPublic] = await Promise.all([
      crypto.subtle.deriveBits({ name: "ECDH", public: verifier.publicKey }, privateKey, 256),
      crypto.subtle.deriveBits({ name: "ECDH", public: importedPublicKey }, verifier.privateKey, 256),
    ]);
    if (!equalBytes(new Uint8Array(fromPrivate), new Uint8Array(fromPublic))) throw new Error();
  } catch {
    throw new Error("invalid_team_device_identity");
  }
  return identity;
}

export async function wrapTeamVaultKeyForDevice({
  vaultKey,
  recipient,
  teamID,
  vaultID,
  keyGeneration,
  cryptoValue = globalThis.crypto,
}) {
  const crypto = webCrypto(cryptoValue);
  const publicKey = normalizeTeamDevicePublicKey(recipient?.publicKey);
  const contextValue = {
    teamID,
    vaultID,
    keyGeneration,
    membershipID: recipient?.membershipID,
    membershipEpoch: recipient?.membershipEpoch,
    deviceID: recipient?.deviceID,
  };
  const contextBytes = textEncoder.encode(teamVaultWrapperContext(contextValue));
  let rawVaultKey;
  try {
    rawVaultKey = new Uint8Array(await crypto.subtle.exportKey("raw", vaultKey));
  } catch {
    throw new Error("invalid_team_vault_key");
  }
  if (rawVaultKey.length !== 32) throw new Error("invalid_team_vault_key");
  const recipientKey = await crypto.subtle.importKey(
    "jwk",
    publicKey,
    { name: "ECDH", namedCurve: "P-256" },
    false,
    [],
  );
  const ephemeral = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    false,
    ["deriveBits"],
  );
  const sharedSecret = await crypto.subtle.deriveBits(
    { name: "ECDH", public: recipientKey },
    ephemeral.privateKey,
    256,
  );
  const wrappingKey = await deriveWrapperKey(sharedSecret, contextBytes, ["encrypt"], crypto);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce, additionalData: contextBytes, tagLength: 128 },
    wrappingKey,
    rawVaultKey,
  ));
  return {
    membershipID: normalizedUUID(recipient.membershipID, "invalid_team_vault_wrapper"),
    membershipEpoch: recipient.membershipEpoch,
    deviceID: normalizedUUID(recipient.deviceID, "invalid_team_vault_wrapper"),
    wrapperVersion: teamVaultWrapperVersion,
    ephemeralPublicKey: normalizeTeamDevicePublicKey(
      await crypto.subtle.exportKey("jwk", ephemeral.publicKey),
    ),
    ciphertext: bytesToBase64URL(encrypted.subarray(0, 32)),
    nonce: bytesToBase64URL(nonce),
    authTag: bytesToBase64URL(encrypted.subarray(32)),
    contextHash: await teamVaultWrapperContextHash(contextValue, crypto),
  };
}

export async function unwrapTeamVaultKeyForDevice({
  privateKey,
  wrapper,
  teamID,
  vaultID,
  keyGeneration,
  deviceID,
  cryptoValue = globalThis.crypto,
}) {
  const crypto = webCrypto(cryptoValue);
  validatedPrivateKey(privateKey);
  const normalized = normalizedWrapper(wrapper);
  if (normalized.deviceID !== normalizedUUID(deviceID, "invalid_team_vault_wrapper")) {
    throw new Error("team_vault_wrapper_device_mismatch");
  }
  const contextValue = {
    teamID,
    vaultID,
    keyGeneration,
    membershipID: normalized.membershipID,
    membershipEpoch: normalized.membershipEpoch,
    deviceID: normalized.deviceID,
  };
  const contextBytes = textEncoder.encode(teamVaultWrapperContext(contextValue));
  if (normalized.contextHash !== await teamVaultWrapperContextHash(contextValue, crypto)) {
    throw new Error("team_vault_wrapper_context_mismatch");
  }
  try {
    const ephemeralKey = await crypto.subtle.importKey(
      "jwk",
      normalized.ephemeralPublicKey,
      { name: "ECDH", namedCurve: "P-256" },
      false,
      [],
    );
    const sharedSecret = await crypto.subtle.deriveBits(
      { name: "ECDH", public: ephemeralKey },
      privateKey,
      256,
    );
    const wrappingKey = await deriveWrapperKey(sharedSecret, contextBytes, ["decrypt"], crypto);
    const rawVaultKey = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: base64URLToBytes(normalized.nonce, 12, "invalid_team_vault_wrapper"),
        additionalData: contextBytes,
        tagLength: 128,
      },
      wrappingKey,
      concatenate(
        base64URLToBytes(normalized.ciphertext, 32, "invalid_team_vault_wrapper"),
        base64URLToBytes(normalized.authTag, 16, "invalid_team_vault_wrapper"),
      ),
    );
    return await crypto.subtle.importKey(
      "raw",
      rawVaultKey,
      { name: "AES-GCM", length: 256 },
      true,
      ["encrypt", "decrypt"],
    );
  } catch (error) {
    if (error?.message?.startsWith("invalid_team_vault")) throw error;
    throw new Error("team_vault_key_unwrap_failed");
  }
}

function payloadContext({ teamID, vaultID, keyGeneration }) {
  return [
    payloadContextLabel,
    normalizedUUID(teamID),
    normalizedUUID(vaultID),
    String(normalizedGeneration(keyGeneration)),
  ].join("\0");
}

async function teamPayloadHash(contextBytes, nonce, ciphertext, authTag, cryptoValue) {
  const digest = await webCrypto(cryptoValue).subtle.digest(
    "SHA-256",
    concatenate(new Uint8Array([teamVaultEnvelopeVersion]), contextBytes, nonce, ciphertext, authTag),
  );
  return bytesToBase64URL(new Uint8Array(digest));
}

export async function encryptTeamVaultPayload({
  vaultKey,
  payload,
  scope,
  baseRevision,
  keyGeneration,
  wrappers = null,
  cryptoValue = globalThis.crypto,
}) {
  if (!Number.isSafeInteger(baseRevision) || baseRevision < 0) throw new Error("invalid_base_revision");
  const normalizedScope = normalizeTeamVaultScope(scope);
  const generation = normalizedGeneration(keyGeneration);
  if (wrappers !== null && !Array.isArray(wrappers)) throw new Error("invalid_team_vault_wrappers");
  const normalizedWrappers = wrappers === null ? null : wrappers.map(normalizedWrapper);
  if (normalizedWrappers && (normalizedWrappers.length === 0
    || new Set(normalizedWrappers.map((value) => value.deviceID)).size !== normalizedWrappers.length)) {
    throw new Error("invalid_team_vault_wrappers");
  }
  const crypto = webCrypto(cryptoValue);
  const contextBytes = textEncoder.encode(payloadContext({ ...normalizedScope, keyGeneration: generation }));
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  let encrypted;
  try {
    encrypted = new Uint8Array(await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: nonce, additionalData: contextBytes, tagLength: 128 },
      vaultKey,
      validatedPayload(payload),
    ));
  } catch {
    throw new Error("team_vault_encryption_failed");
  }
  const ciphertext = encrypted.subarray(0, encrypted.length - 16);
  const authTag = encrypted.subarray(encrypted.length - 16);
  const envelope = {
    baseRevision,
    keyGeneration: generation,
    envelopeVersion: teamVaultEnvelopeVersion,
    ciphertext: bytesToBase64URL(ciphertext),
    nonce: bytesToBase64URL(nonce),
    authTag: bytesToBase64URL(authTag),
    contentHash: await teamPayloadHash(contextBytes, nonce, ciphertext, authTag, crypto),
  };
  if (normalizedWrappers) envelope.wrappers = normalizedWrappers;
  return envelope;
}

export async function decryptTeamVaultPayload({
  vaultKey,
  envelope,
  scope,
  cryptoValue = globalThis.crypto,
}) {
  const normalizedScope = normalizeTeamVaultScope(scope);
  if (!envelope || envelope.envelopeVersion !== teamVaultEnvelopeVersion) {
    throw new Error("invalid_team_vault_envelope");
  }
  const generation = normalizedGeneration(envelope.keyGeneration);
  const nonce = base64URLToBytes(envelope.nonce, 12, "invalid_team_vault_envelope");
  const authTag = base64URLToBytes(envelope.authTag, 16, "invalid_team_vault_envelope");
  base64URLToBytes(envelope.contentHash, 32, "invalid_team_vault_envelope");
  if (typeof envelope.ciphertext !== "string" || envelope.ciphertext.length > maxCiphertextCharacters) {
    throw new Error("vault_too_large");
  }
  let ciphertext;
  try {
    const padded = envelope.ciphertext.replaceAll("-", "+").replaceAll("_", "/")
      + "=".repeat((4 - (envelope.ciphertext.length % 4)) % 4);
    ciphertext = Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
    if (!base64URLPattern.test(envelope.ciphertext) || bytesToBase64URL(ciphertext) !== envelope.ciphertext) throw new Error();
  } catch {
    throw new Error("invalid_team_vault_envelope");
  }
  const contextBytes = textEncoder.encode(payloadContext({ ...normalizedScope, keyGeneration: generation }));
  if (envelope.contentHash !== await teamPayloadHash(contextBytes, nonce, ciphertext, authTag, cryptoValue)) {
    throw new Error("team_vault_content_hash_mismatch");
  }
  let decrypted;
  try {
    decrypted = await webCrypto(cryptoValue).subtle.decrypt(
      { name: "AES-GCM", iv: nonce, additionalData: contextBytes, tagLength: 128 },
      vaultKey,
      concatenate(ciphertext, authTag),
    );
  } catch {
    throw new Error("team_vault_decryption_failed");
  }
  try {
    const payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(decrypted));
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) throw new Error();
    return payload;
  } catch {
    throw new Error("invalid_vault_payload");
  }
}

function openDatabase(indexedDBValue) {
  if (!indexedDBValue?.open) return Promise.reject(new Error("team_device_storage_unavailable"));
  return new Promise((resolve, reject) => {
    const request = indexedDBValue.open(databaseName, 1);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(storeName)) request.result.createObjectStore(storeName);
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(new Error("team_device_storage_unavailable"));
    request.onblocked = () => reject(new Error("team_device_storage_unavailable"));
  });
}

async function transaction(indexedDBValue, mode, operation) {
  const database = await openDatabase(indexedDBValue);
  try {
    return await new Promise((resolve, reject) => {
      const tx = database.transaction(storeName, mode);
      const request = operation(tx.objectStore(storeName));
      let result = null;
      request.onsuccess = () => { result = request.result ?? null; };
      request.onerror = () => reject(new Error("team_device_storage_failed"));
      tx.onabort = () => reject(new Error("team_device_storage_failed"));
      tx.onerror = () => reject(new Error("team_device_storage_failed"));
      tx.oncomplete = () => resolve(result);
    });
  } finally {
    database.close();
  }
}

function validatedStoredIdentity(value, expectedDeviceID) {
  exactKeys(value, ["deviceID", "privateKey", "publicKey"], "invalid_team_device_identity");
  const deviceID = normalizedUUID(value.deviceID, "invalid_team_device_identity");
  if (deviceID !== expectedDeviceID) throw new Error("invalid_team_device_identity");
  return {
    deviceID,
    privateKey: validatedPrivateKey(value.privateKey),
    publicKey: normalizeTeamDevicePublicKey(value.publicKey),
  };
}

export function createIndexedDBTeamDeviceRepository(indexedDBValue = globalThis.indexedDB) {
  return {
    async load(deviceID) {
      const normalized = normalizedUUID(deviceID, "invalid_team_device_identity");
      const value = await transaction(
        indexedDBValue,
        "readonly",
        (store) => store.get(`${identityKeyPrefix}${normalized}`),
      );
      return value === null || value === undefined ? null : validatedStoredIdentity(value, normalized);
    },
    async save(value) {
      const normalized = validatedStoredIdentity(value, normalizedUUID(value?.deviceID, "invalid_team_device_identity"));
      await transaction(
        indexedDBValue,
        "readwrite",
        (store) => store.put(clone(normalized), `${identityKeyPrefix}${normalized.deviceID}`),
      );
    },
    async saveIfAbsent(value) {
      const normalized = validatedStoredIdentity(value, normalizedUUID(value?.deviceID, "invalid_team_device_identity"));
      const database = await openDatabase(indexedDBValue);
      try {
        return await new Promise((resolve, reject) => {
          const tx = database.transaction(storeName, "readwrite");
          const store = tx.objectStore(storeName);
          const key = `${identityKeyPrefix}${normalized.deviceID}`;
          let committed = null;
          const request = store.get(key);
          request.onerror = () => reject(new Error("team_device_storage_failed"));
          request.onsuccess = () => {
            if (request.result !== null && request.result !== undefined) {
              try {
                committed = validatedStoredIdentity(request.result, normalized.deviceID);
              } catch {
                reject(new Error("invalid_team_device_identity"));
              }
              return;
            }
            const add = store.add(clone(normalized), key);
            add.onerror = () => reject(new Error("team_device_storage_failed"));
            add.onsuccess = () => { committed = normalized; };
          };
          tx.onabort = () => reject(new Error("team_device_storage_failed"));
          tx.onerror = () => reject(new Error("team_device_storage_failed"));
          tx.oncomplete = () => resolve(committed);
        });
      } finally {
        database.close();
      }
    },
  };
}

export async function ensureTeamDeviceIdentity({
  repository,
  deviceID,
  cryptoValue = globalThis.crypto,
}) {
  if (!repository || typeof repository.load !== "function" || typeof repository.save !== "function") {
    throw new Error("invalid_team_device_repository");
  }
  const normalizedDeviceID = normalizedUUID(deviceID, "invalid_team_device_identity");
  const existing = await repository.load(normalizedDeviceID);
  if (existing) {
    const normalized = validatedStoredIdentity(existing, normalizedDeviceID);
    await validateIdentityKeyPair(normalized, cryptoValue);
    return normalized;
  }
  const generated = await generateTeamDeviceIdentity(cryptoValue);
  const identity = { deviceID: normalizedDeviceID, ...generated };
  const committed = typeof repository.saveIfAbsent === "function"
    ? await repository.saveIfAbsent(identity)
    : (await repository.save(identity), identity);
  const normalized = validatedStoredIdentity(committed, normalizedDeviceID);
  await validateIdentityKeyPair(normalized, cryptoValue);
  return normalized;
}
