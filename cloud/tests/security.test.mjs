import assert from "node:assert/strict";
import test from "node:test";
import { hashPassword, hashSessionToken, normalizeEmail, validateVaultEnvelope, verifyPassword } from "../src/security.mjs";

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

test("vault envelope rejects unversioned and oversized values", () => {
  const valid = {
    baseRevision: 0,
    envelopeVersion: 1,
    wrappedKey: { algorithm: "test", value: "EE" },
    ciphertext: "AA",
    nonce: "B".repeat(16),
    authTag: "C".repeat(22),
    contentHash: "D".repeat(43),
  };
  assert.deepEqual(validateVaultEnvelope(valid), valid);
  assert.throws(() => validateVaultEnvelope({ ...valid, baseRevision: -1 }), /invalid_base_revision/);
  assert.throws(() => validateVaultEnvelope({ ...valid, baseRevision: Number.MAX_SAFE_INTEGER + 1 }), /invalid_base_revision/);
  assert.throws(() => validateVaultEnvelope({ ...valid, wrappedKey: null }), /invalid_wrapped_key/);
  assert.throws(() => validateVaultEnvelope({ ...valid, wrappedKey: {} }), /invalid_wrapped_key/);
  assert.throws(() => validateVaultEnvelope({ ...valid, ciphertext: "not base64" }), /invalid_vault_envelope/);
  assert.throws(() => validateVaultEnvelope({ ...valid, nonce: "x".repeat(15) }), /invalid_vault_envelope/);
  assert.throws(() => validateVaultEnvelope({ ...valid, envelopeVersion: 2 }), /invalid_envelope_version/);
});
