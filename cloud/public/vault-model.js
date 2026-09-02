export const vaultDocumentSchemaVersion = 1;

const recordTypes = new Set(["host", "credential", "snippet", "forwarding"]);
const exactUUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const forbiddenKeys = new Set(["__proto__", "constructor", "prototype"]);
const maxDocumentBytes = 24 * 1024 * 1024;
const maxEntities = 10_000;
const maxVersionDevices = 128;
const maxJSONNodes = 100_000;

function compareStrings(left, right) {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

function exactKeys(value, expected, code) {
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error(code);
  }
}

function normalizedUUID(value, code) {
  const normalized = String(value ?? "").toLowerCase();
  if (!exactUUID.test(normalized)) throw new Error(code);
  return normalized;
}

function normalizedTimestamp(value, code) {
  if (typeof value !== "string") throw new Error(code);
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.valueOf()) || parsed.toISOString() !== value) throw new Error(code);
  return value;
}

function normalizedJSON(value, depth = 0, budget = { remaining: maxJSONNodes }) {
  budget.remaining -= 1;
  if (budget.remaining < 0) throw new Error("invalid_record_data");
  if (depth > 32) throw new Error("invalid_record_data");
  if (value === null || typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("invalid_record_data");
    return value;
  }
  if (Array.isArray(value)) {
    if (value.length > maxEntities) throw new Error("invalid_record_data");
    return value.map((item) => normalizedJSON(item, depth + 1, budget));
  }
  if (!value || typeof value !== "object") throw new Error("invalid_record_data");
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) throw new Error("invalid_record_data");
  const keys = Object.keys(value).sort();
  if (keys.length > 1_000 || keys.some((key) => forbiddenKeys.has(key))) throw new Error("invalid_record_data");
  return Object.fromEntries(keys.map((key) => [key, normalizedJSON(value[key], depth + 1, budget)]));
}

function normalizedVersion(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid_record_version");
  const entries = Object.entries(value);
  if (entries.length < 1 || entries.length > maxVersionDevices) throw new Error("invalid_record_version");
  const result = {};
  for (const [deviceID, counter] of entries.sort(([left], [right]) => compareStrings(left, right))) {
    const normalizedDeviceID = normalizedUUID(deviceID, "invalid_record_version");
    if (!Number.isSafeInteger(counter) || counter < 1) throw new Error("invalid_record_version");
    result[normalizedDeviceID] = counter;
  }
  return result;
}

function normalizedRecord(value, budget = { remaining: maxJSONNodes }) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid_vault_record");
  exactKeys(value, ["id", "type", "version", "modifiedAt", "data"], "invalid_vault_record");
  if (!recordTypes.has(value.type)) throw new Error("invalid_record_type");
  return {
    id: normalizedUUID(value.id, "invalid_record_id"),
    type: value.type,
    version: normalizedVersion(value.version),
    modifiedAt: normalizedTimestamp(value.modifiedAt, "invalid_modified_at"),
    data: normalizedJSON(value.data, 0, budget),
  };
}

function normalizedTombstone(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid_vault_tombstone");
  exactKeys(value, ["id", "version", "deletedAt"], "invalid_vault_tombstone");
  return {
    id: normalizedUUID(value.id, "invalid_record_id"),
    version: normalizedVersion(value.version),
    deletedAt: normalizedTimestamp(value.deletedAt, "invalid_deleted_at"),
  };
}

function sortedDocument(records, tombstones) {
  return {
    schemaVersion: vaultDocumentSchemaVersion,
    records: [...records].sort((left, right) => compareStrings(left.id, right.id)),
    tombstones: [...tombstones].sort((left, right) => compareStrings(left.id, right.id)),
  };
}

function documentSize(document) {
  return new TextEncoder().encode(JSON.stringify(document)).length;
}

function checkedDocument(records, tombstones) {
  if (records.length + tombstones.length > maxEntities) throw new Error("vault_too_large");
  const ids = new Set();
  for (const entity of [...records, ...tombstones]) {
    if (ids.has(entity.id)) throw new Error("duplicate_record_id");
    ids.add(entity.id);
  }
  const document = sortedDocument(records, tombstones);
  if (documentSize(document) > maxDocumentBytes) throw new Error("vault_too_large");
  return document;
}

function incrementedVersion(value, deviceID) {
  const normalizedDeviceID = normalizedUUID(deviceID, "invalid_device");
  const current = value ? normalizedVersion(value) : {};
  const next = (current[normalizedDeviceID] ?? 0) + 1;
  if (!Number.isSafeInteger(next)) throw new Error("invalid_record_version");
  return Object.fromEntries(
    [...Object.entries(current), [normalizedDeviceID, next]]
      .reduce((entries, [key, counter]) => entries.set(key, counter), new Map())
      .entries(),
  );
}

function entityMap(document) {
  const result = new Map();
  for (const record of document.records) result.set(record.id, { kind: "record", value: record });
  for (const tombstone of document.tombstones) result.set(tombstone.id, { kind: "tombstone", value: tombstone });
  return result;
}

function vectorRelation(left, right) {
  const deviceIDs = new Set([...Object.keys(left), ...Object.keys(right)]);
  let leftAhead = false;
  let rightAhead = false;
  for (const deviceID of deviceIDs) {
    const comparison = (left[deviceID] ?? 0) - (right[deviceID] ?? 0);
    if (comparison > 0) leftAhead = true;
    if (comparison < 0) rightAhead = true;
  }
  if (leftAhead && rightAhead) return "concurrent";
  if (leftAhead) return "left";
  if (rightAhead) return "right";
  return "equal";
}

