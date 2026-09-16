import Foundation
import Testing
@testable import SelectiveRemote

@Test("Размер текста macOS использует четыре различимых native point sizes")
@MainActor
func appTextSizesUseDistinctNativePointSizes() {
    let sizes = AppTextSize.allCases.map(\.bodyPointSize)
    #expect(sizes == sizes.sorted())
    #expect(Set(sizes).count == AppTextSize.allCases.count)
    #expect(AppTextSize.standard.bodyPointSize == 13.0)
    #expect(AppTextSize.extraLarge.bodyPointSize >= 18.0)
}

@Test("Выбранный размер текста сохраняется между запусками")
@MainActor
func appTextSizePersistsInDefaults() throws {
    let suiteName = "SelectiveRemote.AppearancePolishTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = AppAppearanceStore(defaults: defaults)
    first.textSize = .extraLarge
    let reopened = AppAppearanceStore(defaults: defaults)
    #expect(reopened.textSize == .extraLarge)
}

@Test("Keychain использует системный контраст для selected row icons")
func keychainSelectedIconContrastContract() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/CredentialVaultView.swift"),
        encoding: .utf8
    )
    #expect(source.contains("alternateSelectedControlTextColor"))
    #expect(source.contains("selection == .key(key.id)"))
    #expect(source.contains("selection == .credential(profile.id)"))
    #expect(source.contains("selection == .authority(authority.id)"))
    #expect(source.contains("selection == .knownHost(entry.id)"))
}

@Test("Выпадающие списки используют единый современный нативный стиль")
func menuPickersShareModernChrome() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let appearance = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/AppAppearance.swift"),
        encoding: .utf8
    )
    #expect(appearance.contains("func modernMenuPicker"))
    #expect(appearance.contains(".pickerStyle(.menu)"))
    #expect(appearance.contains(".onHover"))
    #expect(appearance.contains("Color.accentColor.opacity(0.58)"))

    for path in [
        "Sources/SelectiveRemote/CloudTeamManagementView.swift",
        "Sources/SelectiveRemote/QuickConnectView.swift",
        "Sources/SelectiveRemote/CloudProfileShareView.swift",
        "Sources/SelectiveRemote/CloudTeamHostEditor.swift",
        "Sources/SelectiveRemote/ConnectionCenter.swift",
        "Sources/SelectiveRemote/ConnectionActivity.swift",
        "Sources/SelectiveRemote/TerminalSessionLogs.swift",
        "Sources/SelectiveRemote/ContentView.swift",
    ] {
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        #expect(source.contains(".modernMenuPicker("), "Missing shared picker style in \(path)")
    }
}

@Test("Hosts and Credentials share the native management workspace chrome")
func managementWorkspacesShareVisualLanguage() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let controls = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/AppControlStyles.swift"),
        encoding: .utf8
    )
    let content = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )
    let credentials = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/CredentialVaultView.swift"),
        encoding: .utf8
    )
    let teamCredentials = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/CloudTeamCredentials.swift"),
        encoding: .utf8
    )

    #expect(controls.contains("SelectiveRemoteWorkspaceChrome"))
    #expect(controls.contains("SelectiveRemoteNavigationButtonStyle"))
    #expect(controls.contains("func selectiveRemoteWorkspaceSurface"))
    #expect(content.contains("PERSONAL VAULT"))
    #expect(content.contains("SelectiveRemoteNavigationButtonStyle(selected: mainArea == area)"))
    #expect(content.contains("selectiveRemoteWorkspaceSurface(cornerRadius: 11, selected: isSelected)"))
    #expect(credentials.contains("TEAM VAULT"))
    #expect(credentials.contains("SelectiveRemoteWorkspaceChrome.accentStrong"))
    #expect(!teamCredentials.contains("selectiveRemoteWorkspaceSurface(cornerRadius: 11, selected: selected)"))
}

@Test("Management workspace avoids duplicated navigation and crowded host controls")
func managementWorkspaceCompositionContract() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let content = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )
    let teamHosts = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/CloudTeamHosts.swift"),
        encoding: .utf8
    )
    let controls = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/AppControlStyles.swift"),
        encoding: .utf8
    )

    #expect(content.contains("@State private var mainArea = MainArea.hosts"))
    #expect(content.contains("private var showsHostQuickAccess: Bool"))
    #expect(content.contains("max: showsHostQuickAccess ? 520 : 280"))
    #expect(content.contains("personalHostNavigatorToolbar"))
    #expect(content.contains("compact: surface == .sidebar"))
    #expect(teamHosts.contains("teamHostNavigatorToolbar"))
    #expect(teamHosts.contains("let onShowPersonal: () -> Void"))
    #expect(controls.contains("ProfileCollectionDisplayModeMenuItems"))
    #expect(controls.contains("SelectiveRemoteCompactAddMenuLabel"))
}
