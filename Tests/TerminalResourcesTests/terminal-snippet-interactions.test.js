const test = require("node:test");
const assert = require("node:assert/strict");
const interactions = require(
    "../../Sources/SelectiveRemote/TerminalResources/terminal-snippet-interactions.js"
);

test("single click selects without running", () => {
    assert.equal(interactions.decision({
        eventType: "click",
        targetKind: "snippet"
    }), "select");
});

test("double click produces exactly one run decision", () => {
    const browserEvents = ["click", "click", "dblclick"];
    const decisions = browserEvents.map((eventType) => interactions.decision({
        eventType,
        targetKind: "snippet"
    }));
    assert.deepEqual(decisions, ["select", "select", "run"]);
    assert.equal(decisions.filter((value) => value === "run").length, 1);
});

test("Enter runs a selected snippet but not a group or editor", () => {
    assert.equal(interactions.decision({
        eventType: "enter",
        targetKind: "snippet"
    }), "run");
    assert.equal(interactions.decision({
        eventType: "enter",
        targetKind: "group"
    }), "none");
    assert.equal(interactions.decision({
        eventType: "enter",
        targetKind: "snippet",
        editorActive: true
    }), "none");
});
