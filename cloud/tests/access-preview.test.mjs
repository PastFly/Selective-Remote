import assert from "node:assert/strict";
import test from "node:test";
import { createPreviewToken, verifyPreviewToken, hashAccessRequest, validateAccessChangeRequest } from "../src/access-preview.mjs";

const request = { type: "GRANT_CREATE", targetID: "resource-1", permissionMask: 1 };
const payloadBase = { actorMembershipID: "member-1", actorEpoch: 2,
  actorDeviceID: "device-1", teamID: "team-1", vaultID: "vault-1",
  teamPolicyRevision: 4, vaultPolicyVersion: 7,
  registryVersions: [{ id: "resource-1", version: 3 }],
  selectedDescendants: ["resource-1"] };

test("preview signature binds the request, actor, versions and expiry", () => {
  const payload = { ...payloadBase, requestHash: hashAccessRequest(request) };
  const token = createPreviewToken(payload, "session-secret-A", { now: 1000, ttlMS: 5000 });
  assert.deepEqual(verifyPreviewToken(token, "session-secret-A", { now: 2000 }),
    { ...payload, expiresAt: 6000 });
  assert.throws(() => verifyPreviewToken(token, "session-secret-B", { now: 2000 }),
    /access_preview_conflict/);
  assert.throws(() => verifyPreviewToken(token, "session-secret-A", { now: 6000 }),
    /access_preview_conflict/);
  assert.throws(() => verifyPreviewToken(token + "x", "session-secret-A", { now: 2000 }),
    /access_preview_conflict/);
  assert.throws(() => verifyPreviewToken("unsigned", "session-secret-A", { now: 2000 }),
    /access_preview_conflict/);
});

test("canonical request hash rejects changed payload independent of key order", () => {
  assert.equal(hashAccessRequest({ permissionMask: 1, targetID: "resource-1", type: "GRANT_CREATE" }),
    hashAccessRequest(request));
  assert.notEqual(hashAccessRequest({ ...request, permissionMask: 2 }), hashAccessRequest(request));
});


test("preview rejects empty and oversized grant batches before SQL", () => {
  assert.throws(() => validateAccessChangeRequest({ changes: [] }), /invalid_access_request/);
  const change = { type: "GRANT_CREATE", principalKind: "USER",
    principalID: "11111111-1111-4111-8111-111111111111",
    targetKind: "RESOURCE", targetID: "22222222-2222-4222-8222-222222222222",
    permissionMask: 1 };
  assert.deepEqual(validateAccessChangeRequest({ changes: [change] }), [change]);
  assert.throws(() => validateAccessChangeRequest({ changes: Array(51).fill(change) }),
    /access_batch_too_large/);
  assert.throws(() => validateAccessChangeRequest({ changes: [{ ...change,
    permissionMask: 0 }] }), /invalid_access_request/);
});

test("a bounded same-Vault resource move has an explicit preview request shape", () => {
  const move = { type: "RESOURCE_MOVE",
    resourceID: "11111111-1111-4111-8111-111111111111",
    newParentFolderID: "22222222-2222-4222-8222-222222222222",
    expectedResourceVersion: 1 };
  assert.deepEqual(validateAccessChangeRequest({ changes: [move] }), [move]);
  assert.throws(() => validateAccessChangeRequest({ changes: [
    { ...move, newParentFolderID: "other-vault" },
  ] }), /invalid_access_request/);
});
