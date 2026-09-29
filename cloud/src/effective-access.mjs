import { evaluateAccessPaths, permissionBits, validateGrant } from "./access-policy.mjs";

function requireValidAncestry(target, ancestors) {
  if (!target || target.deletedAt !== null || !Array.isArray(ancestors)) {
    throw new Error("invalid_access_ancestry");
  }
  let nextID = target.parentFolderID ?? null;
  const seen = new Set([target.id]);
  for (const ancestor of ancestors) {
    if (!nextID || ancestor.id !== nextID || seen.has(ancestor.id)
      || ancestor.kind !== "FOLDER" || ancestor.deletedAt !== null
      || ancestor.teamID !== target.teamID || ancestor.vaultID !== target.vaultID) {
      throw new Error("invalid_access_ancestry");
    }
    seen.add(ancestor.id);
    nextID = ancestor.parentFolderID ?? null;
  }
  if (nextID !== null) throw new Error("invalid_access_ancestry");
}

export function compileEffectiveAccess({ target, ancestors, membership, groupIDs = [],
  grants, cryptoStatus = "NO", requiresCrypto = true }) {
  requireValidAncestry(target, ancestors);
  if (!membership?.id || !membership?.userID || !Number.isSafeInteger(membership.epoch)
    || !Array.isArray(groupIDs) || !Array.isArray(grants)) {
    throw new Error("invalid_access_evaluation");
  }
  const ancestorIDs = new Set(ancestors.map((item) => item.id));
  const activeGroups = new Set(groupIDs);
  const paths = [];
  for (const grant of grants) {
    if (grant.revokedAt != null || grant.teamID !== target.teamID
      || grant.vaultID !== target.vaultID) continue;
    if (grant.principalKind === "USER") {
      if (grant.principalID !== membership.userID
        || grant.membershipID !== membership.id
        || Number(grant.membershipEpoch) !== membership.epoch) continue;
    } else if (grant.principalKind === "GROUP") {
      if (!activeGroups.has(grant.principalID)) continue;
    } else {
      throw new Error("invalid_persisted_grant");
    }
    const direct = grant.targetID === target.id
      && grant.targetKind === (target.kind === "FOLDER" ? "FOLDER" : "RESOURCE");
    const inherited = (grant.targetKind === "VAULT" && grant.targetID === target.vaultID)
      || (grant.targetKind === "FOLDER" && ancestorIDs.has(grant.targetID));
    if (!direct && !inherited) continue;
    if (inherited) {
      try { validateGrant(grant.targetKind, grant.mask); }
      catch { throw new Error("invalid_persisted_grant"); }
      if ((grant.mask & permissionBits.View) === 0) continue;
    }
    paths.push({ id: grant.id,
      principalKind: grant.principalKind, principalID: grant.principalID,
      grantTargetKind: grant.targetKind, grantTargetID: grant.targetID,
      sourceType: direct ? "DIRECT" : "INHERITED_CONTAINER", mask: grant.mask });
  }
  return evaluateAccessPaths({ kind: target.kind, paths, cryptoStatus, requiresCrypto });
}
