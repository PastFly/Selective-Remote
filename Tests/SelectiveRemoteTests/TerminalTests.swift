import Foundation
import Testing
@testable import SelectiveRemote

@Test("Терминал игнорирует промежуточную почти нулевую геометрию SwiftUI")
@MainActor
func ignoresTransientTinyTerminalGeometry() {
    let session = TerminalSessionModel()

    session.resize(columns: 2, rows: 1)
    #expect(session.terminalColumns == 100)
    #expect(session.terminalRows == 30)

    session.resize(columns: 184, rows: 52)
    #expect(session.terminalColumns == 184)
    #expect(session.terminalRows == 52)
}

@Test("Тема, шрифт и размер терминала сохраняются между открытиями")
@MainActor
func persistsTerminalAppearance() throws {
    let suiteName = "SelectiveRemote.TerminalTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let original = TerminalAppearanceStore(defaults: defaults)
    original.applyPreset(.hackerGreen)
    original.font = .menlo
    original.fontSize = 19
    original.lineHeight = 1.3
    original.cursorStyle = .bar
    original.cursorBlink = false
    original.padding = 6

    let restored = TerminalAppearanceStore(defaults: defaults)
    #expect(restored.selectedPreset == .hackerGreen)
    #expect(restored.palette == TerminalThemePreset.hackerGreen.palette)
    #expect(restored.font == .menlo)
    #expect(restored.fontSize == 19)
    #expect(restored.lineHeight == 1.3)
    #expect(restored.cursorStyle == .bar)
    #expect(restored.cursorBlink == false)
    #expect(restored.padding == 6)

    let encoded = try JSONEncoder().encode(restored.snapshot)
    let json = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(json["fontFamily"] as? String == TerminalFontChoice.menlo.cssValue)
    #expect((json["theme"] as? [String: Any])?["background"] as? String == "#07110C")
}

@Test("Терминал предлагает расширенный набор встроенных тем")
func exposesExpandedTerminalThemes() {
    #expect(TerminalThemePreset.allCases.count == 26)
    #expect(TerminalThemePreset.allCases.contains(.tokyoNight))
    #expect(TerminalThemePreset.allCases.contains(.catppuccinMocha))
    #expect(TerminalThemePreset.allCases.contains(.rosePine))
    #expect(TerminalThemePreset.solarizedLight.palette.background == "#FDF6E3")
}

@Test("Бренд приложения везде называется Selective Remote")
func usesSelectiveRemoteBrand() {
    #expect(AppBrand.name == "Selective Remote")
    #expect(AppBrand.tagline == "RDP · SSH · SFTP")
}

@Test("Локальный терминал хранит рабочую папку отдельно от SSH")
func localTerminalConnectionRoundTrips() throws {
    let original = TerminalTabConnection.local(workingDirectory: "/tmp")
    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(TerminalTabConnection.self, from: data)

    #expect(restored.kind == .local)
    #expect(restored.workingDirectory == "/tmp")
    #expect(restored.displayLabel(profiles: []) == "/tmp")
    #expect(!restored.isValidCustomConnection)
}

@Test("Прозрачность окна сохраняется между запусками")
@MainActor
func persistsApplicationTransparency() throws {
    let suiteName = "SelectiveRemote.AppAppearanceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let original = AppAppearanceStore(defaults: defaults)
    original.transparencyEnabled = true
    original.opacity = 0.73

    let restored = AppAppearanceStore(defaults: defaults)
    #expect(restored.transparencyEnabled)
    #expect(restored.opacity == 0.73)
    #expect(restored.opacityPercent == 73)
    #expect(restored.snapshot.transparencyEnabled)
}

@Test("Состояние прозрачности не перекрывает NSView.appearance")
func windowTransparencyAvoidsNSAppearanceOverride() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = projectRoot
        .appendingPathComponent("Sources/SelectiveRemote/AppAppearance.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("private var windowSettings"))
    #expect(!source.contains("private var appearance = AppWindowAppearanceSnapshot"))
}

