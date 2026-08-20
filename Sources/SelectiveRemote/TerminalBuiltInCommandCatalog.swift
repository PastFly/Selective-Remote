import Foundation

struct TerminalBuiltInCommand: Identifiable, Equatable {
    let command: String
    let description: String
    let category: String
    let keywords: String

    var id: String { "\(category)::\(command)" }
}

enum TerminalBuiltInCommandCatalog {
    static let entries: [TerminalBuiltInCommand] = loadEntries()

    private static func loadEntries() -> [TerminalBuiltInCommand] {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("TerminalResources", isDirectory: true)
        let bundledDirectory = Bundle.main.resourceURL?
            .appendingPathComponent("TerminalResources", isDirectory: true)

        for directory in [bundledDirectory, Optional(sourceDirectory)].compactMap({ $0 }) {
            let url = directory.appendingPathComponent("terminal-command-catalog.js")
            guard let source = try? String(contentsOf: url, encoding: .utf8),
                  let entries = parse(source),
                  !entries.isEmpty
            else { continue }
            return entries
        }
        return []
    }

    private static func parse(_ source: String) -> [TerminalBuiltInCommand]? {
        guard let opening = source.range(of: "const rows = ["),
              let closing = source.range(
                of: "\n    ];",
                range: opening.upperBound..<source.endIndex
              )
        else { return nil }

        let rowsSource = source[opening.upperBound..<closing.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard let data = ("[" + rowsSource + "\n]").data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String]]
        else { return nil }

        return rows.compactMap { row in
            guard row.count == 4 else { return nil }
            return TerminalBuiltInCommand(
                command: row[0],
                description: row[1],
                category: row[2],
                keywords: row[3]
            )
        }
    }
}