function canonicalEntity(entity) {
  return JSON.stringify(normalizedJSON(entity));
}

function mergedVersion(left, right, deviceID) {
  const combined = {};
  for (const key of new Set([...Object.keys(left), ...Object.keys(right)])) {
    combined[key] = Math.max(left[key] ?? 0, right[key] ?? 0);
  }
  return incrementedVersion(combined, deviceID);
}

function normalizedConflictEntity(entity, id) {
  if (!entity || typeof entity !== "object" || Array.isArray(entity)) throw new Error("invalid_vault_conflict");
  exactKeys(entity, ["kind", "value"], "invalid_vault_conflict");
  let value;
  if (entity.kind === "record") value = normalizedRecord(entity.value);
  else if (entity.kind === "tombstone") value = normalizedTombstone(entity.value);
  else throw new Error("invalid_vault_conflict");
  if (value.id !== id) throw new Error("invalid_vault_conflict");
  return { kind: entity.kind, value };
}

export function createEmptyVaultDocument() {
  return { schemaVersion: vaultDocumentSchemaVersion, records: [], tombstones: [] };
}

export function validateVaultDocument(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid_vault_document");
  exactKeys(value, ["schemaVersion", "records", "tombstones"], "invalid_vault_document");
  if (value.schemaVersion !== vaultDocumentSchemaVersion) throw new Error("invalid_vault_schema_version");
  if (!Array.isArray(value.records) || !Array.isArray(value.tombstones)) throw new Error("invalid_vault_document");
  if (value.records.length + value.tombstones.length > maxEntities) throw new Error("vault_too_large");
  const budget = { remaining: maxJSONNodes };
  return checkedDocument(
    value.records.map((record) => normalizedRecord(record, budget)),
    value.tombstones.map(normalizedTombstone),
  );
}

export function upsertVaultRecord(documentValue, {
  id,
  type,
  data,
  deviceID,
  modifiedAt = new Date().toISOString(),
  cryptoValue = globalThis.crypto,
}) {
  const document = validateVaultDocument(documentValue);
  const recordID = id === undefined
    ? normalizedUUID(cryptoValue?.randomUUID?.(), "invalid_record_id")
    : normalizedUUID(id, "invalid_record_id");
  const existing = entityMap(document).get(recordID);
  const version = incrementedVersion(existing?.value.version, deviceID);
  const record = normalizedRecord({ id: recordID, type, version, modifiedAt, data });
  const records = document.records.filter((value) => value.id !== recordID);
  const tombstones = document.tombstones.filter((value) => value.id !== recordID);
  records.push(record);
  return checkedDocument(records, tombstones);
}

export function deleteVaultRecord(documentValue, {
  id,
  deviceID,
  deletedAt = new Date().toISOString(),
}) {
  const document = validateVaultDocument(documentValue);
  const recordID = normalizedUUID(id, "invalid_record_id");
  const existing = entityMap(document).get(recordID);
  if (!existing || existing.kind !== "record") throw new Error("record_not_found");
  const tombstone = normalizedTombstone({
    id: recordID,
    version: incrementedVersion(existing.value.version, deviceID),
    deletedAt,
  });
  return checkedDocument(
    document.records.filter((value) => value.id !== recordID),
    [...document.tombstones, tombstone],
  );
}

export function mergeVaultDocuments(localValue, remoteValue) {
  const local = validateVaultDocument(localValue);
  const remote = validateVaultDocument(remoteValue);
  const localEntities = entityMap(local);
  const remoteEntities = entityMap(remote);
  const records = [];
  const tombstones = [];
  const conflicts = [];
  const ids = [...new Set([...localEntities.keys(), ...remoteEntities.keys()])].sort();

  for (const id of ids) {
    const localEntity = localEntities.get(id);
    const remoteEntity = remoteEntities.get(id);
    let selected = localEntity ?? remoteEntity;
    if (localEntity && remoteEntity) {
      const relation = vectorRelation(localEntity.value.version, remoteEntity.value.version);
      if (relation === "left") selected = localEntity;
      else if (relation === "right") selected = remoteEntity;
      else if (relation === "equal" && canonicalEntity(localEntity) === canonicalEntity(remoteEntity)) selected = localEntity;
      else {
        selected = null;
        conflicts.push({ id, local: localEntity, remote: remoteEntity });
      }
    }
    if (selected?.kind === "record") records.push(selected.value);
    if (selected?.kind === "tombstone") tombstones.push(selected.value);
  }

  return { document: checkedDocument(records, tombstones), conflicts };
}

export function resolveVaultConflict(documentValue, conflict, {
  choice,
  deviceID,
  resolvedAt = new Date().toISOString(),
}) {
  const document = validateVaultDocument(documentValue);
  if (!conflict || typeof conflict !== "object" || !["local", "remote"].includes(choice)) {
    throw new Error("invalid_vault_conflict");
  }
  const id = normalizedUUID(conflict.id, "invalid_vault_conflict");
  if (entityMap(document).has(id)) throw new Error("conflict_record_present");
  const local = normalizedConflictEntity(conflict.local, id);
  const remote = normalizedConflictEntity(conflict.remote, id);
  const selected = choice === "local" ? local : remote;
  const version = mergedVersion(
    normalizedVersion(local.value.version),
    normalizedVersion(remote.value.version),
    deviceID,
  );
  if (selected.kind === "record") {
    const record = normalizedRecord({ ...selected.value, version, modifiedAt: resolvedAt });
    return checkedDocument([...document.records, record], document.tombstones);
  }
  const tombstone = normalizedTombstone({ id, version, deletedAt: resolvedAt });
  return checkedDocument(document.records, [...document.tombstones, tombstone]);
}
