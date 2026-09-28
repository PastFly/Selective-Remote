// Local, allowlisted projection of current source problems. No Vault data enters this module.
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const kinds = new Set(["deviceApproval", "invitation", "syncError", "conflict", "failClosed", "wrapperIssue"]);
const fixedSources = new Set(["personal", "team"]);
const maxSourceItems = 1_000;
const maxPersistedItems = 5_000;
const maxResolvedItems = 100;
const resolvedLifetime = 30 * 24 * 60 * 60 * 1_000;

function validGroup(group) {
  return group === "devices" || group === "invitations"
    || group === "sync:personal" || (typeof group === "string" && group.startsWith("sync:team:")
      && uuid.test(group.slice("sync:team:".length)));
}

function validObservation(group, value, recipient) {
  if (!kinds.has(value?.kind) || !uuid.test(value.scopeID)
    || !(uuid.test(value.sourceID) || fixedSources.has(value.sourceID))) return false;
  if (group === "devices") return value.kind === "deviceApproval"
    && value.scopeID.toLowerCase() === recipient.toLowerCase();
  if (group === "invitations") return value.kind === "invitation";
  if (group === "sync:personal") return value.scopeID.toLowerCase() === recipient.toLowerCase()
    && value.sourceID === "personal" && ["syncError", "conflict"].includes(value.kind);
  if (group.startsWith("sync:team:")) return value.scopeID.toLowerCase() === group.slice(10).toLowerCase()
    && ["syncError", "conflict", "failClosed", "wrapperIssue"].includes(value.kind);
  return false;
}

function validTime(value) {
  return typeof value === "string" && Number.isFinite(Date.parse(value)) && value.length <= 32;
}

function safeItem(value, recipient) {
  if (!value || typeof value !== "object" || !uuid.test(value.id)
    || value.recipient !== recipient || !validGroup(value.group)
    || !validObservation(value.group, value, recipient)
    || !validTime(value.createdAt) || !validTime(value.lastObservedAt)
    || (value.readAt !== null && !validTime(value.readAt))
    || (value.resolvedAt !== null && !validTime(value.resolvedAt))) return null;
  return { id: value.id, recipient, group: value.group, kind: value.kind,
    scopeID: value.scopeID, sourceID: value.sourceID, createdAt: value.createdAt,
    lastObservedAt: value.lastObservedAt, readAt: value.readAt, resolvedAt: value.resolvedAt };
}

export function createNotificationState(recipient, serialized = null) {
  if (!uuid.test(recipient)) throw new TypeError("invalid notification recipient");
  let parsed;
  try { parsed = typeof serialized === "string" ? JSON.parse(serialized) : null; } catch { parsed = null; }
  const items = typeof serialized === "string" && serialized.length <= 2_000_000 &&
    parsed?.recipient === recipient && Array.isArray(parsed.items) &&
    parsed.items.length <= maxPersistedItems
    ? parsed.items.map((item) => safeItem(item, recipient)).filter(Boolean)
    : [];
  return { recipient, items, sequenceByGroup: {} };
}