@Test("xterm учитывает внутренний отступ и не обрезает последнюю строку")
func terminalHostInsetDoesNotInflateFitAddonGeometry() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let cssURL = projectRoot
        .appendingPathComponent("Sources/SelectiveRemote/TerminalResources/terminal-host.css")
    let css = try String(contentsOf: cssURL, encoding: .utf8)

    #expect(css.contains("width: calc(100% - (2 * var(--terminal-padding)))"))
    #expect(css.contains("height: calc(100% - (2 * var(--terminal-padding)))"))
    #expect(css.contains("margin: var(--terminal-padding)"))
    #expect(css.contains("padding: 0"))
    #expect(!css.contains("padding: var(--terminal-padding)"))
}

@Test("CSP разрешает геометрию xterm, но не сторонние скрипты")
func terminalContentSecurityPolicySupportsXtermLayout() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let htmlURL = projectRoot
        .appendingPathComponent("Sources/SelectiveRemote/TerminalResources/terminal.html")
    let html = try String(contentsOf: htmlURL, encoding: .utf8)

    #expect(html.contains("style-src 'self' 'unsafe-inline'"))
    #expect(html.contains("script-src 'self'"))
    #expect(!html.contains("script-src 'self' 'unsafe-inline'"))
}

@Test("История команд сохраняется отдельно для каждого SSH-профиля")
@MainActor
func persistsTerminalCommandHistoryPerProfile() throws {
    let suiteName = "SelectiveRemote.CommandHistoryTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let firstProfile = UUID()
    let secondProfile = UUID()
    let firstDate = Date(timeIntervalSince1970: 100)
    let secondDate = Date(timeIntervalSince1970: 200)

    let original = TerminalCommandHistoryStore(defaults: defaults)
    #expect(original.record(command: "uname -a", profileID: firstProfile, now: firstDate))
    #expect(original.record(command: "df -h", profileID: secondProfile, now: secondDate))
    #expect(original.record(command: "uname -a", profileID: firstProfile, now: secondDate))

    let restored = TerminalCommandHistoryStore(defaults: defaults)
    let firstEntries = restored.entries(for: firstProfile)
    #expect(firstEntries.count == 1)
    #expect(firstEntries.first?.command == "uname -a")
    #expect(firstEntries.first?.useCount == 2)
    #expect(restored.entries(for: secondProfile).map(\.command) == ["df -h"])
}

@Test("История не сохраняет приватные и служебные строки")
@MainActor
func filtersSensitiveTerminalHistory() throws {
    let suiteName = "SelectiveRemote.CommandPrivacyTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = TerminalCommandHistoryStore(defaults: defaults)
    let profileID = UUID()

    #expect(!store.record(command: " export TOKEN=secret", profileID: profileID))
    #expect(!store.record(command: "export TOKEN=secret", profileID: profileID))
    #expect(!store.record(command: "curl -H 'Authorization: Bearer value'", profileID: profileID))
    #expect(store.record(command: "systemctl status ssh", profileID: profileID))
    #expect(store.entries(for: profileID).map(\.command) == ["systemctl status ssh"])
}

@Test("История команд ограничивает размер и поддерживает очистку")
@MainActor
func limitsAndClearsTerminalHistory() throws {
    let suiteName = "SelectiveRemote.CommandLimitTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = TerminalCommandHistoryStore(defaults: defaults, maximumEntries: 2)
    let profileID = UUID()

    #expect(store.record(command: "one", profileID: profileID, now: Date(timeIntervalSince1970: 1)))
    #expect(store.record(command: "two", profileID: profileID, now: Date(timeIntervalSince1970: 2)))
    #expect(store.record(command: "three", profileID: profileID, now: Date(timeIntervalSince1970: 3)))
    #expect(store.entries(for: profileID).map(\.command) == ["three", "two"])

    store.clear(profileID: profileID)
    #expect(store.entries(for: profileID).isEmpty)
}

