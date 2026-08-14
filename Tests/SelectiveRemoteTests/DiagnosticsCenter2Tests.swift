import Foundation
import Testing
@testable import SelectiveRemote

@Test("Diagnostics Center 2.0 удаляет секреты из ошибок перед Copy/Export")
func diagnosticsCenterRedactsSecrets() {
    let report = DiagnosticsReportBuilder.build(
        appVersion: "0.20.18",
        macOSVersion: "macOS 15.6",
        architecture: "arm64",
        profiles: [],
        sshKeys: [],
        runtimeItems: [],
        currentError: "Password: SuperSecret42 passphrase=HiddenPhrase /p:RdpSecret https://user:ProxySecret@proxy.example Proxy-Authorization: Basic dXNlcjpwYXNz",
        forwardingErrors: [UUID(): "token=TokenSecret"],
        generatedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(!report.text.contains("SuperSecret42"))
    #expect(!report.text.contains("HiddenPhrase"))
    #expect(!report.text.contains("RdpSecret"))
    #expect(!report.text.contains("ProxySecret"))
    #expect(!report.text.contains("dXNlcjpwYXNz"))
    #expect(!report.text.contains("TokenSecret"))
    #expect(report.text.contains("<redacted>"))
}

@Test("Diagnostics Center экспортирует SSH key только по basename")
func diagnosticsCenterUsesSSHKeyBasename() {
    let keyID = UUID()
    let key = SSHKeyRecord(
        id: keyID,
        name: "production-key",
        privateKeyPath: "/Users/operator/.ssh/company/id_ed25519_prod",
        publicKeyPath: "/Users/operator/.ssh/company/id_ed25519_prod.pub",
        fingerprint: "SHA256:test",
        algorithm: "ED25519",
        createdAt: Date(timeIntervalSince1970: 1_000)
    )
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.friendlyName = "prod"
    profile.host = "prod.example"
    profile.username = "root"
    profile.sshIdentityID = keyID
    profile.sshAuthenticationMode = .key

    let report = DiagnosticsReportBuilder.build(
        appVersion: "0.20.18",
        macOSVersion: "macOS",
        architecture: "arm64",
        profiles: [profile],
        sshKeys: [key],
        runtimeItems: [],
        currentError: nil,
        forwardingErrors: [:]
    )

    #expect(report.text.contains("SSH key basename: id_ed25519_prod"))
    #expect(!report.text.contains("/Users/operator/.ssh/company"))
}

@Test("Diagnostics Center включает реальные runtime state без логов и секретных значений")
func diagnosticsCenterIncludesWhitelistedRuntimeState() {
    let profileID = UUID()
    var profile = ConnectionProfile(connectionType: .rdp)
    profile.id = profileID
    profile.friendlyName = "office"
    profile.host = "rdp.example"
    profile.username = "administrator"
    profile.gatewayHost = "gateway.example"

    let item = ConnectionCenterItem(
        source: .rdp(profileID: profileID),
        kind: .rdp,
        profileName: "office",
        userHost: "administrator@rdp.example",
        port: 3389,
        route: "gateway.example",
        authentication: "Password",
        state: .connected,
        startedAt: Date(timeIntervalSince1970: 2_000),
        errorMessage: nil,
        detailSections: [
            ConnectionCenterDetailSection(
                title: "Основное",
                rows: [
                    ConnectionCenterDetailRow(label: "Host", value: "rdp.example"),
                    ConnectionCenterDetailRow(label: "Режим", value: "Полный экран"),
                    ConnectionCenterDetailRow(label: "Разрешение", value: "1920 × 1080")
                ]
            ),
            ConnectionCenterDetailSection(
                title: "Сессия",
                rows: [
                    ConnectionCenterDetailRow(label: "PID", value: "12345"),
                    ConnectionCenterDetailRow(label: "Лог", value: "session-private.log")
                ]
            )
        ]
    )

    let report = DiagnosticsReportBuilder.build(
        appVersion: "0.20.18",
        macOSVersion: "macOS",
        architecture: "arm64",
        profiles: [profile],
        sshKeys: [],
        runtimeItems: [item],
        currentError: nil,
        forwardingErrors: [:],
        generatedAt: Date(timeIntervalSince1970: 3_000)
    )

    #expect(report.text.contains("RDP session/process state: Connected"))
    #expect(report.text.contains("Process ID: 12345"))
    #expect(report.text.contains("RDP Gateway: gateway.example"))
    #expect(!report.text.contains("session-private.log"))
}

@Test("Diagnostics Center 2.0 встроен в main navigation и не читает Keychain")
func diagnosticsCenterIntegrationContract() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let diagnostics = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/DiagnosticsCenter.swift"),
        encoding: .utf8
    )
    let content = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )

    #expect(content.contains("case diagnostics = \"Диагностика\""))
    #expect(content.contains("DiagnosticsCenterView(model: model)"))
    #expect(diagnostics.contains("Копировать диагностику"))
    #expect(diagnostics.contains("Экспортировать диагностику"))
    #expect(!diagnostics.contains("KeychainService."))

    let uiSource = diagnostics.components(separatedBy: "struct DiagnosticsCenterView").last ?? ""
    #expect(uiSource.contains(".frame(maxWidth: 1180"))
    #expect(!uiSource.contains("Text(\"Environment\")"))
    #expect(!uiSource.contains("Text(\"Raw Report\")"))
    #expect(!uiSource.contains("proxy secrets"))
    #expect(!uiSource.contains("private keys"))
    #expect(!uiSource.contains("basename"))
}
