export const vaultEnvelopeVersion = 1;
export const recoveryKDFIterations = 600_000;

const recoveryAlgorithm = "PBKDF2-SHA256+A256KW";
const additionalData = new TextEncoder().encode("selective-remote:vault-envelope:v1");
const base64URLPattern = /^[A-Za-z0-9_-]+$/;
const maxCiphertextCharacters = 32 * 1024 * 1024;

function webCrypto(cryptoValue) {
  if (!cryptoValue?.subtle || typeof cryptoValue.getRandomValues !== "function") {
    throw new Error("web_crypto_unavailable");
  }
  return cryptoValue;
}

function bytesToBase64URL(bytes) {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function base64URLToBytes(value, expectedLength = null) {
  if (typeof value !== "string" || !base64URLPattern.test(value)) {
    throw new Error("invalid_vault_envelope");
  }
  const padded = value.replaceAll("-", "+").replaceAll("_", "/")
    + "=".repeat((4 - (value.length % 4)) % 4);
  let decoded;
  try {
    decoded = atob(padded);
  } catch {
    throw new Error("invalid_vault_envelope");
  }
  const bytes = Uint8Array.from(decoded, (character) => character.charCodeAt(0));
  if (bytesToBase64URL(bytes) !== value || (expectedLength !== null && bytes.length !== expectedLength)) {
    throw new Error("invalid_vault_envelope");
  }
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

function recoveryPassphraseBytes(passphrase) {
  const value = String(passphrase ?? "").normalize("NFC");
  const bytes = new TextEncoder().encode(value);
  if (bytes.length < 16 || bytes.length > 1024) throw new Error("invalid_recovery_passphrase");
  return bytes;
}

function validatedWrappedKey(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid_wrapped_key");
  const keys = Object.keys(value).sort();
  if (keys.join(",") !== "algorithm,iterations,salt,value") throw new Error("invalid_wrapped_key");
  if (value.algorithm !== recoveryAlgorithm || value.iterations !== recoveryKDFIterations) {
    throw new Error("invalid_wrapped_key");
  }
  try {
    const salt = base64URLToBytes(value.salt, 16);
    const wrapped = base64URLToBytes(value.value, 40);
    return {
      salt,
      wrapped,
      normalized: {
        algorithm: recoveryAlgorithm,
        iterations: recoveryKDFIterations,
        salt: value.salt,
        value: value.value,
      },
    };
  } catch {
    throw new Error("invalid_wrapped_key");
  }
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
  const bytes = new TextEncoder().encode(serialized);
  if (bytes.length > 24 * 1024 * 1024) throw new Error("vault_too_large");
  return bytes;
}

async function deriveRecoveryKey(passphrase, salt, cryptoValue) {
  const crypto = webCrypto(cryptoValue);
  const material = await crypto.subtle.importKey(
    "raw",
    recoveryPassphraseBytes(passphrase),
    "PBKDF2",
    false,
    ["deriveKey"],
  );
  return crypto.subtle.deriveKey(
    { name: "PBKDF2", hash: "SHA-256", salt, iterations: recoveryKDFIterations },
    material,
    { name: "AES-KW", length: 256 },
    false,
    ["wrapKey", "unwrapKey"],
  );
}

async function contentHash(nonce, ciphertext, authTag, cryptoValue) {
  const version = new Uint8Array([vaultEnvelopeVersion]);
  const digest = await webCrypto(cryptoValue).subtle.digest(
    "SHA-256",
    concatenate(version, nonce, ciphertext, authTag),
  );
  return bytesToBase64URL(new Uint8Array(digest));
}

export async function generateVaultKey(cryptoValue = globalThis.crypto) {
  return webCrypto(cryptoValue).subtle.generateKey(
    { name: "AES-GCM", length: 256 },
    true,
    ["encrypt", "decrypt"],
  );
}

export async function wrapVaultKey(vaultKey, passphrase, cryptoValue = globalThis.crypto) {
  const crypto = webCrypto(cryptoValue);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const recoveryKey = await deriveRecoveryKey(passphrase, salt, crypto);
  let wrapped;
  try {
    wrapped = await crypto.subtle.wrapKey("raw", vaultKey, recoveryKey, "AES-KW");
  } catch {
    throw new Error("vault_key_wrap_failed");
  }
  return {
    algorithm: recoveryAlgorithm,
    iterations: recoveryKDFIterations,
    salt: bytesToBase64URL(salt),
    value: bytesToBase64URL(new Uint8Array(wrapped)),
  };
}

export async function unwrapVaultKey(wrappedKey, passphrase, cryptoValue = globalThis.crypto) {
  const crypto = webCrypto(cryptoValue);
  const { salt, wrapped } = validatedWrappedKey(wrappedKey);
  const recoveryKey = await deriveRecoveryKey(passphrase, salt, crypto);
  try {
    return await crypto.subtle.unwrapKey(
      "raw",
      wrapped,
      recoveryKey,
      "AES-KW",
      { name: "AES-GCM", length: 256 },
      true,
      ["encrypt", "decrypt"],
    );
  } catch {
    throw new Error("invalid_recovery_passphrase");
  }
}

export async function encryptVaultPayload({
  vaultKey,
  payload,
  baseRevision,
  wrappedKey,
  cryptoValue = globalThis.crypto,
}) {
  if (!Number.isSafeInteger(baseRevision) || baseRevision < 0) throw new Error("invalid_base_revision");
  const { normalized: normalizedWrappedKey } = validatedWrappedKey(wrappedKey);
  const crypto = webCrypto(cryptoValue);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = validatedPayload(payload);
  let encrypted;
  try {
    encrypted = new Uint8Array(await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: nonce, additionalData, tagLength: 128 },
      vaultKey,
      plaintext,
    ));
  } catch {
    throw new Error("vault_encryption_failed");
  }
  const ciphertext = encrypted.subarray(0, encrypted.length - 16);
  const authTag = encrypted.subarray(encrypted.length - 16);
  return {
    baseRevision,
    envelopeVersion: vaultEnvelopeVersion,
    wrappedKey: normalizedWrappedKey,
    ciphertext: bytesToBase64URL(ciphertext),
    nonce: bytesToBase64URL(nonce),
    authTag: bytesToBase64URL(authTag),
    contentHash: await contentHash(nonce, ciphertext, authTag, crypto),
  };
}

export async function decryptVaultEnvelope(vaultKey, envelope, cryptoValue = globalThis.crypto) {
  if (!envelope || envelope.envelopeVersion !== vaultEnvelopeVersion) throw new Error("invalid_vault_envelope");
  validatedWrappedKey(envelope.wrappedKey);
  const crypto = webCrypto(cryptoValue);
  const nonce = base64URLToBytes(envelope.nonce, 12);
  const authTag = base64URLToBytes(envelope.authTag, 16);
  base64URLToBytes(envelope.contentHash, 32);
  if (typeof envelope.ciphertext !== "string" || envelope.ciphertext.length > maxCiphertextCharacters) {
    throw new Error("vault_too_large");
  }
  const ciphertext = base64URLToBytes(envelope.ciphertext);
  const expectedHash = await contentHash(nonce, ciphertext, authTag, crypto);
  if (envelope.contentHash !== expectedHash) throw new Error("vault_content_hash_mismatch");
  let decrypted;
  try {
    decrypted = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: nonce, additionalData, tagLength: 128 },
      vaultKey,
      concatenate(ciphertext, authTag),
    );
  } catch {
    throw new Error("vault_decryption_failed");
  }
  try {
    const payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(decrypted));
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) throw new Error();
    return payload;
  } catch {
    throw new Error("invalid_vault_payload");
  }
}
