import assert from "node:assert/strict";
import test from "node:test";
import { personalSnippetEditorValues, personalSnippetProjection, personalSnippetRecordData } from "../public/app.js";
import { filterTeamSnippets, teamSnippetFolderPaths, renderTeamSnippetTree } from "../public/team-snippet-browser.js";

const id = "22222222-2222-4222-8222-222222222222";
const groupID = "33333333-3333-4333-8333-333333333333";
const native = { id, profileID: "11111111-1111-4111-8111-111111111111", title: "Deploy", command: "printf old",
  category: "Work/Deploy", groupID, targets: [{ kind: "localTerminal" }], targetProfileIDs: [],
  isExplicitlyUngrouped: false, updatedAt: "2026-09-01T00:00:00Z", future: { untouched: true } };
const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
const decode = (value) => JSON.parse(Buffer.from(value, "base64url").toString());
const record = (data) => ({ id, type: "snippet", modifiedAt: "2026-09-01T00:00:00Z", data });

test("personal folder projection reads native category, not Team folder", () => {
  const data = { title: "Deploy", body: "printf old", category: "Work/Deploy", template: encode(native), folder: "UnrelatedTeamField" };
  const source = record(data);
  assert.equal(personalSnippetProjection(source).data.folder, "Work/Deploy");
  assert.equal(source.data.folder, "UnrelatedTeamField");
  assert.equal(personalSnippetEditorValues(source).folder, "Work/Deploy");
  assert.deepEqual(teamSnippetFolderPaths([personalSnippetProjection(source)]), ["Work", "Work/Deploy"]);
});

test("template-only, folderless and malformed legacy records remain readable", () => {
  assert.equal(personalSnippetEditorValues(record({ template: encode(native) })).folder, "Work/Deploy");
  assert.equal(personalSnippetProjection(record({ category: "", template: encode(native) })).data.folder, "");
  assert.equal(personalSnippetProjection(record({ title: "Legacy", body: "pwd" })).data.folder, "");
  assert.equal(personalSnippetProjection(record({ title: "Broken", body: "pwd", template: "bad" })).data.title, "Broken");
  assert.equal(personalSnippetProjection(record({ category: "A//B" })).data.folder, "");
});

test("personal search reaches the full body and category descendants without persisting a projection", () => {
  const originals = [record({ title: "Name", body: "printf 'hidden needle'", category: "Work/Deploy" }),
    { ...record({ title: "Sibling", body: "pwd", category: "Worker" }), id: "other" }];
  assert.equal(filterTeamSnippets(originals.map(personalSnippetProjection), { query: "needle" }).length, 1);
  assert.equal(filterTeamSnippets(originals.map(personalSnippetProjection), { folder: "folder:Work" }).length, 1);
  assert.equal(originals[0].data.folder, undefined);
});

test("editing updates native template and outer fields together while preserving targets and extensions", () => {
  const data = { title: native.title, body: native.command, category: native.category, template: encode(native), favorite: true, extra: { keep: 1 } };
  const before = structuredClone(data);
  const edited = personalSnippetRecordData({ title: " Новое ", body: "printf 'Привет'\n", folder: "Work/Deploy", recordID: id }, data, new Date("2026-09-17T01:30:00.123Z"));
  const template = decode(edited.template);
  assert.equal(template.title, edited.title);
  assert.equal(template.command, edited.body);
  assert.equal(template.category, edited.category);
  assert.equal(template.groupID, groupID);
  assert.deepEqual(template.targets, native.targets);
  assert.deepEqual(template.future, native.future);
  assert.equal(template.profileID, native.profileID);
  assert.equal(template.updatedAt, "2026-09-17T01:30:00Z");
  assert.deepEqual(data, before);
  assert.deepEqual(edited.extra, { keep: 1 });
  assert.equal(edited.favorite, true);
  assert.equal(edited.folder, undefined);
});

test("moving clears the old opaque group ID and ungrouping is explicit", () => {
  const base = { template: encode(native) };
  const moved = decode(personalSnippetRecordData({ title: "Moved", body: "pwd", folder: "Other/Child" }, base).template);
  assert.equal(moved.category, "Other/Child");
  assert.equal(moved.groupID, "00000000-0000-0000-0000-000000000000");
  assert.equal(moved.isExplicitlyUngrouped, false);
  const ungrouped = personalSnippetRecordData({ title: "Root", body: "pwd", folder: "" }, base);
  assert.equal(ungrouped.category, "");
  assert.equal(decode(ungrouped.template).isExplicitlyUngrouped, true);
});

test("new browser personal snippets use the native category contract without synthetic records", () => {
  assert.deepEqual(personalSnippetRecordData({ title: "New", body: "pwd", folder: "A/B" }), { title: "New", body: "pwd", category: "A/B" });
});

test("invalid paths and corrupt or mismatched templates fail without destroying the original", () => {
  for (const folder of ["A/ B", "A/ /B", "/A", "A/", "A//B", "A\nB", "x".repeat(121)]) {
    assert.throws(() => personalSnippetRecordData({ title: "New", body: "pwd", folder }), /invalid_snippet_folder/);
  }
  assert.throws(() => personalSnippetRecordData({ title: "New", body: "pwd", recordID: "different" }, { template: encode(native) }), /invalid_personal_snippet_template/);
  assert.throws(() => personalSnippetRecordData({ title: "New", body: "pwd" }, { template: "bad" }));
});

test("personal and Team disclosure aria-controls IDs cannot collide", () => {
  const node = () => ({ children: [], dataset: {}, classList: { add() {} }, append(...v) { this.children.push(...v); }, setAttribute() {}, addEventListener() {} });
  const documentValue = { createElement: node };
  const personal = node(), team = node();
  const common = { documentValue, records: [personalSnippetProjection(record({ title: "X", body: "pwd", category: "A" }))], collapsed: new Set(), editable: true, onToggle() {}, onCreateGroup() {} };
  renderTeamSnippetTree({ ...common, container: team });
  renderTeamSnippetTree({ ...common, container: personal, idPrefix: "personal-snippet-folder-content" });
  assert.notEqual(personal.children[0].children[1].id, team.children[0].children[1].id);
});

test("personal folder + updated native template round-trip through the real encrypted controller", async () => {
  const { createLocalVaultController } = await import("../public/vault-local.js");
  let snapshot;
  const repository = { load: async () => snapshot ? structuredClone(snapshot) : null, save: async (value) => { snapshot = structuredClone(value); } };
  const first = createLocalVaultController({ repository });
  await first.create("synthetic local test passphrase");
  const data = personalSnippetRecordData({ title: "Encrypted test", body: "printf protected", folder: "Private/Folder", recordID: id }, { template: encode(native) });
  await first.upsert({ id, type: "snippet", data });
  assert.ok(snapshot.envelope.ciphertext);
  assert.ok(!JSON.stringify(snapshot).includes("Private/Folder"));
  assert.ok(!JSON.stringify(snapshot).includes("printf protected"));
  first.lock();
  const second = createLocalVaultController({ repository });
  await second.unlock("synthetic local test passphrase");
  const restored = second.document().records.find((value) => value.id === id);
  assert.equal(personalSnippetEditorValues(restored).folder, "Private/Folder");
  assert.equal(decode(restored.data.template).category, "Private/Folder");
  second.lock();
});
