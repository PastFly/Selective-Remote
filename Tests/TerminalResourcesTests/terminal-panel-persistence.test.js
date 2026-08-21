const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.join(__dirname, "../..");
const html = fs.readFileSync(
    path.join(root, "Sources/SelectiveRemote/TerminalResources/terminal.html"),
    "utf8"
);
const persistence = fs.readFileSync(
    path.join(root, "Sources/SelectiveRemote/TerminalResources/terminal-panel-persistence.js"),
    "utf8"
);

test("snippet persistence layer loads after terminal host", () => {
    const hostIndex = html.indexOf('src="terminal-host.js"');
    const persistenceIndex = html.indexOf('src="terminal-panel-persistence.js"');
    assert.ok(hostIndex >= 0);
    assert.ok(persistenceIndex > hostIndex);
});

test("run here and insert keep Snippets open while explicit close remains available", () => {
    assert.match(persistence, /\["runHere", "insert"\]/);
    assert.match(persistence, /mode === "hidden" && preserveForCurrentSnippetAction/);
    assert.match(persistence, /return originalSetPanelMode\(mode, notifySwift, restoreTerminalFocus\)/);
});
