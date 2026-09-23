import Foundation
import AppKit
import Testing
@testable import SelectiveRemote

private func repositorySource(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: root.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

@Test("Live NSApplication mainMenu survives locale switches and a SwiftUI menu rebuild")
@MainActor
func liveApplicationMenuFollowsRuntimeLanguageAfterRebuild() async {
    let app = NSApplication.shared
    let previous = app.mainMenu
    defer { app.mainMenu = previous }

    func installMenu() -> NSMenu {
        let menu = NSMenu()
        for title in ["Selective Remote", "Файл", "Правка", "Вид", "Session", "Cloud", "Окно", "Справка"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            if title == "Файл" {
                submenu.addItem(NSMenuItem(
                    title: "Закрыть окно",
                    action: #selector(NSWindow.performClose(_:)),
                    keyEquivalent: "w"
                ))
            }
            item.submenu = submenu
            menu.addItem(item)
        }
        app.mainMenu = menu
        return menu
    }

    func titles() -> [String] { app.mainMenu?.items.map(\.title) ?? [] }
    let menu = installMenu()
    RuntimeMenuLocalization.refresh(.russian)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(titles() == ["Selective Remote", "Файл", "Правка", "Вид", "Сеанс", "Cloud", "Окно", "Справка"])

    RuntimeMenuLocalization.refresh(.english)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(titles() == ["Selective Remote", "File", "Edit", "View", "Session", "Cloud", "Window", "Help"])
    #expect(menu.items[1].submenu?.items[0].action == #selector(NSWindow.performClose(_:)))
    #expect(menu.items[1].submenu?.items[0].keyEquivalent == "w")

    _ = installMenu() // SwiftUI/AppKit may rebuild system menus after the first refresh.
    NotificationCenter.default.post(name: NSApplication.didUpdateNotification, object: app)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(titles() == ["Selective Remote", "File", "Edit", "View", "Session", "Cloud", "Window", "Help"])

    RuntimeMenuLocalization.refresh(.russian)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(titles() == ["Selective Remote", "Файл", "Правка", "Вид", "Сеанс", "Cloud", "Окно", "Справка"])
}

@Test("Runtime language switch localizes Settings, Appearance, and native menu titles both ways")
@MainActor
func runtimeLanguageSwitchLocalizesAllSurfaces() throws {
    let suiteName = "RuntimeLocalizationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let language = AppLanguageStore(defaults: defaults)

    let menu = NSMenu()
    for title in ["Файл", "Правка", "Вид", "Сессия", "Cloud", "Окно", "Справка"] {
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
    }
    let file = NSMenu(title: "Файл")
    file.addItem(NSMenuItem(title: "Закрыть", action: nil, keyEquivalent: "w"))
    menu.items[0].submenu = file

    language.selection = .english
    #expect(language.localized("settings.tab.appearance") == "Appearance")
    #expect(language.localized("appearance.section.window") == "Application Window")
    #expect(language.localized("appearance.help.language") == "The interface switches immediately. System mode follows the macOS language.")
    RuntimeMenuLocalization.apply(to: menu, language: language.selection)
    #expect(menu.items.map(\.title) == ["File", "Edit", "View", "Session", "Cloud", "Window", "Help"])
    #expect(menu.items[0].submenu?.items.first?.title == "Close")
    #expect(menu.items[0].submenu?.items.first?.keyEquivalent == "w")

    language.selection = .russian
    #expect(language.localized("settings.tab.appearance") == "Оформление")
    #expect(language.localized("appearance.section.window") == "Окно приложения")
    RuntimeMenuLocalization.apply(to: menu, language: language.selection)
    #expect(menu.items.map(\.title) == ["Файл", "Правка", "Вид", "Сеанс", "Cloud", "Окно", "Справка"])
    #expect(menu.items[0].submenu?.items.first?.title == "Закрыть")
}

@Test("Appearance selector current values and options follow the live application language")
@MainActor
func appearanceSelectorValuesFollowRuntimeLanguage() throws {
    let suiteName = "AppearanceSelectorLocalization.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let language = AppLanguageStore(defaults: defaults)

    language.selection = .russian
    #expect(AppTheme.dark.localizedTitle(in: language.selection) == "Тёмная")
    #expect(AppLanguage.system.localizedTitle(in: language.selection) == "Системный")
    #expect(AppTextSize.standard.localizedTitle(in: language.selection) == "Обычный")
    #expect(AppDensity.standard.localizedTitle(in: language.selection) == "Стандартная")
    #expect(AppTheme.allCases.allSatisfy { !$0.localizedTitle(in: language.selection).isEmpty })

    language.selection = .english
    #expect(AppTheme.dark.localizedTitle(in: language.selection) == "Dark")
    #expect(AppLanguage.system.localizedTitle(in: language.selection) == "System")
    #expect(AppLanguage.russian.localizedTitle(in: language.selection) == "Russian")
    #expect(AppTextSize.standard.localizedTitle(in: language.selection) == "Normal")
    #expect(AppDensity.standard.localizedTitle(in: language.selection) == "Standard")
    #expect(AppTheme.allCases.allSatisfy {
        !$0.localizedTitle(in: language.selection).unicodeScalars.contains {
            (0x0400...0x052F).contains($0.value)
        }
    })
    language.selection = .russian
    #expect(AppTheme.dark.localizedTitle(in: language.selection) == "Тёмная")
}

