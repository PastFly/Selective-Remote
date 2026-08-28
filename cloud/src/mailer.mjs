import nodemailer from "nodemailer";

export function createVerificationMailer(config, createTransport = nodemailer.createTransport) {
  if (!config.smtp) throw new Error("smtp_not_configured");
  const transport = createTransport({
    host: config.smtp.host,
    port: config.smtp.port,
    secure: config.smtp.secure,
    requireTLS: !config.smtp.secure,
    auth: { user: config.smtp.user, pass: config.smtp.password },
    tls: { minVersion: "TLSv1.2", rejectUnauthorized: true },
    connectionTimeout: 10_000,
    greetingTimeout: 10_000,
    socketTimeout: 30_000,
  });

  return Object.freeze({
    verifyConnection: () => transport.verify(),
    async sendEmailVerification({ recipient, token }) {
      const verificationURL = new URL("/", config.publicOrigin);
      verificationURL.hash = `verify-email?${new URLSearchParams({ token })}`;
      return transport.sendMail({
        from: `Selective Remote <${config.smtp.from}>`,
        to: recipient,
        subject: "Подтвердите email в Selective Remote",
        disableFileAccess: true,
        disableUrlAccess: true,
        text: [
          "Подтвердите адрес электронной почты для Selective Remote:",
          verificationURL.toString(),
          "",
          `Ссылка действует ${config.emailVerificationTTLHours} ч.`,
          "Если вы не создавали аккаунт, проигнорируйте это письмо.",
        ].join("\n"),
      });
    },
  });
}