@Test("Интерфейс терминала содержит подсказки и панель истории")
func terminalIncludesHistoryInterface() throws {
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
    let script = try String(
        contentsOf: resources.appendingPathComponent("terminal-host.js"),
        encoding: .utf8
    )
    let catalog = try String(
        contentsOf: resources.appendingPathComponent("terminal-command-catalog.js"),
        encoding: .utf8
    )
    let snippetInteractions = try String(
        contentsOf: resources.appendingPathComponent("terminal-snippet-interactions.js"),
        encoding: .utf8
    )

    #expect(html.contains("id=\"terminal-suggestions\""))
    #expect(html.contains("id=\"terminal-history\""))
    #expect(html.contains("id=\"history-query\""))
    #expect(html.contains("data-section=\"catalog\""))
    #expect(html.contains("data-section=\"remote\""))
    #expect(html.contains("data-section=\"favorites\""))
    #expect(html.contains("id=\"snippets-list\""))
    #expect(html.contains("id=\"snippet-dialog\""))
    #expect(html.contains("id=\"snippet-group-dialog\""))
    #expect(html.contains("id=\"snippet-context-menu\""))
    #expect(html.contains("id=\"remote-context-retry\""))
    #expect(html.contains("terminal-command-catalog.js"))
    #expect(script.contains("selectiveTerminalSetHistory"))
    #expect(script.contains("retryRemoteContext"))
    #expect(script.contains("isAlternateScreen"))
    #expect(script.contains("outputContainsEchoedCommand"))
    #expect(script.contains("outputEndsInShellPrompt"))
    #expect(script.contains("alternateScreenWasActive"))
    #expect(script.contains("matchingCatalog"))
    #expect(script.contains("normalizedSearchTokens"))
    #expect(script.contains("fuzzyTokenMatch"))
    #expect(script.contains("toggleFavorite"))
    #expect(script.contains("resolveTemplate"))
    #expect(script.contains("selectiveTerminalSetPanelMode"))
    #expect(script.contains("runSnippet"))
    #expect(script.contains("panelVisibility"))
    #expect(snippetInteractions.contains("eventType === \"click\""))
    #expect(snippetInteractions.contains("eventType === \"dblclick\""))
    #expect(snippetInteractions.contains("eventType === \"enter\""))
    #expect(catalog.contains("sudo systemctl restart "))
    #expect(catalog.contains("nano /etc/ssh/sshd_config"))
    #expect(catalog.contains("nano ~/.ssh/authorized_keys"))
    #expect(catalog.contains("touch ~/.ssh/authorized_keys"))
    #expect(catalog.contains("journalctl -u ssh"))
    #expect(catalog.contains("kubectl rollout restart deployment/"))
    #expect(catalog.contains("docker compose logs --tail 100 -f"))
    #expect(catalog.components(separatedBy: "],").count >= 200)
}

@Test("Контекст сервера привязан к активной вкладке и использует SSH credentials")
func terminalServerContextUsesActiveTabAuthentication() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let appModel = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/AppModel.swift"),
        encoding: .utf8
    )
    let embedded = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/EmbeddedTerminalView.swift"),
        encoding: .utf8
    )
    let sshService = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/SSHService.swift"),
        encoding: .utf8
    )
    let workspace = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/TerminalWorkspace.swift"),
        encoding: .utf8
    )
    let contentView = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )

    #expect(contentView.contains("connection: tab.connection"))
    #expect(contentView.contains("tabID: tab.id"))
    #expect(appModel.contains("requiresIndependentAuthentication: true"))
    #expect(appModel.contains("reuseRunningTerminalAuthorization: true"))
    #expect(appModel.contains("isRunningTerminalTab(connection: connection, tabID: tabID)"))
    #expect(appModel.contains("requiresUserPresence: false"))
    #expect(appModel.contains("SSHKeyService.backgroundAuthenticationEnvironment"))
    #expect(appModel.contains("jumpHostPasswordCredential: settings.jumpHostProfileID.map"))
    #expect(sshService.contains("requiresUserPresence: Bool = true"))
    #expect(sshService.contains("requiresUserPresence && requiresTouchID"))
    #expect(embedded.contains("remoteContextRequestIDs"))
    #expect(embedded.contains("workspace.remoteContext(for: tab.id)"))
    #expect(workspace.contains("@Published private(set) var remoteContexts"))
    #expect(workspace.contains("func invalidateRemoteContext(for tabID: UUID)"))
    #expect(workspace.contains("tab.session.$phase.sink"))
    #expect(embedded.contains("currentTab.connection == expectedConnection"))
    #expect(embedded.contains("if action == \"retryRemoteContext\""))
    #expect(embedded.contains("onRemoteContextRetry()"))
    #expect(embedded.contains(".help(\"История и подсказки\")"))
}

