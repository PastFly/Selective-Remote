import Foundation
import CryptoKit

struct SSHKnownHostEntry: Identifiable, Hashable, Sendable {
    let id: String
    let lineNumber: Int
    let marker: String?
    let hosts: String
    let algorithm: String
    let keyData: String
    let comment: String?
    let sourcePath: String

    var isHashed: Bool { hosts.hasPrefix("|1|") }

    var fingerprint: String {
        guard let data = Data(base64Encoded: keyData) else { return "Недоступен" }
        let digest = SHA256.hash(data: data)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    var displayHost: String {
        if isHashed { return "Хешированный хост" }
        return hosts.split(separator: ",").first.map(String.init) ?? hosts
    }

    var directHosts: [String] {
        guard !isHashed else { return [] }
        return hosts.split(separator: ",").map(String.init)
    }
}

enum SSHKnownHostVerification: Equatable, Sendable {
    case matches
    case changed(currentFingerprint: String)
    case unavailable(String)
}

enum SSHKnownHostsService {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("known_hosts")
    }

    static func load(from url: URL = defaultURL) throws -> [SSHKnownHostEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let contents = try String(contentsOf: url, encoding: .utf8)
        return parse(contents: contents, path: url.path)
    }

    static func parse(contents: String, path: String) -> [SSHKnownHostEntry] {
        contents.components(separatedBy: .newlines).enumerated().compactMap { index, rawLine in
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

            var parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            var marker: String?
            if parts.first?.hasPrefix("@") == true {
                marker = parts.removeFirst()
            }
            guard parts.count >= 3 else { return nil }
            let hosts = parts[0]
            let algorithm = parts[1]
            let keyData = parts[2]
            guard Data(base64Encoded: keyData) != nil else { return nil }
            let comment = parts.count > 3 ? parts.dropFirst(3).joined(separator: " ") : nil
            let id = "\(index + 1)|\(hosts)|\(algorithm)|\(keyData.prefix(24))"
            return SSHKnownHostEntry(
                id: id,
                lineNumber: index + 1,
                marker: marker,
                hosts: hosts,
                algorithm: algorithm,
                keyData: keyData,
                comment: comment?.isEmpty == false ? comment : nil,
                sourcePath: path
            )
        }
    }

    static func delete(_ entry: SSHKnownHostEntry, from url: URL = defaultURL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let original = try String(contentsOf: url, encoding: .utf8)
        var lines = original.components(separatedBy: .newlines)
        guard entry.lineNumber > 0, entry.lineNumber <= lines.count else { return }

        let backup = url.deletingLastPathComponent().appendingPathComponent("known_hosts.selectiveremote.bak")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)

        lines.remove(at: entry.lineNumber - 1)
        let updated = lines.joined(separator: "\n")
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    static func verificationTarget(for entry: SSHKnownHostEntry) -> (host: String, port: Int)? {
        guard let raw = entry.directHosts.first else { return nil }
        if raw.hasPrefix("[") , let close = raw.firstIndex(of: "]") {
            let host = String(raw[raw.index(after: raw.startIndex)..<close])
            let suffix = raw[raw.index(after: close)...]
            if suffix.hasPrefix(":"), let port = Int(suffix.dropFirst()) {
                return (host, port)
            }
            return (host, 22)
        }
        return (raw, 22)
    }

    static func verify(_ entry: SSHKnownHostEntry) async -> SSHKnownHostVerification {
        guard let target = verificationTarget(for: entry) else {
            return .unavailable("Хешированную запись нельзя проверить без имени хоста.")
        }
        do {
            let output = try await runKeyscan(host: target.host, port: target.port)
            let candidates = parse(contents: output, path: "ssh-keyscan")
            guard let current = candidates.first(where: { $0.algorithm == entry.algorithm }) else {
                return .unavailable("Сервер не вернул ключ типа \(entry.algorithm).")
            }
            if current.keyData == entry.keyData { return .matches }
            return .changed(currentFingerprint: current.fingerprint)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private static func runKeyscan(host: String, port: Int) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
            process.arguments = ["-T", "5", "-p", String(port), host]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 || !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "SelectiveRemote.SSHKnownHosts", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Не удалось получить host key с сервера."])
            }
            return output
        }.value
    }
}
