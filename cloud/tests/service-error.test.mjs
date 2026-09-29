import assert from "node:assert/strict";
import test from "node:test";
import { publicOperationError } from "../src/service-error.mjs";

test("known operation errors map to stable public responses", () => {
  assert.deepEqual(publicOperationError(new Error("invalid_wrapped_key")), {
    status: 400,
    code: "invalid_wrapped_key",
  });
  assert.deepEqual(publicOperationError(new Error("rate_limited")), {
    status: 429,
    code: "rate_limited",
  });
  assert.deepEqual(publicOperationError(new Error("team_name_mismatch")), {
    status: 409,
    code: "team_name_mismatch",
  });
  assert.deepEqual(publicOperationError(new Error("invalid_team_device_admission_policy")), {
    status: 400,
    code: "invalid_team_device_admission_policy",
  });
  assert.deepEqual(publicOperationError(new Error("team_invitation_not_ready")), {
    status: 409,
    code: "team_invitation_not_ready",
  });
  assert.equal(publicOperationError(new Error("email_exists")), null);
});

test("internal database errors are never exposed as public codes", () => {
  assert.equal(publicOperationError(new Error("relation account_identities does not exist")), null);
  assert.equal(publicOperationError(Object.assign(new Error("duplicate key value"), { code: "23505" })), null);
});

test("a known browser device collision is a bounded retryable conflict", () => {
  assert.deepEqual(publicOperationError(new Error("device_conflict")), {
    status: 409,
    code: "device_conflict",
  });
});

test("access policy failures expose typed bounded responses", () => {
  for (const [code, status] of [
    ["invalid_access_request", 400], ["credential_edit_requires_reveal", 400],
    ["access_preview_conflict", 409], ["access_policy_conflict", 409],
    ["group_grants_must_be_revoked_first", 409], ["access_batch_too_large", 413],
    ["access_v2_preparing_required", 409],
  ]) {
    assert.deepEqual(publicOperationError(new Error(code)), { status, code });
  }
});
