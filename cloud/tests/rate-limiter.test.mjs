import assert from "node:assert/strict";
import test from "node:test";
import { AuthRateLimiter } from "../src/rate-limiter.mjs";

const config = {
  abuseTokenPepper: "a".repeat(32),
  authRateLimits: { login_ip: { limit: 20, windowSeconds: 300 } },
};

test("auth limiter sends only a scoped HMAC key to storage", async () => {
  let consumed;
  const limiter = new AuthRateLimiter({
    async consumeRateLimit(value) { consumed = value; return { allowed: true, retryAfterSeconds: 300 }; },
  }, config);

  await limiter.require("login_ip", "203.0.113.42");
  assert.equal(consumed.scope, "login_ip");
  assert.match(consumed.keyHash, /^[0-9a-f]{64}$/);
  assert.notEqual(consumed.keyHash, "203.0.113.42");
  assert.equal(JSON.stringify(consumed).includes("203.0.113.42"), false);
  assert.equal(consumed.limit, 20);
  assert.equal(consumed.windowSeconds, 300);
});

test("auth limiter fails closed with a bounded retry delay", async () => {
  const limiter = new AuthRateLimiter({
    async consumeRateLimit() { return { allowed: false, retryAfterSeconds: 47 }; },
  }, config);

  await assert.rejects(
    limiter.require("login_ip", "203.0.113.42"),
    (error) => error.message === "rate_limited" && error.retryAfterSeconds === 47,
  );
  await assert.rejects(limiter.require("unknown_scope", "203.0.113.42"), /invalid_rate_limit_policy/);
});

test("auth limiter propagates storage failures instead of allowing the request", async () => {
  const failure = new Error("database_unavailable");
  const limiter = new AuthRateLimiter({
    async consumeRateLimit() { throw failure; },
  }, config);
  await assert.rejects(limiter.require("login_ip", "203.0.113.42"), failure);
});
