function integer(env, name, fallback, minimum, maximum) {
  const raw = env[name];
  const value = raw === undefined ? fallback : Number(raw);
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

export function validateSecret(name, value) {
  if (!value || Buffer.byteLength(value) < 32 || value.toLowerCase().includes("replace-with")) {
    throw new Error(`${name} must contain at least 32 random bytes`);
  }
  return value;
}

export function loadConfig(env = process.env) {
  const publicOrigin = env.CLOUD_PUBLIC_ORIGIN ?? "http://localhost:8080";
  const databaseURL = String(env.DATABASE_URL ?? "").trim();
  const sessionPepper = validateSecret("SESSION_TOKEN_PEPPER", env.SESSION_TOKEN_PEPPER);
  if (!databaseURL || /replace-(?:me|with)/i.test(databaseURL)) throw new Error("DATABASE_URL is required");
  const origin = new URL(publicOrigin);
  if (origin.username || origin.password || origin.pathname !== "/" || origin.search || origin.hash) {
    throw new Error("CLOUD_PUBLIC_ORIGIN must be an origin without credentials, path, query or fragment");
  }
  if (env.NODE_ENV === "production" && origin.protocol !== "https:") {
    throw new Error("CLOUD_PUBLIC_ORIGIN must use HTTPS in production");
  }

  return Object.freeze({
    host: env.CLOUD_HOST ?? "0.0.0.0",
    port: integer(env, "CLOUD_PORT", 8080, 1, 65535),
    publicOrigin: origin.origin,
    databaseURL,
    sessionPepper,
    allowRegistration: boolean(env, "ALLOW_REGISTRATION", false),
    sessionTTLDays: integer(env, "SESSION_TTL_DAYS", 30, 1, 365),
  });
}
