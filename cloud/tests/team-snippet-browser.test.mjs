import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  filterTeamSnippets, normalizeTeamSnippetFolder, renderTeamSnippetTree,
  teamSnippetFolder, teamSnippetFolderPaths, teamSnippetRecordData, teamSnippetTree, visibleTeamSnippetIDs,
} from "../public/team-snippet-browser.js";

const snippet = (id, folder = "", title = id, body = "printf hello", modifiedAt = "2026-09-01T00:00:00.000Z") => ({
  id, type: "snippet", data: { title, body, ...(folder ? { folder } : {}) }, modifiedAt,
});
const records = [
  snippet("root"), snippet("parent", "Prod"), snippet("a", "Prod/Deploy", "Deploy 10"),
  snippet("b", "Prod/Deploy", "Deploy 2", "kubectl rollout"), snippet("c", "Prod/Logs", "Logs"),
  snippet("other", "Production", "Other"), { id: "password", type: "credential", data: { title: "kubectl", secret: "hidden" } },
];

test("Team Snippet creation retains the native encrypted data shape without synthetic folder records", () => {
  assert.deepEqual(teamSnippetRecordData({ title: " Build ", body: "printf test\n", folder: " Prod/Deploy " }), {
    title: "Build", body: "printf test\n", folder: "Prod/Deploy",
  });
  assert.deepEqual(Object.keys(teamSnippetRecordData({ title: "No folder", body: "pwd" })).sort(), ["body", "folder", "title"]);
  assert.equal(teamSnippetFolder(snippet("legacy")), "");
});

test("editing and moving a snippet preserve unknown fields and do not mutate the original", () => {
  const original = { title: "Old", body: "pwd", folder: "A", future: { targets: ["host-1"] }, favorite: true };
  const copy = structuredClone(original);
  const edited = teamSnippetRecordData({ title: "New", body: "id", folder: "B/Child" }, original);
  assert.deepEqual(edited, { ...original, title: "New", body: "id", folder: "B/Child" });
  assert.deepEqual(original, copy);
  assert.equal(teamSnippetRecordData({ title: "Root", body: "id", folder: "" }, edited).folder, "");
});

test("folder validation rejects malformed paths and excessive length, without truncation", () => {
  for (const value of ["/A", "A/", "A//B", "A\nB", "A\u0085B", "\nA", "A\u2028B", "A\u0000B", "x".repeat(121), null]) {
    assert.throws(() => normalizeTeamSnippetFolder(value), /invalid_snippet_folder/u);
  }
  for (const value of ["", "日本/Настройки", "all", "none", "__proto__/constructor", "x".repeat(120)]) {
    assert.equal(normalizeTeamSnippetFolder(value), value);
  }
  assert.equal(teamSnippetFolder({ data: { folder: {} } }), "");
});

test("empty, multiline-title and unsafe-control snippets fail before encryption", () => {
  for (const change of [{ title: " " }, { title: "two\nlines" }, { title: "x".repeat(121) }, { body: "" }, { body: "hi\u0000" }, { body: "x".repeat(32769) }]) {
    assert.throws(() => teamSnippetRecordData({ title: "Title", body: "echo ok", ...change }), /invalid_snippet/u);
  }
  assert.equal(teamSnippetRecordData({ title: "Valid", body: "printf\t'hello'\r\n" }).body, "printf\t'hello'\r\n");
});

test("folder inventory includes virtual ancestors but excludes other record types", () => {
  assert.deepEqual(teamSnippetFolderPaths(records), ["Prod", "Prod/Deploy", "Prod/Logs", "Production"]);
  assert.deepEqual(teamSnippetFolderPaths([snippet("x", "A/B/C")]), ["A", "A/B", "A/B/C"]);
});

test("folder filtering includes descendants, not similarly named siblings or reserved labels", () => {
  assert.deepEqual(filterTeamSnippets(records, { folder: "folder:Prod" }).map((r) => r.id).sort(), ["a", "b", "c", "parent"]);
  assert.deepEqual(filterTeamSnippets(records, { folder: "none" }).map((r) => r.id), ["root"]);
  const reserved = [snippet("1", "all"), snippet("2", "none"), snippet("3", "all/Child")];
  assert.deepEqual(filterTeamSnippets(reserved, { folder: "folder:all" }).map((r) => r.id), ["1", "3"]);
  assert.deepEqual(filterTeamSnippets(reserved, { folder: "folder:none" }).map((r) => r.id), ["2"]);
});

test("search combines title, full command and folder, without searching credential plaintext", () => {
  assert.deepEqual(filterTeamSnippets(records, { query: " KUBECTL " }).map((r) => r.id), ["b"]);
  assert.equal(filterTeamSnippets(records, { query: "deploy", folder: "folder:Prod" }).length, 2);
  assert.equal(filterTeamSnippets(records, { query: "hidden" }).length, 0);
  assert.equal(filterTeamSnippets(records, { query: "missing" }).length, 0);
  assert.equal(filterTeamSnippets(records, { query: "root", folder: "folder:Prod" }).length, 0);
});

