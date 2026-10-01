import test from "node:test";
import assert from "node:assert/strict";
import { CloudService } from "../src/service.mjs";
import { hashPassword, verifyPassword } from "../src/security.mjs";
import { publicOperationError } from "../src/service-error.mjs";

const oldPassword = "synthetic old account password", newPassword = "synthetic new account password";
const passwordHash = await hashPassword(oldPassword);
const userID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", sessionID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const session = { user_id: userID, session_id: sessionID, email: "synthetic@invalid.invalid" };
function fixture(revision = 0) {
  const state = { passwordHash, sessionRevocations: 0, passwordWrites: 0, revision };
  const store = {
    passwordIdentity: async () => ({ id: userID, password_hash: state.passwordHash, disabled_at: null }),
    changePassword: async (uid, sid, nextHash) => {
      assert.equal(uid, userID); assert.equal(sid, sessionID);
      state.passwordHash = nextHash; state.passwordWrites++; state.sessionRevocations++;
      return { changed: true };
    },
    getVault: async () => ({ revision: state.revision, wrapped_key: state.revision ? { algorithm: "PBKDF2-SHA256+A256KW", iterations: 600000, salt: "synthetic", value: "synthetic" } : null }),
  };
  return { state, store, service: new CloudService(store, {}) };
}

// Both initialization states must be blocked; a row lock cannot protect a later first upload.
test("password change is blocked for both initialized and uninitialized Personal Vaults", async () => {
  for (const revision of [1, 0]) {
    const f = fixture(revision), order = revision ? "upload-first" : "password-first";
    await assert.rejects(f.service.changePassword(session, { currentPassword: oldPassword, newPassword }), { message: "personal_vault_rewrap_required" }, order);
    assert.equal(f.state.passwordHash, passwordHash, order);
    assert.equal(f.state.passwordWrites, 0, order);
    assert.equal(f.state.sessionRevocations, 0, order);
    assert.equal(await verifyPassword(oldPassword, f.state.passwordHash), true, order);
    assert.equal(await verifyPassword(newPassword, f.state.passwordHash), false, order);
  }
});

test("the preservation guard retains current-password authentication and new-password validation", async () => {
  const f = fixture();
  await assert.rejects(f.service.changePassword(session, { currentPassword: "synthetic incorrect password", newPassword }), { message: "invalid_credentials" });
  await assert.rejects(f.service.changePassword(session, { currentPassword: oldPassword, newPassword: "short" }), { message: "invalid_password" });
  assert.equal(f.state.passwordWrites, 0);
  assert.equal(f.state.sessionRevocations, 0);
});

test("the preservation guard is exposed as a typed conflict rather than an internal server failure", () => {
  assert.deepEqual(publicOperationError(new Error("personal_vault_rewrap_required")), { status: 409, code: "personal_vault_rewrap_required" });
});
