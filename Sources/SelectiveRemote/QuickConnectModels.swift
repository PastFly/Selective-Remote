import Foundation

struct QuickConnectTarget: Codable, Equatable, Hashable, Sendable {
    var username: String
    var host: String
    var port: Int

    var destination: String {
        let hostPart: String
        if host.contains(":"), !host.hasPrefix("[") {
            hostPart = "[\(host)]"
        } else {
            hostPart = host
        }
        let userPrefix = username.isEmpty ? "" : "\(username)@"
        return port == 22 ? "\(userPrefix)\(hostPart)" : "\(userPrefix)\(hostPart):\(port)"
    }
}

enum QuickConnectParser {
    static func parse(_ rawValue: String) -> QuickConnectTarget? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return nil }

        var tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.first?.lowercased() == "ssh" {
            tokens.removeFirst()
        }
        guard !tokens.isEmpty else { return nil }

        var explicitPort: Int?
        var destination: String?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "-p" {
                guard index + 1 < tokens.count,
                      let port = Int(tokens[index + 1]),
                      (1...65_535).contains(port)
                else { return nil }
                explicitPort = port
                index += 2
                continue
            }
            if token.hasPrefix("-p"), token.count > 2 {
                guard let port = Int(token.dropFirst(2)), (1...65_535).contains(port) else {
                    return nil
                }
                explicitPort = port
                index += 1
                continue
            }
            guard !token.hasPrefix("-") else { return nil }
            guard destination == nil else { return nil }
            destination = token
            index += 1
        }

        guard let destination else { return nil }
        let userAndHost = splitUser(destination)
        guard let hostAndPort = splitHostAndPort(userAndHost.host) else { return nil }
        let port = explicitPort ?? hostAndPort.port ?? 22
        guard (1...65_535).contains(port) else { return nil }

        let username = userAndHost.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = hostAndPort.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              !username.contains(where: { $0.isWhitespace || $0.isNewline })
        else { return nil }

        return QuickConnectTarget(username: username, host: host, port: port)
    }

    private static func splitUser(_ value: String) -> (username: String, host: String) {
        guard let at = value.lastIndex(of: "@") else { return ("", value) }
        return (String(value[..<at]), String(value[value.index(after: at)...]))
    }

    private static func splitHostAndPort(_ value: String) -> (host: String, port: Int?)? {
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<close])
            let suffix = value[value.index(after: close)...]
            guard !host.isEmpty else { return nil }
            if suffix.isEmpty { return (host, nil) }
            guard suffix.first == ":",
                  let port = Int(suffix.dropFirst()),
                  (1...65_535).contains(port)
            else { return nil }
            return (host, port)
        }

        let colonCount = value.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }
        guard colonCount <= 1 else {
            // Bare IPv6 is accepted with the default/explicit -p port.
            return (value, nil)
        }
        guard let colon = value.lastIndex(of: ":") else { return (value, nil) }
        let host = String(value[..<colon])
        guard !host.isEmpty,
              let port = Int(value[value.index(after: colon)...]),
              (1...65_535).contains(port)
        else { return nil }
        return (host, port)
    }
}

struct QuickConnectRecentTarget: Codable, Equatable, Identifiable, Sendable {
    var target: QuickConnectTarget
    var lastUsedAt: Date
    var id: String { target.destination.lowercased() }
}

enum QuickConnectRecentStore {
    static let defaultKey = "SelectiveRemote.quickConnect.recents.v2"
    static let limit = 12

    static func load(defaults: UserDefaults = .standard, key: String = defaultKey) -> [QuickConnectRecentTarget] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([QuickConnectRecentTarget].self, from: data)
        else { return [] }
        return values.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(limit).map { $0 }
    }

    static func record(
        _ target: QuickConnectTarget,
        at date: Date = Date(),
        defaults: UserDefaults = .standard,
        key: String = defaultKey
    ) {
        var values = load(defaults: defaults, key: key)
        values.removeAll { $0.id == target.destination.lowercased() }
        values.insert(QuickConnectRecentTarget(target: target, lastUsedAt: date), at: 0)
        values = Array(values.prefix(limit))
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: key)
    }
}

struct QuickConnectSSHRequest {
    var target: QuickConnectTarget
    var authenticationMode: SSHAuthenticationMode
    var identityID: UUID?
    var jumpHostProfileID: UUID?
    var password: String
    var saveAsProfile: Bool
    var profileName: String
}
