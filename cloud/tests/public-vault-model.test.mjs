import assert from "node:assert/strict";
import test from "node:test";
import {
  createEmptyVaultDocument,
  deleteVaultRecord,
  mergeVaultDocuments,
  resolveVaultConflict,
  upsertVaultRecord,
  validateVaultDocument,
} from "../public/vault-model.js";

const deviceA = "11111111-1111-4111-8111-111111111111";
const deviceB = "22222222-2222-4222-8222-222222222222";
const deviceC = "33333333-3333-4333-8333-333333333333";
const recordID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const firstTime = "2026-09-02T10:00:00.000Z";
const secondTime = "2026-09-02T11:00:00.000Z";
const thirdTime = "2026-09-02T12:00:00.000Z";

function host(document = createEmptyVaultDocument(), title = "Synthetic host", deviceID = deviceA, modifiedAt = firstTime) {
  return upsertVaultRecord(document, {
    id: recordID,
    type: "host",
    data: { hostname: "example.invalid", title },
    deviceID,
    modifiedAt,
  });
}

test("record CRUD is immutable and advances the editing device version", () => {
  const empty = createEmptyVaultDocument();
  const created = host(empty);
  const updated = host(created, "Updated synthetic host", deviceA, secondTime);

  assert.deepEqual(empty, { schemaVersion: 1, records: [], tombstones: [] });
  assert.equal(created.records[0].version[deviceA], 1);
  assert.equal(updated.records[0].version[deviceA], 2);
  assert.equal(updated.records[0].data.title, "Updated synthetic host");
  assert.equal(created.records[0].data.title, "Synthetic host");
});

test("deletion creates a dominating tombstone instead of erasing history", () => {
  const created = host();
  const deleted = deleteVaultRecord(created, { id: recordID, deviceID: deviceB, deletedAt: secondTime });

  assert.equal(deleted.records.length, 0);
  assert.deepEqual(deleted.tombstones[0].version, { [deviceA]: 1, [deviceB]: 1 });
  assert.equal(deleted.tombstones[0].deletedAt, secondTime);
});

test("a causally newer version wins without a conflict", () => {
  const first = host();
  const second = host(first, "Remote update", deviceB, secondTime);
  const result = mergeVaultDocuments(first, second);

  assert.equal(result.conflicts.length, 0);
  assert.deepEqual(result.document, second);
});

test("concurrent offline edits are surfaced and omitted from the merge preview", () => {
  const base = host();
  const local = host(base, "Local edit", deviceA, secondTime);
  const remote = host(base, "Remote edit", deviceB, secondTime);
  const result = mergeVaultDocuments(local, remote);

  assert.equal(result.document.records.length, 0);
  assert.equal(result.conflicts.length, 1);
  assert.equal(result.conflicts[0].local.value.data.title, "Local edit");
  assert.equal(result.conflicts[0].remote.value.data.title, "Remote edit");
});

test("conflict resolution joins both histories before recording the resolver edit", () => {
  const base = host();
  const local = host(base, "Local edit", deviceA, secondTime);
  const remote = host(base, "Remote edit", deviceB, secondTime);
  const merge = mergeVaultDocuments(local, remote);
  const resolved = resolveVaultConflict(merge.document, merge.conflicts[0], {
    choice: "remote",
    deviceID: deviceC,
    resolvedAt: thirdTime,
  });

  assert.equal(resolved.records[0].data.title, "Remote edit");
  assert.deepEqual(resolved.records[0].version, { [deviceA]: 2, [deviceB]: 1, [deviceC]: 1 });
  assert.equal(mergeVaultDocuments(resolved, local).conflicts.length, 0);
});

test("concurrent edit and deletion require an explicit resolution", () => {
  const base = host();
  const edited = host(base, "Edited offline", deviceA, secondTime);
  const deleted = deleteVaultRecord(base, { id: recordID, deviceID: deviceB, deletedAt: secondTime });
  const result = mergeVaultDocuments(edited, deleted);

  assert.equal(result.conflicts.length, 1);
  assert.equal(result.conflicts[0].local.kind, "record");
  assert.equal(result.conflicts[0].remote.kind, "tombstone");
});

test("validation rejects duplicate identities, unknown fields and unsafe record data", () => {
  const created = host();
  const unsafeData = Object.create(null);
  Object.defineProperty(unsafeData, "__proto__", { value: { polluted: true }, enumerable: true });
  assert.throws(
    () => validateVaultDocument({ ...created, tombstones: [{ id: recordID, version: { [deviceA]: 2 }, deletedAt: secondTime }] }),
    /duplicate_record_id/,
  );
  assert.throws(
    () => validateVaultDocument({ ...created, unexpected: true }),
    /invalid_vault_document/,
  );
  assert.throws(
    () => upsertVaultRecord(createEmptyVaultDocument(), {
      id: recordID,
      type: "host",
      data: unsafeData,
      deviceID: deviceA,
      modifiedAt: firstTime,
    }),
    /invalid_record_data/,
  );
  assert.throws(
    () => validateVaultDocument({ schemaVersion: 1, records: Array(10_001), tombstones: [] }),
    /vault_too_large/,
  );
  const oversizedData = Array.from({ length: 1_000 }, () => Array(101).fill(0));
  assert.throws(
    () => upsertVaultRecord(createEmptyVaultDocument(), {
      id: recordID,
      type: "host",
      data: { oversizedData },
      deviceID: deviceA,
      modifiedAt: firstTime,
    }),
    /invalid_record_data/,
  );
});

test("conflict-free merges are idempotent and order-independent", () => {
  const first = host();
  const second = upsertVaultRecord(first, {
    id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    type: "snippet",
    data: { body: "Synthetic snippet" },
    deviceID: deviceB,
    modifiedAt: secondTime,
  });

  assert.deepEqual(mergeVaultDocuments(first, second), mergeVaultDocuments(second, first));
  assert.deepEqual(mergeVaultDocuments(second, second), { document: second, conflicts: [] });
});

test("documents are normalized into deterministic entity and object-key order", () => {
  const anotherID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  let document = upsertVaultRecord(createEmptyVaultDocument(), {
    id: anotherID,
    type: "snippet",
    data: { z: 1, a: { y: 2, b: 3 } },
    deviceID: deviceA,
    modifiedAt: firstTime,
  });
  document = host(document);
  const normalized = validateVaultDocument(document);

  assert.deepEqual(normalized.records.map((record) => record.id), [recordID, anotherID]);
  assert.deepEqual(Object.keys(normalized.records[1].data), ["a", "z"]);
  assert.deepEqual(Object.keys(normalized.records[1].data.a), ["b", "y"]);
});
