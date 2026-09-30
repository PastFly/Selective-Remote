import test from "node:test";
import assert from "node:assert/strict";
import { createAccessManager } from "../public/access-manager.js";
const teamID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  vaultID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
function node(tag = "div") {
  return {
    tagName: tag,
    children: [],
    dataset: {},
    attributes: {},
    ownerDocument: doc,
    append(...n) {
      this.children.push(...n);
    },
    replaceChildren(...n) {
      this.children = n;
    },
    setAttribute(k, v) {
      this.attributes[k] = v;
    },
    addEventListener() {},
    removeEventListener() {},
    focus() {},
    remove() {},
    textContent: "",
    hidden: false,
  };
}
const doc = {
  createElement: node,
  documentElement: { lang: "en" },
  addEventListener() {},
  removeEventListener() {},
};
function fixture(extra = {}) {
  const client = {
    listVaults: async () => ({ rows: [], nextCursor: null }),
    getContext: async () => ({
      formatState: "V2_PREPARING",
      policyMutationAvailable: true,
      groupMutationAvailable: true,
      blockers: [],
    }),
    listMembers: async () => ({ rows: [], nextCursor: null }),
    listGroups: async () => ({ rows: [], nextCursor: null }),
    listResources: async () => ({ rows: [], nextCursor: null }),
    listGrants: async () => ({ rows: [], nextCursor: null }),
    ...extra,
  };
  return { client, root: node() };
}
const context = { teamID, vaultID, role: "owner" };
test("changed draft discards preview and incomplete pagination cannot commit", async () => {
  let commits = 0;
  const f = fixture({
    preview: async () => ({
      token: "t",
      snapshotID: "a".repeat(64),
      details: [],
      affectedGrants: [],
      counts: { pairs: 0 },
      nextCursor: "50",
    }),
    commit: async () => {
      commits++;
      return { notificationCandidates: [] };
    },
  });
  const m = createAccessManager({ ...f, context });
  await m.refresh();
  m.setDraft({ type: "GROUP_CREATE", name: "A" });
  await m.preview();
  await assert.rejects(m.confirm(), /access_preview_incomplete/);
  m.setDraft({ type: "GROUP_CREATE", name: "B" });
  assert.equal(m.state().preview, null);
  assert.equal(commits, 0);
  m.destroy();
});
test("context change suppresses old preview and callbacks; commit double click only once", async () => {
  let resolve;
  let count = 0;
  let callbacks = 0;
  const f = fixture({
    preview: () => new Promise((r) => (resolve = r)),
    commit: async () => {
      count++;
      return { notificationCandidates: [] };
    },
  });
  const m = createAccessManager({
    ...f,
    context,
    onCommitted: () => callbacks++,
  });
  await m.refresh();
  m.setDraft({ type: "GROUP_CREATE", name: "A" });
  const pending = m.preview();
  m.setContext({ ...context, vaultID: teamID });
  resolve({
    token: "t",
    snapshotID: "a".repeat(64),
    details: [],
    affectedGrants: [],
    counts: {},
    nextCursor: null,
  });
  await pending;
  assert.equal(m.state().preview, null);
  f.client.preview = async () => ({
    token: "t",
    snapshotID: "a".repeat(64),
    details: [],
    affectedGrants: [],
    counts: {},
    nextCursor: null,
  });
  await m.refresh();
  m.setDraft({ type: "GROUP_CREATE", name: "A" });
  await m.preview();
  await Promise.all([m.confirm(), m.confirm()]);
  assert.equal(count, 1);
  assert.equal(callbacks, 1);
  m.destroy();
});
test("group mutation flag is independent; snapshot drift discards entire impact", async () => {
  let page = 0;
  const f = fixture({
    getContext: async () => ({
      formatState: "V2_PREPARING",
      policyMutationAvailable: true,
      groupMutationAvailable: false,
      blockers: ["crypto_publication_required"],
    }),
    preview: async () => ({
      token: "t",
      snapshotID: String(++page).repeat(64),
      details: [],
      affectedGrants: [],
      counts: {},
      nextCursor: "50",
    }),
  });
  const m = createAccessManager({ ...f, context });
  await m.refresh();
  m.setDraft({ type: "GROUP_CREATE", name: "A" });
  await assert.rejects(m.preview(), /crypto_publication_required/);
  m.setDraft({
    changes: [{ type: "GRANT_REVOKE", grantID: teamID, expectedVersion: 1 }],
  });
  await m.preview();
  await assert.rejects(m.previewMore(), /access_preview_conflict/);
  assert.equal(m.state().preview, null);
  m.destroy();
});

test("old directory responses cannot paint new Team; failed commit sends no callback", async () => {
  let release;
  let callbacks = 0;
  const f = fixture({
    listMembers: () => new Promise((r) => (release = r)),
    commit: async () => {
      throw new Error("access_preview_conflict");
    },
    preview: async () => ({
      token: "t",
      snapshotID: "a".repeat(64),
      details: [],
      affectedGrants: [],
      counts: {},
      nextCursor: null,
    }),
  });
  const m = createAccessManager({
    ...f,
    context,
    onCommitted: () => callbacks++,
  });
  const pending = m.refresh();
  await new Promise((r) => setTimeout(r, 0));
  m.setContext({ teamID: vaultID, vaultID: teamID });
  release({
    rows: [{ id: teamID, userID: teamID, displayName: "Old Team canary" }],
    nextCursor: null,
  });
  await pending;
  assert.equal(m.state().pages.members.rows.length, 0);
  f.client.listMembers = async () => ({ rows: [], nextCursor: null });
  await m.refresh();
  m.setDraft({ type: "GROUP_CREATE", name: "G" });
  await m.preview();
  await assert.rejects(m.confirm(), /access_preview_conflict/);
  assert.equal(callbacks, 0);
  assert.equal(m.state().preview, null);
  m.destroy();
});
test("new preview supersedes an older response even in the same draft", async () => {
  const releases = [];
  const f = fixture({ preview: () => new Promise((r) => releases.push(r)) });
  const m = createAccessManager({ ...f, context });
  await m.refresh();
  m.setDraft({ type: "GROUP_CREATE", name: "G" });
  const old = m.preview(),
    latest = m.preview();
  releases[1]({
    token: "new",
    snapshotID: "b".repeat(64),
    details: [],
    counts: {},
    nextCursor: null,
  });
  await latest;
  releases[0]({
    token: "old",
    snapshotID: "a".repeat(64),
    details: [],
    counts: {},
    nextCursor: null,
  });
  await old;
  assert.equal(m.state().preview.token, "new");
  m.destroy();
});

test("READY and ACTIVE remain immutable even if capability flags are inconsistent", async () => {
  let previews = 0;
  for (const formatState of ["V2_READY", "V2_ACTIVE"]) {
    const f = fixture({
      getContext: async () => ({
        formatState,
        policyMutationAvailable: true,
        groupMutationAvailable: true,
        blockers: [],
      }),
      preview: async () => {
        previews++;
      },
    });
    const m = createAccessManager({ ...f, context });
    await m.refresh();
    m.setDraft({ type: "GROUP_CREATE", name: "Frozen" });
    await assert.rejects(m.preview(), /crypto_publication_required/);
    m.destroy();
  }
  assert.equal(previews, 0);
});
