// Resource ACL policy bits. These describe policy, never local key availability.
export const RESOURCE_MASKS = Object.freeze({
  HOST: 13,
  CREDENTIAL: 15,
  SNIPPET: 13,
  FORWARDING: 9,
  FOLDER: 33,
});
export const POLICY_MASKS = Object.freeze({ ...RESOURCE_MASKS, VAULT: 29 });
export function accessID(value, code = "invalid_access_id") {
  const id = typeof value === "string" ? value.toLowerCase() : "";
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(
      id,
    )
  )
    throw new Error(code);
  return id;
}
export function accessVersion(value) {
  if (typeof value !== "string" && typeof value !== "number")
    throw new Error("invalid_access_version");
  if (typeof value === "string" && !/^[1-9][0-9]*$/u.test(value))
    throw new Error("invalid_access_version");
  const n = Number(value);
  if (!Number.isSafeInteger(n) || n < 1)
    throw new Error("invalid_access_version");
  return n;
}
export function permissionsFor(kind) {
  if (!Object.hasOwn(POLICY_MASKS, kind))
    throw new Error("invalid_access_kind");
  return [
    { name: kind === "CREDENTIAL" ? "ViewMetadata" : "View", bit: 1 },
    ...(kind === "CREDENTIAL" ? [{ name: "Reveal", bit: 2 }] : []),
    ...(kind === "VAULT" ? [{ name: "Create", bit: 16 }] : []),
    ...(["HOST", "CREDENTIAL", "SNIPPET", "VAULT"].includes(kind)
      ? [{ name: "Edit", bit: 4 }]
      : []),
    {
      name: kind === "FOLDER" ? "Manage" : "ManageAccess",
      bit: kind === "FOLDER" ? 32 : 8,
    },
  ];
}
export function validateMask(kind, mask) {
  const allowed = POLICY_MASKS[kind];
  if (
    !allowed ||
    !Number.isSafeInteger(mask) ||
    mask < 1 ||
    mask & ~allowed ||
    (kind === "CREDENTIAL" && mask & 4 && !(mask & 2))
  )
    throw new Error("invalid_access_permissions");
  return mask;
}
export function presetMask(kind, preset) {
  permissionsFor(kind);
  if (preset === "view") return 1;
  if (preset === "edit")
    return validateMask(kind, kind === "CREDENTIAL" ? 7 : 5);
  if (preset === "manage") return POLICY_MASKS[kind];
  throw new Error("invalid_access_preset");
}
const groupFields = {
  GROUP_CREATE: ["name"],
  GROUP_RENAME: ["groupID", "expectedVersion", "name"],
  GROUP_DELETE: ["groupID", "expectedVersion"],
  GROUP_MEMBER_ADD: ["groupID", "targetMembershipID"],
  GROUP_MEMBER_REMOVE: ["groupID", "edgeID", "expectedVersion"],
};
const changeFields = {
  GRANT_CREATE: [
    "principalKind",
    "principalID",
    "targetKind",
    "targetID",
    "permissionMask",
  ],
  GRANT_CHANGE: ["grantID", "expectedVersion", "permissionMask"],
  GRANT_REVOKE: ["grantID", "expectedVersion"],
  RESOURCE_MOVE: ["resourceID", "newParentFolderID", "expectedResourceVersion"],
};
function normalizeOperation(value, fields) {
  if (!value || !Object.hasOwn(fields, value.type))
    throw new Error("invalid_access_request");
  const keys = ["type", ...fields[value.type]];
  if (
    Object.keys(value).some((k) => !keys.includes(k)) ||
    keys.some((k) => !Object.hasOwn(value, k))
  )
    throw new Error("invalid_access_request");
  const out = { ...value };
  for (const k of keys) {
    if (k.endsWith("ID") && out[k] !== null) out[k] = accessID(out[k]);
    if (k === "expectedVersion" || k === "expectedResourceVersion")
      out[k] = accessVersion(out[k]);
  }
  if (keys.includes("name")) {
    if (
      typeof out.name !== "string" ||
      !out.name.trim() ||
      out.name.length > 120 ||
      /[\u0000-\u001f\u007f]/u.test(out.name)
    )
      throw new Error("invalid_access_group_name");
    out.name = out.name.trim();
  }
  if (
    keys.includes("permissionMask") &&
    (!Number.isSafeInteger(out.permissionMask) ||
      out.permissionMask < 1 ||
      out.permissionMask > 63)
  )
    throw new Error("invalid_access_permissions");
  if (
    (keys.includes("principalKind") &&
      !["USER", "GROUP"].includes(out.principalKind)) ||
    (keys.includes("targetKind") &&
      !["VAULT", "FOLDER", "RESOURCE"].includes(out.targetKind))
  )
    throw new Error("invalid_access_request");
  if (
    keys.some(
      (k) => k.endsWith("ID") && out[k] === null && k !== "newParentFolderID",
    )
  )
    throw new Error("invalid_access_request");
  return out;
}
export function normalizeMutation(request) {
  if (request && Object.hasOwn(request, "changes")) {
    if (
      Object.keys(request).some((k) => k !== "changes") ||
      !Array.isArray(request.changes) ||
      !request.changes.length
    )
      throw new Error("invalid_access_request");
    if (request.changes.length > 50) throw new Error("access_batch_too_large");
    const changes = request.changes.map((c) =>
      normalizeOperation(c, changeFields),
    );
    const principals = new Set(
      changes
        .filter((c) => c.principalID)
        .map((c) => `${c.principalKind}:${c.principalID}`),
    );
    if (principals.size > 20) throw new Error("access_batch_too_large");
    const identities = changes.map(
      (c) =>
        c.grantID ||
        c.resourceID ||
        `${c.principalKind}:${c.principalID}:${c.targetKind}:${c.targetID}`,
    );
    if (new Set(identities).size !== changes.length)
      throw new Error("invalid_access_request");
    return { changes };
  }
  return normalizeOperation(request, groupFields);
}
export function accessLabel(ref, resolveLabel = () => null, kindLabel = (kind) => kind) {
  // The resolver's contract is authorized scoped local V2 decryption. No V1 document is consulted.
  const value = resolveLabel(Object.freeze({ ...ref }));
  return typeof value === "string" && value.trim()
    ? value
    : `${kindLabel(ref.policyKind ?? ref.kind ?? "RESOURCE")} · ${ref.id ?? ref.resourceID}`;
}
export function effectiveSummary(value) {
  return {
    allowed: value?.policyEffective?.policyAllowed === true,
    mask: value?.policyEffective?.policyMask ?? 0,
    paths: value?.policyEffective?.paths ?? [],
    usable: value?.deviceUsability?.effectiveUsable ?? "UNKNOWN",
    blockedReasons: [
      ...(value?.policyEffective?.blockedReasons ?? []),
      ...(value?.deviceUsability?.blockedReasons ?? []),
    ],
  };
}
