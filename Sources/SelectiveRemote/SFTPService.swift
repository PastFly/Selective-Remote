import Foundation

enum SFTPServiceError: LocalizedError, Sendable {
    case executableUnavailable
    case unsupportedPath
    case invalidName
    case invalidPermissions
    case invalidNumericID
    case authenticationRequired
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            "Системная команда /usr/bin/sftp недоступна"
        case .unsupportedPath:
            "Путь SFTP содержит недопустимый перенос строки или нулевой символ"
        case .invalidName:
            "Имя не должно быть пустым, равно «.» или «..», содержать /, перенос строки или нулевой символ"
        case .invalidPermissions:
            "Права доступа должны быть записаны тремя или четырьмя восьмеричными цифрами, например 755 или 0644"
        case .invalidNumericID:
            "UID и GID должны быть целыми неотрицательными числами"
        case .authenticationRequired:
            "SSH-сервер отклонил аутентификацию SFTP. Проверьте логин, пароль "
                + "или SSH-ключ и повторите подключение."
        case let .commandFailed(message):
            "Ошибка SFTP: \(message)"
        }
    }
}

struct SFTPRemoteEntry: Identifiable, Equatable, Sendable {
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64?
    let permissions: String
    let owner: String
    let group: String
    let modifiedText: String
    let modificationDate: Date?

    var id: String { name }

    var sizeText: String {
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var ownerText: String {
        group.isEmpty ? owner : "\(owner):\(group)"
    }

    var modeText: String {
        SFTPPermissionFormatter.octal(fromSymbolic: permissions) ?? "—"
    }
}

enum SFTPFileSortField: String, CaseIterable, Identifiable, Sendable {
    case name
    case size
    case modified
    case owner
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Имя"
        case .size: "Размер"
        case .modified: "Изменён"
        case .owner: "Владелец"
        case .permissions: "Доступ"
        }
    }
}

enum SFTPSortDirection: String, CaseIterable, Identifiable, Sendable {
    case ascending
    case descending

    var id: String { rawValue }
    var title: String { self == .ascending ? "По возрастанию" : "По убыванию" }
    var systemImage: String {
        self == .ascending ? "arrow.up" : "arrow.down"
    }
}

struct SFTPPathCrumb: Identifiable, Equatable, Sendable {
    let title: String
    let path: String

    var id: String { path }
}

enum SFTPNameFilter {
    static func matches(_ name: String, query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty || name.localizedCaseInsensitiveContains(normalized)
    }
}

enum SFTPPermissionFormatter {
    static func symbolic(
        mode: Int,
        isDirectory: Bool,
        isSymbolicLink: Bool
    ) -> String {
        let type = isDirectory ? "d" : isSymbolicLink ? "l" : "-"
        let masks = [
            0o400, 0o200, 0o100,
            0o040, 0o020, 0o010,
            0o004, 0o002, 0o001
        ]
        let characters = Array("rwxrwxrwx")
        var result = type
        for (index, mask) in masks.enumerated() {
            var value = mode & mask == 0 ? "-" : String(characters[index])
            if index == 2, mode & 0o4000 != 0 {
                value = mode & mask == 0 ? "S" : "s"
            } else if index == 5, mode & 0o2000 != 0 {
                value = mode & mask == 0 ? "S" : "s"
            } else if index == 8, mode & 0o1000 != 0 {
                value = mode & mask == 0 ? "T" : "t"
            }
            result += value
        }
        return result
    }

    static func octal(fromSymbolic permissions: String) -> String? {
        let core = Array(permissions.prefix(10))
        guard core.count == 10 else { return nil }
        var mode = 0
        let masks = [
            0o400, 0o200, 0o100,
            0o040, 0o020, 0o010,
            0o004, 0o002, 0o001
        ]
        for index in 0..<9 {
            let character = core[index + 1]
            if index % 3 == 2 {
                if character == "x" || character == "s" || character == "t" {
                    mode |= masks[index]
                }
            } else if character != "-" {
                mode |= masks[index]
            }
        }
        if core[3] == "s" || core[3] == "S" { mode |= 0o4000 }
        if core[6] == "s" || core[6] == "S" { mode |= 0o2000 }
        if core[9] == "t" || core[9] == "T" { mode |= 0o1000 }
        return String(format: "%04o", mode)
    }

