import assert from "node:assert/strict";
import test from "node:test";
import { browserSessionBinding } from "../src/browser-session-binding.mjs";

const sessionID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const other = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const cookie = { sessionID, cookie: "opaque", bearer: null, method: "PUT", path: "/v1/vault" };

test("cookie mutations and reads require the authenticated session binding", () => {
  for (const method of ["GET", "PUT", "POST", "DELETE"]) {
    assert.equal(browserSessionBinding({ ...cookie, method, supplied: sessionID }).allowed, true);
    assert.equal(browserSessionBinding({ ...cookie, method, supplied: other }).allowed, false);
    assert.equal(browserSessionBinding({ ...cookie, method }).allowed, false);
  }
});

test("only initial identity discovery accepts an unbound cookie; bearer clients remain compatible", () => {
  assert.deepEqual(browserSessionBinding({ ...cookie, method: "GET", path: "/v1/me" }), { allowed: true, binding: sessionID });
  assert.equal(browserSessionBinding({ ...cookie, method: "GET", path: "/v1/me", supplied: other }).allowed, false);
  assert.equal(browserSessionBinding({ ...cookie, bearer: "opaque", supplied: other }).allowed, true);
  assert.equal(browserSessionBinding({ ...cookie, bearer: "opaque", sessionID: "invalid" }).allowed, false);
});
