import assert from "node:assert/strict";
import test from "node:test";
import {
  createNotificationState, reconcileNotifications, markNotificationRead,
  notificationCounts, notificationItems, serializeNotificationState,
  deviceNotificationObservations, invitationNotificationObservations,
  syncNotificationDecision,
  committedAccessObservations,
} from "../public/notification-projection.js";

const recipient = "11111111-1111-4111-8111-111111111111";
const device = "22222222-2222-4222-8222-222222222222";
const invitation = "33333333-3333-4333-8333-333333333333";
const team = "44444444-4444-4444-8444-444444444444";
const at = "2026-09-28T19:00:00.000Z";
const later = "2026-09-28T19:05:00.000Z";

test("committed access candidates filter current recipient and effective deltas", () => {
  const result = committedAccessObservations({ notificationCandidates: [
    { userID: recipient, resourceID: device, gainedMask: 1, lostMask: 0 },
    { userID: recipient, resourceID: device, gainedMask: 1, lostMask: 0 },
    { userID: recipient, resourceID: invitation, gainedMask: 0, lostMask: 0 },
    { userID: team, vaultID: team, resourceID: invitation, gainedMask: 0, lostMask: 1 },
  ] }, { vaultID: team }, recipient);
  assert.deepEqual(result, [{ group: `access:${team}`, complete: false,
    observations: [{ kind: "accessGained", scopeID: team, sourceID: device }] }]);
  const groupResult = committedAccessObservations({ notificationCandidates: [
    { userID: recipient, vaultID: invitation, resourceID: device, gainedMask: 0, lostMask: 4 },
  ] }, { vaultID: team }, recipient);
  assert.equal(groupResult[0].group, `access:${invitation}`);
  assert.equal(groupResult[0].observations[0].kind, "accessLost");
});

test("device stays active after read and resolves only after a complete fresh device list", () => {
  let state = createNotificationState(recipient);
  state = reconcileNotifications(state, { group: "devices", complete: true, at,
    observations: [{ kind: "deviceApproval", scopeID: recipient, sourceID: device }] });
  const id = notificationItems(state)[0].id;
  state = markNotificationRead(state, id, later);
  assert.deepEqual(notificationCounts(state), { attentionCount: 1, unreadCount: 0 });
  state = reconcileNotifications(state, { group: "devices", complete: false, at: later, observations: [] });
  assert.equal(notificationItems(state)[0].resolvedAt, null);
  state = reconcileNotifications(state, { group: "devices", complete: true, at: later, observations: [] });
  assert.equal(notificationItems(state)[0].resolvedAt, later);
});

test("an older complete device response cannot clear a newer pending security cue", () => {
  let state = createNotificationState(recipient);
  state = reconcileNotifications(state, { group: "devices", complete: true, at: later, sequence: 2,
    observations: [{ kind: "deviceApproval", scopeID: recipient, sourceID: device }] });
  state = reconcileNotifications(state, { group: "devices", complete: true, at, sequence: 1,
    observations: [] });
  assert.equal(notificationCounts(state).attentionCount, 1);
});

test("pending invitation is one item across refreshes and reappearing issue becomes unread", () => {
  let state = createNotificationState(recipient);
  const observation = { kind: "invitation", scopeID: team, sourceID: invitation };
  state = reconcileNotifications(state, { group: "invitations", complete: true, at, observations: [observation] });
  state = reconcileNotifications(state, { group: "invitations", complete: true, at: later, observations: [observation] });
  assert.equal(notificationItems(state).length, 1);
  assert.equal(notificationItems(state)[0].lastObservedAt, later);
  state = markNotificationRead(state, notificationItems(state)[0].id, later);
  state = reconcileNotifications(state, { group: "invitations", complete: true, at: later, observations: [] });
  state = reconcileNotifications(state, { group: "invitations", complete: true, at: "2026-09-28T19:06:00.000Z", observations: [observation] });
  assert.deepEqual(notificationCounts(state), { attentionCount: 1, unreadCount: 1 });
  assert.equal(notificationItems(state).length, 1);
});

test("sync retry and temporary status leave error active; confirmed success resolves only its scope", () => {
  let state = createNotificationState(recipient);
  state = reconcileNotifications(state, { group: "sync:personal", complete: true, at,
    observations: [{ kind: "syncError", scopeID: recipient, sourceID: "personal" }] });
  state = reconcileNotifications(state, { group: `sync:team:${team}`, complete: true, at,
    observations: [{ kind: "conflict", scopeID: team, sourceID: team }] });
  state = reconcileNotifications(state, { group: "sync:personal", complete: false, at: later, observations: [] });
  assert.equal(notificationCounts(state).attentionCount, 2);
  state = reconcileNotifications(state, { group: "sync:personal", complete: true, at: later, observations: [] });
  assert.equal(notificationCounts(state).attentionCount, 1);
  assert.equal(notificationItems(state).find((item) => item.kind === "conflict").resolvedAt, null);
});

