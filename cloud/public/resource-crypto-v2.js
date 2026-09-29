// Dormant Vault v2 primitives. No production caller or route uses this module.
import { normalizeTeamDevicePublicKey } from "./team-vault-crypto.js";

const encoder = new TextEncoder();
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const b64url = /^[A-Za-z0-9_-]+$/u;
const ciphertextFields = ["teamID", "vaultID", "resourceID", "part", "keyVersion",
  "policyVersion", "registryVersion", "resourceVersion", "manifestVersion"];
const wrapperFields = ["teamID", "vaultID", "resourceID", "part", "keyVersion",
  "membershipID", "membershipEpoch", "deviceID"];
const maxPlaintext = 24 * 1024 * 1024;

function cryptoAPI(value) {
  if (!value?.subtle || typeof value.getRandomValues !== "function") throw new Error("web_crypto_unavailable");
  return value;
}

function exactKeys(value, keys) {
  if (!value || typeof value !== "object" || Array.isArray(value)
    || Object.keys(value).sort().join("\0") !== [...keys].sort().join("\0")) {
    throw new Error("invalid_resource_v2_envelope");
  }
}

function positive(value) {
  if (!Number.isSafeInteger(value) || value < 1) throw new Error("invalid_resource_v2_version");
  return value;
}

function normalizeContext(value, fields) {
  if (!value || typeof value !== "object") throw new Error("invalid_resource_v2_context");
  if (value.schemaVersion !== undefined && value.schemaVersion !== 2) {
    throw new Error("unsupported_resource_v2_schema");
  }
  const result = {};
  for (const field of fields) {
    const item = value[field];
    if (field.endsWith("ID")) {
      const normalized = String(item ?? "").toLowerCase();
      if (!uuid.test(normalized)) throw new Error("invalid_resource_v2_context");
      result[field] = normalized;
    } else if (field === "part") {
      if (item !== "GENERAL" && item !== "METADATA" && item !== "SECRET") {
        throw new Error("invalid_resource_v2_part");
      }
      result[field] = item;
    } else {
      result[field] = positive(item);
    }
  }
  return result;
}

export function validateResourceVersionSet(value) {
  const result = normalizeContext(value, ciphertextFields);
  if (value.schemaVersion !== undefined) result.schemaVersion = 2;
  return result;
}

function aad(value, fields, domain) {
  const context = normalizeContext(value, fields);
  const chunks = [encoder.encode(domain), Uint8Array.of(0, 2)];
  for (const field of fields) {
    const bytes = encoder.encode(String(context[field]));
    if (bytes.length > 65535) throw new Error("invalid_resource_v2_context");
    chunks.push(Uint8Array.of(bytes.length >> 8, bytes.length & 255), bytes);
  }
  const result = new Uint8Array(chunks.reduce((n, chunk) => n + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result;
}

export const resourceCiphertextAAD = (value) => aad(value, ciphertextFields,
  "selective-remote/resource-ciphertext/v2\0");
export const resourceWrapperAAD = (value) => aad(value, wrapperFields,
  "selective-remote/resource-wrapper/v2\0");

function encode(bytes) {
  let text = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(text).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function decode(value, length = null, allowEmpty = false) {
  if (allowEmpty && value === "") return new Uint8Array();
  if (typeof value !== "string" || !b64url.test(value)) throw new Error("invalid_resource_v2_envelope");
  let binary;
  try { binary = atob(value.replaceAll("-", "+").replaceAll("_", "/")
    + "=".repeat((4 - value.length % 4) % 4)); }
  catch { throw new Error("invalid_resource_v2_envelope"); }
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  if (encode(bytes) !== value || (length !== null && bytes.length !== length)) {
    throw new Error("invalid_resource_v2_envelope");
  }
  return bytes;
}

function keyBytes(cek) {
  if (!(cek instanceof Uint8Array) || cek.length !== 32) throw new Error("invalid_resource_cek");
  return cek;
}

export function generateResourceCEK(cryptoValue = globalThis.crypto) {
  return cryptoAPI(cryptoValue).getRandomValues(new Uint8Array(32));
}

function expectedContext(envelopeContext, expected, fields) {
  const actual = normalizeContext(envelopeContext, fields);
  const normalized = normalizeContext(expected, fields);
  if (fields.some((field) => actual[field] !== normalized[field])) {
    throw new Error("resource_v2_context_mismatch");
  }
  return normalized;
}

export async function encryptResourcePart({ plaintext, cek, context, cryptoValue = globalThis.crypto }) {
  if (!(plaintext instanceof Uint8Array) || plaintext.length > maxPlaintext) {
    throw new Error("invalid_resource_v2_plaintext");
  }
  const normalized = normalizeContext(context, ciphertextFields);
  const crypto = cryptoAPI(cryptoValue);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const key = await crypto.subtle.importKey("raw", keyBytes(cek), "AES-GCM", false, ["encrypt"]);
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce,
    additionalData: resourceCiphertextAAD(normalized), tagLength: 128 }, key, plaintext));
  return { formatVersion: 2, algorithm: "AES-256-GCM", aadVersion: 2, context: normalized,
    nonce: encode(nonce), ciphertext: encode(sealed.subarray(0, -16)),
    authTag: encode(sealed.subarray(-16)) };
}

