import Foundation
import Testing
@testable import SelectiveRemote

@Test("Quick Connect 2.0 разбирает поддерживаемые SSH-форматы")
func quickConnectParsesSupportedFormats() throws {
    #expect(QuickConnectParser.parse("user@example.com") == QuickConnectTarget(
        username: "user", host: "example.com", port: 22
    ))
    #expect(QuickConnectParser.parse("user@example.com:2202") == QuickConnectTarget(
        username: "user", host: "example.com", port: 2202
    ))
    #expect(QuickConnectParser.parse("ssh user@example.com") == QuickConnectTarget(
        username: "user", host: "example.com", port: 22
    ))
    #expect(QuickConnectParser.parse("ssh user@example.com -p 2222") == QuickConnectTarget(
        username: "user", host: "example.com", port: 2222
    ))
    #expect(QuickConnectParser.parse("ssh -p2223 user@example.com") == QuickConnectTarget(
        username: "user", host: "example.com", port: 2223
    ))
}

@Test("Quick Connect 2.0 безопасно отклоняет неподдерживаемые shell options")
func quickConnectRejectsUnsafeOrAmbiguousInput() {
    #expect(QuickConnectParser.parse("ssh -oProxyCommand=evil user@example.com") == nil)
    #expect(QuickConnectParser.parse("ssh user@example.com other@example.com") == nil)
    #expect(QuickConnectParser.parse("user@example.com:70000") == nil)
    #expect(QuickConnectParser.parse("user name@example.com") == nil)
}

@Test("Quick Connect 2.0 поддерживает IPv6 с явным портом")
func quickConnectParsesIPv6() {
    #expect(QuickConnectParser.parse("admin@[2001:db8::10]:2222") == QuickConnectTarget(
        username: "admin", host: "2001:db8::10", port: 2222
    ))
    #expect(QuickConnectParser.parse("ssh admin@2001:db8::10 -p 2200") == QuickConnectTarget(
        username: "admin", host: "2001:db8::10", port: 2200
    ))
}

@Test("История Quick Connect не сохраняет секреты и ограничена последними адресами")
func quickConnectRecentStoreKeepsOnlyTargets() throws {
    let suite = "SelectiveRemoteTests.QuickConnect.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = "recents"

    for index in 0..<15 {
        QuickConnectRecentStore.record(
            QuickConnectTarget(username: "user", host: "host\(index).example", port: 22),
            at: Date(timeIntervalSince1970: TimeInterval(index)),
            defaults: defaults,
            key: key
        )
    }

    let values = QuickConnectRecentStore.load(defaults: defaults, key: key)
    #expect(values.count == QuickConnectRecentStore.limit)
    #expect(values.first?.target.host == "host14.example")
    #expect(values.last?.target.host == "host3.example")

    let data = try #require(defaults.data(forKey: key))
    let persisted = String(decoding: data, as: UTF8.self)
    #expect(!persisted.localizedCaseInsensitiveContains("password"))
    #expect(!persisted.localizedCaseInsensitiveContains("passphrase"))
}

@Test("Временное Quick Connect подключение переносит auth, SSH ID и Jump Host в Terminal connection")
func quickConnectCustomConnectionCarriesAdvancedSSHSettings() {
    let identityID = UUID()
    let jumpID = UUID()
    let connection = TerminalTabConnection.custom(
        host: "server.example",
        username: "operator",
        port: 2222,
        authenticationMode: .key,
        identityID: identityID,
        jumpHostProfileID: jumpID
    )

    #expect(connection.authenticationMode == .key)
    #expect(connection.identityID == identityID)
    #expect(connection.jumpHostProfileID == jumpID)
    #expect(connection.displayLabel(profiles: []) == "operator@server.example:2222")
}
