import Foundation
import CryptoKit
import Darwin

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

enum SSHKnownHostRecoveryRole: Equatable, Sendable {
    case destination
    case jumpHost
}

struct SSHKnownHostRecoveryCandidate: Identifiable, Sendable {
    let id = UUID()
    let role: SSHKnownHostRecoveryRole
    let profileID: UUID
    let host: String
    let port: Int
    let originalEntry: SSHKnownHostEntry
    let observedEntry: SSHKnownHostEntry
    let sourceContents: Data

    var endpoint: String {
        let displayHost = host.contains(":") ? "[\(host)]" : host
        return "\(displayHost):\(port)"
    }

    var oldFingerprint: String { originalEntry.fingerprint }
    var newFingerprint: String { observedEntry.fingerprint }
}

enum SSHKnownHostsService {
    static func isHostKeyMismatch(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("host key verification failed")
            || normalized.contains("remote host identification has changed")
    }

    enum RecoveryError: LocalizedError {
        case unsafeSource, sourceChanged, scanChanged, ambiguous, writeFailed

        var errorDescription: String? {
            switch self {
            case .unsafeSource: "Файл known_hosts недоступен или небезопасен для изменения."
            case .sourceChanged: "Файл known_hosts изменился. Повторите проверку."
            case .scanChanged: "Ключ сервера изменился при повторной проверке."
            case .ambiguous: "Запись хоста неоднозначна. Требуется ручная проверка."
            case .writeFailed: "Не удалось безопасно сохранить known_hosts."
            }
        }
    }

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

    static func recoveryCandidate(
        host: String,
        port: Int,
        role: SSHKnownHostRecoveryRole,
        profileID: UUID,
        scannedContents: String,
        from url: URL = defaultURL
    ) -> SSHKnownHostRecoveryCandidate? {
        guard (try? SSHService.validateHost(host)) != nil,
              (1...65_535).contains(port),
              isRegularFileWithoutSymlink(url),
              let sourceContents = try? Data(contentsOf: url),
              let source = String(data: sourceContents, encoding: .utf8)
        else { return nil }

        let lookupHost = host.contains(":") && port != 22 ? "[\(host)]:\(port)"
            : port == 22 ? host : "[\(host)]:\(port)"
        guard let matches = openSSHMatches(host: lookupHost, from: url) else { return nil }
        let stored = parse(contents: source, path: url.path)
        let observed = parse(contents: scannedContents, path: "ssh-keyscan")
        let matched = matches.compactMap { line in stored.first(where: { $0.lineNumber == line }) }
        guard !matched.isEmpty, matched.count == matches.count,
              matched.allSatisfy({
                  $0.marker == nil && !$0.hosts.contains(",")
                      && ($0.hosts == lookupHost || $0.hosts.hasPrefix("|1|"))
              }),
              Set(matched.map(\.algorithm)).count == matched.count,
              !observed.isEmpty,
              observed.allSatisfy({ $0.hosts == lookupHost && $0.marker == nil }),
              Set(observed.map(\.algorithm)).count == observed.count
        else { return nil }
        let paired = observed.compactMap { new -> (SSHKnownHostEntry, SSHKnownHostEntry)? in
            guard let old = matched.first(where: { $0.algorithm == new.algorithm }) else { return nil }
            return (old, new)
        }
        guard !paired.isEmpty else { return nil }
        let changedPairs = paired.filter { $0.0.keyData != $0.1.keyData }
        guard changedPairs.count == 1,
              let pair = changedPairs.first else { return nil }
        return SSHKnownHostRecoveryCandidate(
            role: role, profileID: profileID, host: host, port: port,
            originalEntry: pair.0, observedEntry: pair.1,
            sourceContents: sourceContents
        )
    }

