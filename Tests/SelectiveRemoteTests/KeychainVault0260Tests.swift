import Foundation
import Testing
@testable import SelectiveRemote

@Test("Unified Keychain Vault uses one deterministic entry namespace")
func unifiedVaultEntryKeyIsStable() {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let ssh = KeychainService.credentialReference(profileID: id, kind: .ssh)
    let proxy = KeychainService.credentialReference(profileID: id, kind: .proxy)
    #expect(UnifiedCredentialVault.entryKey(for: ssh) != UnifiedCredentialVault.entryKey(for: proxy))
    #expect(UnifiedCredentialVault.entryKey(for: ssh).contains(id.uuidString))
}

@Test("SSH profile exposes Automation as a dedicated settings tab")
func automationTabSourceRegression() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )
    #expect(source.contains("case automation = \"Автоматизация\""))
    #expect(source.contains("case .automation:"))
    #expect(source.contains("SSHAutomationSettingsView"))
}

@Test("Keychain reads unified vault before legacy per-profile records")
func unifiedVaultRoutingSourceRegression() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let service = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/KeychainService.swift"),
        encoding: .utf8
    )
    let view = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/CredentialVaultView.swift"),
        encoding: .utf8
    )
    #expect(service.contains("UnifiedCredentialVault.shared.read"))
    #expect(service.contains("migrateCredentialsToUnifiedVault"))
    #expect(service.contains("static func authorizeSSHKeyUse"))
    #expect(service.contains("static func setSSHKeyUseProtection"))
    #expect(service.contains("service: legacyService"))
    #expect(view.contains("Объединить пароли"))
}