    static func normalizedMode(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...4).contains(trimmed.count),
              trimmed.allSatisfy({ $0 >= "0" && $0 <= "7" })
        else {
            throw SFTPServiceError.invalidPermissions
        }
        return trimmed.count == 3 ? "0\(trimmed)" : trimmed
    }
}

enum SFTPRemoteEntrySorter {
    static func sorted(
        _ entries: [SFTPRemoteEntry],
        by field: SFTPFileSortField,
        direction: SFTPSortDirection
    ) -> [SFTPRemoteEntry] {
        entries.sorted { left, right in
            if left.isDirectory != right.isDirectory {
                return left.isDirectory
            }
            let comparison: ComparisonResult
            switch field {
            case .name:
                comparison = left.name.localizedCaseInsensitiveCompare(right.name)
            case .size:
                comparison = compare(left.size ?? -1, right.size ?? -1)
            case .modified:
                comparison = compare(
                    left.modificationDate ?? .distantPast,
                    right.modificationDate ?? .distantPast
                )
            case .owner:
                comparison = left.ownerText.localizedCaseInsensitiveCompare(right.ownerText)
            case .permissions:
                comparison = left.permissions.compare(right.permissions)
            }
            if comparison == .orderedSame {
                return left.name.localizedCaseInsensitiveCompare(right.name)
                    == .orderedAscending
            }
            return direction == .ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(
        _ left: T,
        _ right: T
    ) -> ComparisonResult {
        if left < right { return .orderedAscending }
        if left > right { return .orderedDescending }
        return .orderedSame
    }
}

private final class SFTPMasterConnectionManager: @unchecked Sendable {
    private let lock = NSLock()
    private var ownedProcesses: [String: Process] = [:]

    func ensureMaster(
        settings: SSHConnectionSettings,
        executable: String
    ) throws {
        let controlPath = SSHService.controlPath(settings: settings)

        lock.lock()
        defer { lock.unlock() }

        if controlSocketIsAlive(
            settings: settings,
            executable: executable,
            controlPath: controlPath
        ) {
            return
        }

        if let stale = ownedProcesses.removeValue(forKey: controlPath),
           stale.isRunning {
            stale.terminate()
        }
        try? FileManager.default.removeItem(atPath: controlPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = SFTPService.persistentMasterArguments(settings: settings)
        process.environment = SSHKeyService.backgroundAuthenticationEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw SSHServiceError.launchFailed(error.localizedDescription)
        }
        ownedProcesses[controlPath] = process

        // Authentication, including SSH_ASKPASS, happens only in this master.
        // All SFTP child processes attach to the ready socket with BatchMode=yes.
        while process.isRunning {
            if controlSocketIsAlive(
                settings: settings,
                executable: executable,
                controlPath: controlPath
            ) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        ownedProcesses.removeValue(forKey: controlPath)

        // With ControlPersist OpenSSH may successfully detach the master and
        // terminate the bootstrap process with status 0 a fraction of a second
        // before the control socket becomes observable.  Treat that as a
        // successful bootstrap once the socket answers instead of showing a
        // false “code 0” error on the first connection attempt.
        if process.terminationStatus == 0 {
            for _ in 0..<20 {
                if controlSocketIsAlive(
                    settings: settings,
                    executable: executable,
                    controlPath: controlPath
                ) {
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        if process.terminationStatus == 255 {
            throw SFTPServiceError.authenticationRequired
        }
        throw SFTPServiceError.commandFailed(
            "не удалось создать управляющее SSH-соединение "
                + "(код \(process.terminationStatus))"
        )
    }

    private func controlSocketIsAlive(
        settings: SSHConnectionSettings,
        executable: String,
        controlPath: String
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: controlPath) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        var arguments = [
            "-S", controlPath,
            "-O", "check",
            "-p", String(settings.port)
        ]
        if !settings.username.isEmpty {
            arguments += ["-o", "User=\(settings.username)"]
        }
        arguments.append(settings.host)
        process.arguments = arguments
        process.environment = SSHKeyService.processEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

enum SFTPService {
    private static let executable = "/usr/bin/sftp"
    private static let sshExecutable = "/usr/bin/ssh"
    private static let masterManager = SFTPMasterConnectionManager()

    static func list(
        settings: SSHConnectionSettings,
        directory: String
    ) throws -> [SFTPRemoteEntry] {
        let output = try runBatch(
            settings: settings,
            commands: ["ls -la \(try quotedPath(directory))"]
        )
        let entries = parseListing(output, directory: directory)
        if entries.isEmpty, listingContainsUnparsedEntries(output) {
            let sample = listingDiagnosticSample(output)
            throw SFTPServiceError.commandFailed(
                "сервер вернул список файлов в неизвестном формате. "
                    + "Фрагмент ответа: \(sample)"
            )
        }
        return entries
    }

    static func remoteSize(
        settings: SSHConnectionSettings,
        remotePath: String
    ) throws -> Int64? {
        let output = try runBatch(
            settings: settings,
            commands: ["ls -ln \(try quotedPath(remotePath))"]
        )
        return parseListing(output).first?.size
    }

    static func download(
        settings: SSHConnectionSettings,
        remotePath: String,
        localURL: URL,
        isDirectory: Bool = false,
        resume: Bool = false,
        control: SFTPProcessControl? = nil
    ) throws {
        _ = try runBatch(
            settings: settings,
            commands: [
                try downloadCommand(
                    remotePath: remotePath,
                    localURL: localURL,
                    isDirectory: isDirectory,
                    resume: resume
                )
            ],
            control: control
        )
    }

    static func upload(
        settings: SSHConnectionSettings,
        localURL: URL,
        remotePath: String,
        isDirectory: Bool? = nil,
        resume: Bool = false,
        control: SFTPProcessControl? = nil
    ) throws {
        let directory = isDirectory ?? (
            (try? localURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                ?? localURL.hasDirectoryPath
        )
        _ = try runBatch(
            settings: settings,
            commands: [
                try uploadCommand(
                    localURL: localURL,
                    remotePath: remotePath,
                    isDirectory: directory,
                    resume: resume
                )
            ],
            control: control
        )
    }

    static func uploadFileContents(
        settings: SSHConnectionSettings,
        localURL: URL,
        remotePath: String
    ) throws {
        _ = try runBatch(
            settings: settings,
            commands: [try uploadFileContentsCommand(
                localURL: localURL,
                remotePath: remotePath
            )]
        )
    }

    static func createDirectory(
        settings: SSHConnectionSettings,
        remotePath: String
    ) throws {
        _ = try runBatch(
            settings: settings,
            commands: ["mkdir \(try quotedPath(remotePath))"]
        )
    }

    static func rename(
        settings: SSHConnectionSettings,
        from sourcePath: String,
        to destinationPath: String
    ) throws {
        _ = try runBatch(
            settings: settings,
            commands: [try renameCommand(from: sourcePath, to: destinationPath)]
        )
    }

    static func remove(
        settings: SSHConnectionSettings,
        remotePath: String,
        isDirectory: Bool
    ) throws {
        try removeMany(
            settings: settings,
            items: [(path: remotePath, isDirectory: isDirectory)]
        )
    }

    static func removeMany(
        settings: SSHConnectionSettings,
        items: [(path: String, isDirectory: Bool)]
    ) throws {
        guard !items.isEmpty else { return }
        for item in items { try validateRemovalTarget(item.path) }

        // Standard SSH servers can remove a whole tree in one remote process.
        // This is dramatically faster than starting an SFTP batch for every
        // child (thousands of round trips for a directory with many files).
        // If the account is restricted to internal-sftp, fall back to the
        // portable recursive SFTP implementation below.
        do {
            let args = try items.map { try shellQuoted($0.path) }.joined(separator: " ")
            try runRemoteShellCommand(settings: settings, command: "rm -rf -- \(args)")
            return
        } catch {
            for item in items {
                if item.isDirectory {
                    try removeDirectoryRecursively(settings: settings, remotePath: item.path)
                } else {
                    _ = try runBatch(
                        settings: settings,
                        commands: [try removeCommand(remotePath: item.path, isDirectory: false)]
                    )
                }
            }
        }
    }

    /// OpenSSH sftp's `rmdir` only removes empty directories and `rm` has no
    /// portable recursive flag. Walk the tree through SFTP, remove children
    /// first, then remove the directory itself. Symlinks are listed as files,
    /// so they are unlinked rather than followed.
    private static func removeDirectoryRecursively(
        settings: SSHConnectionSettings,
        remotePath: String
    ) throws {
        let children = try list(settings: settings, directory: remotePath)
        for child in children {
            guard child.name != ".", child.name != ".." else { continue }
            let childPath = joinedRemotePath(remotePath, child.name)
            if child.isDirectory {
                try removeDirectoryRecursively(settings: settings, remotePath: childPath)
            } else {
                _ = try runBatch(
                    settings: settings,
                    commands: [try removeCommand(remotePath: childPath, isDirectory: false)]
                )
            }
        }
        _ = try runBatch(
            settings: settings,
            commands: [try removeCommand(remotePath: remotePath, isDirectory: true)]
        )
    }


    private static func validateRemovalTarget(_ path: String) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/", trimmed != ".", trimmed != "~" else {
            throw SFTPServiceError.unsupportedPath
        }
    }

    private static func shellQuoted(_ path: String) throws -> String {
        guard !path.contains("\0"), !path.contains(where: \.isNewline) else {
            throw SFTPServiceError.unsupportedPath
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    @discardableResult
    private static func runRemoteShellCommand(
        settings: SSHConnectionSettings,
        command: String
    ) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: sshExecutable) else {
            throw SFTPServiceError.executableUnavailable
        }
        try masterManager.ensureMaster(settings: settings, executable: sshExecutable)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: sshExecutable)
        var arguments = [
            "-p", String(settings.port),
            "-o", "BatchMode=yes",
            "-o", "ControlPath=\(SSHService.controlPath(settings: settings))",
            "-o", "ControlMaster=no"
        ]
        if !settings.username.isEmpty { arguments += ["-o", "User=\(settings.username)"] }
        arguments += [settings.host, command]
        process.arguments = arguments
        process.environment = SSHKeyService.processEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw SFTPServiceError.commandFailed(
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "удалённая команда завершилась с кодом \(process.terminationStatus)"
                    : String(text.suffix(4_000))
            )
        }
        return text
    }

    /// Returns the current byte size of a remote file. Prefer one lightweight
    /// shell `wc` over parsing `sftp ls` output; accounts restricted to
    /// internal-sftp automatically fall back to the portable SFTP probe.
    static func transferFileSize(
        settings: SSHConnectionSettings,
        remotePath: String
    ) -> Int64? {
        if let expression = try? shellPathExpression(remotePath),
           let output = try? runRemoteShellCommand(
               settings: settings,
               command: "wc -c < \(expression)"
           ),
           let first = output.split(whereSeparator: { $0.isWhitespace }).first,
           let bytes = Int64(first) {
            return bytes
        }
        return try? remoteSize(settings: settings, remotePath: remotePath)
    }

    /// Returns the current transferred byte count for either a file or a
    /// directory. Directory progress uses one lightweight `du` over the
    /// existing SSH master connection; restricted SFTP-only accounts simply
    /// return nil and keep the UI's indeterminate linear progress bar.
    static func transferItemSize(
        settings: SSHConnectionSettings,
        remotePath: String,
        isDirectory: Bool
    ) -> Int64? {
        guard isDirectory else {
            return transferFileSize(settings: settings, remotePath: remotePath)
        }
        guard let expression = try? shellPathExpression(remotePath),
              let output = try? runRemoteShellCommand(
                  settings: settings,
                  command: "du -sk -- \(expression) 2>/dev/null | awk 'NR==1 {print $1}'"
              ),
              let first = output.split(whereSeparator: { $0.isWhitespace }).first,
              let kib = Int64(first)
        else { return nil }
        return kib * 1024
    }

    /// Calculates recursive sizes of the listed child directories in one SSH
    /// process. Each output line corresponds to one requested name; failures
    /// stay nil and do not prevent the rest of the list from updating.
    static func directorySizes(
        settings: SSHConnectionSettings,
        directory: String,
        names: [String]
    ) -> [String: Int64] {
        let safeNames = names.filter { !$0.contains("\0") && !$0.contains(where: \.isNewline) }
        guard !safeNames.isEmpty else { return [:] }
        var expressions: [String] = []
        for name in safeNames {
            let path = joinedRemotePath(directory, name)
            guard let expression = try? shellPathExpression(path) else { continue }
            expressions.append(expression)
        }
        guard expressions.count == safeNames.count else { return [:] }
        let joined = expressions.joined(separator: " ")
        let command = "for p in \(joined); do "
            + "s=$(du -sk -- \"$p\" 2>/dev/null | awk 'NR==1 {print $1}'); "
            + "printf '%s\\n' \"${s:-}\"; done"
        guard let output = try? runRemoteShellCommand(settings: settings, command: command) else {
            return [:]
        }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [String: Int64] = [:]
        for (index, name) in safeNames.enumerated() where index < lines.count {
            let value = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if let kib = Int64(value) { result[name] = kib * 1024 }
        }
        return result
    }

    private static func shellPathExpression(_ path: String) throws -> String {
        if path == "~" { return "$HOME" }
        if path.hasPrefix("~/") {
            return "$HOME/" + (try shellQuoted(String(path.dropFirst(2))))
        }
        return try shellQuoted(path)
    }

    static func updateAttributes(
        settings: SSHConnectionSettings,
        remotePath: String,
        mode: String?,
        ownerID: Int?,
        groupID: Int?
    ) throws {
        let commands = try attributeCommands(
            remotePath: remotePath,
            mode: mode,
            ownerID: ownerID,
            groupID: groupID
        )
        guard !commands.isEmpty else { return }
        _ = try runBatch(settings: settings, commands: commands)
    }

    static func parseListing(
        _ output: String,
        directory: String? = nil
    ) -> [SFTPRemoteEntry] {
        output.components(separatedBy: .newlines)
            .compactMap { parseListingLine($0, directory: directory) }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private struct ListingToken {
        let value: String
        let range: Range<String.Index>
    }

    /// OpenSSH does not guarantee one textual representation for `ls -l`.
    /// Depending on the client/server versions it may use a numeric or unknown
    /// link count, localized months, an ISO date and ACL suffixes. Parse the
    /// stable fields around the date instead of requiring one rigid regex.
    private static func parseListingLine(
        _ rawLine: String,
        directory: String?
    ) -> SFTPRemoteEntry? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = listingTokens(in: line)
        guard let permissionIndex = tokens.firstIndex(where: {
            isPermissionToken($0.value)
        }) else {
            return nil
        }

        let permissions = tokens[permissionIndex].value
        let firstMetadataIndex = permissionIndex + 1
        guard firstMetadataIndex < tokens.count else { return nil }

        var dateMatch: (start: Int, length: Int)?
        for index in firstMetadataIndex..<tokens.count {
            guard index > firstMetadataIndex,
                  parseListingSize(tokens[index - 1].value) != nil,
                  let length = listingDateLength(tokens: tokens, at: index),
                  index + length < tokens.count
            else {
                continue
            }
            dateMatch = (index, length)
            break
        }
        guard let dateMatch,
              let size = parseListingSize(tokens[dateMatch.start - 1].value)
        else {
            return nil
        }

        var identityFields = tokens[firstMetadataIndex..<(dateMatch.start - 1)]
            .map(\.value)
        if identityFields.count >= 3,
           (identityFields[0] == "?" || Int(identityFields[0]) != nil) {
            identityFields.removeFirst()
        }
        let owner = identityFields.first ?? ""
        let group = identityFields.dropFirst().first ?? ""

        let nameIndex = dateMatch.start + dateMatch.length
        let nameStart = tokens[nameIndex].range.lowerBound
        var name = String(line[nameStart...])
        if permissions.hasPrefix("l"),
           let arrow = name.range(of: " -> ") {
            name = String(name[..<arrow.lowerBound])
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = relativeListingName(name, directory: directory)
        guard !isCurrentOrParentDirectory(name), !name.isEmpty else { return nil }

        let modifiedText = tokens[
            dateMatch.start..<(dateMatch.start + dateMatch.length)
        ]
        .map(\.value)
        .joined(separator: " ")

        return SFTPRemoteEntry(
            name: name,
            isDirectory: permissions.hasPrefix("d"),
            isSymbolicLink: permissions.hasPrefix("l"),
            size: permissions.hasPrefix("d") ? nil : size,
            permissions: permissions,
            owner: owner,
            group: group,
            modifiedText: modifiedText,
            modificationDate: parseModificationDate(modifiedText)
        )
    }

    private static func listingTokens(in line: String) -> [ListingToken] {
        var result: [ListingToken] = []
        var index = line.startIndex
        while index < line.endIndex {
            while index < line.endIndex, line[index].isWhitespace {
                index = line.index(after: index)
            }
            guard index < line.endIndex else { break }
            let start = index
            while index < line.endIndex, !line[index].isWhitespace {
                index = line.index(after: index)
            }
            let range = start..<index
            result.append(ListingToken(value: String(line[range]), range: range))
        }
        return result
    }

    private static func isPermissionToken(_ value: String) -> Bool {
        let characters = Array(value)
        guard (10...13).contains(characters.count),
              "bcdlps-D?".contains(characters[0])
        else {
            return false
        }
        let permissionCharacters = Set("rwxstST-?")
        guard characters[1...9].allSatisfy({
            permissionCharacters.contains($0)
        }) else {
            return false
        }
        return characters.dropFirst(10).allSatisfy({ "+@.".contains($0) })
    }

    private static func isPotentialPermissionToken(_ value: String) -> Bool {
        let characters = Array(value)
        return characters.count >= 10 && "bcdlps-D?".contains(characters[0])
    }

    private static func parseListingSize(_ value: String) -> Int64? {
        Int64(value.replacingOccurrences(of: ",", with: ""))
    }

    private static func listingDateLength(
        tokens: [ListingToken],
        at index: Int
    ) -> Int? {
        guard index < tokens.count else { return nil }
        let first = tokens[index].value

        if isISODate(first) {
            if index + 1 < tokens.count, isClock(tokens[index + 1].value) {
                return 2
            }
            return 1
        }

        guard index + 2 < tokens.count else { return nil }
        let second = tokens[index + 1].value
        let third = tokens[index + 2].value
        let monthDay = isMonth(first) && isDay(second)
        let dayMonth = isDay(first) && isMonth(second)
        guard (monthDay || dayMonth), isClock(third) || isYear(third) else {
            return nil
        }
        return 3
    }

    private static func isMonth(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        return !value.isEmpty
            && value.count <= 16
            && scalars.contains(where: CharacterSet.letters.contains)
    }

    private static func isDay(_ value: String) -> Bool {
        guard let day = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: ",")))
        else {
            return false
        }
        return (1...31).contains(day)
    }

    private static func isClock(_ value: String) -> Bool {
        let components = value.split(separator: ":")
        guard components.count == 2 || components.count == 3,
              let hour = Int(components[0]),
              let minute = Int(components[1]),
              (0...23).contains(hour),
              (0...59).contains(minute)
        else {
            return false
        }
        if components.count == 3 {
            guard let second = Int(components[2]), (0...60).contains(second) else {
                return false
            }
        }
        return true
    }

    private static func isYear(_ value: String) -> Bool {
        guard value.count == 4, let year = Int(value) else { return false }
        return (1_900...3_000).contains(year)
    }

    private static func isISODate(_ value: String) -> Bool {
        let normalized = value.replacingOccurrences(of: "/", with: "-")
        let components = normalized.split(separator: "-")
        guard components.count == 3,
              components[0].count == 4,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2])
        else {
            return false
        }
        return (1_900...3_000).contains(year)
            && (1...12).contains(month)
            && (1...31).contains(day)
    }

