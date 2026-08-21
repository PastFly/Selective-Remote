(() => {
    "use strict";

    const contextMenu = document.getElementById("snippet-context-menu");
    const panel = document.getElementById("terminal-history");
    const snippetOptions = document.getElementById("snippet-options");
    const originalSetPanelMode = window.selectiveTerminalSetPanelMode;

    if (!contextMenu || !panel || !snippetOptions || typeof originalSetPanelMode !== "function") {
        return;
    }

    let preserveForCurrentSnippetAction = false;

    // Capture runs before terminal-host.js handles the same click.  Only actions that
    // used to close the Snippets panel get the one-shot preservation flag.
    contextMenu.addEventListener("click", (event) => {
        const button = event.target.closest("button[data-action]");
        if (!button || !["runHere", "insert"].includes(button.dataset.action)) {
            return;
        }
        preserveForCurrentSnippetAction = true;
        queueMicrotask(() => {
            preserveForCurrentSnippetAction = false;
        });
    }, true);

    window.selectiveTerminalSetPanelMode = (
        mode,
        notifySwift = false,
        restoreTerminalFocus = true
    ) => {
        const snippetsAreVisible = !panel.hidden && !snippetOptions.hidden;
        if (mode === "hidden" && preserveForCurrentSnippetAction && snippetsAreVisible) {
            window.requestAnimationFrame(() => window.selectiveTerminalFit?.());
            return;
        }
        return originalSetPanelMode(mode, notifySwift, restoreTerminalFocus);
    };
})();
