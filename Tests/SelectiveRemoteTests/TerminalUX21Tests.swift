import Foundation
import Testing
@testable import SelectiveRemote

@Test("Подсветка shell-команд включена по умолчанию и сохраняется")
@MainActor
func terminalSyntaxHighlightingPersists() throws {
    let suiteName = "SelectiveRemote.SyntaxHighlighting.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let fresh = TerminalAppearanceStore(defaults: defaults)
    #expect(fresh.syntaxHighlighting)
    #expect(fresh.snapshot.syntaxHighlighting)

    fresh.syntaxHighlighting = false
    let restored = TerminalAppearanceStore(defaults: defaults)
    #expect(restored.syntaxHighlighting == false)
    #expect(restored.snapshot.syntaxHighlighting == false)
}

@Test("Syntax highlighting остаётся визуальным слоем и не меняет PTY поток")
func terminalSyntaxHighlightingIsVisualOnly() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let resources = projectRoot
        .appendingPathComponent("Sources/SelectiveRemote/TerminalResources")

    let html = try String(
        contentsOf: resources.appendingPathComponent("terminal.html"),
        encoding: .utf8
    )
    let css = try String(
        contentsOf: resources.appendingPathComponent("terminal-host.css"),
        encoding: .utf8
    )
    let script = try String(
        contentsOf: resources.appendingPathComponent("terminal-host.js"),
        encoding: .utf8
    )

    #expect(html.contains("id=\"terminal-input-highlight\""))
    #expect(css.contains("#terminal-input-highlight"))
    #expect(css.contains("--syntax-command"))
    #expect(script.contains("tokenizeShellSyntax"))
    #expect(script.contains("renderInputHighlight"))
    #expect(script.contains("lineStartedAtShellPrompt"))
    #expect(script.contains("syntaxHighlightingEnabled"))
    #expect(script.contains("terminalInput.postMessage(data)"))
    #expect(script.contains("terminal.write(bytes"))
    #expect(script.contains("allowProposedApi: false"))
    #expect(!script.contains("allowProposedApi: true"))
    #expect(!script.contains("registerDecoration("))
    #expect(script.contains("span.textContent = token.text"))
}

@Test("Каталог тем показывает hover preview без применения темы")
func terminalThemeCatalogHasLivePreview() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/TerminalThemeCatalog.swift"),
        encoding: .utf8
    )

    #expect(source.contains("TerminalThemeLivePreview"))
    #expect(source.contains("@State private var previewPreset"))
    #expect(source.contains(".onHover { hovering in"))
    #expect(source.contains("previewPreset = preset"))
    #expect(source.contains("store.applyPreset(preset)"))
    #expect(source.contains("grep"))
    #expect(source.contains("/var/log/nginx/*.log"))
}
@Test("Подсказки команд поддерживают стрелки, Enter и Tab")
func terminalSuggestionsSupportKeyboardAcceptance() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/TerminalResources/terminal-host.js"),
        encoding: .utf8
    )

    #expect(source.contains(#"event.key === "ArrowDown""#))
    #expect(source.contains(#"event.key === "ArrowUp""#))
    #expect(source.contains(#"event.key === "Tab""#))
    #expect(source.contains("useCommandEntry(currentSuggestions[index])"))
}

