import assert from "node:assert/strict";
import test from "node:test";
import {
  createSyncPresentationState,
  publishSyncObservation,
  reduceSyncPresentationState,
  summarizeSyncPresentationState,
  syncPresentationLabels,
} from "../public/app.js";

test("sync presentation starts unknown and never infers success from silence", () => {
  const state = createSyncPresentationState();
  assert.equal(summarizeSyncPresentationState(state).status, "unknown");
  assert.equal(state.personal.status, "unknown");
  assert.equal(state.team.status, "unknown");
});

test("typed Personal and Team outcomes preserve conflict, attention and confirmed revision", () => {
  let state = createSyncPresentationState();
  state = reduceSyncPresentationState(state, { scope: "personal", type: "result", result: { status: "uploaded", revision: 4 } });
  assert.deepEqual({ status: state.personal.status, revision: state.personal.revision }, { status: "current", revision: 4 });
  assert.equal(summarizeSyncPresentationState(state).status, "unknown");

  state = reduceSyncPresentationState(state, { scope: "team", type: "result", result: { status: "conflict", revision: 7, conflicts: [{}] } });
  assert.equal(summarizeSyncPresentationState(state).status, "conflict");
  state = reduceSyncPresentationState(state, { scope: "team", type: "result", result: { status: "uploaded_with_new_local_changes", revision: 8 } });
  assert.equal(summarizeSyncPresentationState(state).status, "attention");
  state = reduceSyncPresentationState(state, { scope: "team", type: "result", result: { status: "up_to_date", revision: 8 } });
  assert.equal(summarizeSyncPresentationState(state).status, "current");
});

test("one failed scope masks a successful scope even with an offline hint", () => {
  let state = createSyncPresentationState();
  state = reduceSyncPresentationState(state, { scope: "personal", type: "result", result: { status: "up_to_date", revision: 2 } });
  state = reduceSyncPresentationState(state, { scope: "team", type: "error", code: "network_unavailable" });
  assert.equal(summarizeSyncPresentationState(state).status, "error");
  assert.equal(summarizeSyncPresentationState(state, { online: false }).status, "error");
  assert.equal(state.personal.status, "current");
});

test("offline hint does not imply a pending count or confirmed synchronization", () => {
  const state = createSyncPresentationState();
  const summary = summarizeSyncPresentationState(state, { online: false });
  assert.equal(summary.status, "offline");
  assert.equal(summary.personal.status, "unknown");
  assert.equal(summary.team.status, "unknown");
  assert.match(syncPresentationLabels(summary, "en").note, /may be waiting/u);
  assert.match(syncPresentationLabels(summary, "ru").note, /могут ожидать/u);
});

test("session and lock events clear stale success; RU/EN labels read state, not message text", () => {
  let state = createSyncPresentationState();
  state = reduceSyncPresentationState(state, { scope: "personal", type: "result", result: { status: "downloaded", revision: 9 } });
  state = reduceSyncPresentationState(state, { scope: "team", type: "result", result: { status: "up_to_date", revision: 3 } });
  assert.equal(syncPresentationLabels(summarizeSyncPresentationState(state), "ru").summary, "Наблюдаемые Vaults подтверждены");
  assert.equal(syncPresentationLabels(summarizeSyncPresentationState(state), "en").summary, "Observed Vaults confirmed");
  state = reduceSyncPresentationState(state, { scope: "personal", type: "locked" });
  assert.equal(state.personal.status, "locked");
  state = reduceSyncPresentationState(state, { type: "signedOut" });
  assert.equal(summarizeSyncPresentationState(state).status, "signedOut");
});

test("confirmed detail identifies the local revision and time", () => {
  const state = reduceSyncPresentationState(createSyncPresentationState(), {
    scope: "personal", type: "result", result: { status: "up_to_date", revision: 5 }, at: "2026-09-28T12:00:00.000Z",
  });
  assert.match(syncPresentationLabels(summarizeSyncPresentationState(state), "en").personal, /r5/u);
  assert.match(syncPresentationLabels(summarizeSyncPresentationState(state), "ru").personal, /r5/u);
});

test("unknown engine errors do not enter presentation state verbatim", () => {
  const state = reduceSyncPresentationState(createSyncPresentationState(), {
    scope: "team", type: "error", code: "private host example.internal refused connection",
  });
  assert.equal(state.team.status, "error");
  assert.equal(state.team.issue, "unknown_failure");
});

test("aggregate keeps security and errors visible over other scopes and offline hint", () => {
  let state = createSyncPresentationState();
  state = reduceSyncPresentationState(state, { scope: "personal", type: "result", result: { status: "conflict" } });
  state = reduceSyncPresentationState(state, { scope: "team", type: "error", code: "unknown_failure" });
  assert.equal(summarizeSyncPresentationState(state, { online: false }).status, "error");
  state = reduceSyncPresentationState(state, { scope: "team", type: "error", code: "team_vault_key_unavailable" });
  assert.equal(summarizeSyncPresentationState(state, { online: false }).status, "attention");
});

test("observation event strips conflict records and arbitrary error text", () => {
  const events = [];
  class FakeEvent { constructor(type, options) { this.type = type; this.detail = options.detail; } }
  const documentValue = { defaultView: { CustomEvent: FakeEvent }, dispatchEvent: (event) => events.push(event) };
  publishSyncObservation(documentValue, {
    scope: "team", type: "result", result: { status: "conflict", revision: 6, conflicts: [{ title: "Secret host" }] },
  });
  publishSyncObservation(documentValue, { scope: "team", type: "error", code: "private host example.internal" });
  assert.deepEqual(events[0].detail.result, { status: "conflict", revision: 6 });
  assert.equal(events[1].detail.code, "unknown_failure");
  assert.doesNotMatch(JSON.stringify(events), /Secret host|example\.internal/u);
});

test("sync observation preserves only a typed recipient to bind delayed results", () => {
  const events = [];
  class FakeEvent { constructor(type, options) { this.type = type; this.detail = options.detail; } }
  const documentValue = { defaultView: { CustomEvent: FakeEvent }, dispatchEvent: (event) => events.push(event) };
  publishSyncObservation(documentValue, { scope: "personal", type: "result",
    recipient: "11111111-1111-4111-8111-111111111111", result: { status: "up_to_date" } });
  assert.equal(events[0].detail.recipient, "11111111-1111-4111-8111-111111111111");
});

test("a Team sync target becomes stale when the selected Vault changes during an await", async () => {
  const { teamSyncTargetMatches } = await import("../public/app.js");
  assert.equal(typeof teamSyncTargetMatches, "function");
  const controller = {};
  const captured = { controller, teamID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    vaultID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" };
  const current = { ...captured, vaultID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc" };
  assert.equal(teamSyncTargetMatches(captured, current), false);
  assert.equal(teamSyncTargetMatches(captured, { ...captured, controller: {} }), false);
  assert.equal(teamSyncTargetMatches(captured, { ...captured, teamID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd" }), false);
  assert.equal(teamSyncTargetMatches(captured, captured), true);
});
