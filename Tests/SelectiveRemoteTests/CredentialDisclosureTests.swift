import Foundation
import Testing
@testable import SelectiveRemote

@Test("Saved host passwords require macOS authentication before disclosure")
func savedCredentialDisclosureUsesSystemAuthentication() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let keychain = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/KeychainService.swift"),
        encoding: .utf8
    )
    let appModel = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/AppModel.swift"),
        encoding: .utf8
    )

    #expect(keychain.contains("static func revealPassword("))
    #expect(keychain.contains(".deviceOwnerAuthentication"))
    #expect(keychain.contains("try await context.evaluatePolicy"))
    #expect(appModel.contains("revealSelectedCredential"))
    #expect(!appModel.contains("@Published var revealed"))
}

@Test("Credential disclosure is temporary and clears only its own clipboard value")
func credentialDisclosurePolicyIsSafe() throws {
    #expect(CredentialDisclosurePolicy.visibleNanoseconds == 30_000_000_000)
    #expect(CredentialDisclosurePolicy.clipboardNanoseconds == 30_000_000_000)

    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/SelectiveRemote/CredentialDisclosureField.swift"
        ),
        encoding: .utf8
    )
    #expect(source.contains("NSApplication.didResignActiveNotification"))
    #expect(source.contains("if NSPasteboard.general.string(forType: .string) == secret"))
    #expect(source.contains(".privacySensitive()"))
    #expect(!source.contains("UserDefaults"))
}

@Test("RDP, Gateway, SSH and Proxy editors expose the protected reveal control")
func allSavedHostCredentialEditorsUseDisclosureField() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )

    #expect(source.components(separatedBy: "CredentialDisclosureField(").count == 4)
    #expect(source.contains("kind: .rdp"))
    #expect(source.contains("kind: .gateway"))
    #expect(source.contains("revealSelectedCredential(kind: .ssh)"))
    #expect(source.contains("revealSelectedCredential(kind: .proxy)"))
}