@Test("Трекер команд восстанавливается из xterm после shell redraw")
func terminalInputTrackingRecoversAfterShellRedraw() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/TerminalResources/terminal-host.js"),
        encoding: .utf8
    )

    #expect(source.contains("const recoverTrackedLineFromTerminal = () =>"))
    #expect(source.contains("promptPrefix"))
    #expect(source.contains("line.translateToString("))
    #expect(source.contains("const recoveredTrackedLine = ("))
    #expect(source.contains("renderSuggestions();"))
    #expect(source.contains("window.webkit.messageHandlers.terminalInput.postMessage(data);"))
}
@Test("Подсветка shell-команды берёт строку из xterm buffer")
func terminalSyntaxHighlightingUsesRenderedXtermLine() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/TerminalResources/terminal-host.js"),
        encoding: .utf8
    )

    #expect(source.contains("const shellCommandRegionsFromBuffer = () =>"))
    #expect(source.contains("buffer.getLine(bufferRow)"))
    #expect(source.contains("line.translateToString(true)"))
    #expect(source.contains("inputHighlightOrigin?.promptPrefix"))
    #expect(source.contains("terminal.onWriteParsed(() =>"))
    #expect(source.contains("tokenizeShellSyntax(region.text)"))
    #expect(source.contains("window.webkit.messageHandlers.terminalInput.postMessage(data);"))
}

@Test("Terminal Syntax 2.2 сохраняет область и пользовательскую палитру")
@MainActor
func terminalSyntaxFullViewportSettingsPersist() throws {
    let suiteName = "SelectiveRemote.Syntax22.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let original = TerminalAppearanceStore(defaults: defaults)
    #expect(original.syntaxScope == .visibleCommands)
    #expect(original.syntaxFollowTheme)
    #expect(original.syntaxBoldCommands)

    original.syntaxScope = .currentLine
    original.syntaxFollowTheme = false
    original.syntaxHistoryOpacity = 0.65
    original.syntaxBoldCommands = false
    original.updateSyntaxColor(\.command, "#123456")

    let restored = TerminalAppearanceStore(defaults: defaults)
    #expect(restored.syntaxScope == .currentLine)
    #expect(restored.syntaxFollowTheme == false)
    #expect(restored.syntaxHistoryOpacity == 0.65)
    #expect(restored.syntaxBoldCommands == false)
    #expect(restored.syntaxCustomPalette.command == "#123456")
    #expect(restored.snapshot.syntaxPalette.command == "#123456")
}

@Test("Terminal Syntax 2.2 следует палитре активной темы")
@MainActor
func terminalSyntaxPaletteCanFollowTheme() throws {
    let suiteName = "SelectiveRemote.SyntaxTheme.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = TerminalAppearanceStore(defaults: defaults)
    store.applyPreset(.dracula)

    #expect(store.syntaxFollowTheme)
    #expect(store.snapshot.syntaxPalette.command == TerminalThemePreset.dracula.palette.brightBlue)
    #expect(store.snapshot.syntaxPalette.option == TerminalThemePreset.dracula.palette.cyan)
    #expect(store.snapshot.syntaxPalette.number == TerminalThemePreset.dracula.palette.yellow)
}

@Test("Terminal Syntax 2.2 подсвечивает только command lines видимого viewport")
func terminalSyntaxFullViewportIsVisualOnly() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let resources = projectRoot
        .appendingPathComponent("Sources/SelectiveRemote/TerminalResources")
    let script = try String(
        contentsOf: resources.appendingPathComponent("terminal-host.js"),
        encoding: .utf8
    )
    let css = try String(
        contentsOf: resources.appendingPathComponent("terminal-host.css"),
        encoding: .utf8
    )

    #expect(script.contains("const shellCommandRegionsFromBuffer = () =>"))
    #expect(script.contains("buffer.viewportY"))
    #expect(script.contains("knownPromptPrefixes"))
    #expect(script.contains(#"syntaxHighlightScope === "currentLine""#))
    #expect(script.contains("terminal.onScroll(() =>"))
    #expect(script.contains("scheduleInputHighlightRender"))
    #expect(script.contains("settings.syntaxPalette"))
    #expect(script.contains("window.webkit.messageHandlers.terminalInput.postMessage(data);"))
    #expect(script.contains("terminal.write(bytes"))
    #expect(!script.contains("registerDecoration("))
    #expect(css.contains(".terminal-syntax-row.is-history"))
    #expect(css.contains("--syntax-history-opacity"))
    #expect(css.contains("--syntax-command-weight"))
}