test("fail-closed records never serialize raw errors, keys or arbitrary labels; Mac-only host key is rejected", () => {
  let state = createNotificationState(recipient);
  state = reconcileNotifications(state, { group: `sync:team:${team}`, complete: true, at,
    observations: [{ kind: "failClosed", scopeID: team, sourceID: team,
      rawError: "private-key-SECRET", label: "decrypted-host-SECRET" }] });
  state = reconcileNotifications(state, { group: "host-key", complete: true, at,
    observations: [{ kind: "hostIdentity", scopeID: recipient, sourceID: device,
      fingerprint: "fingerprint-SECRET" }] });
  const serialized = serializeNotificationState(state);
  assert.equal(notificationCounts(state).attentionCount, 1);
  assert.doesNotMatch(serialized, /SECRET|rawError|fingerprint|label/u);
});

test("recipient isolation rejects another account and malformed persisted records", () => {
  const other = "55555555-5555-4555-8555-555555555555";
  let state = createNotificationState(recipient);
  state = reconcileNotifications(state, { group: "devices", complete: true, at,
    observations: [{ kind: "deviceApproval", scopeID: recipient, sourceID: device }] });
  assert.equal(notificationItems(createNotificationState(other, serializeNotificationState(state))).length, 0);
  assert.equal(notificationItems(createNotificationState(recipient, '{"recipient":"evil","items":[{}]}')).length, 0);
  const forged = reconcileNotifications(createNotificationState(recipient), { group: "devices",
    complete: true, at, observations: [{ kind: "deviceApproval", scopeID: other, sourceID: device }] });
  assert.equal(notificationItems(forged).length, 0);
});

test("resolved records expire after 30 days while active security items survive", () => {
  let state = createNotificationState(recipient);
  state = reconcileNotifications(state, { group: "devices", complete: true, at,
    observations: [{ kind: "deviceApproval", scopeID: recipient, sourceID: device }] });
  state = reconcileNotifications(state, { group: "invitations", complete: true, at,
    observations: [{ kind: "invitation", scopeID: team, sourceID: invitation }] });
  state = reconcileNotifications(state, { group: "invitations", complete: true, at: later, observations: [] });
  state = reconcileNotifications(state, { group: "devices", complete: false, at: "2026-11-01T00:00:00.000Z", observations: [] });
  assert.equal(notificationItems(state).length, 1);
  assert.equal(notificationItems(state)[0].kind, "deviceApproval");
});

test("device and invitation adapters project only active source identities", () => {
  const devices = deviceNotificationObservations([
    { id: device, keyRegistered: true, keyApprovedAt: null, revokedAt: null, name: "Secret host" },
    { id: invitation, keyRegistered: true, keyApprovedAt: at, revokedAt: null },
  ], recipient);
  assert.deepEqual(devices, [{ kind: "deviceApproval", scopeID: recipient, sourceID: device }]);
  const invitations = invitationNotificationObservations([
    { id: invitation, teamID: team, teamName: "Private team" },
  ]);
  assert.deepEqual(invitations, [{ kind: "invitation", scopeID: team, sourceID: invitation }]);
});

test("secure pending approval replaces the legacy cue and resolves with source state", () => {
  const legacy = [{ id: device, keyRegistered: true, keyApprovedAt: null, revokedAt: null }];
  const pending = [{ requestID: invitation, deviceID: device, status: "pending" }];
  assert.deepEqual(deviceNotificationObservations(legacy, recipient, pending),
    [{ kind: "deviceApproval", scopeID: recipient, sourceID: invitation }]);
  assert.deepEqual(deviceNotificationObservations(legacy, recipient,
    [{ ...pending[0], status: "approved" }]),
  []);
});

test("typed sync adapter skips temporary states and keeps Team Vault identity", () => {
  assert.deepEqual(syncNotificationDecision({ status: "syncing" }, {
    scope: "team", recipient, teamVaultID: team,
  }), { group: `sync:team:${team}`, complete: false, observations: [] });
  assert.deepEqual(syncNotificationDecision({ status: "conflict" }, {
    scope: "team", recipient, teamVaultID: team,
  }), { group: `sync:team:${team}`, complete: true,
    observations: [{ kind: "conflict", scopeID: team, sourceID: team }] });
  assert.deepEqual(syncNotificationDecision({ status: "attention", issue: "team_vault_key_unavailable" }, {
    scope: "team", recipient, teamVaultID: team,
  }), { group: `sync:team:${team}`, complete: true,
    observations: [{ kind: "wrapperIssue", scopeID: team, sourceID: team }] });
  assert.equal(syncNotificationDecision({ status: "error", issue: "unknown_failure" }, {
    scope: "team", recipient, teamVaultID: null,
  }), null);
});
