import assert from "node:assert/strict";
import test from "node:test";
import { publicOperationError } from "../src/service-error.mjs";

test("known operation errors map to stable public responses", () => {
  assert.deepEqual(publicOperationError(new Error("invalid_wrapped_key")), {
    status: 400,
    code: "invalid_wrapped_key",
  });
  assert.deepEqual(publicOperationError(new Error("email_exists")), {
    status: 409,
    code: "email_exists",
  });
});

test("internal database errors are never exposed as public codes", () => {
  assert.equal(publicOperationError(new Error("relation account_identities does not exist")), null);
  assert.equal(publicOperationError(Object.assign(new Error("duplicate key value"), { code: "23505" })), null);
});
