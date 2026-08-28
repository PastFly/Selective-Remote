import assert from "node:assert/strict";
import test from "node:test";
import { loadConfig, validateProxySecret, validateSecret } from "../src/config.mjs";

const baseEnv = {
  DATABASE_URL: "postgres://example.invalid/selective_remote",
  SESSION_TOKEN_PEPPER: "s".repeat(32),
  EMAIL_VERIFICATION_TOKEN_PEPPER: "e".repeat(32),
  ABUSE_TOKEN_PEPPER: "a".repeat(32),
  PROXY_SHARED_SECRET: "b".repeat(64),
};

test("runtime secrets reject placeholders and short values", () => {
  assert.throws(() => validateSecret("TEST_SECRET", "short"), /at least 32 random bytes/);
  assert.throws(
    () => validateSecret("TEST_SECRET", "replace-with-at-least-32-random-bytes"),
    /at least 32 random bytes/,
  );
  assert.equal(validateSecret("TEST_SECRET", "x".repeat(32)), "x".repeat(32));
  assert.equal(validateSecret("OPTIONAL_SECRET", undefined, false), null);
});

test("proxy trust requires a header-safe independent hexadecimal secret", () => {
  assert.equal(validateProxySecret("a".repeat(64)), "a".repeat(64));
  assert.throws(() => validateProxySecret("A".repeat(64)), /64 lowercase hexadecimal/);
  assert.throws(() => validateProxySecret("a".repeat(63)), /64 lowercase hexadecimal/);
});

test("rate-limit overrides reject partial and out-of-range numbers", () => {
  assert.throws(() => loadConfig({ ...baseEnv, AUTH_LOGIN_IP_LIMIT: "30requests" }), /AUTH_LOGIN_IP_LIMIT/);
  assert.throws(() => loadConfig({ ...baseEnv, AUTH_REGISTER_IP_LIMIT: "0" }), /AUTH_REGISTER_IP_LIMIT/);
  const config = loadConfig({ ...baseEnv, AUTH_LOGIN_IP_LIMIT: "40" });
  assert.deepEqual(config.authRateLimits.login_ip, { limit: 40, windowSeconds: 300 });
});

test("runtime security secrets cannot be reused across purposes", () => {
  assert.throws(
    () => loadConfig({ ...baseEnv, ABUSE_TOKEN_PEPPER: baseEnv.SESSION_TOKEN_PEPPER }),
    /security secrets must be independent/,
  );
});

test("registration stays usable only with complete secure mail configuration", () => {
  assert.equal(loadConfig(baseEnv).smtp, null);
  assert.throws(
    () => loadConfig({ ...baseEnv, ALLOW_REGISTRATION: "true" }),
    /SMTP_HOST is required/,
  );

  const config = loadConfig({
    ...baseEnv,
    ALLOW_REGISTRATION: "true",
    SMTP_HOST: "smtp.example.com",
    SMTP_PORT: "587",
    SMTP_SECURE: "false",
    SMTP_USER: "mailer@example.com",
    SMTP_PASSWORD: "m".repeat(24),
    SMTP_FROM: "no-reply@example.com",
  });
  assert.deepEqual(config.smtp, {
    host: "smtp.example.com",
    port: 587,
    secure: false,
    user: "mailer@example.com",
    password: "m".repeat(24),
    from: "no-reply@example.com",
  });
});

test("verification pepper remains mandatory while registration is disabled", () => {
  const { EMAIL_VERIFICATION_TOKEN_PEPPER: _removed, ...missingPepper } = baseEnv;
  assert.throws(() => loadConfig(missingPepper), /EMAIL_VERIFICATION_TOKEN_PEPPER/);
});

test("mail configuration rejects placeholders and insecurely short credentials", () => {
  assert.throws(
    () => loadConfig({ ...baseEnv, SMTP_HOST: "smtp://example.com" }),
    /SMTP_HOST must be a hostname or IP address/,
  );
  assert.throws(
    () => loadConfig({
      ...baseEnv,
      SMTP_HOST: "smtp.example.com",
      SMTP_USER: "mailer@example.com",
      SMTP_PASSWORD: "short",
      SMTP_FROM: "no-reply@example.com",
    }),
    /SMTP_PASSWORD must contain at least 16 characters/,
  );
});
