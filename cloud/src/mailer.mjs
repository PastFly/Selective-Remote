import nodemailer from "nodemailer";

const COLORS = { ink: "#071611", border: "#244137", mint: "#73dfb5", muted: "#a7bbb4", white: "#f4fbf8" };

function escapeHTML(value) {
  return String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}

function emailHTML({ preview, eyebrow, title, body, buttonLabel, url, details = [] }) {
  const safeURL = escapeHTML(url);
  const rows = details.map(({ label, value }) => `<tr><td style="padding:8px 12px;color:${COLORS.muted};font-size:14px">${escapeHTML(label)}</td><td style="padding:8px 12px;color:${COLORS.white};font-size:14px;font-weight:600;text-align:right">${escapeHTML(value)}</td></tr>`).join("");
  const detailTable = rows ? `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="margin:24px 0;border:1px solid ${COLORS.border};border-radius:12px;border-collapse:separate;overflow:hidden">${rows}</table>` : "";
  return `<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHTML(title)}</title></head>
<body style="margin:0;padding:0;background:#0a1014;color:${COLORS.white};font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent">${escapeHTML(preview)}</div>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#0a1014"><tr><td align="center" style="padding:32px 16px">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:600px;background:${COLORS.ink};border:1px solid ${COLORS.border};border-radius:22px">
<tr><td style="padding:28px 32px 18px"><table role="presentation" cellspacing="0" cellpadding="0"><tr><td style="width:44px;height:44px;border:1px solid ${COLORS.mint};border-radius:13px;color:${COLORS.mint};font-size:17px;font-weight:800;text-align:center">SR</td><td style="padding-left:14px;color:${COLORS.white};font-size:20px;font-weight:750">Selective Remote</td></tr></table></td></tr>
<tr><td style="padding:18px 32px 34px"><div style="color:${COLORS.mint};font-size:12px;font-weight:800;letter-spacing:2px;text-transform:uppercase">${escapeHTML(eyebrow)}</div><h1 style="margin:12px 0 14px;color:${COLORS.white};font-size:30px;line-height:1.2">${escapeHTML(title)}</h1><div style="color:${COLORS.muted};font-size:16px;line-height:1.65">${body}</div>${detailTable}
<table role="presentation" cellspacing="0" cellpadding="0" style="margin:28px 0 20px"><tr><td bgcolor="${COLORS.mint}" style="border-radius:11px"><a href="${safeURL}" style="display:inline-block;padding:14px 24px;color:#052018;text-decoration:none;font-size:16px;font-weight:800">${escapeHTML(buttonLabel)}</a></td></tr></table>
<div style="color:${COLORS.muted};font-size:13px;line-height:1.55">Если кнопка не открывается, скопируйте ссылку:<br><a href="${safeURL}" style="color:${COLORS.mint};word-break:break-all">${safeURL}</a></div></td></tr>
<tr><td style="padding:20px 32px;border-top:1px solid ${COLORS.border};color:#779188;font-size:12px;line-height:1.5">Безопасный доступ к вашим подключениям. Если вы не ожидали это письмо, просто проигнорируйте его.</td></tr>
</table></td></tr></table></body></html>`;
}

function message(config, recipient, subject, text, html) {
  return { from: `Selective Remote <${config.smtp.from}>`, to: recipient, subject, disableFileAccess: true, disableUrlAccess: true, text, html };
}

function invitationRole(role) {
  return ({ admin: "Администратор", editor: "Редактор", operator: "Оператор", viewer: "Наблюдатель" })[role] ?? role;
}

function invitationExpiry(value) {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return value;
  return new Intl.DateTimeFormat("ru-RU", {
    dateStyle: "long", timeStyle: "short", timeZone: "UTC",
  }).format(date) + " UTC";
}