export function reconcileNotifications(state, { group, observations = [], complete = false, at, sequence }) {
  if (!validGroup(group) || !validTime(at) || !Array.isArray(observations)) return state;
  const sequenced = Number.isSafeInteger(sequence) && sequence > 0;
  if (sequenced && sequence <= (state.sequenceByGroup?.[group] ?? 0)) return state;
  const sequenceByGroup = { ...state.sequenceByGroup };
  if (sequenced) sequenceByGroup[group] = sequence;
  const next = state.items.map((item) => ({ ...item }));
  const seen = new Set();
  const indexed = new Map(next.filter((item) => item.group === group)
    .map((item) => [`${item.kind}:${item.scopeID.toLowerCase()}:${item.sourceID.toLowerCase()}`, item]));
  for (const observation of observations.slice(0, maxSourceItems)) {
    if (!validObservation(group, observation, state.recipient)) continue;
    const key = `${observation.kind}:${observation.scopeID.toLowerCase()}:${observation.sourceID.toLowerCase()}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const existing = indexed.get(key);
    if (existing) {
      if (Date.parse(at) > Date.parse(existing.lastObservedAt)) existing.lastObservedAt = at;
      if (existing.resolvedAt !== null) { existing.resolvedAt = null; existing.readAt = null; }
    } else {
      if (next.length >= maxPersistedItems) continue;
      const item = { id: globalThis.crypto.randomUUID(), recipient: state.recipient, group,
        kind: observation.kind, scopeID: observation.scopeID, sourceID: observation.sourceID,
        createdAt: at, lastObservedAt: at, readAt: null, resolvedAt: null };
      next.push(item);
      indexed.set(key, item);
    }
  }
  if (complete) {
    for (const item of next) {
      if (item.group === group && item.resolvedAt === null &&
        !seen.has(`${item.kind}:${item.scopeID.toLowerCase()}:${item.sourceID.toLowerCase()}`)) item.resolvedAt = at;
    }
  }
  const cutoff = Date.parse(at) - resolvedLifetime;
  const active = next.filter((item) => item.resolvedAt === null);
  const resolved = next.filter((item) => item.resolvedAt !== null && Date.parse(item.resolvedAt) >= cutoff)
    .sort((a, b) => Date.parse(b.resolvedAt) - Date.parse(a.resolvedAt)).slice(0, maxResolvedItems);
  return { recipient: state.recipient, items: [...active, ...resolved], sequenceByGroup };
}

export function markNotificationRead(state, id, at) {
  if (!uuid.test(id) || !validTime(at)) return state;
  return { recipient: state.recipient, sequenceByGroup: state.sequenceByGroup,
    items: state.items.map((item) => item.id === id &&
    item.resolvedAt === null && item.readAt === null ? { ...item, readAt: at } : item) };
}

export function notificationCounts(state) {
  const active = state.items.filter((item) => item.resolvedAt === null);
  return { attentionCount: active.length, unreadCount: active.filter((item) => item.readAt === null).length };
}

export function notificationItems(state) {
  return [...state.items].sort((a, b) => (a.resolvedAt === null ? 0 : 1) -
    (b.resolvedAt === null ? 0 : 1) || Date.parse(b.lastObservedAt) - Date.parse(a.lastObservedAt));
}

export function serializeNotificationState(state) {
  return JSON.stringify({ recipient: state.recipient,
    items: state.items.map((item) => safeItem(item, state.recipient)).filter(Boolean) });
}

export function deviceNotificationObservations(devices, recipient) {
  if (!uuid.test(recipient) || !Array.isArray(devices)) return [];
  return devices.filter((device) => uuid.test(device?.id) && device.keyRegistered === true
    && device.keyApprovedAt === null && device.revokedAt === null)
    .slice(0, maxSourceItems)
    .map((device) => ({ kind: "deviceApproval", scopeID: recipient, sourceID: device.id }));
}

export function invitationNotificationObservations(invitations) {
  if (!Array.isArray(invitations)) return [];
  return invitations.filter((invitation) => uuid.test(invitation?.id) && uuid.test(invitation?.teamID))
    .slice(0, maxSourceItems)
    .map((invitation) => ({ kind: "invitation", scopeID: invitation.teamID, sourceID: invitation.id }));
}

export function syncNotificationDecision(snapshot, { scope, recipient, teamVaultID = null }) {
  if (!uuid.test(recipient)) return null;
  const personal = scope === "personal";
  if (!personal && (scope !== "team" || !uuid.test(teamVaultID))) return null;
  const group = personal ? "sync:personal" : `sync:team:${teamVaultID}`;
  const scopeID = personal ? recipient : teamVaultID;
  const sourceID = personal ? "personal" : teamVaultID;
  const empty = { group, complete: false, observations: [] };
  if (snapshot?.status === "current") return { group, complete: true, observations: [] };
  if (snapshot?.status === "conflict") return { group, complete: true,
    observations: [{ kind: "conflict", scopeID, sourceID }] };
  if (snapshot?.status === "error" && snapshot.issue === "wrapper_provisioning_failed" && !personal) {
    return { group, complete: true, observations: [{ kind: "wrapperIssue", scopeID, sourceID }] };
  }
  if (snapshot?.status === "error" && snapshot.issue !== "network_unavailable") {
    return { group, complete: true, observations: [{ kind: "syncError", scopeID, sourceID }] };
  }
  if (snapshot?.status === "attention") {
    const kind = snapshot.issue === "team_vault_key_unavailable" ? "wrapperIssue"
      : snapshot.issue === "team_vault_rotation_required" ? "failClosed"
        : snapshot.issue === "device_approval_required" ? "wrapperIssue" : null;
    if (kind && !personal) return { group, complete: true, observations: [{ kind, scopeID, sourceID }] };
  }
  return empty;
}
