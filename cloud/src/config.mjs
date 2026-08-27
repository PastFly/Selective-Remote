function integer(name, fallback, minimum, maximum) {
  const raw = process.env[name];
  const value = raw === undefined ? fallback : Number.parseInt(raw, 10);
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer between ${minimum} and ${maximum}`);
  }
  return value;
}

function boolean(name, fallback) {
  const raw = process.env[name];
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

export function loadConfig() {
  const publicOrigin = process.env.CLOUD_PUBLIC_ORIGIN ?? "http://localhost:8080";
  const databaseURL = process.env.DATABASE_URL;
  const allowRegistration = boolean("ALLOW_REGISTRATION", false);
  const sessionPepper = validateSecret("SESSION_TOKEN_PEPPER", process.env.SESSION_TOKEN_PEPPER);
  const emailVerificationPepper = validateSecret(
    "EMAIL_VERIFICATION_TOKEN_PEPPER",
    process.env.EMAIL_VERIFICATION_TOKEN_PEPPER,
    allowRegistration,
  );
  if (!databaseURL) throw new Error("DATABASE_URL is required");
  const origin = new URL(publicOrigin);
  if (process.env.NODE_ENV === "production" && origin.protocol !== "https:") {
    throw new Error("CLOUD_PUBLIC_ORIGIN must use HTTPS in production");
  }

  return Object.freeze({
    host: process.env.CLOUD_HOST ?? "0.0.0.0",
    port: integer("CLOUD_PORT", 8080, 1, 65535),
    publicOrigin: origin.origin,
    databaseURL,
    sessionPepper,
    emailVerificationPepper,
    allowRegistration,
    sessionTTLDays: integer("SESSION_TTL_DAYS", 30, 1, 365),
    emailVerificationTTLHours: integer("EMAIL_VERIFICATION_TTL_HOURS", 24, 1, 168),
  });
}