@Test("Security Settings timeout selector values are explicit runtime-localized choices")
@MainActor
func appLockTimeoutChoicesFollowRuntimeLanguage() throws {
    let expected: [(String, String, String)] = [
        ("security.timeout.immediate", "Сразу после перехода в фон", "Immediately After Going to Background"),
        ("security.timeout.1_minute", "Через 1 минуту", "After 1 Minute"),
        ("security.timeout.5_minutes", "Через 5 минут", "After 5 Minutes"),
        ("security.timeout.15_minutes", "Через 15 минут", "After 15 Minutes"),
        ("security.timeout.30_minutes", "Через 30 минут", "After 30 Minutes")
    ]
    for (key, ru, en) in expected {
        #expect(UpdateLocalization.key(key, english: false) == ru)
        #expect(UpdateLocalization.key(key, english: true) == en)
    }
    let source = try repositorySource("Sources/SelectiveRemote/AppLock.swift")
    #expect(source.contains("Text(language.localized(option.1))"))
}

@Test("Secondary selectors expose explicit localized current and option values")
@MainActor
func secondarySelectorValueCatalogIsComplete() throws {
    let keys = [
        "keychain.filter.all", "keychain.filter.keys", "keychain.filter.certificates",
        "keychain.filter.touchID", "keychain.filter.passwords", "keychain.filter.authorities",
        "keychain.filter.knownHosts", "keychain.sort.name", "keychain.sort.type",
        "keychain.sort.usage", "keychain.sort.fingerprint",
        "diagnostics.pane.overview", "diagnostics.pane.systemCheck",
        "diagnostics.pane.connections", "diagnostics.pane.rdp", "diagnostics.pane.ssh",
        "diagnostics.pane.sftp", "diagnostics.pane.forwarding", "diagnostics.pane.errors",
        "diagnostics.pane.environment", "diagnostics.pane.raw",
        "terminal.theme_filter.all", "terminal.theme_filter.dark",
        "terminal.theme_filter.light", "terminal.theme_filter.favorites"
    ]
    for key in keys {
        let ru = UpdateLocalization.key(key, english: false)
        let en = UpdateLocalization.key(key, english: true)
        #expect(ru != key && en != key)
        #expect(!en.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) })
    }
    let keychain = try repositorySource("Sources/SelectiveRemote/CredentialVaultView.swift")
    let diagnostics = try repositorySource("Sources/SelectiveRemote/DiagnosticsCenter.swift")
    let themes = try repositorySource("Sources/SelectiveRemote/TerminalThemeCatalog.swift")
    #expect(keychain.contains(#"language.localized("keychain.filter.\(item.rawValue)")"#))
    #expect(diagnostics.contains(#"language.localized("diagnostics.pane.\(pane.rawValue)")"#))
    #expect(themes.contains(#"language.localized("terminal.theme_filter.\($0.rawValue)")"#))
}

@Test("Team roles and secondary picker values follow the active app locale")
@MainActor
func teamAndTransportValuesFollowRuntimeLanguage() throws {
    #expect(SelectiveRemoteCloudTeamRole.owner.displayRoleTitle(english: false) == "Владелец")
    #expect(SelectiveRemoteCloudTeamRole.owner.displayRoleTitle(english: true) == "Owner")
    #expect(SelectiveRemoteCloudTeamRole.viewer.displayRoleTitle(english: false) == "Наблюдатель")
    #expect(SerialParity.none.localizedTitle(english: false) == "Нет")
    #expect(SerialParity.none.localizedTitle(english: true) == "None")
    #expect(SerialFlowControl.none.localizedTitle(english: true) == "None")
    #expect(ProfileSortMode.favoritesAndName.title == UpdateLocalization.key("hosts.sort.favoritesAndName"))
    let roleSource = try repositorySource("Sources/SelectiveRemote/CloudProfileShareView.swift")
    #expect(roleSource.contains("team.role.displayRoleTitle()"))
    let terminal = try repositorySource("Sources/SelectiveRemote/EmbeddedTerminalView.swift")
    #expect(terminal.contains("$0.localizedTitle()"))
    let hosts = try repositorySource("Sources/SelectiveRemote/ContentView.swift")
    #expect(hosts.contains("SerialParity.allCases) { Text($0.localizedTitle())"))
}

