import assert from "node:assert/strict";
import test from "node:test";
import {
  createSyncPresentationState,
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

test("one failed scope masks a successful scope and offline is only a connectivity hint", () => {
  let state = createSyncPresentationState();
  state = reduceSyncPresentationState(state, { scope: "personal", type: "result", result: { status: "up_to_date", revision: 2 } });
  state = reduceSyncPresentationState(state, { scope: "team", type: "error", code: "network_unavailable" });
  assert.equal(summarizeSyncPresentationState(state).status, "error");
  assert.equal(summarizeSyncPresentationState(state, { online: false }).status, "offline");
  assert.equal(state.personal.status, "current");
});

test("session and lock events clear stale success; RU/EN labels read state, not message text", () => {
  let state = createSyncPresentationState();
  state = reduceSyncPresentationState(state, { scope: "personal", type: "result", result: { status: "downloaded", revision: 9 } });
  state = reduceSyncPresentationState(state, { scope: "team", type: "result", result: { status: "up_to_date", revision: 3 } });
  assert.equal(syncPresentationLabels(summarizeSyncPresentationState(state), "ru").summary, "Синхронизировано здесь");
  assert.equal(syncPresentationLabels(summarizeSyncPresentationState(state), "en").summary, "Confirmed here");
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
