import Foundation

struct SSHConfigHost: Identifiable, Hashable, Sendable {
    let alias: String
    var hostName: String
    var user: String
    var port: Int
    var identityFile: String?
    var proxyJump: String?

    var id: String { alias }

    var displayDestination: String {
        let resolvedHost = hostName.isEmpty ? alias : hostName
        let userPrefix = user.isEmpty ? "" : "\(user)@"
        return port == 22 ? "\(userPrefix)\(resolvedHost)" : "\(userPrefix)\(resolvedHost):\(port)"
    }
}

enum SSHConfigService {
    static func loadHosts(
        url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    ) -> [SSHConfigHost] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [SSHConfigHost] {
        struct Draft {
            var aliases: [String]
            var hostName = ""
            var user = ""
            var port = 22
            var identityFile: String?
            var proxyJump: String?
        }

        var result: [SSHConfigHost] = []
        var current: Draft?

        func flush(_ draft: Draft?) {
            guard let draft else { return }
            for alias in draft.aliases where isConcreteAlias(alias) {
                result.append(
                    SSHConfigHost(
                        alias: alias,
                        hostName: draft.hostName,
                        user: draft.user,
                        port: draft.port,
                        identityFile: draft.identityFile,
                        proxyJump: draft.proxyJump
                    )
                )
            }
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let withoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let line = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard let keyPart = parts.first else { continue }
            let key = keyPart.lowercased()
            let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

            if key == "host" {
                flush(current)
                let aliases = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                current = Draft(aliases: aliases)
                continue
            }
            guard current != nil else { continue }
            switch key {
            case "hostname": current?.hostName = value
            case "user": current?.user = value
            case "port": current?.port = Int(value).flatMap { (1...65_535).contains($0) ? $0 : nil } ?? 22
            case "identityfile": current?.identityFile = expandTilde(value)
            case "proxyjump": current?.proxyJump = value
            default: break
            }
        }
        flush(current)

        var seen = Set<String>()
        return result.filter { seen.insert($0.alias.lowercased()).inserted }
    }

    private static func isConcreteAlias(_ value: String) -> Bool {
        !value.isEmpty
            && !value.contains("*")
            && !value.contains("?")
            && !value.hasPrefix("!")
    }

    private static func expandTilde(_ value: String) -> String {
        guard value.hasPrefix("~/") else { return value }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(value.dropFirst(2)))
            .path
    }
}