@Test("Cloud record metadata formats dates in the selected language without translating user titles")
@MainActor
func cloudMetadataLocalization() {
    #expect(UpdateLocalization.key("cloud.vault.recordType.sshKey", english: false) == "SSH-ключ")
    #expect(UpdateLocalization.key("cloud.vault.recordType.sshKey", english: true) == "SSH Key")
    let timestamp = "2026-09-23T12:30:00Z"
    let en = UpdateLocalization.cloudTimestamp(timestamp, english: true)
    let ru = UpdateLocalization.cloudTimestamp(timestamp, english: false)
    #expect(en != timestamp && ru != timestamp && en != ru)
    #expect(!en.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) })
    #expect(ru.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) })
    #expect(UpdateLocalization.cloudTimestamp("user-defined", english: true) == "user-defined")
}

@Test("Host status and serial captions are localized at their rendered call sites")
@MainActor
func hostStatusRuntimeLocalizationContract() throws {
    let source = try repositorySource("Sources/SelectiveRemote/ContentView.swift")
    #expect(source.contains(#"ru: "Сессия активна", en: "Session Active""#))
    #expect(source.contains(#"ru: "Подключено", en: "Connected""#))
    #expect(source.contains(#"ru: "Туннель активен", en: "Tunnel Active""#))
    #expect(source.contains(#"ru: "Скорость (бод)", en: "Baud rate""#))
    #expect(source.contains(#"ru: "Достигнут лимит вкладок Terminal Workspace""#))
}

@Test("RU secondary settings and serial controls do not retain English-only captions")
func russianSecondaryControlCaptions() throws {
    let terminal = try repositorySource("Sources/SelectiveRemote/EmbeddedTerminalView.swift")
    let backup = try repositorySource("Sources/SelectiveRemote/BackupSettingsView.swift")
    for pair in [
        #"ru: "Биты данных", en: "Data bits""#,
        #"ru: "Чётность", en: "Parity""#,
        #"ru: "Стоп-биты", en: "Stop bits""#,
        #"ru: "Управление потоком", en: "Flow control""#
    ] {
        #expect(terminal.contains(pair), "Missing bilingual serial caption: \(pair)")
    }
    #expect(backup.contains(#"ru: "Резервная копия и восстановление", en: "Backup & Restore""#))
}

@Test("Dynamic camera and terminal phase labels are localized before display")
func dynamicCameraAndPhaseValuesAreLocalized() {
    #expect(CameraDeviceKind.builtIn.title == UpdateLocalization.key("camera.kind.builtIn"))
    #expect(CapturePermissionKind.camera.title == UpdateLocalization.key("capture.permission.camera"))
    #expect(CapturePermissionState.denied.title == UpdateLocalization.key("capture.permissionState.denied"))
    #expect(EmbeddedTerminalPhase.idle.title == UpdateLocalization.key("terminal.phase.idle"))
    #expect(TerminalWorkspaceSessionState.connected.localizedTitle(english: true) == "Connected")
    #expect(TerminalWorkspaceSessionState.error(5).localizedDetail(english: false) == "Код выхода: 5")
}

@Test("Terminal toolbar actions use the same live language catalog as the rest of the window")
@MainActor
func terminalToolbarLocalizationContract() throws {
    let suiteName = "TerminalToolbarLocalization.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let language = AppLanguageStore(defaults: defaults)
    language.selection = .english
    #expect(language.localized("terminal.local.terminate") == "Terminate")
    language.selection = .russian
    #expect(language.localized("terminal.local.terminate") == "Завершить")
    let source = try repositorySource("Sources/SelectiveRemote/LocalTerminalView.swift")
    #expect(source.contains("language.localized(\"terminal.local.terminate\")"))
}

