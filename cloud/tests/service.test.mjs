import assert from "node:assert/strict";
import test from "node:test";
import { CloudService } from "../src/service.mjs";

class MemoryStore {
  constructor() {
    this.identity = null;
    this.sessions = new Map();
    this.revision = 0;
    this.verificationAvailable = true;
    this.lastVerificationHash = null;
    this.lastVerificationExpiry = null;
    this.replacementVerificationHash = null;
  }
  async createUser(input) {
    this.lastVerificationHash = input.verificationHash;
    this.lastVerificationExpiry = input.verificationExpiresAt;
    this.identity = {
      id: "user-1",
      email: input.email,
      display_name: input.displayName,
      created_at: new Date(),
      password_hash: input.passwordHash,
      email_verified_at: null,
    };
    return this.identity;
  }
  async passwordIdentity(email) { return this.identity?.email === email ? this.identity : null; }
  async createSession(input) { this.sessions.set(input.sessionHash, { session_id: "session-2", user_id: input.userID, device_id: input.device.id, email: this.identity.email, display_name: this.identity.display_name }); }
  async session(hash) { return this.sessions.get(hash) ?? null; }
  async consumeEmailVerificationToken(hash) {
    this.lastVerificationHash = hash;
    if (!this.verificationAvailable) return null;
    this.verificationAvailable = false;
    if (this.identity) this.identity.email_verified_at = new Date();
    return { id: "user-1" };
  }
  async replaceEmailVerificationToken(input) {
    this.replacementVerificationHash = input.tokenHash;
    this.lastVerificationExpiry = input.expiresAt;
    return true;
  }
  async getVault() { return { id: "vault-1", revision: this.revision, envelope_version: 1, wrapped_key: null, ciphertext: null, nonce: null, auth_tag: null, content_hash: null, updated_at: new Date() }; }
  async putVault(_userID, _deviceID, envelope) {
    if (envelope.baseRevision !== this.revision) return { conflict: true, revision: this.revision };
    this.revision += 1;
    return { conflict: false, revision: this.revision };
  }
}

const config = {
  allowRegistration: true,
  sessionPepper: "p".repeat(32),
  emailVerificationPepper: "v".repeat(32),
  sessionTTLDays: 30,
  emailVerificationTTLHours: 24,
};
const device = { id: "84f6c860-0d26-4ef5-8652-27cb8b991b70", name: "Test Mac", platform: "macOS", appVersion: "0.32.0" };

test("registration sends an opaque verification token and issues no session", async () => {
  const store = new MemoryStore();
  let delivery;
  const mailer = { async sendEmailVerification(value) { delivery = value; } };
  const service = new CloudService(store, config, mailer);
  const registered = await service.register({ email: "user@example.com", password: "correct horse battery", displayName: "User", device });
  assert.equal(registered.user.email, "user@example.com");
  assert.equal(registered.verificationRequired, true);
  assert.equal("token" in registered, false);
  assert.equal(delivery.recipient, "user@example.com");
  assert.ok(delivery.token.length >= 40);
  assert.match(store.lastVerificationHash, /^[0-9a-f]{64}$/);
  assert.notEqual(store.lastVerificationHash, delivery.token);
  assert.ok(store.lastVerificationExpiry > new Date());
  assert.equal(store.sessions.size, 0);
  await assert.rejects(
    service.login({ email: "user@example.com", password: "correct horse battery", device }),
    /email_not_verified/,
  );

  await service.verifyEmail({ token: delivery.token });
  const loggedIn = await service.login({ email: "user@example.com", password: "correct horse battery", device });
  assert.ok(loggedIn.token.length >= 40);
  assert.equal((await service.authenticate(loggedIn.token)).user_id, "user-1");
});

test("vault writes use optimistic revisions", async () => {
  const store = new MemoryStore();
  const service = new CloudService(store, config);
  const session = { user_id: "user-1", device_id: device.id };
  const body = { baseRevision: 0, envelopeVersion: 1, ciphertext: "AA", nonce: "BB", authTag: "CC", contentHash: "DD" };
  assert.deepEqual(await service.putVault(session, body), { conflict: false, revision: 1 });
  assert.deepEqual(await service.putVault(session, body), { conflict: true, revision: 1 });
});

