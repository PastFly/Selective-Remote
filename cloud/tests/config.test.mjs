import assert from "node:assert/strict";
import test from "node:test";
import { validateSecret } from "../src/config.mjs";

test("runtime secrets reject placeholders and short values", () => {
  assert.throws(() => validateSecret("TEST_SECRET", "short"), /at least 32 random bytes/);
  assert.throws(
    () => validateSecret("TEST_SECRET", "replace-with-at-least-32-random-bytes"),
    /at least 32 random bytes/,
  );
  assert.equal(validateSecret("TEST_SECRET", "x".repeat(32)), "x".repeat(32));
  assert.equal(validateSecret("OPTIONAL_SECRET", undefined, false), null);
});