@Test("Перезагрузка WebView повторно выводит активную SSH-сессию")
func terminalReloadReplaysActiveSession() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = projectRoot
        .appendingPathComponent("Sources/SelectiveRemote/EmbeddedTerminalView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let sessionURL = projectRoot
        .appendingPathComponent("Sources/SelectiveRemote/PTYSession.swift")
    let sessionSource = try String(contentsOf: sessionURL, encoding: .utf8)

    #expect(source.contains("didStartProvisionalNavigation"))
    #expect(source.contains("navigationGeneration"))
    #expect(source.contains("detachObserver()"))
    #expect(source.contains("observeSession()"))
    #expect(source.contains("TerminalSessionModel replays its retained"))
    #expect(sessionSource.contains("observer(Data(\"\\u{001B}c\".utf8))"))
    #expect(sessionSource.contains("observer(replayBuffer)"))
}

@Test("Каждая вкладка SSH может использовать собственное подключение")
func terminalTabsExposeIndependentConnectionEditor() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/EmbeddedTerminalView.swift"
        ),
        encoding: .utf8
    )
    let workspace = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/TerminalWorkspace.swift"
        ),
        encoding: .utf8
    )

    #expect(source.contains("TerminalConnectionEditor"))
    #expect(workspace.contains("Из сохранённых"))
    #expect(workspace.contains("Другой сервер"))
    #expect(workspace.contains("var connection: TerminalTabConnection"))
    #expect(workspace.contains("isValidCustomConnection"))
    #expect(source.contains("if let tab = workspace.addTab"))
    #expect(source.contains("connect(tab, temporaryPassword)"))
    #expect(source.contains("connect(tab, nil)"))
    #expect(source.contains("requestConnection(for: workspace.selectedTab)"))
    #expect(source.contains("requestConnection(for: tab)"))
    #expect(source.contains("terminalFocus"))
    #expect(source.contains(".dropDestination(for: String.self)"))
    #expect(source.contains("GeometryReader"))
    #expect(source.contains("showsLayoutPicker"))
    #expect(workspace.contains("func moveTab"))
    #expect(workspace.contains("func duplicateTab"))
    #expect(source.contains("Создать копию вкладки"))
    #expect(workspace.contains("var displayedTabs"))
    #expect(workspace.contains("Array(displayedTabs.prefix"))
}

@Test("Приложение содержит глобальные Terminal, SFTP и Forwarding")
func exposesGlobalSSHWorkspaces() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let content = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/ContentView.swift"
        ),
        encoding: .utf8
    )
    let forwarding = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/ForwardingManager.swift"
        ),
        encoding: .utf8
    )
    #expect(content.contains("case terminal = \"Терминал\""))
    #expect(content.contains("case sftp = \"SFTP\""))
    #expect(content.contains("case forwarding = \"Forwarding\""))
    #expect(content.contains("model.globalTerminalWorkspace()"))
    #expect(content.contains("SFTPWorkspaceView(workspace: model.sftpWorkspace)"))
    #expect(!content.contains("showsGlobalSFTPConnectionEditor"))
    #expect(content.contains("ForwardingManagerView("))
    #expect(forwarding.contains("model.independentPortForwards"))
    #expect(forwarding.contains("model.startIndependentPortForward"))
}

