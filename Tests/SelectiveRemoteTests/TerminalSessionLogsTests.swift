import Foundation
import Testing
@testable import SelectiveRemote

@Test("Session log sanitizer removes terminal escapes and known credentials")
func sessionLogSanitizerRedactsOutput() {
    let source = "\u{001B}c\u{001B}[32mgreen\u{001B}[0m password=hunter2\r\n"
    let sanitized = TerminalSessionLogSanitizer.sanitize(source)

    #expect(sanitized.hasPrefix("green"))
    #expect(sanitized.contains("green"))
    #expect(sanitized.contains("password=<redacted>"))
    #expect(!sanitized.contains("hunter2"))
    #expect(!sanitized.contains("\u{001B}"))
    #expect(sanitized.hasSuffix("\n"))
}

@Test("Session log store persists sanitized output without blocking the terminal")
@MainActor
func sessionLogStoreLifecycle() async throws {
    let suite = "TerminalSessionLogsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SelectiveRemoteTests-\(UUID().uuidString)", isDirectory: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    let store = TerminalSessionLogStore(
        rootURL: root,
        defaults: defaults,
        maximumLogBytes: 32_768,
        maximumRecordCount: 25
    )
    let id = try #require(store.begin(
        kind: .ssh,
        profileID: UUID(),
        profileName: "Production",
        target: "example.test:22"
    ))
    store.append(Data("ready\r".utf8), to: id)
    store.append(Data("\nsecond line\r\npassword=secret\n".utf8), to: id)
    store.finish(id, exitCode: 0, requested: false)

    for _ in 0..<100 where store.records.first?.state == .active {
        try await Task.sleep(for: .milliseconds(10))
    }

    let record = try #require(store.records.first)
    #expect(record.state == .completed)
    #expect(record.byteCount > 0)
    #expect(store.text(for: record).contains("ready"))
    #expect(store.text(for: record).contains("ready\nsecond line\n"))
    #expect(!store.text(for: record).contains("readysecond"))
    #expect(store.text(for: record).contains("password=<redacted>"))
    #expect(!store.text(for: record).contains("secret"))
}

@Test("SSH and Local Terminal attach logs through output observers")
func sessionLogsUseNonInvasiveOutputObservers() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let appModel = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/AppModel.swift"),
        encoding: .utf8
    )
    let session = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/PTYSession.swift"),
        encoding: .utf8
    )

    #expect(appModel.contains("kind: .ssh"))
    #expect(appModel.contains("kind: .local"))
    #expect(appModel.contains("session.addOutputObserver"))
    #expect(appModel.contains("session.removeOutputObserver"))
    #expect(session.contains("private var outputObservers"))
    #expect(!session.contains("TerminalSessionLogStore"))
}

@Test("Session log preview supports readable wrapping, copy and live refresh")
func sessionLogPreviewReadabilityRegression() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/TerminalSessionLogs.swift"),
        encoding: .utf8
    )

    #expect(source.contains("Timer.publish("))
    #expect(source.contains("text.word.spacing"))
    #expect(source.contains("Button(\"Копировать\""))
    #expect(source.contains(".lineSpacing(3)"))
    #expect(source.contains("ScrollView(axes)"))
    #expect(source.contains("pendingData.firstIndex"))
}
