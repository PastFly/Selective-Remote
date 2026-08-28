import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadConfig } from "./config.mjs";
import { createVerificationMailer } from "./mailer.mjs";
import { PostgresStore } from "./postgres-store.mjs";
import { AuthRateLimiter } from "./rate-limiter.mjs";
import { clientIPAddress } from "./request-security.mjs";
import { normalizeEmail } from "./security.mjs";
import { CloudService } from "./service.mjs";

const config = loadConfig();
const store = new PostgresStore(config.databaseURL);
const mailer = config.smtp ? createVerificationMailer(config) : null;
const service = new CloudService(store, config, mailer);
const authRateLimiter = new AuthRateLimiter(store, config);
const publicDirectory = fileURLToPath(new URL("../public/", import.meta.url));
const maxBodyBytes = 34 * 1024 * 1024;

const server = createServer(async (request, response) => {
  const requestID = crypto.randomUUID();
  response.setHeader("X-Request-ID", requestID);
  response.setHeader("Cache-Control", "no-store");
  try {
    await route(request, response);
  } catch (error) {
    console.error(JSON.stringify({ level: "error", requestID, message: error?.message ?? "unknown" }));
    sendError(response, 500, "internal_error");
  }
});

async function route(request, response) {
  const url = new URL(request.url, config.publicOrigin);
  const method = request.method ?? "GET";
  if (method === "GET" && url.pathname === "/healthz") return sendJSON(response, 200, { status: "ok" });
  if (method === "GET" && url.pathname === "/readyz") {
    await store.ready();
    return sendJSON(response, 200, { status: "ready" });
  }
  if (method === "GET" && url.pathname === "/v1/meta") {
    return sendJSON(response, 200, { apiVersion: 1, vaultSchemaVersion: 1, registrationEnabled: config.allowRegistration });
  }
  if (method === "POST" && url.pathname === "/v1/auth/register") {
    return handleAuthOperation(request, response, "register_ip", "register_email", service.register.bind(service), 201);
  }
  if (method === "POST" && url.pathname === "/v1/auth/login") {
    return handleAuthOperation(request, response, "login_ip", "login_email", service.login.bind(service));
  }
  if (method === "POST" && url.pathname === "/v1/auth/verify-email") {
    return handleAuthOperation(request, response, "verify_email_ip", null, service.verifyEmail.bind(service));
  }
  if (method === "POST" && url.pathname === "/v1/auth/resend-verification") {
    return handleAuthOperation(
      request,
      response,
      "resend_verification_ip",
      "resend_verification_email",
      service.resendEmailVerification.bind(service),
      202,
    );
  }
  if (method === "POST" && url.pathname === "/v1/auth/request-password-reset") {
    return handleAuthOperation(
      request,
      response,
      "request_password_reset_ip",
      "request_password_reset_email",
      service.requestPasswordReset.bind(service),
      202,
    );
  }
  if (method === "POST" && url.pathname === "/v1/auth/reset-password") {
    return handleAuthOperation(request, response, "reset_password_ip", null, service.resetPassword.bind(service));
  }

  if (url.pathname.startsWith("/v1/")) {
    const session = await service.authenticate(bearerToken(request));
    if (!session) return sendError(response, 401, "unauthorized");
    if (method === "POST" && url.pathname === "/v1/auth/logout") {
      await store.revokeSession(session.session_id);
      return empty(response, 204);
    }
    if (method === "GET" && url.pathname === "/v1/me") {
      return sendJSON(response, 200, {
        id: session.user_id,
        email: session.email,
        displayName: session.display_name,
        deviceID: session.device_id,
      });
    }
    if (method === "GET" && url.pathname === "/v1/devices") {
      return sendJSON(response, 200, { devices: await store.listDevices(session.user_id) });
    }
    const deviceMatch = url.pathname.match(/^\/v1\/devices\/([0-9a-f-]+)$/i);
    if (method === "DELETE" && deviceMatch) {
      const revoked = await store.revokeDevice(session.user_id, deviceMatch[1]);
      return revoked ? empty(response, 204) : sendError(response, 404, "device_not_found");
    }
    if (method === "GET" && url.pathname === "/v1/vault") {
      return sendJSON(response, 200, await service.getVault(session));
    }
    if (method === "PUT" && url.pathname === "/v1/vault") {
      const result = await service.putVault(session, await readJSON(request));
      return result.conflict ? sendJSON(response, 409, result) : sendJSON(response, 200, result);
    }
    return sendError(response, 404, "not_found");
  }

  if (method === "GET" || method === "HEAD") return serveStatic(url.pathname, response, method === "HEAD");
  return sendError(response, 404, "not_found");
}