    private static func isRegularFileWithoutSymlink(_ url: URL) -> Bool {
        var metadata = stat()
        return isSafeParentDirectory(url.deletingLastPathComponent())
            && lstat(url.path, &metadata) == 0
            && (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && metadata.st_uid == getuid()
    }

    private static func isSafeParentDirectory(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
            && (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && metadata.st_uid == getuid()
            && (metadata.st_mode & 0o022) == 0
    }

    static func replaceConfirmed(
        _ candidate: SSHKnownHostRecoveryCandidate,
        from url: URL = defaultURL,
        rescan: @Sendable () async throws -> String
    ) async throws -> URL {
        // A lock serializes this app's own recovery transactions. External editors are
        // detected by the exact source snapshot immediately before replacement.
        guard url.standardizedFileURL.path == URL(fileURLWithPath: candidate.originalEntry.sourcePath).standardizedFileURL.path,
              isSafeParentDirectory(url.deletingLastPathComponent()) else {
            throw RecoveryError.unsafeSource
        }
        let lockURL = url.appendingPathExtension("selectiveremote.lock")
        let lockFD = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw RecoveryError.unsafeSource }
        defer { _ = flock(lockFD, LOCK_UN); close(lockFD) }
        var lockMetadata = stat()
        guard fstat(lockFD, &lockMetadata) == 0,
              (lockMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              lockMetadata.st_uid == getuid(),
              (lockMetadata.st_mode & 0o077) == 0,
              flock(lockFD, LOCK_EX | LOCK_NB) == 0
        else { throw RecoveryError.unsafeSource }

        guard isRegularFileWithoutSymlink(url) else { throw RecoveryError.unsafeSource }
        let scanned = try await rescan()
        guard let confirmation = recoveryCandidate(
            host: candidate.host, port: candidate.port, role: candidate.role,
            profileID: candidate.profileID, scannedContents: scanned, from: url
        ), confirmation.originalEntry.id == candidate.originalEntry.id,
           confirmation.observedEntry.keyData == candidate.observedEntry.keyData,
           confirmation.sourceContents == candidate.sourceContents
        else { throw RecoveryError.scanChanged }

        let sourceFD = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard sourceFD >= 0 else { throw RecoveryError.unsafeSource }
        defer { close(sourceFD) }
        var metadata = stat()
        guard fstat(sourceFD, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              let current = try? FileHandle(fileDescriptor: sourceFD, closeOnDealloc: false).readToEnd(),
              current == candidate.sourceContents,
              let source = String(data: current, encoding: .utf8)
        else { throw RecoveryError.sourceChanged }

        var lines = source.components(separatedBy: "\n")
        let index = candidate.originalEntry.lineNumber - 1
        guard lines.indices.contains(index),
              let oldRange = lines[index].range(of: candidate.originalEntry.keyData),
              lines[index].range(of: candidate.originalEntry.keyData, range: oldRange.upperBound..<lines[index].endIndex) == nil
        else { throw RecoveryError.ambiguous }
        lines[index].replaceSubrange(oldRange, with: candidate.observedEntry.keyData)
        let replacement = Data(lines.joined(separator: "\n").utf8)
        let directory = url.deletingLastPathComponent()
        let backup = directory.appendingPathComponent("known_hosts.selectiveremote.\(Int(Date().timeIntervalSince1970 * 1000)).\(UUID().uuidString).bak")
        let temporary = directory.appendingPathComponent(".known_hosts.selectiveremote.\(UUID().uuidString).tmp")
        guard try writeExclusive(current, to: backup, mode: 0o600) else { throw RecoveryError.writeFailed }
        do {
            guard try writeExclusive(replacement, to: temporary, mode: metadata.st_mode & 0o777) else {
                throw RecoveryError.writeFailed
            }
            guard isRegularFileWithoutSymlink(url),
                  (try? Data(contentsOf: url)) == current,
                  rename(temporary.path, url.path) == 0
            else { throw RecoveryError.sourceChanged }
            guard (try? Data(contentsOf: url)) == replacement else { throw RecoveryError.writeFailed }
            let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if directoryFD >= 0 {
                _ = fsync(directoryFD)
                close(directoryFD)
            }
            pruneRecoveryBackups(in: directory, preserving: backup.lastPathComponent, keeping: 10)
            return backup
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    private static func pruneRecoveryBackups(
        in directory: URL,
        preserving newest: String,
        keeping maximum: Int
    ) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let backups = names.filter { name in
            let fields = name.split(separator: ".")
            return fields.count == 5
                && fields[0] == "known_hosts"
                && fields[1] == "selectiveremote"
                && Int(fields[2]) != nil
                && UUID(uuidString: String(fields[3])) != nil
                && fields[4] == "bak"
        }.sorted(by: >)
        let ordered = [newest] + backups.filter { $0 != newest }
        for name in ordered.dropFirst(maximum) {
            let url = directory.appendingPathComponent(name)
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0,
                  (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  metadata.st_uid == getuid() else { continue }
            _ = unlink(url.path)
        }
    }

    private static func writeExclusive(_ contents: Data, to url: URL, mode: mode_t) throws -> Bool {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { return false }
        var complete = false
        defer {
            close(fd)
            if !complete { unlink(url.path) }
        }
        let wrote = contents.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return contents.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        guard wrote, fsync(fd) == 0 else { return false }
        complete = true
        return true
    }

    private static func openSSHMatches(host: String, from url: URL) -> [Int]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-F", host, "-f", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("# Host "),
                  let range = line.range(of: " found: line ") else { return nil }
            return Int(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
        }
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

    static func runKeyscan(host: String, port: Int) async throws -> String {
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
