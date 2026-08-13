import Foundation
import Testing
@testable import SelectiveRemote

@Test("Terminal Workspace 2.0 нормализует состояния SSH-сессии")
func terminalWorkspaceNormalizesSessionStates() {
    #expect(TerminalWorkspaceSessionState.resolve(phase: .idle) == .disconnected)
    #expect(TerminalWorkspaceSessionState.resolve(phase: .starting("SSH")) == .connecting)
    #expect(TerminalWorkspaceSessionState.resolve(phase: .running("SSH")) == .connected)
    #expect(TerminalWorkspaceSessionState.resolve(phase: .stopping) == .stopping)
    #expect(TerminalWorkspaceSessionState.resolve(phase: .finished(0)) == .disconnected)
    #expect(TerminalWorkspaceSessionState.resolve(phase: .finished(255)) == .error(255))
}

@Test("Reconnecting имеет приоритет над промежуточной фазой PTY")
func terminalWorkspaceShowsReconnectState() {
    #expect(
        TerminalWorkspaceSessionState.resolve(
            phase: .stopping,
            isReconnecting: true
        ) == .reconnecting
    )
    #expect(
        TerminalWorkspaceSessionState.resolve(
            phase: .starting("SSH"),
            isReconnecting: true
        ) == .reconnecting
    )
}

@Test("Terminal Workspace 2.0 показывает активную панель, uptime и broadcast mode")
func terminalWorkspaceTwoUIContract() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/EmbeddedTerminalView.swift"
        ),
        encoding: .utf8
    )
    let sessionSource = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/PTYSession.swift"
        ),
        encoding: .utf8
    )

    #expect(source.contains("BROADCAST · ГРУППОВОЙ ВВОД"))
    #expect(source.contains("ACTIVE"))
    #expect(source.contains("reconnectingTabIDs"))
    #expect(source.contains("duplicateAndConnect"))
    #expect(source.contains("TimelineView(.periodic"))
    #expect(source.contains("connectionHost(for:"))
    #expect(source.contains("terminalStatusBadge(for:"))
    #expect(sessionSource.contains("@Published private(set) var startedAt: Date?"))
    #expect(sessionSource.contains("startedAt = Date()"))
}