export async function decryptResourcePart({ envelope, cek, context, cryptoValue = globalThis.crypto }) {
  validateResourceCipherEnvelope(envelope);
  const normalized = expectedContext(envelope.context, context, ciphertextFields);
  const nonce = decode(envelope.nonce, 12);
  const body = decode(envelope.ciphertext, null, true);
  const tag = decode(envelope.authTag, 16);
  if (body.length > maxPlaintext) throw new Error("invalid_resource_v2_envelope");
  const sealed = new Uint8Array(body.length + tag.length);
  sealed.set(body); sealed.set(tag, body.length);
  const crypto = cryptoAPI(cryptoValue);
  const key = await crypto.subtle.importKey("raw", keyBytes(cek), "AES-GCM", false, ["decrypt"]);
  return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce,
    additionalData: resourceCiphertextAAD(normalized), tagLength: 128 }, key, sealed));
}

export function validateResourceCipherEnvelope(envelope) {
  exactKeys(envelope, ["formatVersion", "algorithm", "aadVersion", "context", "nonce", "ciphertext", "authTag"]);
  if (envelope.formatVersion !== 2 || envelope.algorithm !== "AES-256-GCM" || envelope.aadVersion !== 2) {
    throw new Error("unsupported_resource_v2_format");
  }
  exactKeys(envelope.context, ciphertextFields);
  resourceCiphertextAAD(envelope.context);
  decode(envelope.nonce, 12);
  if (decode(envelope.ciphertext, null, true).length > maxPlaintext) throw new Error("invalid_resource_v2_envelope");
  decode(envelope.authTag, 16);
  return envelope.context;
}

async function wrappingKey({ privateKey, publicKey, context, usage, crypto }) {
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: publicKey }, privateKey, 256));
  try {
    const hkdf = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
    const salt = await crypto.subtle.digest("SHA-256", context);
    return await crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt,
      info: encoder.encode("selective-remote/resource-wrapper-key/v2") }, hkdf,
    { name: "AES-GCM", length: 256 }, false, [usage]);
  } finally { shared.fill(0); }
}

export async function wrapResourceCEK({ cek, context, recipientPublicKey, cryptoValue = globalThis.crypto }) {
  const normalized = normalizeContext(context, wrapperFields);
  const crypto = cryptoAPI(cryptoValue);
  const recipient = await crypto.subtle.importKey("jwk", normalizeTeamDevicePublicKey(recipientPublicKey),
    { name: "ECDH", namedCurve: "P-256" }, false, []);
  const ephemeral = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const aadBytes = resourceWrapperAAD(normalized);
  const key = await wrappingKey({ privateKey: ephemeral.privateKey, publicKey: recipient,
    context: aadBytes, usage: "encrypt", crypto });
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce,
    additionalData: aadBytes, tagLength: 128 }, key, keyBytes(cek)));
  return { wrapperVersion: 2, algorithm: "P256-ECDH-HKDF-SHA256-AES-256-GCM", aadVersion: 2,
    context: normalized, ephemeralPublicKey: normalizeTeamDevicePublicKey(
      await crypto.subtle.exportKey("jwk", ephemeral.publicKey)), nonce: encode(nonce),
    ciphertext: encode(sealed.subarray(0, -16)), authTag: encode(sealed.subarray(-16)) };
}

