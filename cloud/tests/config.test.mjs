import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { loadConfig, validateProxySecret, validateSecret } from "../src/config.mjs";

const baseEnv = {
  DATABASE_URL: "postgres://example.invalid/selective_remote",
  SESSION_TOKEN_PEPPER: "s".repeat(32),
  EMAIL_VERIFICATION_TOKEN_PEPPER: "e".repeat(32),
  PASSWORD_RESET_TOKEN_PEPPER: "p".repeat(32),
  TEAM_INVITATION_TOKEN_PEPPER: "t".repeat(32),
  TEAM_OUTBOX_ENCRYPTION_KEY: "o".repeat(32),
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

test("password reset uses an independent bounded token lifetime", () => {
  assert.equal(loadConfig(baseEnv).passwordResetTTLHours, 1);
  assert.equal(loadConfig(baseEnv).recoveryMinimumResponseMS, 500);
  assert.throws(() => loadConfig({ ...baseEnv, PASSWORD_RESET_TTL_HOURS: "25" }), /PASSWORD_RESET_TTL_HOURS/);
  assert.throws(() => loadConfig({ ...baseEnv, AUTH_RECOVERY_MIN_RESPONSE_MS: "249" }), /AUTH_RECOVERY_MIN_RESPONSE_MS/);
});

test("Team invitations use fixed 48-hour expiry and independent secrets", () => {
  const config = loadConfig(baseEnv);
  assert.equal(config.teamInvitationTTLHours, 48);
  assert.equal(config.teamInvitationTokenPepper, "t".repeat(32));
  assert.equal(config.teamOutboxEncryptionKey, "o".repeat(32));
  assert.throws(
    () => loadConfig({ ...baseEnv, TEAM_OUTBOX_ENCRYPTION_KEY: baseEnv.TEAM_INVITATION_TOKEN_PEPPER }),
    /security secrets must be independent/,
  );
  const { TEAM_INVITATION_TOKEN_PEPPER: _missingInvitation, ...withoutInvitation } = baseEnv;
  const { TEAM_OUTBOX_ENCRYPTION_KEY: _missingOutbox, ...withoutOutbox } = baseEnv;
  assert.throws(() => loadConfig(withoutInvitation), /TEAM_INVITATION_TOKEN_PEPPER/);
  assert.throws(() => loadConfig(withoutOutbox), /TEAM_OUTBOX_ENCRYPTION_KEY/);
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
  assert.deepEqual(config.authRateLimits.resend_verification_email, { limit: 3, windowSeconds: 3_600 });
  assert.deepEqual(config.authRateLimits.request_password_reset_ip, { limit: 5, windowSeconds: 3_600 });
  assert.deepEqual(config.authRateLimits.request_password_reset_email, { limit: 3, windowSeconds: 3_600 });
  assert.deepEqual(config.authRateLimits.reset_password_ip, { limit: 10, windowSeconds: 900 });
  assert.deepEqual(config.authRateLimits.team_invitation_create_user, { limit: 50, windowSeconds: 3_600 });
  assert.deepEqual(config.authRateLimits.team_invitation_accept_ip, { limit: 20, windowSeconds: 3_600 });
  assert.throws(
    () => loadConfig({ ...baseEnv, AUTH_PASSWORD_RESET_REQUEST_IP_LIMIT: "0" }),
    /AUTH_PASSWORD_RESET_REQUEST_IP_LIMIT/,
  );
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

test("example environment leaves optional SMTP disabled for closed staging", async () => {
  const example = await readFile(fileURLToPath(new URL("../.env.example", import.meta.url)), "utf8");
  for (const name of ["SMTP_HOST", "SMTP_PORT", "SMTP_SECURE", "SMTP_USER", "SMTP_PASSWORD", "SMTP_FROM"]) {
    assert.doesNotMatch(example, new RegExp(`^${name}=`, "m"));
    assert.match(example, new RegExp(`^# ${name}=`, "m"));
  }
  assert.match(example, /^ALLOW_REGISTRATION=false$/m);
});

test("Git ignores runtime environment files but preserves the example", async () => {
  const repositoryRoot = fileURLToPath(new URL("../../", import.meta.url));
  const ignore = await readFile(new URL("../../.gitignore", import.meta.url), "utf8");
  assert.match(ignore, /^\.env$/m);
  assert.match(ignore, /^\.env\.\*$/m);
  assert.match(ignore, /^!\.env\.example$/m);

  for (const path of ["cloud/.env", "cloud/.env.tmp.example"]) {
    const result = spawnSync("git", ["check-ignore", "--no-index", "-q", path], {
      cwd: repositoryRoot,
      encoding: "utf8",
    });
    assert.equal(result.status, 0, `${path}: ${result.stderr}`);
  }

  const example = spawnSync(
    "git",
    ["check-ignore", "--no-index", "-q", "cloud/.env.example"],
    { cwd: repositoryRoot, encoding: "utf8" },
  );
  assert.equal(example.status, 1, example.stderr);
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
