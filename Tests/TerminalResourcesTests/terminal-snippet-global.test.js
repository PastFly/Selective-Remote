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
