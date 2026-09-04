const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const base64URLPattern = /^[A-Za-z0-9_-]+$/u;
const envelopeKeys = ["authTag", "baseRevision", "ciphertext", "contentHash", "envelopeVersion", "nonce", "wrappedKey"];

export const personalVaultScope = Object.freeze({ type: "personal", id: "self" });

function exactKeys(value, expected, code) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(code);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error(code);
  }
}

function normalizedScope(value) {
  exactKeys(value, ["id", "type"], "invalid_vault_scope");
  if (value.type !== "personal" || value.id !== "self") throw new Error("unsupported_vault_scope");
  return personalVaultScope;
}

function normalizedEnvelope(value, expectedBaseRevision = null) {
  exactKeys(value, envelopeKeys, "invalid_remote_vault");
  if (!Number.isSafeInteger(value.baseRevision) || value.baseRevision < 0) throw new Error("invalid_remote_vault");
  if (expectedBaseRevision !== null && value.baseRevision !== expectedBaseRevision) {
    throw new Error("invalid_remote_vault");
  }
  if (value.envelopeVersion !== 1) throw new Error("invalid_remote_vault");
  for (const key of ["ciphertext", "nonce", "authTag", "contentHash"]) {
    if (typeof value[key] !== "string" || !base64URLPattern.test(value[key])) {
      throw new Error("invalid_remote_vault");
    }
  }
  if (!value.wrappedKey || typeof value.wrappedKey !== "object" || Array.isArray(value.wrappedKey)) {
    throw new Error("invalid_remote_vault");
  }
  return structuredClone(value);
}

function normalizedRemoteVault(value) {
  exactKeys(value, ["authTag", "ciphertext", "contentHash", "envelopeVersion", "id", "nonce", "revision", "updatedAt", "wrappedKey"], "invalid_remote_vault");
  if (!uuidPattern.test(String(value.id ?? ""))) throw new Error("invalid_remote_vault");
  if (!Number.isSafeInteger(value.revision) || value.revision < 0) throw new Error("invalid_remote_vault");
  if (value.revision === 0) {
    for (const key of ["wrappedKey", "ciphertext", "nonce", "authTag", "contentHash"]) {
      if (value[key] !== null) throw new Error("invalid_remote_vault");
    }
    return { id: value.id.toLowerCase(), revision: 0, envelope: null, updatedAt: value.updatedAt };
  }
  return {
    id: value.id.toLowerCase(),
    revision: value.revision,
    envelope: normalizedEnvelope({
      baseRevision: value.revision - 1,
      envelopeVersion: value.envelopeVersion,
      wrappedKey: value.wrappedKey,
      ciphertext: value.ciphertext,
      nonce: value.nonce,
      authTag: value.authTag,
      contentHash: value.contentHash,
    }, value.revision - 1),
    updatedAt: value.updatedAt,
  };
}

async function responseJSON(response, code) {
  try {
    const value = await response.json();
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(code);
    return value;
  } catch {
    throw new Error(code);
  }
}

