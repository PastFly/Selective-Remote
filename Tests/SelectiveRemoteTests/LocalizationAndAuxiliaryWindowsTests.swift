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
    #expect(activity.contains("en: \"Interrupted\""))
    #expect(activity.contains("localizedErrorMessage"))
    #expect(vault.contains("Label(LocalizedStringKey(title)"))
    #expect(vault.contains("Text(LocalizedStringKey(value))"))
}