    private static func isCurrentOrParentDirectory(_ name: String) -> Bool {
        name == "."
            || name == ".."
            || name.hasSuffix("/.")
            || name.hasSuffix("/..")
    }

    private static func relativeListingName(
        _ name: String,
        directory: String?
    ) -> String {
        guard var directory else { return name }
        directory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        while directory.count > 1, directory.hasSuffix("/") {
            directory.removeLast()
        }

        let prefix: String
        switch directory {
        case "/":
            prefix = "/"
        case ".":
            prefix = "./"
        default:
            prefix = "\(directory)/"
        }
        guard name.hasPrefix(prefix) else { return name }
        return String(name.dropFirst(prefix.count))
    }

    private static func listingContainsUnparsedEntries(_ output: String) -> Bool {
        output.components(separatedBy: .newlines)
            .map { listingTokens(in: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .contains { tokens in
                guard tokens.contains(where: {
                    isPotentialPermissionToken($0.value)
                }), let name = tokens.last?.value
                else {
                    return false
                }
                return !isCurrentOrParentDirectory(name)
            }
    }

    private static func listingDiagnosticSample(_ output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty
                    && !line.hasPrefix("Connected to ")
                    && !line.hasPrefix("sftp>")
            }
        let sample = lines.prefix(3).joined(separator: " | ")
        return String(sample.prefix(700))
    }

    static func joinedRemotePath(_ directory: String, _ name: String) -> String {
        if directory == "/" { return "/\(name)" }
        if directory == "." { return name }
        if directory.hasSuffix("/") { return directory + name }
        return directory + "/" + name
    }

    static func parentRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "/", trimmed != "~" else {
            return trimmed == "/" ? "/" : "."
        }
        let value = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let slash = value.lastIndex(of: "/") else { return "." }
        let parent = String(value[..<slash])
        if parent.isEmpty { return "/" }
        return parent
    }

