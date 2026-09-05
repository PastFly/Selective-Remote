import {
  normalizeTeamDevicePublicKey,
  normalizeTeamVaultScope,
  teamDevicePublicKeyAlgorithm,
} from "./team-vault-crypto.js";

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const base64URLPattern = /^[A-Za-z0-9_-]+$/u;
const envelopeKeys = ["authTag", "baseRevision", "ciphertext", "contentHash", "envelopeVersion", "nonce", "wrappedKey"];
const teamEnvelopeKeys = ["authTag", "baseRevision", "ciphertext", "contentHash", "envelopeVersion", "keyGeneration", "nonce"];
const teamWrapperKeys = [
  "authTag", "ciphertext", "contextHash", "deviceID", "ephemeralPublicKey",
  "membershipEpoch", "membershipID", "nonce", "wrapperVersion",
];

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

function normalizedUUID(value, code) {
  const normalized = String(value ?? "").toLowerCase();
  if (!uuidPattern.test(normalized)) throw new Error(code);
  return normalized;
}

function normalizedIdempotencyKey(value) {
  const key = String(value ?? "");
  if (key.length < 16 || key.length > 128 || !/^[A-Za-z0-9._:-]+$/u.test(key)) {
    throw new Error("invalid_idempotency_key");
  }
  return key;
}

function normalizedTeamWrapper(value) {
  exactKeys(value, teamWrapperKeys, "invalid_team_vault_wrapper");
  if (value.wrapperVersion !== 1
    || !Number.isSafeInteger(value.membershipEpoch) || value.membershipEpoch < 1) {
    throw new Error("invalid_team_vault_wrapper");
  }
  for (const [key, length] of [["ciphertext", 43], ["nonce", 16], ["authTag", 22], ["contextHash", 43]]) {
    if (typeof value[key] !== "string" || value[key].length !== length || !base64URLPattern.test(value[key])) {
      throw new Error("invalid_team_vault_wrapper");
    }
  }
  return {
    membershipID: normalizedUUID(value.membershipID, "invalid_team_vault_wrapper"),
    membershipEpoch: value.membershipEpoch,
    deviceID: normalizedUUID(value.deviceID, "invalid_team_vault_wrapper"),
    wrapperVersion: 1,
    ephemeralPublicKey: normalizeTeamDevicePublicKey(value.ephemeralPublicKey),
    ciphertext: value.ciphertext,
    nonce: value.nonce,
    authTag: value.authTag,
    contextHash: value.contextHash,
  };
}

function normalizedTeamEnvelope(value) {
  const hasWrappers = value && Object.hasOwn(value, "wrappers");
  exactKeys(value, hasWrappers ? [...teamEnvelopeKeys, "wrappers"] : teamEnvelopeKeys, "invalid_team_vault_envelope");
  if (!Number.isSafeInteger(value.baseRevision) || value.baseRevision < 0
    || !Number.isSafeInteger(value.keyGeneration) || value.keyGeneration < 1
    || value.envelopeVersion !== 1) {
    throw new Error("invalid_team_vault_envelope");
  }
  for (const [key, length] of [["nonce", 16], ["authTag", 22], ["contentHash", 43]]) {
    if (typeof value[key] !== "string" || value[key].length !== length || !base64URLPattern.test(value[key])) {
      throw new Error("invalid_team_vault_envelope");
    }
  }
  if (typeof value.ciphertext !== "string" || value.ciphertext.length > 32 * 1024 * 1024
    || !base64URLPattern.test(value.ciphertext)) {
    throw new Error("invalid_team_vault_envelope");
  }
  if (hasWrappers && !Array.isArray(value.wrappers)) throw new Error("invalid_team_vault_envelope");
  const wrappers = hasWrappers ? value.wrappers.map(normalizedTeamWrapper) : null;
  if (hasWrappers && (wrappers.length === 0
    || new Set(wrappers.map((wrapper) => wrapper.deviceID)).size !== wrappers.length)) {
    throw new Error("invalid_team_vault_envelope");
  }
  const normalized = structuredClone(value);
  if (hasWrappers) normalized.wrappers = wrappers;
  return normalized;
}

