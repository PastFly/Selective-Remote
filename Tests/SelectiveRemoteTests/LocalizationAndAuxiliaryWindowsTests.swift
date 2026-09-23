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
