import test from "node:test";
import assert from "node:assert/strict";
import { createAccessManager } from "../public/access-manager.js";
import { accessConsequence, accessCopy } from "../public/access-copy.js";
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
test('active publication uses the staging driver and confirms its complete team preview without foundation writes',async()=>{
  let foundation=0,publications=0;
  const f=fixture({getContext:async()=>({formatState:'V2_ACTIVE',policyMutationAvailable:false,groupMutationAvailable:false,blockers:['crypto_publication_required']}),preview:async()=>foundation++,commit:async()=>foundation++});
  const driver={enabled:true,getContext:async()=>({formatState:'V2_ACTIVE',wholePublication:true,policyMutationAvailable:true,groupMutationAvailable:true,blockers:[]}),
    resources:()=>({rows:[],nextCursor:null}),grants:()=>({rows:[],nextCursor:null}),groups:()=>({rows:[],nextCursor:null}),
    preview:async()=>({wholePublication:true,complete:true,request:{operationID:teamID},binding:{rowCount:1,counts:{vaults:2,resources:4,parts:5,wrappers:5}},counts:{vaults:2,resources:4,parts:5,wrappers:5},rows:[{type:'CUSTODY'}],details:[],nextCursor:null}),
    commit:async(_scope,approved)=>{assert.equal(approved.binding.counts.vaults,2);publications++;return{vaults:[]};}};
  const m=createAccessManager({...f,context,publicationDriver:async()=>driver});await m.refresh();
  m.setDraft({type:'GROUP_CREATE',name:'Stage group'});await m.preview();await m.confirm();
  assert.equal(publications,1);assert.equal(foundation,0);assert.equal(m.state().capability.wholePublication,true);m.destroy();
});
test('active publication cannot use a partial preview or activate without an explicit driver capability',async()=>{
  const f=fixture({getContext:async()=>({formatState:'V2_ACTIVE',policyMutationAvailable:true,groupMutationAvailable:true,blockers:[]})});const m=createAccessManager({...f,context});await m.refresh();m.setDraft({type:'GROUP_CREATE',name:'A'});await assert.rejects(m.preview(),/crypto_publication_required/);m.destroy();
});
test("first grant and surviving-path revoke use distinct copy", () => {
  const first = accessConsequence({ gainedMask: 1, lostMask: 0, after: { policyEffective: { paths: [] } } }, "en");
  assert.match(first, /will gain/);
  assert.match(first, /selected recipients/);
  assert.doesNotMatch(first, /this member/);
  assert.doesNotMatch(first, /revoking/);
  const surviving = accessConsequence({ gainedMask: 0, lostMask: 1, after: { policyEffective: { paths: [{}] } } }, "en");
  assert.match(surviving, /Other paths remain/);
});
test("path kind labels are localized without exposing protocol enum names", () => {
  assert.equal(accessCopy("USER", "ru"), "Участник");
  assert.equal(accessCopy("GROUP", "ru"), "Группа");
  assert.equal(accessCopy("FOLDER", "en"), "Folder");
});
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
test("terminal impact must match counts and contain distinct rows before commit", async () => {
  const detail = (id) => ({ vaultID, resourceID: id, subjectUserID: teamID });
  for (const [name, first, last] of [
    ["incomplete", [detail(teamID)], [],],
    ["duplicate", [detail(teamID)], [detail(teamID)]],
    ["changed counts", [detail(teamID)], [detail(vaultID)]],
  ]) {
    let calls = 0, commits = 0;
    const f = fixture({
      preview: async () => (++calls === 1 ? {
        token: "t", snapshotID: "a".repeat(64), details: first,
        affectedGrants: [], counts: { pairs: 2, widened: 0, lost: 0, affectedGrants: 0 }, nextCursor: "50",
      } : {
        token: "t", snapshotID: "a".repeat(64), details: last,
        affectedGrants: [], counts: { pairs: name === "changed counts" ? 3 : 2, widened: 0, lost: 0, affectedGrants: 0 }, nextCursor: null,
      }),
      commit: async () => { commits++; return { notificationCandidates: [] }; },
    });
    const m = createAccessManager({ ...f, context });
    await m.refresh();
    m.setDraft({ changes: [{ type: "GRANT_REVOKE", grantID: teamID, expectedVersion: 1 }] });
    await m.preview();
    await assert.rejects(m.previewMore(), /access_preview_incomplete/, name);
    await assert.rejects(m.confirm(), /access_preview_incomplete/, name);
    assert.equal(commits, 0, name);
    m.destroy();
  }
});
test("group grant impact requires every distinct affected grant", async () => {
  const grant = (id) => ({ grantID: id });
  for (const last of [[], [grant(teamID)]]) {
    let call = 0, commits = 0;
    const f = fixture({ preview: async () => (++call === 1 ? {
      token: "t", snapshotID: "a".repeat(64), details: [],
      affectedGrants: [grant(teamID)], counts: { pairs: 0, widened: 0, lost: 0, affectedGrants: 2 }, nextCursor: "50",
    } : {
      token: "t", snapshotID: "a".repeat(64), details: [],
      affectedGrants: last, counts: { pairs: 0, widened: 0, lost: 0, affectedGrants: 2 }, nextCursor: null,
    }), commit: async () => { commits++; return { notificationCandidates: [] }; } });
    const m = createAccessManager({ ...f, context });
    await m.refresh(); m.setDraft({ type: "GROUP_CREATE", name: "Fixture" });
    await m.preview();
    await assert.rejects(m.previewMore(), /access_preview_incomplete/);
    await assert.rejects(m.confirm(), /access_preview_incomplete/);
    assert.equal(commits, 0);
    m.destroy();
  }
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
test("verified published contextual reference queries exact resource and keeps publication changes blocked", async () => {
  const resourceID="cccccccc-cccc-4ccc-8ccc-cccccccccccc";
  let requested=null;
  const f=fixture({getContext:async()=>({formatState:"V2_ACTIVE",policyMutationAvailable:false,groupMutationAvailable:false,blockers:["crypto_publication_required"]}),whoHas:async(scope,id)=>{requested={scope,id};return {rows:[],nextCursor:null};}});
  const manager=createAccessManager({...f,context});
  await manager.openResource({teamID,vaultID,resourceID,kind:"CREDENTIAL",role:"owner"},"share");
  assert.equal(requested.id,resourceID);assert.equal(requested.scope.teamID,teamID);assert.equal(requested.scope.vaultID,vaultID);
  manager.setDraft({type:"GROUP_CREATE",name:"Frozen"});await assert.rejects(manager.preview(),/crypto_publication_required/);manager.destroy();
});


test('a discovered committed operation exposes receipt recovery before current policy or membership routes',async()=>{
  let ordinary=0;const f=fixture({listVaults:async()=>{ordinary++;throw Error('team_permission_denied');},getContext:async()=>{ordinary++;throw Error('team_permission_denied');}});
  const driver={enabled:false,pendingOperationID:teamID,pendingReceipt:{operationID:teamID},canResumePending:false,getContext:async()=>({formatState:'V2_ACTIVE',wholePublication:true,policyMutationAvailable:false,groupMutationAvailable:false,blockers:['publication_resume_required']})};
  const manager=createAccessManager({...f,context:{...context,role:'viewer'},publicationDriver:()=>driver});await manager.refresh();assert.equal(ordinary,0);assert.equal(manager.state().capability.wholePublication,true);manager.setDraft({type:'GROUP_CREATE',name:'Denied'});await assert.rejects(manager.preview(),/crypto_publication_required/);manager.destroy();
});
