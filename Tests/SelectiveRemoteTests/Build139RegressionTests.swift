import Foundation
import Testing
@testable import SelectiveRemote

private func source(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

@Test("Group configuration stays editable independently of profile inheritance")
func groupConfigurationEditingRegression() throws {
    let text = try source("Sources/SelectiveRemote/SmartTerminalFeatures.swift")
    #expect(text.contains("Поля справа — общие значения группы и всегда доступны для редактирования"))
    #expect(!text.contains(".disabled(!profile.sshGroupInheritance.username)"))
    #expect(!text.contains(".disabled(!profile.sshGroupInheritance.port)"))
    #expect(!text.contains(".disabled(!profile.sshGroupInheritance.jumpHost)"))
    #expect(!text.contains(".disabled(!profile.sshGroupInheritance.keepAlive)"))
    #expect(!text.contains(".disabled(!profile.sshGroupInheritance.startupSnippet)"))
}

@Test("Keychain migration never requests all password data in one query")
func keychainMigrationQueryRegression() throws {
    let text = try source("Sources/SelectiveRemote/UnifiedCredentialVault.swift")
    #expect(text.contains("private func legacyAccounts(service: String)"))
    #expect(text.contains("private func readLegacySecret(service: String, account: String)"))
    #expect(text.contains("kSecMatchLimit as String: kSecMatchLimitAll,\n            kSecReturnAttributes as String: true"))
    #expect(text.contains("kSecReturnData as String: true,\n            kSecMatchLimit as String: kSecMatchLimitOne"))
    #expect(!text.contains("kSecMatchLimit as String: kSecMatchLimitAll,\n                kSecReturnAttributes as String: true,\n                kSecReturnData as String: true"))
}

@Test("Profile context menu has direct Edit navigation to General")
func profileContextMenuEditRegression() throws {
    let text = try source("Sources/SelectiveRemote/ContentView.swift")
    #expect(text.contains("Button(\"Изменить\", systemImage: \"pencil\")"))
    #expect(text.contains("setMainArea(.connections)\n            selectedTab = .general"))
}