@Test("Composed secondary help text has whole-message RU and EN variants")
@MainActor
func composedSecondaryHelpUsesWholeMessageLocalization() throws {
    let keys = [
        "ssh.keygen.separate_terminal.help",
        "terminal.startup.sequence.help",
        "hosts.known_host.same_endpoint.help"
    ]
    for key in keys {
        let ru = UpdateLocalization.key(key, english: false)
        let en = UpdateLocalization.key(key, english: true)
        #expect(ru != key && en != key)
        #expect(ru.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) })
        #expect(!en.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) })
    }
}

@Test("Interpolated UI messages keep user data verbatim while translating surrounding copy")
func interpolatedMacOSMessagesUseCatalog() {
    #expect(UpdateLocalization.formatted("sftp.permissions.read", english: false, "owner") == "Чтение для: owner")
    #expect(UpdateLocalization.formatted("sftp.permissions.read", english: true, "owner") == "Read for: owner")
    #expect(UpdateLocalization.formatted("terminal.snippets.sent", english: true, 2) == "Sent: 2")
    #expect(UpdateLocalization.formatted("terminal.snippets.sent", english: false, 2) == "Отправлено: 2")
    #expect(UpdateLocalization.formatted("hosts.known_host.duplicate", english: true, "Терминал 1")
        == "This SSH profile already exists: Терминал 1")
}

@Test("Native and custom menu inventory reversibly localizes nested commands without changing actions")
@MainActor
func nativeMenuInventoryIsReversible() {
    let root = NSMenu()
    let parent = NSMenuItem(title: "Файл", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "Файл")
    for pair in RuntimeMenuLocalization.nativeTitles {
        let item = NSMenuItem(title: pair.ru, action: nil, keyEquivalent: "x")
        item.isEnabled = false
        submenu.addItem(item)
    }
    parent.submenu = submenu
    root.addItem(parent)
    RuntimeMenuLocalization.apply(to: root, language: .english)
    #expect(submenu.items.map(\.title) == RuntimeMenuLocalization.nativeTitles.map(\.en))
    #expect(submenu.items.allSatisfy { !$0.isEnabled && $0.keyEquivalent == "x" })
    RuntimeMenuLocalization.apply(to: root, language: .russian)
    let expectedRussian = RuntimeMenuLocalization.nativeTitles.map {
        $0.en == "Session" ? "Сеанс" : $0.ru
    }
    #expect(submenu.items.map(\.title) == expectedRussian)
    #expect(submenu.items.allSatisfy { !$0.isEnabled && $0.keyEquivalent == "x" })

    let sessionRoot = NSMenu()
    let session = NSMenuItem(title: "Session", action: nil, keyEquivalent: "")
    let sessions = NSMenu(title: "Session")
    let userProfile = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    let profileActions = NSMenu(title: "File")
    profileActions.addItem(NSMenuItem(title: "Disconnect", action: nil, keyEquivalent: ""))
    userProfile.submenu = profileActions
    sessions.addItem(userProfile)
    session.submenu = sessions
    sessionRoot.addItem(session)
    RuntimeMenuLocalization.apply(to: sessionRoot, language: .russian)
    #expect(userProfile.title == "File")
    #expect(userProfile.submenu?.title == "File")
}

@Test("Runtime localization inventory covers every Settings tab and the Appearance controls")
func runtimeLocalizationInventoryCoversVisibleSurfaces() throws {
    for key in [
        "settings.tab.appearance", "settings.tab.updates", "settings.tab.security",
        "settings.tab.cloud", "settings.tab.backup", "settings.reset_appearance",
        "appearance.section.theme", "appearance.theme", "appearance.text_size",
        "appearance.density", "appearance.help.text_size", "appearance.section.window",
        "appearance.transparent_window", "appearance.opacity", "appearance.help.opacity",
        "appearance.section.language", "appearance.language", "appearance.help.language"
    ] {
        let entry = try #require(AppCopy.translations[key])
        #expect(!entry.ru.isEmpty && !entry.en.isEmpty)
        #expect(!entry.en.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) })
        if key != "settings.tab.cloud" {
            #expect(entry.ru.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) })
        }
    }
    let settings = try repositorySource("Sources/SelectiveRemote/UpdateExperienceView.swift")
    let appearance = try repositorySource("Sources/SelectiveRemote/AppAppearance.swift")
    let terminal = try repositorySource("Sources/SelectiveRemote/TerminalAppearance.swift")
    let app = try repositorySource("Sources/SelectiveRemote/SelectiveRemoteApp.swift")
    #expect(settings.contains("language.localized(\"settings.tab.appearance\")"))
    #expect(settings.contains(".id(language.selection)"))
    #expect(appearance.contains("language.localized(\"appearance.section.theme\")"))
    #expect(terminal.contains("language.localized(\"appearance.section.language\")"))
    #expect(app.contains("AppRuntimeLanguageObserver()"))
}

