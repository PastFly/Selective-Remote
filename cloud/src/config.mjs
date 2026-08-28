function integer(env, name, fallback, minimum, maximum) {
  const raw = env[name];
  const value = raw === undefined ? fallback : Number.parseInt(raw, 10);
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer between ${minimum} and ${maximum}`);
  }
  return value;
}

function boolean(env, name, fallback) {
  const raw = env[name];
  if (raw === undefined) return fallback;
  if (raw === "true") return true;
  if (raw === "false") return false;
  throw new Error(`${name} must be true or false`);
}

export function validateSecret(name, value, required = true) {
  if (!value && !required) return null;
  if (!value || Buffer.byteLength(value) < 32 || value.toLowerCase().includes("replace-with")) {
    throw new Error(`${name} must contain at least 32 random bytes`);
  }
  return value;
}

function required(name, value, trim = true) {
  const raw = String(value ?? "");
  const normalized = trim ? raw.trim() : raw;
  if (!normalized || normalized.toLowerCase().includes("replace-with")) {
    throw new Error(`${name} is required`);
  }
  return normalized;
}

function loadSMTPConfig(env, requiredForRegistration) {
  const configured = ["SMTP_HOST", "SMTP_PORT", "SMTP_SECURE", "SMTP_USER", "SMTP_PASSWORD", "SMTP_FROM"]
    .some((name) => env[name] !== undefined);
  if (!configured && !requiredForRegistration) return null;

  const host = required("SMTP_HOST", env.SMTP_HOST);
  if (!/^[a-zA-Z0-9.-]+$/.test(host)) throw new Error("SMTP_HOST must be a hostname or IP address");
  const user = required("SMTP_USER", env.SMTP_USER);
  const password = required("SMTP_PASSWORD", env.SMTP_PASSWORD, false);
  if (password.length < 16) throw new Error("SMTP_PASSWORD must contain at least 16 characters");
  const from = required("SMTP_FROM", env.SMTP_FROM);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(from)) throw new Error("SMTP_FROM must be an email address");

  return Object.freeze({
    host,
    port: integer(env, "SMTP_PORT", 465, 1, 65535),
    secure: boolean(env, "SMTP_SECURE", true),
    user,
    password,
    from,
  });
}

export function loadConfig(env = process.env) {
  const publicOrigin = env.CLOUD_PUBLIC_ORIGIN ?? "http://localhost:8080";
  const databaseURL = env.DATABASE_URL;
  const allowRegistration = boolean(env, "ALLOW_REGISTRATION", false);
  const sessionPepper = validateSecret("SESSION_TOKEN_PEPPER", env.SESSION_TOKEN_PEPPER);
  const emailVerificationPepper = validateSecret(
    "EMAIL_VERIFICATION_TOKEN_PEPPER",
    env.EMAIL_VERIFICATION_TOKEN_PEPPER,
  );
  if (!databaseURL) throw new Error("DATABASE_URL is required");
  const origin = new URL(publicOrigin);
  if (env.NODE_ENV === "production" && origin.protocol !== "https:") {
    throw new Error("CLOUD_PUBLIC_ORIGIN must use HTTPS in production");
  }

  return Object.freeze({
    host: env.CLOUD_HOST ?? "0.0.0.0",
    port: integer(env, "CLOUD_PORT", 8080, 1, 65535),
    publicOrigin: origin.origin,
    databaseURL,
    sessionPepper,
    emailVerificationPepper,
    smtp: loadSMTPConfig(env, allowRegistration),
    allowRegistration,
    sessionTTLDays: integer(env, "SESSION_TTL_DAYS", 30, 1, 365),
    emailVerificationTTLHours: integer(env, "EMAIL_VERIFICATION_TTL_HOURS", 24, 1, 168),
  });
}