export async function unwrapResourceCEK({ wrapper, context, privateKey, cryptoValue = globalThis.crypto }) {
  validateResourceKeyWrapper(wrapper);
  const normalized = expectedContext(wrapper.context, context, wrapperFields);
  if (privateKey?.type !== "private" || privateKey?.algorithm?.name !== "ECDH"
    || privateKey?.algorithm?.namedCurve !== "P-256" || privateKey?.extractable !== false) {
    throw new Error("invalid_resource_v2_device_key");
  }
  const crypto = cryptoAPI(cryptoValue);
  const ephemeral = await crypto.subtle.importKey("jwk", normalizeTeamDevicePublicKey(wrapper.ephemeralPublicKey),
    { name: "ECDH", namedCurve: "P-256" }, false, []);
  const aadBytes = resourceWrapperAAD(normalized);
  const key = await wrappingKey({ privateKey, publicKey: ephemeral, context: aadBytes,
    usage: "decrypt", crypto });
  const body = decode(wrapper.ciphertext, 32);
  const tag = decode(wrapper.authTag, 16);
  const sealed = new Uint8Array(48);
  sealed.set(body); sealed.set(tag, 32);
  const raw = new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: decode(wrapper.nonce, 12),
    additionalData: aadBytes, tagLength: 128 }, key, sealed));
  return keyBytes(raw);
}

export function validateResourceKeyWrapper(wrapper) {
  exactKeys(wrapper, ["wrapperVersion", "algorithm", "aadVersion", "context",
    "ephemeralPublicKey", "nonce", "ciphertext", "authTag"]);
  if (wrapper.wrapperVersion !== 2 || wrapper.algorithm !== "P256-ECDH-HKDF-SHA256-AES-256-GCM"
    || wrapper.aadVersion !== 2) throw new Error("unsupported_resource_v2_wrapper");
  exactKeys(wrapper.context, wrapperFields);
  resourceWrapperAAD(wrapper.context);
  normalizeTeamDevicePublicKey(wrapper.ephemeralPublicKey);
  decode(wrapper.nonce, 12);
  decode(wrapper.ciphertext, 32);
  decode(wrapper.authTag, 16);
  return wrapper.context;
}

export function prepareResourceRotation({ context, oldCEK, cryptoValue = globalThis.crypto }) {
  keyBytes(oldCEK);
  const current = normalizeContext(context, ciphertextFields);
  if (current.keyVersion === Number.MAX_SAFE_INTEGER
    || current.manifestVersion === Number.MAX_SAFE_INTEGER) throw new Error("resource_v2_version_exhausted");
  return { state: "PREPARED", context: { ...current, keyVersion: current.keyVersion + 1,
    manifestVersion: current.manifestVersion + 1 },
    cek: generateResourceCEK(cryptoValue) };
}

export function validateResourceVersionCompatibility({ ciphertext, wrapper, pointer, expected }) {
  const actual = validateResourceCipherEnvelope(ciphertext);
  const target = validateResourceKeyWrapper(wrapper);
  const required = validateResourceVersionSet(expected);
  exactKeys(pointer, ["keyVersion", "manifestVersion"]);
  if (ciphertextFields.some((field) => actual[field] !== required[field])
    || pointer.keyVersion !== actual.keyVersion
    || pointer.manifestVersion !== actual.manifestVersion
    || ["teamID", "vaultID", "resourceID", "part", "keyVersion"].some(
      (field) => target[field] !== actual[field])) {
    throw new Error("stale_resource_v2_version");
  }
  return true;
}
