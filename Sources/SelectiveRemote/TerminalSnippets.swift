import Foundation

enum TerminalSnippetRunResult: String, Encodable, Equatable {
    case success
    case connecting
    case noTargets
    case inactiveSession
    case invalidSnippet
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
