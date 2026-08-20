const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const hostScript = fs.readFileSync(
    path.join(
        __dirname,
        "../../Sources/SelectiveRemote/TerminalResources/terminal-host.js"
    ),
    "utf8"
);

test("terminal Snippets panel describes the shared Targets library", () => {
    assert.match(hostScript, /Общая библиотека · запуск по Targets/);
    assert.match(hostScript, /targetProfileIDs/);
    assert.match(hostScript, /Connecting SSH targets/);
});

test("terminal snippet editor renders and submits assigned SSH targets", () => {
    assert.match(hostScript, /const renderSnippetTargets = \(selectedIDs = \[\]\)/);
    assert.match(hostScript, /snippetTargetOptions = Array\.isArray\(payload\.snippetTargets\)/);
    assert.match(hostScript, /const targetProfileIDs = selectedSnippetTargetIDs\(\)/);
    assert.match(hostScript, /command: snippetCommand\.value,\s*targetProfileIDs/);
    assert.match(hostScript, /groupID: group\.id/);
});

test("snippet context menu supports local run, insert and clipboard copy", () => {
    assert.match(hostScript, /action === "runHere"/);
    assert.match(hostScript, /action === "insert"/);
    assert.match(hostScript, /action === "copy"/);
    assert.match(hostScript, /replaceCurrentLine\(entry\.command, true\)/);
    assert.match(hostScript, /action: "copySnippet"/);
});

test("snippet rendering uses stable group IDs with a legacy category fallback", () => {
    assert.match(hostScript, /entry\.groupID === group\.id/);
    assert.match(hostScript, /!entry\.groupID && entry\.category === group\.name/);
});

test("empty groups and snippet context menu can create in the current group", () => {
    assert.match(hostScript, /className = "snippet-empty-group-add"/);
    assert.match(hostScript, /openSnippetEditor\(null, group\.name\)/);
    assert.match(hostScript, /action === "new"/);
    assert.match(hostScript, /openSnippetEditor\(null, entry\.category\)/);
});

test("snippet deletion posts the command without an unsupported WKWebView confirm", () => {
    assert.match(
        hostScript,
        /action === "remove"\) \{\s*postHistory\(\{ action: "removeSnippet", id: entry\.id \}\)/
    );
    assert.doesNotMatch(
        hostScript,
        /window\.confirm\(snippetText\("deleteSnippetConfirm"\)/
    );
});

test("terminal selection keeps readable contrast and hides the syntax overlay", () => {
    assert.match(hostScript, /selectionForeground: "#FFFFFF"/);
    assert.match(hostScript, /terminal\.hasSelection\(\)/);
    assert.match(hostScript, /terminal\.onSelectionChange/);
    assert.match(hostScript, /luminance > 160 \? "#111827" : "#FFFFFF"/);
});
