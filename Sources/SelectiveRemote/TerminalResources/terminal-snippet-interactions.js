((root, factory) => {
    const api = factory();
    if (typeof module === "object" && module.exports) {
        module.exports = api;
    }
    if (root) {
        root.SelectiveTerminalSnippetInteractions = api;
    }
})(typeof globalThis === "object" ? globalThis : this, () => {
    "use strict";

    const decision = ({ eventType, targetKind, editorActive = false }) => {
        if (editorActive || targetKind !== "snippet") {
            return "none";
        }
        if (eventType === "click") {
            return "select";
        }
        if (eventType === "dblclick" || eventType === "enter") {
            return "run";
        }
        return "none";
    };

    return { decision };
});
