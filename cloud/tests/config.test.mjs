import assert from "node:assert/strict";
import test from "node:test";
import { loadConfig, validateSecret } from "../src/config.mjs";

const baseEnv = {
  DATABASE_URL: "postgres://example.invalid/selective_remote",
  SESSION_TOKEN_PEPPER: "s".repeat(32),
};

test("runtime secrets reject placeholders and short values", () => {
  assert.throws(() => validateSecret("TEST_SECRET", "short"), /at least 32 random bytes/);
  assert.throws(
    () => validateSecret("TEST_SECRET", "replace-with-at-least-32-random-bytes"),
    /at least 32 random bytes/,
  );
  assert.equal(validateSecret("TEST_SECRET", "x".repeat(32)), "x".repeat(32));
});

test("configuration rejects placeholder database values and partial numbers", () => {
  assert.throws(
    () => loadConfig({ ...baseEnv, DATABASE_URL: "postgres://user:replace-me@postgres/db" }),
    /DATABASE_URL/,
  );
  assert.throws(() => loadConfig({ ...baseEnv, CLOUD_PORT: "8080oops" }), /CLOUD_PORT/);
  assert.throws(() => loadConfig({ ...baseEnv, SESSION_TTL_DAYS: "30days" }), /SESSION_TTL_DAYS/);
});

test("public origin is an origin and production requires HTTPS", () => {
  assert.equal(loadConfig(baseEnv).publicOrigin, "http://localhost:8080");
  assert.throws(
    () => loadConfig({ ...baseEnv, CLOUD_PUBLIC_ORIGIN: "https://user@example.com/path" }),
    /must be an origin/,
  );
  assert.throws(
    () => loadConfig({ ...baseEnv, NODE_ENV: "production", CLOUD_PUBLIC_ORIGIN: "http://cloud.example.com" }),
    /must use HTTPS/,
  );
});
