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
  }
  async createUser(input) {
    this.identity = { id: "user-1", email: input.email, display_name: input.displayName, created_at: new Date(), password_hash: input.passwordHash };
    this.sessions.set(input.sessionHash, { session_id: "session-1", user_id: "user-1", device_id: input.device.id, email: input.email, display_name: input.displayName });
    return this.identity;
  }
  async passwordIdentity(email) { return this.identity?.email === email ? this.identity : null; }
  async createSession(input) { this.sessions.set(input.sessionHash, { session_id: "session-2", user_id: input.userID, device_id: input.device.id, email: this.identity.email, display_name: this.identity.display_name }); }
  async session(hash) { return this.sessions.get(hash) ?? null; }
  async consumeEmailVerificationToken(hash) {
    this.lastVerificationHash = hash;
    if (!this.verificationAvailable) return null;
    this.verificationAvailable = false;
    return { id: "user-1" };
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
};
const device = { id: "84f6c860-0d26-4ef5-8652-27cb8b991b70", name: "Test Mac", platform: "macOS", appVersion: "0.32.0" };

test("registration and login issue opaque sessions", async () => {
  const store = new MemoryStore();
  const service = new CloudService(store, config);
  const registered = await service.register({ email: "user@example.com", password: "correct horse battery", displayName: "User", device });
  assert.equal(registered.user.email, "user@example.com");
  assert.ok(registered.token.length >= 40);
  assert.equal((await service.authenticate(registered.token)).user_id, "user-1");
  const loggedIn = await service.login({ email: "user@example.com", password: "correct horse battery", device });
  assert.notEqual(loggedIn.token, registered.token);
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
