// Dormant V2 policy vocabulary. Bit 1 is ViewMetadata for Credential.
export const permissionBits = Object.freeze({
  View: 1, Reveal: 2, Edit: 4, ManageAccess: 8, Create: 16, Manage: 32,
});

const allowedMasks = Object.freeze({
  HOST: 13, CREDENTIAL: 15, SNIPPET: 13,
  FORWARDING: 9, FOLDER: 33, VAULT: 29,
});

export function validateGrant(kind, mask) {
  const allowed = allowedMasks[kind];
  if (allowed === undefined) throw new Error("invalid_policy_kind");
  if (!Number.isSafeInteger(mask) || mask <= 0 || (mask & ~allowed) !== 0) {
    throw new Error("invalid_grant_permission");
  }
  if (kind === "CREDENTIAL" && (mask & permissionBits.Edit) !== 0
    && (mask & permissionBits.Reveal) === 0) {
    throw new Error("credential_edit_requires_reveal");
  }
  return mask;
}

export function inheritedViewBit(kind) {
  if (!["HOST", "CREDENTIAL", "SNIPPET", "FORWARDING", "FOLDER"].includes(kind)) {
    throw new Error("invalid_policy_kind");
  }
  return permissionBits.View;
}

export function evaluateAccessPaths({ kind, paths, cryptoStatus = "NO",
  requiresCrypto = false }) {
  if (allowedMasks[kind] === undefined || !Array.isArray(paths)
    || !["NO", "WRAP_PRESENT_UNVERIFIED"].includes(cryptoStatus)) {
    throw new Error("invalid_access_evaluation");
  }
  let policyMask = 0;
  const contributing = [];
  for (const path of paths) {
    let mask;
    if (path.sourceType === "DIRECT") {
      try { mask = validateGrant(kind, path.mask); }
      catch { throw new Error("invalid_persisted_grant"); }
    } else if (path.sourceType === "INHERITED_CONTAINER") {
      if (!Number.isSafeInteger(path.mask) || (path.mask & permissionBits.View) === 0) {
        throw new Error("invalid_persisted_grant");
      }
      mask = inheritedViewBit(kind);
    } else {
      throw new Error("invalid_persisted_grant");
    }
    policyMask |= mask;
    const permissions = Object.entries(permissionBits)
      .filter(([, bit]) => (mask & bit) !== 0)
      .map(([name]) => name === "View" && kind === "CREDENTIAL"
        ? "ViewMetadata" : name);
    contributing.push({ ...path, effectiveMask: mask, permissions,
      permission: permissions.length === 1 ? permissions[0] : undefined });
  }
  const policyAllowed = policyMask !== 0;
  let effectiveUsable = "NO";
  if (policyAllowed) {
    if (!requiresCrypto) {
      effectiveUsable = "YES";
    } else if (cryptoStatus === "WRAP_PRESENT_UNVERIFIED") {
      effectiveUsable = "UNKNOWN";
    }
  }
  return { policyAllowed, policyMask, cryptoAvailable: cryptoStatus,
    effectiveUsable, paths: contributing,
    blockedReasons: !policyAllowed ? ["POLICY_DENIED"]
      : effectiveUsable === "NO" && requiresCrypto ? ["KEY_UNAVAILABLE"] : [] };
}

export function requiredCryptoParts(kind, mask) {
  validateGrant(kind, mask);
  if (kind === "CREDENTIAL") {
    const parts = [];
    if ((mask & permissionBits.View) !== 0) parts.push("METADATA");
    if ((mask & (permissionBits.Reveal | permissionBits.Edit)) !== 0) parts.push("SECRET");
    return parts;
  }
  if (["HOST", "SNIPPET", "FORWARDING"].includes(kind)
    && (mask & (permissionBits.View | permissionBits.Edit)) !== 0) {
    return ["GENERAL"];
  }
  return [];
}
