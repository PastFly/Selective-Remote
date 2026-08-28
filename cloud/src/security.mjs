import { createHash, createHmac, randomBytes, scrypt as scryptCallback, timingSafeEqual } from "node:crypto";
import { promisify } from "node:util";

const scrypt = promisify(scryptCallback);
const passwordKeyLength = 32;
const scryptOptions = Object.freeze({ N: 1 << 17, r: 8, p: 1, maxmem: 256 * 1024 * 1024 });

export function normalizeEmail(value) {
  const email = String(value ?? "").trim().toLowerCase();
  if (email.length < 3 || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new Error("invalid_email");
  }
  return email;
}

export function validatePassword(value) {
  const password = String(value ?? "");
  if (password.length < 12 || password.length > 1024) throw new Error("invalid_password");
  return password;
}

export async function hashPassword(password) {
  const validated = validatePassword(password);
  const salt = randomBytes(32);
  const derived = await scrypt(validated, salt, passwordKeyLength, scryptOptions);
  return `scrypt$v=1$N=${scryptOptions.N},r=${scryptOptions.r},p=${scryptOptions.p}$${salt.toString("base64url")}$${derived.toString("base64url")}`;
}

export async function verifyPassword(password, encoded) {
  try {
    const [algorithm, version, params, saltValue, hashValue] = String(encoded).split("$");
    if (algorithm !== "scrypt" || version !== "v=1") return false;
    const parsed = Object.fromEntries(params.split(",").map((entry) => entry.split("=")));
    const options = {
      N: Number.parseInt(parsed.N, 10),
      r: Number.parseInt(parsed.r, 10),
      p: Number.parseInt(parsed.p, 10),
      maxmem: 256 * 1024 * 1024,
    };
    if (options.N !== scryptOptions.N || options.r !== scryptOptions.r || options.p !== scryptOptions.p) return false;
    const expected = Buffer.from(hashValue, "base64url");
    const actual = await scrypt(validatePassword(password), Buffer.from(saltValue, "base64url"), expected.length, options);
    return expected.length === actual.length && timingSafeEqual(expected, actual);
  } catch {
    return false;
  }
}

export function createSessionToken() {
  return randomBytes(32).toString("base64url");
}

export function hashSessionToken(token, pepper) {
  return createHash("sha256").update(pepper).update("\0").update(token).digest("base64url");
}

export function createEmailVerificationToken() {
  return randomBytes(32).toString("base64url");
}

export function hashEmailVerificationToken(token, pepper) {
  if (!token || token.length > 256) throw new Error("invalid_verification_token");
  return createHmac("sha256", pepper).update(token).digest("hex");
}

export function createPasswordResetToken() {
  return randomBytes(32).toString("base64url");
}

export function hashPasswordResetToken(token, pepper) {
  if (!token || token.length > 256) throw new Error("invalid_password_reset_token");
  return createHmac("sha256", pepper).update(token).digest("hex");
}

export function hashAbuseKey(scope, value, pepper) {
  const normalizedScope = String(scope ?? "");
  const normalizedValue = String(value ?? "");
  if (!/^[a-z][a-z0-9_-]{0,63}$/.test(normalizedScope) || !normalizedValue || normalizedValue.length > 512) {
    throw new Error("invalid_abuse_key");
  }
  return createHmac("sha256", pepper)
    .update(normalizedScope)
    .update("\0")
    .update(normalizedValue)
    .digest("hex");
}

export function isUUID(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value));
}

export function validateVaultEnvelope(value) {
  const envelope = value && typeof value === "object" ? value : {};
  const required = ["ciphertext", "nonce", "authTag", "contentHash"];
  for (const key of required) {
    if (typeof envelope[key] !== "string" || envelope[key].length === 0) throw new Error("invalid_vault_envelope");
  }
  if (!Number.isInteger(envelope.baseRevision) || envelope.baseRevision < 0) throw new Error("invalid_base_revision");
  if (!Number.isInteger(envelope.envelopeVersion) || envelope.envelopeVersion < 1) throw new Error("invalid_envelope_version");
  if (envelope.ciphertext.length > 32 * 1024 * 1024) throw new Error("vault_too_large");
  if (envelope.nonce.length > 128 || envelope.authTag.length > 128 || envelope.contentHash.length > 256) {
    throw new Error("invalid_vault_envelope");
  }
  return envelope;
}