test("sorting is numeric by title, deterministic for ties and non-mutating", () => {
  const before = structuredClone(records);
  assert.deepEqual(filterTeamSnippets(records, { folder: "folder:Prod/Deploy" }).map((r) => r.id), ["b", "a"]);
  const dated = [snippet("old", "", "Z", "pwd", "2026-09-01T00:00:00Z"), snippet("new", "", "A", "pwd", "2026-09-01T00:00:00.001Z")];
  assert.deepEqual(filterTeamSnippets(dated, { sort: "modified-desc" }).map((r) => r.id), ["new", "old"]);
  assert.deepEqual(filterTeamSnippets([snippet("b", "", "Same"), snippet("a", "", "Same")]).map((r) => r.id), ["a", "b"]);
  assert.deepEqual(records, before);
});

test("the hierarchy counts descendants once and preserves virtual and literal prototype-named nodes", () => {
  const tree = teamSnippetTree(records);
  assert.equal(tree.count, 6);
  assert.deepEqual(tree.records.map((r) => r.id), ["root"]);
  assert.equal(tree.children[0].count, 4);
  assert.deepEqual(tree.children[0].children.map((r) => r.path), ["Prod/Deploy", "Prod/Logs"]);
  const edge = teamSnippetTree([snippet("x", "__proto__/constructor/A")]);
  assert.equal(edge.children[0].children[0].children[0].records[0].id, "x");
});

test("select-visible excludes descendants of collapsed folders but not unrelated groups", () => {
  const tree = teamSnippetTree(records);
  assert.deepEqual(visibleTeamSnippetIDs(tree, new Set(["Prod"])), ["root", "other"]);
  assert.deepEqual(visibleTeamSnippetIDs(tree, new Set(["", "Prod/Deploy"])), ["parent", "c", "other"]);
  assert.equal(visibleTeamSnippetIDs(tree, new Set()).length, 6);
});

// Small DOM adapter exercises real disclosure events and accessible state without a browser dependency.
function dom() {
  const createElement = (tagName) => ({
    tagName, children: [], dataset: {}, attributes: {}, listeners: {}, className: "", hidden: false,
    classList: { add() {} },
    append(...values) { this.children.push(...values); },
    setAttribute(key, value) { this.attributes[key] = value; },
    addEventListener(type, listener) { this.listeners[type] = listener; },
  });
  return { createElement };
}

test("disclosure remains enabled for Viewers and updates aria-expanded and visible selection", () => {
  const documentValue = dom();
  const container = documentValue.createElement("div");
  const collapsed = new Set();
  let visible;
  const rendered = renderTeamSnippetTree({ documentValue, container, records, collapsed, editable: false,
    onToggle(ids) { visible = ids; }, onCreateGroup() { assert.fail("disclosure must not create a folder"); },
  });
  assert.equal(rendered.containers.size, 6);
  const prod = container.children.find((node) => node.dataset.snippetFolder === "Prod");
  const [heading, create] = prod.children[0].children;
  const content = prod.children[1];
  assert.equal(create.disabled, true);
  assert.notEqual(heading.disabled, true);
  assert.equal(heading.attributes["aria-controls"], content.id);
  heading.listeners.click();
  assert.equal(content.hidden, true);
  assert.equal(heading.attributes["aria-expanded"], "false");
  assert.deepEqual(visible, ["root", "other"]);
  heading.listeners.click();
  assert.equal(content.hidden, false);
  assert.equal(collapsed.size, 0);
});

test("nested creation passes the exact parent and displays hostile-looking names as text", () => {
  const documentValue = dom();
  const container = documentValue.createElement("div");
  let parent;
  renderTeamSnippetTree({ documentValue, container, records: [snippet("x", "<svg onload=alert(1)>")],
    collapsed: new Set(), editable: true, onToggle() {}, onCreateGroup(path) { parent = path; },
  });
  const [heading, create] = container.children[0].children[0].children;
  assert.equal(heading.children[0].textContent, "<svg onload=alert(1)>");
  assert.equal(heading.children[0].attributes.translate, "no");
  create.listeners.click();
  assert.equal(parent, "<svg onload=alert(1)>");
});

test("Team workspace wires folder state cleanup, read-only navigation and encrypted upsert", async () => {
  const application = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const browser = await readFile(new URL("../public/team-snippet-browser.js", import.meta.url), "utf8");
  const html = await readFile(new URL("../public/index.html", import.meta.url), "utf8");
  assert.match(application, /function lockCurrentVault\(\) \{\s*stopBackgroundSync\(\);\s*resetRecordEditor\(\);\s*resetSnippetBrowser\(\{ lock: true \}\);/u);
  assert.match(application, /\.record-actions button, \[data-snippet-create-child\]/u);
  assert.match(application, /teamSnippetRecordData\(\{ title: recordTitle.value, body: recordSecret.value, folder: snippetFolder.value \}, existingRecord\?\.data\)/u);
  assert.match(application, /if \(controller !== editingController\) return;/u);
  assert.match(application, /snippetFilteredCollapsedFolders.clear\(\); renderRecords\(\);/u);
  assert.match(html, /id="team-snippet-group-create"/u);
  assert.match(html, /id="team-snippet-group-parent"/u);
  assert.match(html, /id="team-snippet-folder" name="snippetFolder"/u);
  assert.doesNotMatch(browser, /localStorage|sessionStorage|fetch\(|innerHTML|document.cookie/u);
});
