// Capability names are reserved for the later v2 rollout; this foundation
// cannot activate resource_acl_v2 or serve resource ciphertext.
export const vaultFormatStates = Object.freeze([
  "V1_ACTIVE", "V2_PREPARING", "V2_READY", "V2_ACTIVE",
]);
export const vaultCapabilityNames = Object.freeze([
  "resource_registry_v2", "resource_acl_v2",
]);

export function vaultFoundationCapabilities({ session, formatState, formatSchemaVersion,
  registryRouteEligible = false }) {
  if (!session?.user_id || !session?.device_id) throw new Error("authentication_required");
  if (!vaultFormatStates.includes(formatState)) throw new Error("invalid_vault_format_state");
  if (formatSchemaVersion !== (formatState === "V1_ACTIVE" ? 1 : 2)) {
    throw new Error("invalid_vault_format_schema");
  }
  return Object.freeze({
    formatState,
    legacyWholeVault: formatState === "V1_ACTIVE",
    resource_registry_v2: formatState === "V2_PREPARING" && registryRouteEligible === true,
    resource_acl_v2: false,
  });
}