@Test("SSH-профиль использует современную настройку и полноразмерные рабочие области")
func sshProfileUsesModernSettingsAndFullSizeWorkspaces() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let content = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/ContentView.swift"
        ),
        encoding: .utf8
    )

    #expect(content.contains("case authentication = \"Аутентификация\""))
    #expect(content.contains("case route = \"Маршрут\""))
    #expect(content.contains("private var sshProfileWorkspace: some View"))
    #expect(content.contains("private var sshSectionRail: some View"))
    #expect(content.contains("private var sshProfileInspector: some View"))
    #expect(content.contains("private var sshRuntimeWorkspace: some View"))
    #expect(content.contains("private var sshCompactWorkspaceHeader: some View"))
    #expect(content.contains("private var sshWorkspaceSwitcher: some View"))
    #expect(content.contains("terminalPanel\n                .id(profile.id)"))
    #expect(content.contains("SFTPWorkspaceView(workspace: model.sftpWorkspace)"))
    #expect(!content.contains("SFTPBrowserView(profile: profile, session: sftpSession)"))
    #expect(content.contains("PortForwardingView(profile: profile)"))
    #expect(content.contains("else if selectedTab != .terminal"))
    #expect(content.contains("private var focusExitBar: some View"))
    #expect(!content.contains(".overlay(alignment: .topTrailing)"))
    #expect(!content.contains("legacyProfileDetail"))
    #expect(!content.contains("sshGeneralSettings"))
    #expect(!content.contains("private var profileTabPicker"))
}

@Test("Двойной клик запускает профильный и независимый SSH-туннель")
func forwardingRowsKeepDoubleClickStartGesture() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let manager = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/ForwardingManager.swift"
        ),
        encoding: .utf8
    )
    let profile = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/PortForwardingView.swift"
        ),
        encoding: .utf8
    )

    #expect(manager.contains(".simultaneousGesture("))
    #expect(manager.contains("TapGesture(count: 2).onEnded"))
    #expect(manager.contains("start(item)"))
    #expect(manager.contains("model.startProfileSSHTunnel"))
    #expect(manager.contains("model.startIndependentPortForward"))
    #expect(profile.contains(".simultaneousGesture("))
    #expect(profile.contains("TapGesture(count: 2).onEnded"))
    #expect(profile.contains("model.startSSHTunnel(rule.id)"))
}

@Test("Публичный проект содержит английский интерфейс и README")
func includesEnglishLocalizationAndDocumentation() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let localization = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Resources/en.lproj/Localizable.strings"
        ),
        encoding: .utf8
    )
    let readme = try String(
        contentsOf: projectRoot.appendingPathComponent("README_EN.md"),
        encoding: .utf8
    )
    #expect(localization.contains("\"Подключения\" = \"Connections\""))
    #expect(localization.contains("\"Другой сервер\" = \"Other server\""))
    #expect(localization.contains("\"Язык приложения\" = \"Application Language\""))
    #expect(localization.contains("\"SFTP не подключён\" = \"SFTP is not connected\""))
    #expect(readme.contains("### Terminal Workspace"))
    #expect(readme.contains("### Forwarding Manager"))
}

@Test("Защищённый SSH-запрос поддерживает вставку пароля")
func sshAskPassSupportsPaste() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let helper = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Native/SSHKeychainAskPass.swift"
        ),
        encoding: .utf8
    )
    let readme = try String(
        contentsOf: projectRoot.appendingPathComponent("README.md"),
        encoding: .utf8
    )

    #expect(helper.contains("#selector(NSText.paste(_:))"))
    #expect(helper.contains("keyEquivalent: \"v\""))
    #expect(helper.contains("field.menu = fieldMenu"))
    #expect(!readme.contains("Почему камера не работала в 0.7.1"))
}

@Test("Сборка DMG отключает образ по device node")
func dmgBuildDetachesStableDeviceNode() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let buildScript = try String(
        contentsOf: projectRoot.appendingPathComponent("scripts/build_app.sh"),
        encoding: .utf8
    )

    #expect(buildScript.contains("DMG_DEVICE=\"\""))
    #expect(buildScript.contains("target=\"${DMG_DEVICE:-$DMG_MOUNT}\""))
    #expect(buildScript.contains("hdiutil info | grep -Fq -- \"$DMG_DEVICE\""))
}

@Test("Палитра терминала не использует падающий bridge SwiftUI Color в NSColor")
func terminalPaletteAvoidsSwift63ColorBridge() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = projectRoot
        .appendingPathComponent("Sources/SelectiveRemote/TerminalAppearance.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("NSColorWell"))
    #expect(source.contains("@MainActor @objc func colorChanged"))
    #expect(!source.contains("NSColor(color)"))
    #expect(!source.contains("ColorPicker("))
}
