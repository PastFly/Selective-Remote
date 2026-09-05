import assert from "node:assert/strict";
import test from "node:test";
import {
  createEmailVerificationToken,
  createPasswordResetToken,
  createTeamInvitationToken,
  decryptOutboxPayload,
  encryptOutboxPayload,
  hashAbuseKey,
  hashPasswordResetToken,
  hashEmailVerificationToken,
  hashPassword,
  hashSessionToken,
  hashTeamInvitationToken,
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

test("password reset tokens are opaque and use a dedicated HMAC", () => {
  const token = createPasswordResetToken();
  const pepper = "p".repeat(32);
  const hash = hashPasswordResetToken(token, pepper);

  assert.ok(token.length >= 40);
  assert.match(hash, /^[0-9a-f]{64}$/);
  assert.notEqual(hash, token);
  assert.notEqual(hash, hashPasswordResetToken(token, "q".repeat(32)));
  assert.throws(() => hashPasswordResetToken("", pepper), /invalid_password_reset_token/);
});

test("Team invitation tokens are hash-only and outbox payloads are authenticated ciphertext", () => {
  const token = createTeamInvitationToken();
  const tokenPepper = "t".repeat(32);
  const outboxKey = "o".repeat(32);
  const payload = {
    recipient: "member@example.com",
    token,
    teamID: "84f6c860-0d26-4ef5-8652-27cb8b991b70",
    role: "editor",
  };
  const tokenHash = hashTeamInvitationToken(token, tokenPepper);
  const envelope = encryptOutboxPayload(payload, outboxKey);

  assert.match(tokenHash, /^[0-9a-f]{64}$/);
  assert.notEqual(tokenHash, token);
  assert.doesNotMatch(JSON.stringify(envelope), /member@example\.com|editor/);
  assert.deepEqual(decryptOutboxPayload(envelope, outboxKey), payload);
  assert.throws(
    () => decryptOutboxPayload({ ...envelope, authTag: "A".repeat(22) }, outboxKey),
    /invalid_outbox_payload/,
  );
  assert.throws(() => hashTeamInvitationToken("", tokenPepper), /invalid_team_invitation/);
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
