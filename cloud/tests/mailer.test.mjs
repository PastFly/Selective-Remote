import assert from "node:assert/strict";
import test from "node:test";
import { spawnSync } from "node:child_process";
import nodemailer from "nodemailer";
import { createVerificationMailer } from "../src/mailer.mjs";
import { normalizeEmail } from "../src/security.mjs";

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
  assert.match(message.html, /Остался один шаг/);
  assert.match(message.html, /Подтвердить email/);
  assert.match(message.html, /href="https:\/\/cloud\.example\.com\/#verify-email\?token=opaque-token"/);
  assert.equal(message.disableFileAccess, true);
  assert.equal(message.disableUrlAccess, true);
  assert.doesNotMatch(JSON.stringify(message), /secret-secret-secret/);
});

test("mailer refuses to start without SMTP configuration", () => {
  assert.throws(() => createVerificationMailer({ ...config, smtp: null }), /smtp_not_configured/);
});

// The public envelope sanitizes the quoted local-part ">" to a space;
// the security invariant is that its domain remains good.example.
for (const { advisory, recipient, expected } of [
  { advisory: "GHSA-8c8m-p3m8-cjg8", recipient: "Victim (x(y) <evil@evil.example>) <v@victim.example>", expected: "v@victim.example" },
  { advisory: "GHSA-m943-m63m-w62w", recipient: "G: (a; <evil@evil.example>) <v@victim.example>;", expected: "v@victim.example" },
  { advisory: "GHSA-85x2-q946-cp5h", recipient: '<"a@evil.example>"@good.example>', expected: '"a@evil.example "@good.example' },
]) {
  test(`installed transport prevents addressparser recipient redirection (${advisory})`, async () => {
    const transport = nodemailer.createTransport({ streamTransport: true, buffer: true });
    const result = await transport.sendMail({ from: "sender@example.com", to: recipient, text: "parser regression" });
    assert.deepEqual(result.envelope.to, [expected]);
    // These upstream parser reproductions are rejected by the application's
    // current ingress validator; they do not establish a deployed exploit.
    assert.throws(() => normalizeEmail(recipient), /invalid_email/);
  });
}

for (const [method, fragment] of [
  ["sendEmailVerification", "verify-email"],
  ["sendPasswordReset", "reset-password"],
  ["sendTeamInvitation", "accept-team-invitation"],
]) {
  test(`installed transport compiles legitimate application mail: ${method}`, async () => {
    const mailer = createVerificationMailer(config, () => nodemailer.createTransport({ streamTransport: true, buffer: true }));
    const result = await mailer[method]({
      recipient: normalizeEmail(" Person+Mail@Example.com "), token: "opaque-token",
      teamID: "84f6c860-0d26-4ef5-8652-27cb8b991b70", teamName: "Operations",
      invitedBy: "owner.name", role: "viewer", expiresAt: "2030-01-03T00:00:00.000Z",
    });
    assert.deepEqual(result.envelope.to, ["person+mail@example.com"]);
    assert.equal(result.envelope.from, "no-reply@example.com");
    const message = result.message.toString();
    assert.match(message, /MIME-Version: 1\.0/);
    assert.ok(message.includes(`#${fragment}?token=3Dopaque-token`));
    assert.doesNotMatch(message, /secret-secret-secret/);
  });
}

test("installed mail transport bounds malformed address parsing (GHSA-v53p-9fqp-m79j)", () => {
  // Exercise the public mail path in a killable child: the vulnerable parser
  // blocks the event loop, so an in-process Promise timeout is insufficient.
  const result = spawnSync(process.execPath, ["--input-type=module", "-e", `
    import nodemailer from "nodemailer";
    const transport = nodemailer.createTransport({ streamTransport: true, buffer: true });
    await transport.sendMail({ from: "sender@example.com", to: " >" + ">[x][x]".repeat(40000), text: "bounded parser regression" });
  `], { cwd: new URL("../", import.meta.url), encoding: "utf8", timeout: 10000, maxBuffer: 16384 });
  assert.equal(result.error?.code, undefined, "malformed recipient processing exceeded the child process budget");
  assert.equal(result.status, 0, result.stderr);
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
  assert.match(message.html, /Задать новый пароль/);
  assert.match(message.html, /#reset-password\?token=opaque-reset-token/);
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
    teamName: "Operations & Security",
    invitedBy: "owner.name",
    role: "viewer",
    expiresAt: "2030-01-03T00:00:00.000Z",
  });

  assert.equal(message.to, "member@example.com");
  assert.match(message.subject, /Приглашение в команду/);
  assert.match(message.text, /#accept-team-invitation\?token=opaque-team-token/);
  assert.match(message.text, /Роль: Наблюдатель/);
  assert.match(message.html, /Принять приглашение/);
  assert.match(message.subject, /Operations & Security/);
  assert.match(message.html, /Operations &amp; Security/);
  assert.match(message.html, /Наблюдатель/);
  assert.match(message.html, /@owner\.name/);
  assert.match(message.html, /3 января 2030 г\. в 00:00 UTC/);
  assert.doesNotMatch(message.html, /84f6c860-0d26-4ef5-8652-27cb8b991b70/);
  assert.equal(message.disableFileAccess, true);
  assert.equal(message.disableUrlAccess, true);
});
