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
  teamVaultWrapperContextHash,
  validateDevicePublicKey,
  validateTeamVaultEnvelope,
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

test("Team device keys are canonical public-only P-256 JWKs", () => {
  const key = { kty: "EC", crv: "P-256", x: "A".repeat(43), y: "B".repeat(43) };
  assert.deepEqual(JSON.parse(validateDevicePublicKey(key)), {
    ...key,
    ext: true,
    key_ops: [],
  });
  assert.throws(() => validateDevicePublicKey({ ...key, d: "private" }), /invalid_device_public_key/);
  assert.throws(() => validateDevicePublicKey({ ...key, crv: "P-384" }), /invalid_device_public_key/);
});

test("Team Vault envelopes bind one unique wrapper to membership epoch and device", () => {
  const wrapper = {
    membershipID: "7026d8a4-116a-4f61-9d8e-ff04e3a73360",
    membershipEpoch: 3,
    deviceID: "1f386e3d-d7b7-4365-a116-19f68e7f512d",
    wrapperVersion: 1,
    ephemeralPublicKey: { kty: "EC", crv: "P-256", x: "E".repeat(43), y: "F".repeat(43) },
    ciphertext: "G".repeat(43),
    nonce: "H".repeat(16),
    authTag: "I".repeat(22),
    contextHash: "J".repeat(43),
  };
  const envelope = {
    baseRevision: 0,
    keyGeneration: 1,
    envelopeVersion: 1,
    ciphertext: "AA",
    nonce: "B".repeat(16),
    authTag: "C".repeat(22),
    contentHash: "D".repeat(43),
    wrappers: [wrapper],
  };
  const validated = validateTeamVaultEnvelope(envelope);
  assert.equal(validated.wrappers[0].membershipEpoch, 3);
  assert.equal(validated.wrappers[0].ephemeralPublicKey.ext, true);
  assert.throws(
    () => validateTeamVaultEnvelope({ ...envelope, wrappers: [wrapper, { ...wrapper }] }),
    /invalid_team_vault_wrappers/,
  );
  assert.throws(
    () => validateTeamVaultEnvelope({ ...envelope, keyGeneration: 0 }),
    /invalid_key_generation/,
  );
});

test("Team wrapper context changes across every authorization boundary", () => {
  const input = {
    teamID: "84f6c860-0d26-4ef5-8652-27cb8b991b70",
    vaultID: "bc01823b-1401-4058-9488-f4f6d1839b3b",
    keyGeneration: 2,
    membershipID: "7026d8a4-116a-4f61-9d8e-ff04e3a73360",
    membershipEpoch: 3,
    deviceID: "33cc880e-084a-4d9a-b1ea-f99d2ff86032",
  };
  const expected = teamVaultWrapperContextHash(input);
  assert.match(expected, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(expected, teamVaultWrapperContextHash({ ...input, keyGeneration: 3 }));
  assert.notEqual(expected, teamVaultWrapperContextHash({ ...input, membershipEpoch: 4 }));
  assert.notEqual(expected, teamVaultWrapperContextHash({
    ...input,
    vaultID: "e6087707-d527-4028-a47c-5cd49080b781",
  }));
});