async function handleAuthOperation(request, response, ipScope, emailScope, operation, successStatus = 200) {
  return handleOperation(response, async () => {
    await authRateLimiter.require(ipScope, clientIPAddress(request, config.proxySharedSecret));
    const input = await readJSON(request);
    if (emailScope) {
      let email = null;
      try { email = normalizeEmail(input.email); } catch {}
      if (email) await authRateLimiter.require(emailScope, email);
    }
    return operation(input);
  }, successStatus);
}

async function handleOperation(response, operation, successStatus = 200) {
  try {
    return sendJSON(response, successStatus, await operation());
  } catch (error) {
    const code = error?.message ?? "invalid_request";
    if (code === "rate_limited" && Number.isInteger(error.retryAfterSeconds)) {
      response.setHeader("Retry-After", String(Math.max(1, error.retryAfterSeconds)));
    }
    const statuses = {
      registration_disabled: 403,
      email_exists: 409,
      invalid_credentials: 401,
      email_not_verified: 403,
      email_delivery_failed: 502,
      smtp_not_configured: 503,
      rate_limited: 429,
      invalid_verification_token: 400,
      invalid_password_reset_token: 400,
      invalid_email: 400,
      invalid_password: 400,
      invalid_device: 400,
      invalid_content_type: 415,
      invalid_json: 400,
      request_too_large: 413,
      invalid_vault_envelope: 400,
      invalid_base_revision: 400,
      invalid_envelope_version: 400,
      vault_too_large: 413,
    };
    return sendError(response, statuses[code] ?? 400, code);
  }
}

function bearerToken(request) {
  const value = request.headers.authorization ?? "";
  return value.startsWith("Bearer ") ? value.slice(7) : null;
}

async function readJSON(request) {
  const contentType = request.headers["content-type"] ?? "";
  if (!contentType.toLowerCase().startsWith("application/json")) throw new Error("invalid_content_type");
  const chunks = [];
  let total = 0;
  for await (const chunk of request) {
    total += chunk.length;
    if (total > maxBodyBytes) throw new Error("request_too_large");
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); }
  catch { throw new Error("invalid_json"); }
}

async function serveStatic(pathname, response, head) {
  const relative = pathname === "/" ? "index.html" : pathname.slice(1);
  if (!/^[a-zA-Z0-9._/-]+$/.test(relative) || relative.includes("..")) return sendError(response, 404, "not_found");
  try {
    const data = await readFile(join(publicDirectory, relative));
    const types = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".svg": "image/svg+xml" };
    response.writeHead(200, {
      "Content-Type": types[extname(relative)] ?? "application/octet-stream",
      "Cache-Control": relative === "index.html" ? "no-cache" : "public, max-age=3600",
      "Content-Security-Policy": "default-src 'self'; style-src 'self'; script-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
    });
    response.end(head ? undefined : data);
  } catch { sendError(response, 404, "not_found"); }
}

function sendJSON(response, status, value) {
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(value));
}

function sendError(response, status, code) { sendJSON(response, status, { error: code }); }
function empty(response, status) { response.writeHead(status); response.end(); }

async function start() {
  if (config.allowRegistration) {
    try {
      await mailer.verifyConnection();
    } catch {
      console.error(JSON.stringify({ level: "error", message: "SMTP preflight failed" }));
      await store.close();
      process.exit(1);
    }
  }
  server.listen(config.port, config.host, () => {
    console.log(JSON.stringify({ level: "info", message: "Selective Remote Cloud listening", host: config.host, port: config.port }));
  });
}

await start();

async function shutdown(signal) {
  console.log(JSON.stringify({ level: "info", message: "Shutting down", signal }));
  server.close(async () => { await store.close(); process.exit(0); });
  setTimeout(() => process.exit(1), 10_000).unref();
}
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