test("registration can be disabled until SMTP is configured", async () => {
  const service = new CloudService(new MemoryStore(), { ...config, allowRegistration: false });
  await assert.rejects(service.register({ email: "user@example.com", password: "correct horse battery", device }), /registration_disabled/);
});

test("registration fails closed when SMTP delivery is unavailable", async () => {
  const service = new CloudService(new MemoryStore(), config);
  await assert.rejects(
    service.register({ email: "user@example.com", password: "correct horse battery", device }),
    /smtp_not_configured/,
  );
});

test("mail transport errors do not expose provider details", async () => {
  const mailer = { async sendEmailVerification() { throw new Error("provider-secret-response"); } };
  const warnings = [];
  const service = new CloudService(new MemoryStore(), config, mailer, { warn(value) { warnings.push(value); } });
  await assert.rejects(
    service.register({ email: "user@example.com", password: "correct horse battery", device }),
    (error) => error.message === "email_delivery_failed",
  );
  assert.equal(warnings.length, 1);
  assert.equal(warnings[0].includes("provider-secret-response"), false);
  assert.equal(warnings[0].includes("user@example.com"), false);
});

test("verification resend rotates the hash and always returns an accepted response", async () => {
  const store = new MemoryStore();
  store.identity = {
    id: "user-1",
    email: "user@example.com",
    password_hash: "unused",
    email_verified_at: null,
    disabled_at: null,
  };
  let delivery;
  const service = new CloudService(store, config, {
    async sendEmailVerification(value) { delivery = value; },
  });

  assert.deepEqual(await service.resendEmailVerification({ email: "USER@example.com" }), { accepted: true });
  assert.equal(delivery.recipient, "user@example.com");
  assert.ok(delivery.token.length >= 40);
  assert.match(store.replacementVerificationHash, /^[0-9a-f]{64}$/);
  assert.notEqual(store.replacementVerificationHash, delivery.token);
  assert.ok(store.lastVerificationExpiry > new Date());

  const unknownStore = new MemoryStore();
  let unknownDelivered = false;
  const unknownService = new CloudService(unknownStore, config, {
    async sendEmailVerification() { unknownDelivered = true; },
  });
  assert.deepEqual(await unknownService.resendEmailVerification({ email: "unknown@example.com" }), { accepted: true });
  assert.equal(unknownDelivered, false);

  unknownStore.identity = {
    id: "user-2",
    email: "verified@example.com",
    password_hash: "unused",
    email_verified_at: new Date(),
    disabled_at: null,
  };
  assert.deepEqual(await unknownService.resendEmailVerification({ email: "verified@example.com" }), { accepted: true });
  assert.equal(unknownDelivered, false);
});

test("verification resend hides mail provider failures", async () => {
  const store = new MemoryStore();
  store.identity = {
    id: "user-1",
    email: "user@example.com",
    password_hash: "unused",
    email_verified_at: null,
    disabled_at: null,
  };
  const warnings = [];
  const service = new CloudService(store, config, {
    async sendEmailVerification() { throw new Error("private-provider-detail"); },
  }, { warn(value) { warnings.push(value); } });

  assert.deepEqual(await service.resendEmailVerification({ email: "user@example.com" }), { accepted: true });
  assert.equal(warnings.length, 1);
  assert.equal(warnings[0].includes("private-provider-detail"), false);
  assert.equal(warnings[0].includes("user@example.com"), false);
});

test("email verification consumes an HMAC hash exactly once", async () => {
  const store = new MemoryStore();
  const service = new CloudService(store, config);
  const token = "opaque-email-verification-token-value";

  assert.deepEqual(await service.verifyEmail({ token }), { verified: true });
  assert.match(store.lastVerificationHash, /^[0-9a-f]{64}$/);
  assert.notEqual(store.lastVerificationHash, token);
  await assert.rejects(service.verifyEmail({ token }), /invalid_verification_token/);
  await assert.rejects(service.verifyEmail({ token: "" }), /invalid_verification_token/);
});