@Test("Central runtime copy catalog has complete language pairs and matching format arguments")
func runtimeCopyCatalogContract() throws {
    let formatPattern = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?(?:@|d|ld|f)"#)
    for (key, copy) in AppCopy.translations {
        #expect(!copy.ru.isEmpty && !copy.en.isEmpty, "Empty copy: \(key)")
        #expect(!copy.en.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) },
                "Cyrillic in EN: \(key)")
        let ruRange = NSRange(copy.ru.startIndex..<copy.ru.endIndex, in: copy.ru)
        let enRange = NSRange(copy.en.startIndex..<copy.en.endIndex, in: copy.en)
        let ruFormats = formatPattern.matches(in: copy.ru, range: ruRange).compactMap {
            Range($0.range, in: copy.ru).map { String(copy.ru[$0]) }
        }
        let enFormats = formatPattern.matches(in: copy.en, range: enRange).compactMap {
            Range($0.range, in: copy.en).map { String(copy.en[$0]) }
        }
        #expect(ruFormats == enFormats, "Format arguments diverge: \(key)")
    }
}

@Test("AppKit save panels use the selected application language, not the system locale")
func appKitPanelRuntimeLocalizationContract() throws {
    #expect(UpdateLocalization.key("ssh.key.save_private.title", english: false) == "Сохранить новый приватный SSH-ключ")
    #expect(UpdateLocalization.key("ssh.key.save_private.title", english: true) == "Save New Private SSH Key")
    #expect(UpdateLocalization.key("diagnostics.export.title", english: false) == "Экспорт диагностики")
    #expect(UpdateLocalization.key("diagnostics.export.title", english: true) == "Export Diagnostics")
    let ssh = try repositorySource("Sources/SelectiveRemote/SSHKeyGenerationView.swift")
    let diagnostics = try repositorySource("Sources/SelectiveRemote/DiagnosticsCenter.swift")
    #expect(ssh.contains("panel.title = UpdateLocalization.key(\"ssh.key.save_private.title\")"))
    #expect(diagnostics.contains("panel.title = UpdateLocalization.key(\"diagnostics.export.title\")"))
    #expect(!diagnostics.contains("String(localized: \"Экспорт диагностики\")"))
}

