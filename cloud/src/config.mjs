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

export function loadConfig() {
  const publicOrigin = process.env.CLOUD_PUBLIC_ORIGIN ?? "http://localhost:8080";
  const databaseURL = process.env.DATABASE_URL;
  const sessionPepper = process.env.SESSION_TOKEN_PEPPER;
  if (!databaseURL) throw new Error("DATABASE_URL is required");
  if (!sessionPepper || Buffer.byteLength(sessionPepper) < 32) {
    throw new Error("SESSION_TOKEN_PEPPER must contain at least 32 bytes");
  }
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
    allowRegistration: boolean("ALLOW_REGISTRATION", false),
    sessionTTLDays: integer("SESSION_TTL_DAYS", 30, 1, 365),
  });
}
