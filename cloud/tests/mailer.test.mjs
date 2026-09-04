import assert from "node:assert/strict";
import test from "node:test";
import { createVerificationMailer } from "../src/mailer.mjs";

const config = {
  publicOrigin: "https://cloud.example.com",
  emailVerificationTTLHours: 24,
  passwordResetTTLHours: 1,
  smtp: {
    host: "smtp.example.com",
    port: 587,
    secure: false,
    user: "mailer@example.com",
    password: "secret-secret-secret",
    from: "no-reply@example.com",
  },
};

test("verification mail requires TLS and keeps credentials out of the message", async () => {
  let transportOptions;
  let message;
  let verified = false;
  const mailer = createVerificationMailer(config, (options) => {
    transportOptions = options;
    return {
      async verify() { verified = true; },
      async sendMail(value) { message = value; return { messageId: "test" }; },
    };
  });

  await mailer.verifyConnection();
  await mailer.sendEmailVerification({ recipient: "person@example.com", token: "opaque-token" });

  assert.equal(verified, true);
  assert.deepEqual(transportOptions, {
    host: "smtp.example.com",
    port: 587,
    secure: false,
    requireTLS: true,
    auth: { user: "mailer@example.com", pass: "secret-secret-secret" },
    tls: { minVersion: "TLSv1.2", rejectUnauthorized: true },
    connectionTimeout: 10_000,
    greetingTimeout: 10_000,
    socketTimeout: 30_000,
  });
  assert.equal(message.to, "person@example.com");
  assert.equal(message.from, "Selective Remote <no-reply@example.com>");
  assert.match(message.text, /https:\/\/cloud\.example\.com\/#verify-email\?token=opaque-token/);
  assert.equal(message.disableFileAccess, true);
  assert.equal(message.disableUrlAccess, true);
  assert.doesNotMatch(JSON.stringify(message), /secret-secret-secret/);
});

test("mailer refuses to start without SMTP configuration", () => {
  assert.throws(() => createVerificationMailer({ ...config, smtp: null }), /smtp_not_configured/);
});

test("password reset mail keeps the opaque token in a fragment", async () => {
  let message;
  const mailer = createVerificationMailer(config, () => ({
    async verify() {},
    async sendMail(value) { message = value; return { messageId: "test" }; },
  }));

  await mailer.sendPasswordReset({ recipient: "person@example.com", token: "opaque-reset-token" });

  assert.equal(message.to, "person@example.com");
  assert.match(message.subject, /Сброс пароля/);
  assert.match(message.text, /https:\/\/cloud\.example\.com\/#reset-password\?token=opaque-reset-token/);
  assert.match(message.text, /1 ч\./);
  assert.equal(message.disableFileAccess, true);
  assert.equal(message.disableUrlAccess, true);
  assert.doesNotMatch(JSON.stringify(message), /secret-secret-secret/);
});

test("Team invitation mail carries one opaque fragment token and bounded metadata", async () => {
  let message;
  const mailer = createVerificationMailer(config, () => ({
    async verify() {},
    async sendMail(value) { message = value; return { messageId: "test" }; },
  }));

  await mailer.sendTeamInvitation({
    recipient: "member@example.com",
    token: "opaque-team-token",
    teamID: "84f6c860-0d26-4ef5-8652-27cb8b991b70",
    role: "viewer",
    expiresAt: "2030-01-03T00:00:00.000Z",
  });

  assert.equal(message.to, "member@example.com");
  assert.match(message.subject, /Приглашение в команду/);
  assert.match(message.text, /#accept-team-invitation\?token=opaque-team-token/);
  assert.match(message.text, /Роль: viewer/);
  assert.equal(message.disableFileAccess, true);
  assert.equal(message.disableUrlAccess, true);
});
