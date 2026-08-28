import assert from "node:assert/strict";
import test from "node:test";
import {
  createEmailVerificationToken,
  hashAbuseKey,
  hashEmailVerificationToken,
  hashPassword,
  hashSessionToken,
  normalizeEmail,
  validateVaultEnvelope,
  verifyPassword,
} from "../src/security.mjs";

test("email normalization is deterministic", () => {
  assert.equal(normalizeEmail("  User@Example.COM "), "user@example.com");
  assert.throws(() => normalizeEmail("not-an-email"), /invalid_email/);
});

test("password hashes are salted and verifiable", async () => {
  const password = "a-long-test-password";
  const first = await hashPassword(password);
  const second = await hashPassword(password);
  assert.notEqual(first, second);
  assert.equal(await verifyPassword(password, first), true);
  assert.equal(await verifyPassword("wrong-password-value", first), false);
});

test("session token hashes are pepper-bound", () => {
  assert.notEqual(hashSessionToken("token", "a".repeat(32)), hashSessionToken("token", "b".repeat(32)));
});

test("email verification tokens are opaque and HMAC-bound", () => {
  const first = createEmailVerificationToken();
  const second = createEmailVerificationToken();
  assert.notEqual(first, second);
  assert.ok(first.length >= 40);
  const hash = hashEmailVerificationToken(first, "a".repeat(32));
  assert.match(hash, /^[0-9a-f]{64}$/);
  assert.notEqual(hash, hashEmailVerificationToken(first, "b".repeat(32)));
  assert.throws(() => hashEmailVerificationToken("", "a".repeat(32)), /invalid_verification_token/);
});

test("abuse-control keys are scope- and pepper-bound HMAC values", () => {
  const value = "203.0.113.42";
  const pepper = "r".repeat(32);
  const loginHash = hashAbuseKey("login_ip", value, pepper);

  assert.match(loginHash, /^[0-9a-f]{64}$/);
  assert.notEqual(loginHash, value);
  assert.notEqual(loginHash, hashAbuseKey("register_ip", value, pepper));
  assert.notEqual(loginHash, hashAbuseKey("login_ip", value, "s".repeat(32)));
  assert.throws(() => hashAbuseKey("INVALID SCOPE", value, pepper), /invalid_abuse_key/);
  assert.throws(() => hashAbuseKey("login_ip", "", pepper), /invalid_abuse_key/);
});

test("vault envelope rejects unversioned and oversized values", () => {
  const valid = { baseRevision: 0, envelopeVersion: 1, ciphertext: "AA", nonce: "BB", authTag: "CC", contentHash: "DD" };
  assert.equal(validateVaultEnvelope(valid), valid);
  assert.throws(() => validateVaultEnvelope({ ...valid, baseRevision: -1 }), /invalid_base_revision/);
  assert.throws(() => validateVaultEnvelope({ ...valid, nonce: "x".repeat(129) }), /invalid_vault_envelope/);
});
