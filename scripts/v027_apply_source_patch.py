from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, got {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


embedded = Path("Sources/SelectiveRemote/EmbeddedTerminalView.swift")
replace_once(
    embedded,
    '''    private var workspaceInspectorVisible: Bool {\n        workspace.layout == .grid && (showsHistory || showsSnippets)\n    }''',
    '''    private var workspaceInspectorVisible: Bool {\n        showsHistory || showsSnippets\n    }''',
)

replace_once(
    embedded,
    '''                historyVisible: Binding(\n                    get: {\n                        workspace.layout != .grid\n                            && showsHistory\n                            && tab.id == workspace.selectedTabID\n                    },\n                    set: { visible in\n                        // Each pane owns a WKWebView and can report its history visibility\n                        // asynchronously. Ignore stale callbacks from a pane that stopped\n                        // being active, otherwise two grid panes can keep re-selecting each\n                        // other while the history panel is open.\n                        guard workspace.layout != .grid,\n                              tab.id == workspace.selectedTabID\n                        else { return }\n                        showsHistory = visible\n                        if visible { showsSnippets = false }\n                    }\n                ),''',
    '''                historyVisible: Binding(\n                    get: { false },\n                    set: { visible in\n                        // The native SwiftUI inspector is the single History surface in\n                        // every layout. WebView shortcuts may request it, but the embedded\n                        // quick panel itself stays hidden.\n                        guard tab.id == workspace.selectedTabID else { return }\n                        showsHistory = visible\n                        if visible { showsSnippets = false }\n                    }\n                ),''',
)

replace_once(
    embedded,
    '''                snippetsVisible: Binding(\n                    get: {\n                        workspace.layout != .grid\n                            && showsSnippets\n                            && tab.id == workspace.selectedTabID\n                    },\n                    set: { visible in\n                        guard workspace.layout != .grid,\n                              tab.id == workspace.selectedTabID\n                        else { return }\n                        showsSnippets = visible\n                        if visible { showsHistory = false }\n                    }\n                )''',
    '''                snippetsVisible: Binding(\n                    get: { false },\n                    set: { visible in\n                        guard tab.id == workspace.selectedTabID else { return }\n                        showsSnippets = visible\n                        if visible { showsHistory = false }\n                    }\n                )''',
)

sftp = Path("Sources/SelectiveRemote/SFTPInspectorViews.swift")
replace_once(
    sftp,
    "        .toggleStyle(.checkbox)",
    "        .toggleStyle(SelectiveRemoteCheckboxToggleStyle())",
)

# Remove the temporary self-patcher from the resulting source commit.
Path("scripts/v027_apply_source_patch.py").unlink(missing_ok=True)
Path(".github/workflows/v027-source-patch.yml").unlink(missing_ok=True)
