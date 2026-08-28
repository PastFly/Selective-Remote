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
  assert.equal(validateSecret("OPTIONAL_SECRET", undefined, false), null);
});

test("registration stays usable only with complete secure mail configuration", () => {
  assert.equal(loadConfig(baseEnv).smtp, null);
  assert.throws(
    () => loadConfig({ ...baseEnv, ALLOW_REGISTRATION: "true", EMAIL_VERIFICATION_TOKEN_PEPPER: "e".repeat(32) }),
    /SMTP_HOST is required/,
  );

  const config = loadConfig({
    ...baseEnv,
    ALLOW_REGISTRATION: "true",
    EMAIL_VERIFICATION_TOKEN_PEPPER: "e".repeat(32),
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
