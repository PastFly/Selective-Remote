import { webcrypto, createHash } from "node:crypto";
import {
  canonicalMigrationJSON,
  migrationBytes,
  migrationHash,
  fromBase64,
} from "../public/vault-v2-migration.js";
import { compileEffectiveAccess } from "./effective-access.mjs";
import { validateGrant, requiredCryptoParts } from "./access-policy.mjs";
import { requireAccessMutation } from "./team-policy.mjs";
export { canonicalMigrationJSON, migrationHash };
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
export function validateMigrationResources(resources) {
  if (
    !Array.isArray(resources) ||
    resources.length < 1 ||
    resources.length > 1000
  )
    throw Error("invalid_migration_resources");
  const ids = new Map(),
    ordinals = new Set();
  for (const r of resources) {
    if (
      !r ||
      Object.keys(r).sort().join(",") !==
        "id,kind,parentFolderID,sourceOrdinal" ||
      !uuid.test(r.id) ||
      !["HOST", "CREDENTIAL", "SNIPPET", "FORWARDING", "FOLDER"].includes(
        r.kind,
      ) ||
      !Number.isSafeInteger(r.sourceOrdinal) ||
      r.sourceOrdinal < 0 ||
      ids.has(r.id) ||
      ordinals.has(r.sourceOrdinal)
    )
      throw Error("invalid_migration_resources");
    ids.set(r.id, r);
    ordinals.add(r.sourceOrdinal);
  }
  for (const r of resources) {
    let current = r;
    const seen = new Set([r.id]);
    while (current.parentFolderID !== null) {
      const parent = ids.get(current.parentFolderID);
      if (
        !parent ||
        parent.kind !== "FOLDER" ||
        seen.has(parent.id) ||
        seen.size > 33
      )
        throw Error("invalid_migration_resources");
      seen.add(parent.id);
      current = parent;
    }
  }
  return ids;
}
export function defaultMigrationPolicy({ resources, snapshot }) {
  const masks = {
    HOST: 13,
    CREDENTIAL: 15,
    SNIPPET: 13,
    FORWARDING: 9,
    FOLDER: 33,
  };
  return snapshot.memberships.flatMap((m) =>
    resources.map((r) => ({
      id: (() => {
        const h=createHash("sha256").update(`migration-policy:${snapshot.teamID}:${snapshot.vaultID}:${m.id}:${m.epoch}:${r.id}`).digest("hex");
        return `${h.slice(0,8)}-${h.slice(8,12)}-5${h.slice(13,16)}-a${h.slice(17,20)}-${h.slice(20,32)}`;
      })(),
      teamID: snapshot.teamID,
      vaultID: snapshot.vaultID,
      principalKind: "USER",
      principalID: m.userID,
      membershipID: m.id,
      membershipEpoch: m.epoch,
      targetKind: r.kind === "FOLDER" ? "FOLDER" : "RESOURCE",
      targetID: r.id,
      mask:
        m.role === "owner" || m.role === "admin"
          ? masks[r.kind]
          : r.kind === "CREDENTIAL"
            ? m.role === "editor"
              ? 7
              : 3
            : ["HOST", "SNIPPET"].includes(r.kind) && m.role === "editor"
              ? 5
              : 1,
      revokedAt: null,
    })),
  );
}
export function migrationRecipients({
  resources,
  policy,
  snapshot,
  actorRole = "owner",
  resourceIDs = null,
  effectiveMasks = null,
  requireDevices = true,
}) {
  const ids = validateMigrationResources(resources);
  requireAccessMutation(actorRole);
  if (
    !Array.isArray(policy) ||
    policy.length > 10000 ||
    !Array.isArray(snapshot.memberships) ||
    snapshot.memberships.length > 1000
  )
    throw Error("invalid_migration_policy");
  const grantIDs = new Set();
  for (const g of policy) {
    const keys = [
      "id",
      "teamID",
      "vaultID",
      "principalKind",
      "principalID",
      "targetKind",
      "targetID",
      "mask",
      "revokedAt",
      ...(g.principalKind === "USER"
        ? ["membershipID", "membershipEpoch"]
        : []),
    ];
    if (Object.keys(g).sort().join(",") !== keys.sort().join(","))
      throw Error("invalid_migration_policy");
    const target =
      g.targetKind === "VAULT" && g.targetID === snapshot.vaultID
        ? { kind: "VAULT" }
        : ids.get(g.targetID);
    if (
      !target ||
      g.teamID !== snapshot.teamID ||
      g.vaultID !== snapshot.vaultID ||
      !uuid.test(g.id) ||
      grantIDs.has(g.id) ||
      !["USER", "GROUP"].includes(g.principalKind) ||
      g.revokedAt !== null ||
      g.targetKind !==
        (target.kind === "VAULT"
          ? "VAULT"
          : target.kind === "FOLDER"
            ? "FOLDER"
            : "RESOURCE")
    )
      throw Error("invalid_migration_policy");
    grantIDs.add(g.id);
    validateGrant(target.kind, g.mask);
    if (g.principalKind === "USER") {
      const m = snapshot.memberships.find(
        (m) =>
          m.userID === g.principalID &&
          m.id === g.membershipID &&
          m.epoch === g.membershipEpoch,
      );
      if (!m) throw Error("invalid_migration_policy");
    } else if (!snapshot.groups.some((group) => group.id === g.principalID))
      throw Error("invalid_migration_policy");
  }
  const result = {};
  for (const r of resources.filter(
    (r) => !resourceIDs || resourceIDs.includes(r.id),
  )) {
    const target = {
        ...r,
        teamID: snapshot.teamID,
        vaultID: snapshot.vaultID,
        deletedAt: null,
      },
      ancestors = [];
    let next = r.parentFolderID;
    while (next) {
      const p = ids.get(next);
      ancestors.push({
        ...p,
        teamID: snapshot.teamID,
        vaultID: snapshot.vaultID,
        deletedAt: null,
      });
      next = p.parentFolderID;
    }
    const parts =
      r.kind === "CREDENTIAL" ? ["METADATA", "SECRET"] : ["GENERAL"];
    result[r.id] = Object.fromEntries(parts.map((p) => [p, []]));
    for (const m of snapshot.memberships) {
      const groupIDs = snapshot.edges
        .filter(
          (e) =>
            e.membershipID === m.id &&
            e.membershipEpoch === m.epoch &&
            e.userID === m.userID,
        )
        .map((e) => e.groupID);
      const access = compileEffectiveAccess({
        target,
        ancestors,
        membership: m,
        groupIDs,
        grants: policy,
      });
      if (effectiveMasks) effectiveMasks[`${m.id}:${r.id}`] = access.policyMask;
      if (actorRole === "admin" && ["owner", "admin"].includes(m.role)) {
        const allowed = {
          HOST: 13,
          CREDENTIAL: 15,
          SNIPPET: 13,
          FORWARDING: 9,
          FOLDER: 33,
        };
        if (access.policyMask !== allowed[r.kind])
          throw Error("team_access_denied");
      }
      const needed =
        access.policyMask === 0
          ? []
          : r.kind === "FOLDER"
            ? access.policyMask & 1
              ? ["GENERAL"]
              : []
            : requiredCryptoParts(r.kind, access.policyMask);
      if (!needed.length) continue;
      const devices = snapshot.devices.filter(
        (d) => d.membershipID === m.id && d.membershipEpoch === m.epoch,
      );
      if (requireDevices && !devices.length) throw Error("eligible_device_required");
      for (const part of needed) result[r.id][part].push(...devices);
    }
  }
  return result;
}
export async function verifyMigrationManifest({
  manifest,
  expected,
  rootPublicKey,
}) {
  const payload = {
    version: 2,
    scope: expected.scope,
    policyHash: await migrationHash(expected.policy),
    resources: expected.resources,
    parts: expected.parts,
  };
  if (
    canonicalMigrationJSON(manifest?.payload) !==
      canonicalMigrationJSON(payload) ||
    typeof manifest?.signature !== "string" ||
    manifest.signature.length !== 86
  )
    throw Error("invalid_migration_manifest");
  const key = await webcrypto.subtle.importKey(
    "raw",
    fromBase64(rootPublicKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  if (
    !(await webcrypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      fromBase64(manifest.signature),
      migrationBytes(payload),
    ))
  )
    throw Error("invalid_migration_manifest");
  return true;
}

// Pure proposal evaluation: no resource reservation, database mutation or notification.
export function previewMigrationPolicy({resources, policy, snapshot}) {
 const baseline = defaultMigrationPolicy({resources,snapshot});
 const before={}, after={};
 migrationRecipients({resources,policy:baseline,snapshot,effectiveMasks:before,requireDevices:false});
 const selected=policy??baseline;
 try {
  const recipients=migrationRecipients({resources,policy:selected,snapshot,actorRole:snapshot.actorRole,effectiveMasks:after});
  let wrapperCount=0,partCount=0;
  const blockers=[];
  for (const parts of Object.values(recipients)) for (const targets of Object.values(parts)) {
   partCount++;wrapperCount+=targets.length;
   if (!targets.length) blockers.push("migration_part_without_recipient");
   if (targets.length>100) blockers.push("recipient_limit");
  }
  const effectiveChanges=[];
  for (const m of snapshot.memberships) for (const r of resources) {
   const key=`${m.id}:${r.id}`, oldMask=before[key]??0,newMask=after[key]??0;
   if (oldMask!==newMask) effectiveChanges.push({userID:m.userID,membershipID:m.id,resourceID:r.id,beforeMask:oldMask,afterMask:newMask,removedMask:oldMask&~newMask,addedMask:newMask&~oldMask});
  }
  return {policy:selected,recipients,resourceCount:resources.length,partCount,wrapperCount,effectiveChanges,blockers:[...new Set(blockers)]};
 } catch(e) {
  if (!["invalid_migration_policy","invalid_grant_permission","invalid_permission_mask","team_access_denied","eligible_device_required"].includes(e.message)) throw e;
  return {blockers:[e.message],effectiveChanges:null,wrapperCount:null};
 }
}
