import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";

// A restart intentionally invalidates previews from the prior process.
const bootNonce = randomBytes(32);
const tokenDomain = "selective-remote-access-preview-v1";

function canonical(value) {
  if (value === null || typeof value === "string" || typeof value === "boolean") {
    return JSON.stringify(value);
  }
  if (typeof value === "number" && Number.isFinite(value)) return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
    return `{${Object.keys(value).sort().map((key) => {
      if (value[key] === undefined) throw new Error("invalid_access_request");
      return `${JSON.stringify(key)}:${canonical(value[key])}`;
    }).join(",")}}`;
  }
  throw new Error("invalid_access_request");
}

export function hashAccessRequest(request) {
  return createHash("sha256").update(canonical(request)).digest("hex");
}

function signingKey(sessionSecret) {
  if (typeof sessionSecret !== "string" || !sessionSecret) {
    throw new Error("invalid_access_preview_secret");
  }
  return createHmac("sha256", sessionSecret).update(tokenDomain).update(bootNonce).digest();
}

function signature(body, secret) {
  return createHmac("sha256", signingKey(secret)).update(body).digest("base64url");
}

export function createPreviewToken(payload, sessionSecret, { now = Date.now(), ttlMS = 300_000 } = {}) {
  if (!Number.isSafeInteger(now) || !Number.isSafeInteger(ttlMS)
    || ttlMS < 1 || ttlMS > 300_000) throw new Error("invalid_access_preview_expiry");
  const body = Buffer.from(canonical({ ...payload, expiresAt: now + ttlMS })).toString("base64url");
  return `${body}.${signature(body, sessionSecret)}`;
}

export function verifyPreviewToken(token, sessionSecret, { now = Date.now() } = {}) {
  try {
    if (typeof token !== "string" || token.length > 8192
      || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{43}$/u.test(token)) {
      throw new Error("invalid");
    }
    const [body, mac] = token.split(".");
    const expected = signature(body, sessionSecret);
    if (!timingSafeEqual(Buffer.from(mac), Buffer.from(expected))) throw new Error("invalid");
    const decoded = Buffer.from(body, "base64url").toString("utf8");
    const payload = JSON.parse(decoded);
    if (canonical(payload) !== decoded || !Number.isSafeInteger(payload.expiresAt)
      || !Number.isSafeInteger(now) || now >= payload.expiresAt) throw new Error("invalid");
    return payload;
  } catch {
    throw new Error("access_preview_conflict");
  }
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;

export function validateAccessChangeRequest(request) {
  const changes = request?.changes;
  if (!Array.isArray(changes) || changes.length === 0) {
    throw new Error("invalid_access_request");
  }
  if (changes.length > 50) throw new Error("access_batch_too_large");
  const principals = new Set();
  const targets = new Set();
  const identities = new Set();
  for (const change of changes) {
    if (!change || typeof change !== "object" || Array.isArray(change)) {
      throw new Error("invalid_access_request");
    }
    const isCreate = change.type === "GRANT_CREATE";
    const isChange = change.type === "GRANT_CHANGE";
    const isRevoke = change.type === "GRANT_REVOKE";
    const isMove = change.type === "RESOURCE_MOVE";
    if (!isCreate && !isChange && !isRevoke && !isMove) {
      throw new Error("invalid_access_request");
    }
    const allowed = isCreate
      ? ["type", "principalKind", "principalID", "targetKind", "targetID", "permissionMask"]
      : isChange ? ["type", "grantID", "expectedVersion", "permissionMask"]
        : isMove ? ["type", "resourceID", "newParentFolderID", "expectedResourceVersion"]
          : ["type", "grantID", "expectedVersion"];
    if (Object.keys(change).some((key) => !allowed.includes(key))) {
      throw new Error("invalid_access_request");
    }
    if (isMove) {
      if (!uuid.test(change.resourceID ?? "")
        || (change.newParentFolderID !== null
          && !uuid.test(change.newParentFolderID ?? ""))
        || !Number.isSafeInteger(change.expectedResourceVersion)
        || change.expectedResourceVersion < 1
        || identities.has(change.resourceID)) throw new Error("invalid_access_request");
      identities.add(change.resourceID);
      targets.add(`RESOURCE:${change.resourceID}`);
      continue;
    }
    if (isCreate) {
      if (!["USER", "GROUP"].includes(change.principalKind)
        || !uuid.test(change.principalID ?? "")
        || !["VAULT", "FOLDER", "RESOURCE"].includes(change.targetKind)
        || !uuid.test(change.targetID ?? "")) throw new Error("invalid_access_request");
      principals.add(`${change.principalKind}:${change.principalID}`);
      targets.add(`${change.targetKind}:${change.targetID}`);
      const identity = `${change.principalKind}:${change.principalID}:${change.targetKind}:${change.targetID}`;
      if (identities.has(identity)) throw new Error("invalid_access_request");
      identities.add(identity);
    } else {
      if (!uuid.test(change.grantID ?? "")
        || !Number.isSafeInteger(change.expectedVersion)
        || change.expectedVersion < 1 || identities.has(change.grantID)) {
        throw new Error("invalid_access_request");
      }
      identities.add(change.grantID);
    }
    if ((isCreate || isChange) && (!Number.isSafeInteger(change.permissionMask)
      || change.permissionMask < 1 || change.permissionMask > 63)) {
      throw new Error("invalid_access_request");
    }
  }
  if (principals.size > 20 || targets.size > 50) throw new Error("access_batch_too_large");
  return changes;
}
