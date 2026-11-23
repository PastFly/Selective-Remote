// Whole-Vault writers must use an explicit protocol frame. This is only one
// part of the cutover: old server processes must be drained and rollback fenced.
export const v1WriteFenceHeader = "x-selective-v1-write-fence";
export const v1WriteFenceValue = "1";
export const v1WriteProtocol = "framed-v1";
export const personalVaultPilotHeader = "X-Selective-Personal-Vault-Write-Status";
export const personalVaultPilotValue = "pilot";
const personalVaultWriterHeader = "x-selective-personal-vault-writer";
const personalVaultWriterVersion = "migration-checkpoint-v1";

export function v1WriteRequiresFence(method, path) {
  return method === "PUT" && (path === "/v1/vault"
    || /^\/v1\/teams\/[^/]+\/vaults\/[^/]+$/iu.test(path));
}

export function v1WriteFenceAccepted(headers, path) {
  return headers?.[v1WriteFenceHeader] === v1WriteFenceValue
    && (path !== "/v1/vault" || headers[personalVaultWriterHeader] === personalVaultWriterVersion);
}

export function isPrivatePersonalPilotEnvironment(config) {
  return config.publication.environment === "staging" && !config.allowRegistration
    && !config.publication.enabled && !config.wholePublication.enabled
    && new URL(config.publicOrigin).protocol === "https:";
}

export function personalWritePilotIsCurrent(pilot, now = Date.now()) {
  return Boolean(pilot && pilot.issuedAt <= now && now < pilot.expiresAt);
}

export function unwrapV1Write(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || Object.keys(value).sort().join(",") !== "envelope,protocol"
      || value.protocol !== v1WriteProtocol || !value.envelope
      || typeof value.envelope !== "object" || Array.isArray(value.envelope)) {
    throw Error("invalid_vault_envelope");
  }
  return value.envelope;
}
