import Foundation

enum TerminalSnippetRunResult: String, Encodable, Equatable {
    case success
    case connecting
    case noTargets
    case inactiveSession
    case invalidSnippet
}

enum TerminalSnippetTargetRunState: Equatable {
    case connecting
    case sent
    case failed(String)
}

struct TerminalSnippetTargetRunStatus: Identifiable, Equatable {
    let profileID: UUID
    let name: String
    var state: TerminalSnippetTargetRunState

    var id: UUID { profileID }
}

struct TerminalSnippetRunSummary: Identifiable, Equatable {
    let id: UUID
    let snippetID: UUID
    let title: String
    let startedAt: Date
    var targets: [TerminalSnippetTargetRunStatus]
}

enum TerminalSnippetExecution {
    static func canRun(
        originTabID: UUID,
        selectedTabID: UUID,
        sessionIsRunning: Bool
    ) -> Bool {
        originTabID == selectedTabID && sessionIsRunning
    }

    static func inputData(for rawCommand: String) -> Data? {
        let command = rawCommand.trimmingCharacters(in: .newlines)
        guard !command.isEmpty,
              !command.contains("\0"),
              command.count <= 8_192
        else { return nil }
        return Data((command + "\n").utf8)
    }
}