export function createVerificationMailer(config, createTransport = nodemailer.createTransport) {
  if (!config.smtp) throw new Error("smtp_not_configured");
  const transport = createTransport({
    host: config.smtp.host, port: config.smtp.port, secure: config.smtp.secure,
    requireTLS: !config.smtp.secure,
    auth: { user: config.smtp.user, pass: config.smtp.password },
    tls: { minVersion: "TLSv1.2", rejectUnauthorized: true },
    connectionTimeout: 10_000, greetingTimeout: 10_000, socketTimeout: 30_000,
  });
  return Object.freeze({
    verifyConnection: () => transport.verify(),
    async sendEmailVerification({ recipient, token }) {
      const target = new URL("/", config.publicOrigin);
      target.hash = `verify-email?${new URLSearchParams({ token })}`;
      const url = target.toString();
      const text = ["Подтвердите адрес электронной почты для Selective Remote:", url, "", `Ссылка действует ${config.emailVerificationTTLHours} ч.`, "Если вы не создавали аккаунт, проигнорируйте это письмо."].join("\n");
      const html = emailHTML({ preview: "Подтвердите email и завершите настройку Selective Remote.", eyebrow: "Подтверждение аккаунта", title: "Остался один шаг", body: `Подтвердите адрес электронной почты, чтобы завершить регистрацию. Ссылка действует <strong style="color:${COLORS.white}">${escapeHTML(config.emailVerificationTTLHours)} ч.</strong>`, buttonLabel: "Подтвердить email", url });
      return transport.sendMail(message(config, recipient, "Подтвердите email в Selective Remote", text, html));
    },
    async sendPasswordReset({ recipient, token }) {
      const target = new URL("/", config.publicOrigin);
      target.hash = `reset-password?${new URLSearchParams({ token })}`;
      const url = target.toString();
      const text = ["Чтобы задать новый пароль Selective Remote, откройте ссылку:", url, "", `Ссылка действует ${config.passwordResetTTLHours} ч.`, "Если вы не запрашивали сброс, проигнорируйте это письмо."].join("\n");
      const html = emailHTML({ preview: "Безопасная ссылка для смены пароля Selective Remote.", eyebrow: "Безопасность аккаунта", title: "Сброс пароля", body: `Мы получили запрос на смену пароля. Ссылка действует <strong style="color:${COLORS.white}">${escapeHTML(config.passwordResetTTLHours)} ч.</strong> и предназначена только для вас.`, buttonLabel: "Задать новый пароль", url });
      return transport.sendMail(message(config, recipient, "Сброс пароля Selective Remote", text, html));
    },
    async sendTeamInvitation({ recipient, token, teamID, teamName, invitedBy, role, expiresAt }) {
      const target = new URL("/", config.publicOrigin);
      target.hash = `accept-team-invitation?${new URLSearchParams({ token })}`;
      const url = target.toString();
      const displayTeam = teamName || teamID;
      const displayRole = invitationRole(role);
      const displayExpiry = invitationExpiry(expiresAt);
      const inviterLine = invitedBy ? `Пригласил: @${invitedBy}.` : "";
      const text = [`Вас пригласили в команду «${displayTeam}» в Selective Remote.`, inviterLine, url, "", `Роль: ${displayRole}.`, `Приглашение действует до ${displayExpiry} и может быть использовано один раз.`, "Если вы не ожидали приглашение, проигнорируйте это письмо."].filter(Boolean).join("\n");
      const details = [{ label: "Команда", value: displayTeam }, { label: "Роль", value: displayRole }];
      if (invitedBy) details.push({ label: "Пригласил", value: `@${invitedBy}` });
      details.push({ label: "Действует до", value: displayExpiry });
      const html = emailHTML({ preview: `Вас пригласили в команду «${displayTeam}».`, eyebrow: "Командная работа", title: "Приглашение в команду", body: "Примите приглашение, чтобы получить защищённый доступ к общим хостам и ресурсам команды.", buttonLabel: "Принять приглашение", url, details });
      return transport.sendMail(message(config, recipient, `Приглашение в команду «${displayTeam}»`, text, html));
    },
  });
}