export function createAuthenticatedVaultClient({ fetchValue = globalThis.fetch } = {}) {
  if (typeof fetchValue !== "function") throw new Error("invalid_fetch");
  let token = null;
  let user = null;

  async function authorizedRequest(path, options = {}) {
    if (!token) throw new Error("authentication_required");
    const response = await fetchValue(path, {
      ...options,
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${token}`,
        ...(options.body ? { "Content-Type": "application/json" } : {}),
      },
      cache: "no-store",
      credentials: "omit",
      referrerPolicy: "no-referrer",
    });
    if (response.status === 401) {
      token = null;
      user = null;
      throw new Error("authentication_required");
    }
    return response;
  }

  return {
    async login({ email, password, deviceID }) {
      const normalizedDeviceID = String(deviceID ?? "").toLowerCase();
      if (!uuidPattern.test(normalizedDeviceID)) throw new Error("invalid_device");
      const response = await fetchValue("/v1/auth/login", {
        method: "POST",
        headers: { Accept: "application/json", "Content-Type": "application/json" },
        body: JSON.stringify({
          email: String(email ?? "").trim(),
          password: String(password ?? ""),
          device: {
            id: normalizedDeviceID,
            name: "Web browser",
            platform: "web",
            appVersion: "0.32",
            publicKey: null,
          },
        }),
        cache: "no-store",
        credentials: "omit",
        referrerPolicy: "no-referrer",
      });
      if (!response.ok) throw new Error("login_failed");
      const result = await responseJSON(response, "login_failed");
      if (typeof result.token !== "string" || result.token.length < 32 || result.token.length > 256) {
        throw new Error("login_failed");
      }
      if (!result.user || typeof result.user !== "object" || !uuidPattern.test(String(result.user.id ?? ""))) {
        throw new Error("login_failed");
      }
      if (String(result.deviceID ?? "").toLowerCase() !== normalizedDeviceID) throw new Error("login_failed");
      token = result.token;
      user = {
        id: String(result.user.id).toLowerCase(),
        email: String(result.user.email ?? ""),
        displayName: String(result.user.displayName ?? ""),
      };
      return structuredClone(user);
    },

    session() {
      return user ? structuredClone(user) : null;
    },

    async logout() {
      if (!token) return;
      try {
        await authorizedRequest("/v1/auth/logout", { method: "POST" });
      } finally {
        token = null;
        user = null;
      }
    },

    async getVault(scope = personalVaultScope) {
      normalizedScope(scope);
      const response = await authorizedRequest("/v1/vault");
      if (!response.ok) throw new Error("vault_download_failed");
      return normalizedRemoteVault(await responseJSON(response, "vault_download_failed"));
    },

    async putVault(scope = personalVaultScope, envelope) {
      normalizedScope(scope);
      const normalized = normalizedEnvelope(envelope);
      const response = await authorizedRequest("/v1/vault", {
        method: "PUT",
        body: JSON.stringify(normalized),
      });
      const result = await responseJSON(response, "vault_upload_failed");
      if (response.status === 409) {
        if (result.conflict !== true || !Number.isSafeInteger(result.revision) || result.revision < 0) {
          throw new Error("vault_upload_failed");
        }
        return { conflict: true, revision: result.revision };
      }
      if (!response.ok || result.conflict !== false || !Number.isSafeInteger(result.revision) || result.revision < 1) {
        throw new Error("vault_upload_failed");
      }
      return { conflict: false, revision: result.revision };
    },
  };
}

async function uploadCurrent(client, vault, scope, baseRevision) {
  const prepared = await vault.prepareUpload(baseRevision);
  const result = await client.putVault(scope, prepared.envelope);
  if (result.conflict) return { status: "remote_changed", remoteRevision: result.revision };
  if (result.revision !== baseRevision + 1) throw new Error("invalid_remote_revision");
  const state = await vault.markSynced({
    serverRevision: result.revision,
    localRevision: prepared.localRevision,
  });
  return { status: state.dirty ? "uploaded_with_new_local_changes" : "uploaded", revision: result.revision };
}

export async function synchronizeVault({
  client,
  vault,
  scope = personalVaultScope,
  recoveryPassphrase = null,
} = {}) {
  normalizedScope(scope);
  if (!client?.session()) throw new Error("authentication_required");
  if (!vault || typeof vault.status !== "function") throw new Error("invalid_local_vault");

  const remote = await client.getVault(scope);
  const localStatus = await vault.status();
  if (localStatus === "empty") {
    if (remote.revision === 0) return { status: "empty" };
    if (!recoveryPassphrase) throw new Error("recovery_passphrase_required");
    await vault.importRemote(remote, recoveryPassphrase);
    return { status: "downloaded", revision: remote.revision };
  }
  if (localStatus !== "unlocked") throw new Error("local_vault_locked");

  const state = await vault.syncState();
  if (remote.revision < state.serverRevision) throw new Error("remote_revision_regressed");
  if (remote.revision === 0) return uploadCurrent(client, vault, scope, 0);
  if (remote.revision === state.serverRevision) {
    return state.dirty
      ? uploadCurrent(client, vault, scope, remote.revision)
      : { status: "up_to_date", revision: remote.revision };
  }

  const merged = await vault.mergeRemote(remote);
  if (merged.conflicts.length > 0) {
    return { status: "conflict", revision: remote.revision, conflicts: merged.conflicts };
  }
  const afterMerge = await vault.syncState();
  if (merged.matchesRemote) {
    await vault.markSynced({ serverRevision: remote.revision, localRevision: afterMerge.localRevision });
    return { status: "downloaded", revision: remote.revision };
  }
  return uploadCurrent(client, vault, scope, remote.revision);
}
