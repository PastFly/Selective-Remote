import {
  accessID,
  accessVersion,
  normalizeMutation,
  RESOURCE_MASKS,
} from "./access-model.js";
export class AccessError extends Error {
  constructor(code, status = 0, metadata = {}) {
    super(code);
    this.name = "AccessError";
    this.code = code;
    this.status = status;
    if (metadata.safeCount === "1001+") this.safeCount = metadata.safeCount;
  }
}
const invalid = () => {
  throw new AccessError("invalid_access_response");
};
const scopeMismatch = () => {
  throw new AccessError("access_scope_mismatch");
};
const number = (value) => {
  if (!Number.isSafeInteger(value) || value < 0) invalid();
  return value;
};
function policy(value) {
  if (
    typeof value?.policyAllowed !== "boolean" ||
    !Array.isArray(value.paths) ||
    !Array.isArray(value.blockedReasons)
  )
    invalid();
  number(value.policyMask);
  return {
    ...value,
    paths: value.paths.map((p) => {
      if (
        !["USER", "GROUP"].includes(p.principalKind) ||
        !["VAULT", "FOLDER", "RESOURCE"].includes(p.grantTargetKind) ||
        !["DIRECT", "INHERITED_CONTAINER"].includes(p.sourceType) ||
        !Array.isArray(p.permissions)
      )
        invalid();
      return {
        ...p,
        id: accessID(p.id),
        principalID: accessID(p.principalID),
        grantTargetID: accessID(p.grantTargetID),
        mask: number(p.mask),
        effectiveMask: number(p.effectiveMask),
      };
    }),
  };
}
function pagination(options = {}) {
  const limit = options.limit ?? 50;
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 50)
    throw new AccessError("invalid_access_page");
  const q = new URLSearchParams({ limit: String(limit) });
  if (options.cursor != null) q.set("cursor", accessID(options.cursor));
  if (options.search) {
    if (typeof options.search !== "string" || options.search.length > 120)
      throw new AccessError("invalid_access_page");
    q.set("search", options.search);
  }
  return q;
}
export function createAccessClient({
  request,
  currentUserID,
  currentDeviceID,
} = {}) {
  if (typeof request !== "function")
    throw new Error("invalid_access_transport");
  const current = (value) => (typeof value === "function" ? value() : value);
  const base = (s) =>
    `/v1/teams/${accessID(s.teamID)}/vaults/${accessID(s.vaultID)}`;
  async function json(path, options) {
    const response = await request(path, options);
    let result;
    try {
      result = await response.json();
    } catch {
      invalid();
    }
    if (!response.ok)
      throw new AccessError(
        response.status === 401
          ? "authentication_required"
          : typeof result?.error === "string"
            ? result.error
            : "access_request_failed",
        response.status,
        result,
      );
    return result;
  }
  async function page(path, options, transform, key = "rows") {
    const result = await json(`${path}?${pagination(options)}`);
    if (
      !Array.isArray(result?.[key]) ||
      result[key].length > (options?.limit ?? 50)
    )
      invalid();
    const nextCursor =
      result.nextCursor === null ? null : accessID(result.nextCursor);
    return {
      rows: result[key].map(transform),
      nextCursor,
      ...(key === "members" ? { total: number(result.total) } : {}),
    };
  }
  function scoped(row, s) {
    if (
      accessID(row.teamID ?? row.team_id) !== accessID(s.teamID) ||
      (s.vaultID &&
        accessID(row.vaultID ?? row.vault_id) !== accessID(s.vaultID))
    )
      scopeMismatch();
    return row;
  }
  const group = (r, teamID) => ({
    ...scoped(r, { teamID }),
    id: accessID(r.id),
    version: accessVersion(r.version),
  });
  const resource = (r, s) => {
    scoped(r, s);
    if (!Object.hasOwn(RESOURCE_MASKS, r.policyKind)) invalid();
    return {
      ...r,
      id: accessID(r.id),
      teamID: accessID(r.teamID),
      vaultID: accessID(r.vaultID),
      parentFolderID:
        r.parentFolderID === null ? null : accessID(r.parentFolderID),
      resourceVersion: accessVersion(r.resourceVersion),
    };
  };
  return {
    identity() {
      return {
        userID: current(currentUserID),
        deviceID: current(currentDeviceID),
      };
    },
    listVaults(teamID, options = {}) {
      return page(
        `/v1/teams/${accessID(teamID)}/access-vaults`,
        options,
        (r) => {
          scoped(r, { teamID });
          if (
            !["V1_ACTIVE", "V2_PREPARING", "V2_READY", "V2_ACTIVE"].includes(
              r.formatState,
            ) ||
            typeof r.name !== "string"
          )
            invalid();
          return { ...r, id: accessID(r.id) };
        },
      );
    },
    async getContext(s) {
      const r = await json(`${base(s)}/access-context`);
      if (
        !["V1_ACTIVE", "V2_PREPARING", "V2_READY", "V2_ACTIVE"].includes(
          r?.formatState,
        ) ||
        typeof r.policyMutationAvailable !== "boolean" ||
        typeof r.groupMutationAvailable !== "boolean" ||
        !Array.isArray(r.blockers)
      )
        invalid();
      return r;
    },
    listMembers(teamID, options = {}) {
      const search = options.search ?? "";
      if (typeof search !== "string" || search.length > 120)
        throw new AccessError("invalid_access_page");
      const query = Object.assign({}, options);
      const path = `/v1/teams/${accessID(teamID)}/members`;
      return page(
        path,
        { ...query },
        (r) => {
          if (
            !["owner", "admin", "editor", "viewer"].includes(r.role) ||
            typeof r.displayName !== "string" ||
            typeof r.username !== "string"
          )
            invalid();
          return {
            ...r,
            id: accessID(r.id),
            userID: accessID(r.userID),
            epoch: accessVersion(r.epoch),
          };
        },
        "members",
      );
    },
    async listGroups(teamID, options = {}) {
      const q = pagination(options);
      if (options.search) {
        if (typeof options.search !== "string" || options.search.length > 120)
          throw new AccessError("invalid_access_page");
        q.set("search", options.search);
      }
      const r = await json(`/v1/teams/${accessID(teamID)}/access-groups?${q}`);
      if (!Array.isArray(r.rows) || r.rows.length > (options.limit ?? 50))
        invalid();
      return {
        rows: r.rows.map((row) => group(row, teamID)),
        nextCursor: r.nextCursor === null ? null : accessID(r.nextCursor),
      };
    },
    listGroupMembers(teamID, groupID, options = {}) {
      return page(
        `/v1/teams/${accessID(teamID)}/access-groups/${accessID(groupID)}/members`,
        options,
        (r) => {
          if (accessID(r.groupID) !== accessID(groupID)) scopeMismatch();
          return {
            ...r,
            id: accessID(r.id),
            userID: accessID(r.userID),
            membershipID: accessID(r.membershipID),
            membershipEpoch: accessVersion(r.membershipEpoch),
            version: accessVersion(r.version),
          };
        },
      );
    },
    async listResources(s, options = {}) {
      const q = pagination(options);
      if (options.kind) {
        if (!Object.hasOwn(RESOURCE_MASKS, options.kind))
          throw new AccessError("invalid_access_kind");
        q.set("kind", options.kind);
      }
      const r = await json(`${base(s)}/access-resources?${q}`);
      if (!Array.isArray(r.rows) || r.rows.length > (options.limit ?? 50))
        invalid();
      return {
        rows: r.rows.map((row) => resource(row, s)),
        nextCursor: r.nextCursor === null ? null : accessID(r.nextCursor),
      };
    },
    listGrants(s, options = {}) {
      return page(`${base(s)}/access-grants`, options, (r) => {
        if (
          !["USER", "GROUP"].includes(r.principal_kind) ||
          !["VAULT", "FOLDER", "RESOURCE"].includes(r.target_kind)
        )
          invalid();
        return {
          ...r,
          id: accessID(r.id),
          principal_id: accessID(r.principal_id),
          target_id: accessID(r.target_id),
          permission_mask: number(r.permission_mask),
          version: accessVersion(r.version),
        };
      });
    },
    whoHas(s, resourceID, options = {}) {
      return page(
        `${base(s)}/who-has-access/${accessID(resourceID)}`,
        options,
        (r) => ({
          ...r,
          userID: accessID(r.userID),
          policyEffective: policy(r.policyEffective),
        }),
      );
    },
    resourcesByPrincipal(s, kind, id, options = {}) {
      if (!["USER", "GROUP"].includes(kind))
        throw new AccessError("invalid_access_request");
      return page(
        `${base(s)}/resources-by-principal/${kind}/${accessID(id)}`,
        options,
        (r) => ({
          ...r,
          resourceID: accessID(r.resourceID),
          policyEffective: policy(r.policyEffective),
        }),
      );
    },
    listDevices(s, subjectUserID, options = {}) {
      const path = `${base(s)}/access-devices`;
      const q = pagination(options);
      q.set("subjectUserID", accessID(subjectUserID, "invalid_access_subject"));
      return json(`${path}?${q}`).then((r) => {
        if (!Array.isArray(r.rows) || r.rows.length > (options.limit ?? 50))
          invalid();
        return {
          rows: r.rows.map((d) => {
            if (
              typeof d.admitted !== "boolean" ||
              typeof d.name !== "string" ||
              typeof d.platform !== "string"
            )
              invalid();
            return { ...d, id: accessID(d.id) };
          }),
          nextCursor: r.nextCursor === null ? null : accessID(r.nextCursor),
        };
      });
    },
    async effective(s, resourceID, subjectUserID, subjectDeviceID) {
      const q = new URLSearchParams({
        subjectUserID: accessID(subjectUserID, "invalid_access_subject"),
        subjectDeviceID: accessID(subjectDeviceID, "invalid_access_device"),
      });
      const r = await json(
        `${base(s)}/effective-access/${accessID(resourceID)}?${q}`,
      );
      const d = r.deviceUsability;
      if (!d || accessID(d.deviceID) !== accessID(subjectDeviceID))
        scopeMismatch();
      if (!["YES", "NO", "UNKNOWN"].includes(d.effectiveUsable)) invalid();
      return { ...r, policyEffective: policy(r.policyEffective) };
    },
    async preview(s, input, cursor = null) {
      const normalized = normalizeMutation(input);
      if (
        cursor !== null &&
        (!/^\d{1,4}$/u.test(String(cursor)) || Number(cursor) > 1000)
      )
        throw new AccessError("invalid_access_page");
      const r = await json(
        `${base(s)}/${normalized.changes ? "access-preview" : "access-group-preview"}`,
        {
          method: "POST",
          body: JSON.stringify({
            request: normalized,
            ...(cursor !== null ? { cursor: String(cursor) } : {}),
          }),
        },
      );
      if (
        typeof r.token !== "string" ||
        !r.token ||
        !/^[0-9a-f]{64}$/u.test(r.snapshotID) ||
        !Array.isArray(r.details) ||
        r.details.length > 50 ||
        !r.counts ||
        (r.nextCursor !== null &&
          (!/^\d{1,4}$/u.test(r.nextCursor) ||
            Number(r.nextCursor) > 1000 ||
            Number(r.nextCursor) <= Number(cursor ?? 0)))
      )
        invalid();
      const details = r.details.map((d) => {
        if (normalized.changes && accessID(d.vaultID) !== accessID(s.vaultID))
          scopeMismatch();
        return {
          ...d,
          vaultID: accessID(d.vaultID),
          resourceID: accessID(d.resourceID),
          subjectUserID: accessID(d.subjectUserID),
          before: {
            ...d.before,
            policyEffective: policy(d.before?.policyEffective),
          },
          after: {
            ...d.after,
            policyEffective: policy(d.after?.policyEffective),
          },
          gainedMask: number(d.gainedMask),
          lostMask: number(d.lostMask),
        };
      });
      for (const key of ["pairs", "widened", "lost"]) number(r.counts[key]);
      if (r.counts.pairs > 1000) invalid();
      if (!normalized.changes) number(r.counts.affectedGrants);
      const affectedGrants = r.affectedGrants ?? [];
      if (!Array.isArray(affectedGrants) || affectedGrants.length > 50)
        invalid();
      return {
        ...r,
        details,
        affectedGrants: affectedGrants.map((g) => {
          if (!["VAULT", "FOLDER", "RESOURCE"].includes(g.targetKind))
            invalid();
          number(g.permissionMask);
          return {
            ...g,
            grantID: accessID(g.grantID),
            vaultID: accessID(g.vaultID),
            targetID: accessID(g.targetID),
            version: accessVersion(g.version),
          };
        }),
      };
    },
    async commit(s, input, token, idempotencyKey) {
      const normalized = normalizeMutation(input);
      if (
        typeof token !== "string" ||
        !token ||
        typeof idempotencyKey !== "string" ||
        !idempotencyKey
      )
        throw new AccessError("access_preview_conflict");
      const r = await json(
        `${base(s)}/${normalized.changes ? "access-commit" : "access-group-commit"}`,
        {
          method: "POST",
          headers: { "Idempotency-Key": idempotencyKey },
          body: JSON.stringify({ request: normalized, token }),
        },
      );
      if (!r || !Array.isArray(r.notificationCandidates)) invalid();
      r.notificationCandidates = r.notificationCandidates.map((candidate) => {
        if (
          normalized.changes &&
          candidate.vaultID &&
          accessID(candidate.vaultID) !== accessID(s.vaultID)
        )
          scopeMismatch();
        return {
          ...candidate,
          userID: accessID(candidate.userID),
          resourceID: accessID(candidate.resourceID),
          ...(candidate.vaultID
            ? { vaultID: accessID(candidate.vaultID) }
            : {}),
          gainedMask: number(candidate.gainedMask),
          lostMask: number(candidate.lostMask),
        };
      });
      if (
        normalized.type === "GROUP_CREATE" ||
        normalized.type === "GROUP_RENAME"
      ) {
        if (!r.group) invalid();
        if (normalized.groupID && accessID(r.group.id) !== normalized.groupID)
          scopeMismatch();
      }
      if (
        normalized.type === "GROUP_MEMBER_REMOVE" &&
        (!r.removed || accessID(r.edgeID) !== normalized.edgeID)
      )
        scopeMismatch();
      if (
        normalized.type === "GROUP_DELETE" &&
        (!r.deleted || accessID(r.groupID) !== normalized.groupID)
      )
        scopeMismatch();
      if (
        normalized.type === "GROUP_MEMBER_ADD" &&
        (!r.member ||
          accessID(r.member.group_id) !== normalized.groupID ||
          accessID(r.member.membership_id) !== normalized.targetMembershipID)
      )
        scopeMismatch();
      if (r.group) r.group = group(r.group, s.teamID);
      if (r.member)
        r.member = {
          ...r.member,
          id: accessID(r.member.id),
          group_id: accessID(r.member.group_id),
          user_id: accessID(r.member.user_id),
          membership_id: accessID(r.member.membership_id),
          membership_epoch: accessVersion(r.member.membership_epoch),
          version: accessVersion(r.member.version),
        };
      return r;
    },
  };
}
