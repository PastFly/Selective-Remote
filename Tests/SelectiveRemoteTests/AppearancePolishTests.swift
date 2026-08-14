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