    static func breadcrumbs(for path: String) -> [SFTPPathCrumb] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "." else {
            return [SFTPPathCrumb(title: "~", path: ".")]
        }
        if trimmed == "/" {
            return [SFTPPathCrumb(title: "/", path: "/")]
        }
        if trimmed == "~" {
            return [SFTPPathCrumb(title: "~", path: "~")]
        }

        let absolute = trimmed.hasPrefix("/")
        let tilde = trimmed == "~" || trimmed.hasPrefix("~/")
        let components = trimmed.split(separator: "/").map(String.init)
        var crumbs: [SFTPPathCrumb] = []
        var accumulated = absolute ? "/" : tilde ? "~" : ""

        if absolute {
            crumbs.append(SFTPPathCrumb(title: "/", path: "/"))
        } else {
            crumbs.append(
                SFTPPathCrumb(
                    title: "~",
                    path: tilde ? "~" : "."
                )
            )
        }

        for component in components where component != "~" && component != "." {
            if accumulated.isEmpty || accumulated == "." {
                accumulated = component
            } else if accumulated == "/" {
                accumulated += component
            } else {
                accumulated += "/\(component)"
            }
            crumbs.append(SFTPPathCrumb(title: component, path: accumulated))
        }
        return crumbs
    }

    static func connectionArguments(settings: SSHConnectionSettings) -> [String] {
        // Every file operation is a non-interactive slave of the persistent
        // master created before the first operation. If that master disappears,
        // the child fails instead of asking for the password again.
        var arguments = [
            "-P", String(settings.port),
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=\(settings.hostKeyPolicy.openSSHValue)",
            "-o", "ControlPath=\(SSHService.controlPath(settings: settings))",
            "-o", "ControlMaster=no"
        ]
        if !settings.username.isEmpty {
            arguments += ["-o", "User=\(settings.username)"]
        }
        if let identity = settings.identity {
            arguments += [
                "-i", identity.privateKeyPath,
                "-o", "IdentitiesOnly=yes"
            ]
        }
        if settings.compression {
            arguments.append("-C")
        }
        if settings.keepAliveSeconds > 0 {
            arguments += [
                "-o", "ServerAliveInterval=\(settings.keepAliveSeconds)",
                "-o", "ServerAliveCountMax=3"
            ]
        }
        arguments.append(settings.host)
        return arguments
    }

    static func persistentMasterArguments(settings: SSHConnectionSettings) -> [String] {
        var arguments = [
            "-p", String(settings.port),
            "-o", "BatchMode=no",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "PreferredAuthentications=publickey,keyboard-interactive,password",
            "-o", "StrictHostKeyChecking=\(settings.hostKeyPolicy.openSSHValue)",
            "-o", "ControlPath=\(SSHService.controlPath(settings: settings))",
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=600",
            "-o", "ConnectTimeout=15"
        ]
        if !settings.username.isEmpty {
            arguments += ["-o", "User=\(settings.username)"]
        }
        if let identity = settings.identity {
            arguments += [
                "-i", identity.privateKeyPath,
                "-o", "IdentitiesOnly=yes"
            ]
        }
        if settings.compression {
            arguments.append("-C")
        }
        if settings.keepAliveSeconds > 0 {
            arguments += [
                "-o", "ServerAliveInterval=\(settings.keepAliveSeconds)",
                "-o", "ServerAliveCountMax=3"
            ]
        }
        arguments += ["-N", settings.host]
        return arguments
    }

    static func downloadCommand(
        remotePath: String,
        localURL: URL,
        isDirectory: Bool,
        resume: Bool = false
    ) throws -> String {
        let flags = isDirectory ? "-pR" : "-p"
        let verb = resume && !isDirectory ? "reget" : "get"
        return "\(verb) \(flags) \(try quotedPath(remotePath)) \(try quotedPath(localURL.path))"
    }

    static func uploadCommand(
        localURL: URL,
        remotePath: String,
        isDirectory: Bool,
        resume: Bool = false
    ) throws -> String {
        let flags = isDirectory ? "-pR" : "-p"
        let verb = resume && !isDirectory ? "reput" : "put"
        return "\(verb) \(flags) \(try quotedPath(localURL.path)) \(try quotedPath(remotePath))"
    }

    static func uploadFileContentsCommand(
        localURL: URL,
        remotePath: String
    ) throws -> String {
        "put \(try quotedPath(localURL.path)) \(try quotedPath(remotePath))"
    }

    static func renameCommand(from sourcePath: String, to destinationPath: String) throws -> String {
        "rename \(try quotedPath(sourcePath)) \(try quotedPath(destinationPath))"
    }

    static func removeCommand(remotePath: String, isDirectory: Bool) throws -> String {
        "\(isDirectory ? "rmdir" : "rm") \(try quotedPath(remotePath))"
    }

    static func attributeCommands(
        remotePath: String,
        mode: String?,
        ownerID: Int?,
        groupID: Int?
    ) throws -> [String] {
        if let ownerID, ownerID < 0 { throw SFTPServiceError.invalidNumericID }
        if let groupID, groupID < 0 { throw SFTPServiceError.invalidNumericID }
        let path = try quotedPath(remotePath)
        var commands: [String] = []
        if let mode {
            commands.append("chmod \(try SFTPPermissionFormatter.normalizedMode(mode)) \(path)")
        }
        if let ownerID {
            commands.append("chown \(ownerID) \(path)")
        }
        if let groupID {
            commands.append("chgrp \(groupID) \(path)")
        }
        return commands
    }

    static func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0"),
              !name.contains(where: \.isNewline)
        else {
            throw SFTPServiceError.invalidName
        }
        return name
    }

    private static func runBatch(
        settings: SSHConnectionSettings,
        commands: [String],
        control: SFTPProcessControl? = nil
    ) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable),
              FileManager.default.isExecutableFile(atPath: sshExecutable)
        else {
            throw SFTPServiceError.executableUnavailable
        }

        try masterManager.ensureMaster(
            settings: settings,
            executable: sshExecutable
        )

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = connectionArguments(settings: settings)
        process.environment = SSHKeyService.backgroundAuthenticationEnvironment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            control?.attach(process)
            try input.fileHandleForWriting.write(
                contentsOf: Data((commands.joined(separator: "\n") + "\n").utf8)
            )
            try input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
            throw SSHServiceError.launchFailed(error.localizedDescription)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        control?.detach(process)
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.localizedCaseInsensitiveContains("Permission denied") {
                throw SFTPServiceError.authenticationRequired
            }
            throw SFTPServiceError.commandFailed(
                message.isEmpty ? "команда завершилась с кодом \(process.terminationStatus)"
                    : String(message.suffix(4_000))
            )
        }
        return text
    }

    private static func quotedPath(_ path: String) throws -> String {
        guard !path.contains("\0"),
              !path.contains(where: \.isNewline)
        else {
            throw SFTPServiceError.unsupportedPath
        }
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func parseModificationDate(_ text: String) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: Date())
        let candidates = [
            ("MMM d HH:mm yyyy", "\(text) \(year)"),
            ("MMM d yyyy", text),
            ("d MMM HH:mm yyyy", "\(text) \(year)"),
            ("d MMM yyyy", text),
            ("yyyy-MM-dd HH:mm", text),
            ("yyyy-MM-dd HH:mm:ss", text),
            ("yyyy/MM/dd HH:mm", text),
            ("yyyy/MM/dd HH:mm:ss", text),
            ("yyyy-MM-dd", text),
            ("yyyy/MM/dd", text)
        ]
        let locales = [
            Locale(identifier: "en_US_POSIX"),
            Locale.current
        ]
        for locale in locales {
            for (format, value) in candidates {
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.calendar = calendar
                formatter.isLenient = false
                formatter.dateFormat = format
                if let date = formatter.date(from: value) {
                    return date
                }
            }
        }
        return nil
    }
}