function normalizedTeamKeyDevices(value, scope) {
  exactKeys(value, ["devices"], "invalid_team_key_devices");
  if (!Array.isArray(value.devices) || value.devices.length > 1024) throw new Error("invalid_team_key_devices");
  const devices = value.devices.map((device) => {
    exactKeys(device, ["deviceID", "membershipEpoch", "membershipID", "publicKey", "publicKeyAlgorithm"], "invalid_team_key_devices");
    if (device.publicKeyAlgorithm !== teamDevicePublicKeyAlgorithm
      || !Number.isSafeInteger(device.membershipEpoch) || device.membershipEpoch < 1) {
      throw new Error("invalid_team_key_devices");
    }
    return {
      membershipID: normalizedUUID(device.membershipID, "invalid_team_key_devices"),
      membershipEpoch: device.membershipEpoch,
      deviceID: normalizedUUID(device.deviceID, "invalid_team_key_devices"),
      publicKeyAlgorithm: teamDevicePublicKeyAlgorithm,
      publicKey: normalizeTeamDevicePublicKey(device.publicKey),
    };
  });
  if (new Set(devices.map((device) => device.deviceID)).size !== devices.length) {
    throw new Error("invalid_team_key_devices");
  }
  return { scope, devices };
}

function normalizedRemoteTeamVault(value, scope) {
  exactKeys(value, [
    "authTag", "ciphertext", "contentHash", "createdAt", "envelopeVersion", "id",
    "keyGeneration", "name", "nonce", "revision", "rotationRequired", "teamID", "updatedAt", "wrapper",
  ], "invalid_remote_team_vault");
  if (normalizedUUID(value.id, "invalid_remote_team_vault") !== scope.vaultID
    || normalizedUUID(value.teamID, "invalid_remote_team_vault") !== scope.teamID
    || !Number.isSafeInteger(value.revision) || value.revision < 0
    || !Number.isSafeInteger(value.keyGeneration) || value.keyGeneration < 1
    || typeof value.rotationRequired !== "boolean") {
    throw new Error("invalid_remote_team_vault");
  }
  if (value.revision === 0) {
    for (const key of ["envelopeVersion", "ciphertext", "nonce", "authTag", "contentHash", "wrapper"]) {
      if (value[key] !== null) throw new Error("invalid_remote_team_vault");
    }
  } else {
    if (value.envelopeVersion !== 1) throw new Error("invalid_remote_team_vault");
    for (const [key, length] of [["nonce", 16], ["authTag", 22], ["contentHash", 43]]) {
      if (typeof value[key] !== "string" || value[key].length !== length || !base64URLPattern.test(value[key])) {
        throw new Error("invalid_remote_team_vault");
      }
    }
    if (typeof value.ciphertext !== "string" || !base64URLPattern.test(value.ciphertext)
      || value.ciphertext.length > 32 * 1024 * 1024) {
      throw new Error("invalid_remote_team_vault");
    }
    if (value.wrapper !== null) normalizedTeamWrapper(value.wrapper);
  }
  return {
    scope,
    id: scope.vaultID,
    teamID: scope.teamID,
    name: String(value.name ?? ""),
    revision: value.revision,
    keyGeneration: value.keyGeneration,
    rotationRequired: value.rotationRequired,
    envelopeVersion: value.envelopeVersion,
    ciphertext: value.ciphertext,
    nonce: value.nonce,
    authTag: value.authTag,
    contentHash: value.contentHash,
    wrapper: value.wrapper === null ? null : normalizedTeamWrapper(value.wrapper),
    createdAt: value.createdAt,
    updatedAt: value.updatedAt,
  };
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
  let currentDeviceID = null;

  async function authorizedRequest(path, options = {}) {
    if (!token) throw new Error("authentication_required");
    const response = await fetchValue(path, {
      ...options,
      headers: {
        ...(options.headers ?? {}),
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
      currentDeviceID = null;
      throw new Error("authentication_required");
    }
    return response;
  }

  return {
    async login({ email, password, deviceID, publicKey = null }) {
      const normalizedDeviceID = String(deviceID ?? "").toLowerCase();
      if (!uuidPattern.test(normalizedDeviceID)) throw new Error("invalid_device");
      const normalizedPublicKey = publicKey === null ? null : normalizeTeamDevicePublicKey(publicKey);
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
            publicKey: normalizedPublicKey,
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
      currentDeviceID = normalizedDeviceID;
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
        currentDeviceID = null;
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

    async approveDeviceKey({ deviceID, publicKey, idempotencyKey }) {
      const normalizedDeviceID = normalizedUUID(deviceID, "invalid_device");
      const response = await authorizedRequest(`/v1/devices/${normalizedDeviceID}`, {
        method: "POST",
        headers: { "Idempotency-Key": normalizedIdempotencyKey(idempotencyKey) },
        body: JSON.stringify({ publicKey: normalizeTeamDevicePublicKey(publicKey) }),
      });
      const result = await responseJSON(response, "device_approval_failed");
      if (!response.ok || result.approved !== true
        || normalizedUUID(result.deviceID, "device_approval_failed") !== normalizedDeviceID) {
        throw new Error("device_approval_failed");
      }
      return { approved: true, deviceID: normalizedDeviceID };
    },

    async bootstrapDeviceKey({ password, publicKey, idempotencyKey }) {
      if (!currentDeviceID) throw new Error("authentication_required");
      const response = await authorizedRequest("/v1/devices/bootstrap-key", {
        method: "POST",
        headers: { "Idempotency-Key": normalizedIdempotencyKey(idempotencyKey) },
        body: JSON.stringify({
          password: String(password ?? ""),
          publicKey: normalizeTeamDevicePublicKey(publicKey),
        }),
      });
      const result = await responseJSON(response, "device_key_bootstrap_failed");
      if (!response.ok || result.approved !== true || typeof result.bootstrapped !== "boolean"
        || normalizedUUID(result.deviceID, "device_key_bootstrap_failed") !== currentDeviceID) {
        throw new Error("device_key_bootstrap_failed");
      }
      return { approved: true, deviceID: currentDeviceID, bootstrapped: result.bootstrapped };
    },

    async listTeamKeyDevices(scope) {
      const normalized = normalizeTeamVaultScope(scope);
      const response = await authorizedRequest(
        `/v1/teams/${normalized.teamID}/vaults/${normalized.vaultID}/key-devices`,
      );
      if (!response.ok) throw new Error("team_key_devices_failed");
      return normalizedTeamKeyDevices(
        await responseJSON(response, "team_key_devices_failed"),
        normalized,
      );
    },

    async getTeamVault(scope) {
      const normalized = normalizeTeamVaultScope(scope);
      const response = await authorizedRequest(
        `/v1/teams/${normalized.teamID}/vaults/${normalized.vaultID}`,
      );
      if (!response.ok) throw new Error("team_vault_download_failed");
      return normalizedRemoteTeamVault(
        await responseJSON(response, "team_vault_download_failed"),
        normalized,
      );
    },

    async putTeamVault(scope, envelope, idempotencyKey) {
      const normalized = normalizeTeamVaultScope(scope);
      const response = await authorizedRequest(
        `/v1/teams/${normalized.teamID}/vaults/${normalized.vaultID}`,
        {
          method: "PUT",
          headers: { "Idempotency-Key": normalizedIdempotencyKey(idempotencyKey) },
          body: JSON.stringify(normalizedTeamEnvelope(envelope)),
        },
      );
      const result = await responseJSON(response, "team_vault_upload_failed");
      if (response.status === 409) {
        if (result.conflict !== true || !Number.isSafeInteger(result.revision) || result.revision < 0
          || !Number.isSafeInteger(result.keyGeneration) || result.keyGeneration < 1) {
          throw new Error("team_vault_upload_failed");
        }
        return { conflict: true, revision: result.revision, keyGeneration: result.keyGeneration };
      }
      if (!response.ok || result.conflict !== false
        || !Number.isSafeInteger(result.revision) || result.revision < 1
        || !Number.isSafeInteger(result.keyGeneration) || result.keyGeneration < 1
        || typeof result.rotationCompleted !== "boolean") {
        throw new Error("team_vault_upload_failed");
      }
      return {
        conflict: false,
        revision: result.revision,
        keyGeneration: result.keyGeneration,
        rotationCompleted: result.rotationCompleted,
      };
    },

    async grantTeamVaultWrapper(scope, { keyGeneration, wrapper }, idempotencyKey) {
      const normalized = normalizeTeamVaultScope(scope);
      if (!Number.isSafeInteger(keyGeneration) || keyGeneration < 1) throw new Error("invalid_key_generation");
      const normalizedWrapper = normalizedTeamWrapper(wrapper);
      const response = await authorizedRequest(
        `/v1/teams/${normalized.teamID}/vaults/${normalized.vaultID}/wrappers`,
        {
          method: "POST",
          headers: { "Idempotency-Key": normalizedIdempotencyKey(idempotencyKey) },
          body: JSON.stringify({ keyGeneration, wrapper: normalizedWrapper }),
        },
      );
      const result = await responseJSON(response, "team_vault_wrapper_grant_failed");
      if (!response.ok || result.granted !== true || result.keyGeneration !== keyGeneration
        || normalizedUUID(result.deviceID, "team_vault_wrapper_grant_failed") !== normalizedWrapper.deviceID) {
        throw new Error("team_vault_wrapper_grant_failed");
      }
      return { granted: true, keyGeneration, deviceID: normalizedWrapper.deviceID };
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
