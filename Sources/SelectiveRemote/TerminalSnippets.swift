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
        let normalizedLineEndings = rawCommand
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let command = normalizedLineEndings.trimmingCharacters(in: .newlines)
        guard !command.isEmpty,
              command.count <= 8_192,
              !command.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      && $0.value != 9
                      && $0.value != 10
              })
        else { return nil }
        return Data((command + "\n").utf8)
    }
}
