import Foundation
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
    #expect(about.contains("MIT"))
}

@Test("English resources cover main navigation and reported partial translations")
func englishLocalizationCoversReportedViews() throws {
    let strings = try repositorySource("Resources/en.lproj/Localizable.strings")
    let content = try repositorySource("Sources/SelectiveRemote/ContentView.swift")
    let activity = try repositorySource("Sources/SelectiveRemote/ConnectionActivity.swift")
    let vault = try repositorySource("Sources/SelectiveRemote/CredentialVaultView.swift")

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