@Test("Nested application menu copy switches in both directions without losing actions")
@MainActor
func nestedMenuRuntimeLocalizationContract() {
    let menu = NSMenu(title: "File")
    for (key, copy) in AppCopy.translations where key.hasPrefix("menu.") {
        let item = NSMenuItem(title: copy.ru, action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(item)
    }
    #expect(!menu.items.isEmpty)
    RuntimeMenuLocalization.apply(to: menu, language: .english)
    #expect(menu.items.allSatisfy { !$0.title.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) } })
    #expect(menu.items.allSatisfy { $0.action == #selector(NSWindow.performClose(_:)) && $0.keyEquivalent == "w" })
    RuntimeMenuLocalization.apply(to: menu, language: .russian)
    #expect(menu.items.contains { $0.title == "Сеанс" || $0.title == "Открыть настройки Cloud…" })
}

@Test("Settings control inventory has English resources for every remaining literal")
func settingsControlInventoryHasEnglishCoverage() throws {
    let resources = try repositorySource("Resources/en.lproj/Localizable.strings")
    let pattern = try NSRegularExpression(
        pattern: #"(?:Section|Button|Toggle|Picker|LabeledContent|DisclosureGroup)\("([^\"]+)\""#
    )
    for path in [
        "Sources/SelectiveRemote/UpdateExperienceView.swift",
        "Sources/SelectiveRemote/AppLock.swift",
        "Sources/SelectiveRemote/BackupSettingsView.swift",
        "Sources/SelectiveRemote/CloudSettingsView.swift"
    ] {
        let source = try repositorySource(path)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in pattern.matches(in: source, range: range) {
            guard let literalRange = Range(match.range(at: 1), in: source) else { continue }
            let literal = String(source[literalRange])
            guard literal.unicodeScalars.contains(where: { (0x0400...0x052F).contains($0.value) })
            else { continue }
            if !resources.contains("\"\(literal)\" = \"") {
                Issue.record("Missing English: \(path): \(literal)")
            }
        }
    }
}

@Test("Every direct macOS UI literal in the executable has an English catalog entry")
func allDirectMacOSUILiteralsHaveEnglishCatalogEntries() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sources = root.appendingPathComponent("Sources/SelectiveRemote")
    let resource = try repositorySource("Resources/en.lproj/Localizable.strings")
    let pattern = try NSRegularExpression(pattern:
        #"(?:Text|Label|Button|Toggle|Picker|Menu|CommandMenu|Section|LabeledContent|TextField|SecureField|\.help|\.accessibility(?:Label|Hint)|NSMenuItem|NSAlert|confirmationDialog|alert)\s*\(\s*\"((?:\\.|[^\"\\])*)\""#)
    let files = try FileManager.default.contentsOfDirectory(
        at: sources, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" }
    #expect(files.count >= 100)
    for file in files where file.lastPathComponent != "AppCopy.swift" {
        let source = try String(contentsOf: file, encoding: .utf8)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in pattern.matches(in: source, range: range) {
            guard let literalRange = Range(match.range(at: 1), in: source) else { continue }
            let literal = String(source[literalRange])
            guard literal.unicodeScalars.contains(where: { (0x0400...0x052F).contains($0.value) })
            else { continue }
            // Interpolated values require explicit runtime copy, not a static resource key.
            if literal.contains(#"\("#) { continue }
            if !resource.contains("\"\(literal)\" = \"") {
                Issue.record("Missing EN UI copy: \(file.lastPathComponent): \(literal)")
            }
        }
    }
}

@Test("Language observer refreshes native menus and auxiliary Help/About/What's New windows")
func runtimeLocalizationCoversDetachedSurfaces() throws {
    let language = try repositorySource("Sources/SelectiveRemote/AppLanguage.swift")
    let app = try repositorySource("Sources/SelectiveRemote/SelectiveRemoteApp.swift")
    let auxiliary = try repositorySource("Sources/SelectiveRemote/AppAppearance.swift")
    let notes = try repositorySource("Sources/SelectiveRemote/UpdateReleaseNotes.swift")
    #expect(language.contains(".onChange(of: language.selection)"))
    #expect(language.contains("RuntimeMenuLocalization.refresh(newValue)"))
    #expect(app.contains(".background(AppRuntimeLanguageObserver())"))
    #expect(auxiliary.contains("@ObservedObject private var language = AppLanguageStore.shared"))
    #expect(auxiliary.contains(".environment(\\.locale, language.locale)"))
    #expect(notes.contains("func refreshLanguageIfPresented()"))
}

@Test("Confirmed English audit paths use stable keys that rerender with the app language")
func prereleaseAuditCopyUsesLiveSemanticKeys() throws {
    let cases: [(String, String, String)] = [
        ("menu.session.title", "Сеанс", "Session"),
        ("menu.help.title", "Справка Selective Remote", "Selective Remote Help"),
        ("hosts.auth.automatic.help", "OpenSSH попробует выбранный ключ, ssh-agent и затем пароль. Удобно для совместимости.", "OpenSSH tries the selected key, ssh-agent, then a password for compatibility."),
        ("terminal.local.restart", "Перезапустить shell", "Restart Shell"),
        ("connection.updated.just_now", "Обновлено только что", "Updated just now"),
        ("help.support.title", "Поддержать проект", "Support the Project")
    ]
    for (key, russian, english) in cases {
        #expect(UpdateLocalization.key(key, english: false) == russian)
        #expect(UpdateLocalization.key(key, english: true) == english)
    }
    for (key, copy) in AppCopy.translations {
        #expect(!key.isEmpty)
        #expect(!copy.ru.isEmpty)
        #expect(!copy.en.isEmpty)
        #expect(!copy.en.unicodeScalars.contains {
            (0x0400...0x052F).contains($0.value)
        })
    }
    let menu = try repositorySource("Sources/SelectiveRemote/SelectiveRemoteApp.swift")
    let hosts = try repositorySource("Sources/SelectiveRemote/ContentView.swift")
    let ssh = try repositorySource("Sources/SelectiveRemote/SSHService.swift")
    #expect(menu.contains("CommandMenu(UpdateLocalization.key(\"menu.session.title\"))"))
    #expect(menu.contains("Button(UpdateLocalization.key(\"menu.help.title\"))"))
    #expect(hosts.contains("UpdateLocalization.key(\"hosts.auth.password.help\")"))
    #expect(ssh.contains("UpdateLocalization.key(\"ssh.error.invalid_host\")"))
}

@Test("Audited secondary macOS UI has English fallbacks across SSH, SFTP, Terminal, Help and Settings")
func auditedSecondaryEnglishResources() throws {
    let english = try repositorySource("Resources/en.lproj/Localizable.strings")
    for key in [
        "Продолжить SFTP-передачи", "Приостановить SFTP-передачи",
        "Локальный shell остановлен", "История и подсказки команд терминала",
        "Назад к подключениям", "Маршрут без промежуточного узла",
        "Рядом с приватным ключом не найден файл публичного ключа .pub",
        "Версия приложения", "Проверять обновления при запуске и каждые 5 часов",
        "Новая локальная вкладка", "Палитра действий терминала"
    ] {
        #expect(english.contains("\"\(key)\" = \""))
    }
    let sftp = try repositorySource("Sources/SelectiveRemote/SFTPWorkspace.swift")
    let forwarding = try repositorySource("Sources/SelectiveRemote/ForwardingManager.swift")
    let terminal = try repositorySource("Sources/SelectiveRemote/LocalTerminalView.swift")
    #expect(sftp.contains("en: \"Servers: "))
    #expect(forwarding.contains("en: \"of "))
    #expect(terminal.contains("UpdateLocalization.key(\"terminal.local.description\")"))
}

@Test("Help and What's New keep an opaque auxiliary window frame")
func auxiliaryWindowsKeepVisibleFrame() throws {
    let app = try repositorySource("Sources/SelectiveRemote/SelectiveRemoteApp.swift")
    let appearance = try repositorySource("Sources/SelectiveRemote/AppAppearance.swift")
    let releaseNotes = try repositorySource("Sources/SelectiveRemote/UpdateReleaseNotes.swift")

    #expect(app.contains("AppAuxiliaryWindowRoot(store: .shared) { AppHelpView() }"))
    #expect(app.contains("window.isOpaque = true"))
    #expect(app.contains("window.titlebarAppearsTransparent = false"))
    #expect(appearance.contains("struct AppAuxiliaryWindowRoot"))
    #expect(appearance.contains("Color(nsColor: .windowBackgroundColor)"))
    #expect(releaseNotes.contains("AppAuxiliaryWindowRoot(store: .shared)"))
    #expect(releaseNotes.contains("created.hasShadow = true"))
}

@Test("About Selective Remote contains product, security, and project information")
func aboutWindowHasProductInformation() throws {
    let app = try repositorySource("Sources/SelectiveRemote/SelectiveRemoteApp.swift")
    let about = try repositorySource("Sources/SelectiveRemote/AppAboutView.swift")

    #expect(app.contains("CommandGroup(replacing: .appInfo)"))
    #expect(app.contains("appDelegate.showAboutWindow()"))
    #expect(about.contains("AppBuildInfo.fullText"))
    #expect(about.contains("AppBuildInfo.build"))
    #expect(about.contains("macOS Keychain"))
    #expect(about.contains("ProjectSupport.githubURL"))
    #expect(about.contains("ProjectSupport.websiteURL"))
    #expect(about.contains("ProjectSupport.telegramURL"))
    #expect(about.contains("aboutTelegramChannelButton"))
    #expect(about.contains("MIT"))
}

@Test("English resources cover main navigation and reported partial translations")
func englishLocalizationCoversReportedViews() throws {
    let strings = try repositorySource("Resources/en.lproj/Localizable.strings")
    let content = try repositorySource("Sources/SelectiveRemote/ContentView.swift")
    let activity = try repositorySource("Sources/SelectiveRemote/ConnectionActivity.swift")
    let vault = try repositorySource("Sources/SelectiveRemote/CredentialVaultView.swift")
    let connectionCenter = try repositorySource("Sources/SelectiveRemote/ConnectionCenter.swift")
    let forwarding = try repositorySource("Sources/SelectiveRemote/ForwardingManager.swift")
    let sessionLogs = try repositorySource("Sources/SelectiveRemote/TerminalSessionLogs.swift")

    for key in [
        "Сниппеты",
        "Общая библиотека команд · SSH и Локальный терминал используют одни Snippets",
        "Локальная запись вывода SSH и Local Terminal",
        "Единое состояние активных RDP, SSH, SFTP и Forwarding-подключений",
        "Выберите подключение",
        "Параметры",
        "Используется",
        "Хранение"
    ] {
        #expect(strings.contains("\"\(key)\" ="))
    }

    #expect(content.contains("case .snippets: UpdateLocalization.text"))
    #expect(content.contains("ru: \"Центр подключений\""))
    #expect(content.contains("case .forwarding: UpdateLocalization.text(ru: \"Туннели\""))
    #expect(content.contains("ru: \"Журналы сессий\""))
    #expect(content.contains("case .keychain: UpdateLocalization.text(ru: \"Связка ключей\""))
    #expect(content.contains("case .sftp: UpdateLocalization.text(ru: \"Файлы SFTP\""))
    #expect(connectionCenter.contains("ru: \"Центр подключений\""))
    #expect(forwarding.contains("Text(UpdateLocalization.text(ru: \"Туннели\""))
    #expect(sessionLogs.contains("ru: \"Журналы сессий\""))
    #expect(activity.contains("en: \"Interrupted\""))
    #expect(activity.contains("localizedErrorMessage"))
    #expect(vault.contains("Label(LocalizedStringKey(title)"))
    #expect(vault.contains("Text(LocalizedStringKey(value))"))
}

@Test("English localization covers SFTP, RDP settings, Keychain, and dynamic values")
func englishLocalizationCoversWorkspaceDetails() throws {
    let strings = try repositorySource("Resources/en.lproj/Localizable.strings")
    let localization = try repositorySource("Sources/SelectiveRemote/UpdateInstaller.swift")
    let models = try repositorySource("Sources/SelectiveRemote/Models.swift")
    let sftp = try repositorySource("Sources/SelectiveRemote/SFTPWorkspace.swift")
    let sftpModels = try repositorySource("Sources/SelectiveRemote/SFTPBrowserModels.swift")
    let forwarding = try repositorySource("Sources/SelectiveRemote/ForwardingManager.swift")
    let appModel = try repositorySource("Sources/SelectiveRemote/AppModel.swift")

    for key in [
        "Этот Mac",
        "Выберите источник",
        "Новый файл…",
        "Удалить безвозвратно",
        "Сортировать",
        "Одиночное нажатие Fn отправляет Win+Space. Fn в сочетании с другими клавишами не переключает язык.",
        "Пароль сохранён",
        "Доступ защищён Touch ID",
        "Объединить пароли"
    ] {
        #expect(strings.contains("\"\(key)\" ="))
    }

    #expect(localization.contains("static var locale: Locale"))
    #expect(localization.contains("static func dateTime(_ date: Date)"))
    #expect(models.contains("case .automatic: UpdateLocalization.text(ru: \"Автоматически\", en: \"Automatic\")"))
    #expect(models.contains("var displayName: String"))
    #expect(sftp.contains("var displayTitle: String"))
    #expect(sftpModels.contains("UpdateLocalization.dateTimeShort(modificationDate)"))
    #expect(forwarding.contains("en: \"Waiting for first connection\""))
    #expect(forwarding.contains("en: \"The OpenSSH log is empty.\""))
    #expect(appModel.contains("UpdateLocalization.dateTime(date)"))
}

@Test("Russian strings in audited workspace views have English resources or explicit localization")
func auditedWorkspaceStringsHaveEnglishFallbacks() throws {
    let strings = try repositorySource("Resources/en.lproj/Localizable.strings")
    let keys = Set(
        strings.split(separator: "\n").compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\"") else { return nil }
            return value.dropFirst().split(separator: "\"", maxSplits: 1).first.map(String.init)
        }
    )

    for path in [
        "Sources/SelectiveRemote/SFTPWorkspace.swift",
        "Sources/SelectiveRemote/SFTPInspectorViews.swift",
        "Sources/SelectiveRemote/CredentialVaultView.swift"
    ] {
        let source = try repositorySource(path)
        let literalPattern = #"\"([^\"\\]*(?:\\.[^\"\\]*)*[А-Яа-яЁё][^\"\\]*(?:\\.[^\"\\]*)*)\""#
        let regex = try NSRegularExpression(pattern: literalPattern)
        let range = NSRange(source.startIndex..., in: source)

        for match in regex.matches(in: source, range: range) {
            guard let literalRange = Range(match.range(at: 1), in: source) else { continue }
            let literal = String(source[literalRange])
            if literal.contains("\\(") || literal.contains(" + ") { continue }
            let contextStart = source.index(literalRange.lowerBound, offsetBy: -min(120, source.distance(from: source.startIndex, to: literalRange.lowerBound)))
            let context = source[contextStart..<literalRange.lowerBound]
            if context.contains("ru:") { continue }
            #expect(keys.contains(literal), "Missing English localization for \(path): \(literal)")
        }
    }
}
