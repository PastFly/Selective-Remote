import assert from "node:assert/strict";
import test from "node:test";
import { consumeVerificationFragment, submitEmailVerification } from "../public/app.js";

test("verification token is consumed from the fragment and immediately removed from browser history", () => {
  const replacements = [];
  const result = consumeVerificationFragment(
    { hash: "#verify-email?token=opaque-token", pathname: "/", search: "?source=email" },
    { replaceState(...values) { replacements.push(values); } },
  );

  assert.deepEqual(result, { present: true, token: "opaque-token" });
  assert.deepEqual(replacements, [[null, "", "/?source=email"]]);
  assert.equal(JSON.stringify(replacements).includes("opaque-token"), false);
});

test("unrelated and malformed fragments are never submitted as verification tokens", () => {
  const history = { replaceState() {} };
  assert.deepEqual(
    consumeVerificationFragment({ hash: "#features", pathname: "/", search: "" }, history),
    { present: false, token: null },
  );
  assert.deepEqual(
    consumeVerificationFragment({ hash: "#verify-email?token=", pathname: "/", search: "" }, history),
    { present: true, token: null },
  );
  assert.deepEqual(
    consumeVerificationFragment({ hash: `#verify-email?token=${"x".repeat(257)}`, pathname: "/", search: "" }, history),
    { present: true, token: null },
  );
});

test("browser submits the token only in a no-store JSON request", async () => {
  let request;
  await submitEmailVerification("opaque-token", async (...values) => {
    request = values;
    return { ok: true, async json() { return { verified: true }; } };
  });

  assert.equal(request[0], "/v1/auth/verify-email");
  assert.deepEqual(request[1], {
    method: "POST",
    headers: { Accept: "application/json", "Content-Type": "application/json" },
    body: JSON.stringify({ token: "opaque-token" }),
    cache: "no-store",
    credentials: "omit",
    referrerPolicy: "no-referrer",
  });
});

test("browser maps every rejected verification response to one local error", async () => {
  await assert.rejects(
    submitEmailVerification("opaque-token", async () => ({ ok: false })),
    (error) => error.message === "invalid_verification_token",
  );
  await assert.rejects(
    submitEmailVerification("opaque-token", async () => ({ ok: true, async json() { return {}; } })),
    (error) => error.message === "invalid_verification_token",
  );
});
