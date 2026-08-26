import CommonCrypto
import CryptoKit
import Foundation
import Security

enum SelectiveRemoteBackupError: LocalizedError, Equatable {
    case invalidPassword
    case invalidArchive
    case unsupportedVersion(Int)
    case authenticationFailed
    case fileTooLarge
    case cryptoFailure
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidPassword:
            "Пароль архива должен содержать не менее 12 символов."
        case .invalidArchive:
            "Файл не является корректным архивом Selective Remote или повреждён."
        case let .unsupportedVersion(version):
            "Версия архива \(version) пока не поддерживается."
        case .authenticationFailed:
            "Не удалось расшифровать архив. Проверьте пароль и целостность файла."
        case .fileTooLarge:
            "Архив или один из его файлов превышает допустимый размер."
        case .cryptoFailure:
            "Не удалось подготовить ключ шифрования архива."
        case let .missingFile(path):
            "Файл для резервной копии недоступен: \(path)"
        }
    }
}

enum SelectiveRemoteBackupFileCategory: String, Codable, Sendable {
    case sshPrivateKey
    case sshPublicKey
    case sshCertificate
    case sshCAPrivateKey
    case sshCAPublicKey
    case sessionLog
    case connectionActivity
}

struct SelectiveRemoteBackupFileDescriptor: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var category: SelectiveRemoteBackupFileCategory
    var relatedID: UUID?
    var originalPath: String
    var relativePath: String
    var permissions: Int
    var byteCount: Int64
}

struct SelectiveRemoteBackupSummary: Codable, Equatable, Sendable {
    var createdAt: Date
    var appVersion: String
    var profileCount: Int
    var snippetCount: Int
    var credentialCount: Int
    var privateKeyCount: Int
    var sessionLogCount: Int
    var activityLogCount: Int
    var totalFileBytes: Int64
}

struct SelectiveRemoteBackupOptions: Equatable, Sendable {
    var includeCredentials = true
    var includePrivateKeys = true
    var includeSessionLogs = true
    var includeConnectionActivity = true

    static let full = SelectiveRemoteBackupOptions()
}

private struct SelectiveRemoteBackupManifest: Codable, Sendable {
    var schemaVersion: Int
    var createdAt: Date
    var appVersion: String
    var userDefaultsPlist: Data
    var credentials: [String: String]
    var files: [SelectiveRemoteBackupFileDescriptor]
    var summary: SelectiveRemoteBackupSummary
}

struct SelectiveRemoteBackupInspection: Equatable, Sendable {
    var summary: SelectiveRemoteBackupSummary
}

struct SelectiveRemoteBackupRestoreResult: Equatable, Sendable {
    var summary: SelectiveRemoteBackupSummary
    var rollbackURL: URL
    var restoredFileCount: Int
}

final class SelectiveRemoteBackupService: @unchecked Sendable {
    static let shared = SelectiveRemoteBackupService()

    private static let magic = Data("SRBACKUP".utf8)
    private static let schemaVersion: UInt16 = 1
    private static let kdfIterations: UInt32 = 600_000
    private static let saltLength = 32
    private static let maximumManifestBytes: UInt64 = 64 * 1_024 * 1_024
    private static let maximumEntryBytes: UInt64 = 64 * 1_024 * 1_024
    private static let defaultsPrefix = "SelectiveRemote."

    private let fileManager: FileManager
    private let defaults: UserDefaults

    init(fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
        self.fileManager = fileManager
        self.defaults = defaults
    }

    func exportArchive(
        to destination: URL,
        password: String,
        options: SelectiveRemoteBackupOptions = .full
    ) throws -> SelectiveRemoteBackupSummary {
        try validatePassword(password)
        if options.includeCredentials {
            _ = try? KeychainService.migrateCredentialsToUnifiedVault()
        }

        let defaultsPlist = try captureDefaults()
        let credentials = options.includeCredentials
            ? try UnifiedCredentialVault.shared.exportedSecrets()
            : [:]
        let descriptors = try collectFiles(options: options)
        let summary = try makeSummary(
            defaultsPlist: defaultsPlist,
            credentials: credentials,
            descriptors: descriptors
        )
        let manifest = SelectiveRemoteBackupManifest(
            schemaVersion: Int(Self.schemaVersion),
            createdAt: summary.createdAt,
            appVersion: summary.appVersion,
            userDefaultsPlist: defaultsPlist,
            credentials: credentials,
            files: descriptors,
            summary: summary
        )
        try writeArchive(manifest, to: destination, password: password)
        return summary
    }

    func inspectArchive(at url: URL, password: String) throws -> SelectiveRemoteBackupInspection {
        try validatePassword(password)
        let reader = try ArchiveReader(url: url, password: password)
        return SelectiveRemoteBackupInspection(summary: reader.manifest.summary)
    }

    func restoreArchive(
        at source: URL,
        password: String
    ) throws -> SelectiveRemoteBackupRestoreResult {
        try validatePassword(password)
        let reader = try ArchiveReader(url: source, password: password)
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("SelectiveRemote-Restore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: staging) }

        let stagedFiles = try reader.decryptFiles(to: staging)
        let rollbackURL = try createRollbackArchive(password: password)
        let remappedPaths = try installFiles(stagedFiles, descriptors: reader.manifest.files)
        let defaultsPlist = try remapKeyPaths(
            in: reader.manifest.userDefaultsPlist,
            descriptors: reader.manifest.files,
            restoredPaths: remappedPaths
        )

        if !reader.manifest.credentials.isEmpty {
            try UnifiedCredentialVault.shared.replaceSecrets(reader.manifest.credentials)
        }
        try restoreDefaults(from: defaultsPlist)

        return SelectiveRemoteBackupRestoreResult(
            summary: reader.manifest.summary,
            rollbackURL: rollbackURL,
            restoredFileCount: stagedFiles.count
        )
    }

    private func validatePassword(_ password: String) throws {
        guard password.count >= 12 else { throw SelectiveRemoteBackupError.invalidPassword }
    }

    private func captureDefaults() throws -> Data {
        let values = defaults.dictionaryRepresentation().filter {
            $0.key.hasPrefix(Self.defaultsPrefix)
        }
        return try PropertyListSerialization.data(
            fromPropertyList: values,
            format: .binary,
            options: 0
        )
    }

    private func restoreDefaults(from data: Data) throws {
        guard let values = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw SelectiveRemoteBackupError.invalidArchive
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.defaultsPrefix) {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in values where key.hasPrefix(Self.defaultsPrefix) {
            defaults.set(value, forKey: key)
        }
    }

    private func collectFiles(
        options: SelectiveRemoteBackupOptions
    ) throws -> [SelectiveRemoteBackupFileDescriptor] {
        var result: [SelectiveRemoteBackupFileDescriptor] = []
        var seenPaths = Set<String>()

        func append(
            path: String,
            category: SelectiveRemoteBackupFileCategory,
            relatedID: UUID?,
            relativePath: String,
            permissions: Int
        ) throws {
            let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seenPaths.insert(canonical).inserted else { return }
            guard fileManager.isReadableFile(atPath: canonical) else {
                throw SelectiveRemoteBackupError.missingFile(canonical)
            }
            let attributes = try fileManager.attributesOfItem(atPath: canonical)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular else { return }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size >= 0, UInt64(size) <= Self.maximumEntryBytes else {
                throw SelectiveRemoteBackupError.fileTooLarge
            }
            result.append(
                SelectiveRemoteBackupFileDescriptor(
                    id: UUID(),
                    category: category,
                    relatedID: relatedID,
                    originalPath: canonical,
                    relativePath: relativePath,
                    permissions: permissions,
                    byteCount: size
                )
            )
        }

        if options.includePrivateKeys,
           let data = defaults.data(forKey: "SelectiveRemote.sshKeys.v1"),
           let records = try? JSONDecoder().decode([SSHKeyRecord].self, from: data) {
            for record in records {
                let privateURL = URL(fileURLWithPath: record.privateKeyPath)
                try append(
                    path: privateURL.path,
                    category: .sshPrivateKey,
                    relatedID: record.id,
                    relativePath: privateURL.lastPathComponent,
                    permissions: 0o600
                )
                if let publicPath = record.publicKeyPath,
                   fileManager.isReadableFile(atPath: publicPath) {
                    try append(
                        path: publicPath,
                        category: .sshPublicKey,
                        relatedID: record.id,
                        relativePath: URL(fileURLWithPath: publicPath).lastPathComponent,
                        permissions: 0o644
                    )
                }
                let certificatePath = record.privateKeyPath + "-cert.pub"
                if fileManager.isReadableFile(atPath: certificatePath) {
                    try append(
                        path: certificatePath,
                        category: .sshCertificate,
                        relatedID: record.id,
                        relativePath: URL(fileURLWithPath: certificatePath).lastPathComponent,
                        permissions: 0o644
                    )
                }
            }
        }

        if options.includePrivateKeys,
           let data = defaults.data(forKey: "SelectiveRemote.sshCertificateAuthorities.v1"),
           let records = try? JSONDecoder().decode([SSHCertificateAuthorityRecord].self, from: data) {
            for record in records {
                if fileManager.isReadableFile(atPath: record.privateKeyPath) {
                    try append(
                        path: record.privateKeyPath,
                        category: .sshCAPrivateKey,
                        relatedID: record.id,
                        relativePath: URL(fileURLWithPath: record.privateKeyPath).lastPathComponent,
                        permissions: 0o600
                    )
                }
                if fileManager.isReadableFile(atPath: record.publicKeyPath) {
                    try append(
                        path: record.publicKeyPath,
                        category: .sshCAPublicKey,
                        relatedID: record.id,
                        relativePath: URL(fileURLWithPath: record.publicKeyPath).lastPathComponent,
                        permissions: 0o644
                    )
                }
            }
        }

        let support = applicationSupportURL()
        if options.includeSessionLogs {
            let logs = support.appendingPathComponent("Session Logs", isDirectory: true)
            if let enumerator = fileManager.enumerator(
                at: logs,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator {
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                    guard values?.isRegularFile == true else { continue }
                    try append(
                        path: url.path,
                        category: .sessionLog,
                        relatedID: nil,
                        relativePath: url.path.replacingOccurrences(of: logs.path + "/", with: ""),
                        permissions: 0o600
                    )
                }
            }
        }

        if options.includeConnectionActivity {
            let activity = support.appendingPathComponent("connection-activity.json")
            if fileManager.isReadableFile(atPath: activity.path) {
                try append(
                    path: activity.path,
                    category: .connectionActivity,
                    relatedID: nil,
                    relativePath: activity.lastPathComponent,
                    permissions: 0o600
                )
            }
        }
        return result
    }

    private func makeSummary(
        defaultsPlist: Data,
        credentials: [String: String],
        descriptors: [SelectiveRemoteBackupFileDescriptor]
    ) throws -> SelectiveRemoteBackupSummary {
        guard let values = try PropertyListSerialization.propertyList(
            from: defaultsPlist,
            options: [],
            format: nil
        ) as? [String: Any] else { throw SelectiveRemoteBackupError.invalidArchive }
        let profiles = decodeCount([ConnectionProfile].self, key: "SelectiveRemote.connectionProfiles.v2", values: values)
        let snippets = decodeCount([TerminalCommandTemplate].self, key: "SelectiveRemote.terminal.commandTemplates.v1", values: values)
        return SelectiveRemoteBackupSummary(
            createdAt: Date(),
            appVersion: AppBuildInfo.fullText,
            profileCount: profiles,
            snippetCount: snippets,
            credentialCount: credentials.count,
            privateKeyCount: descriptors.filter {
                $0.category == .sshPrivateKey || $0.category == .sshCAPrivateKey
            }.count,
            sessionLogCount: descriptors.filter { $0.category == .sessionLog }.count,
            activityLogCount: descriptors.filter { $0.category == .connectionActivity }.count,
            totalFileBytes: descriptors.reduce(0) { $0 + $1.byteCount }
        )
    }

    private func decodeCount<T: Decodable>(
        _ type: [T].Type,
        key: String,
        values: [String: Any]
    ) -> Int {
        guard let data = values[key] as? Data,
              let decoded = try? JSONDecoder().decode(type, from: data) else { return 0 }
        return decoded.count
    }

    private func writeArchive(
        _ manifest: SelectiveRemoteBackupManifest,
        to destination: URL,
        password: String
    ) throws {
        let salt = try randomData(count: Self.saltLength)
        let key = try Self.deriveKey(password: password, salt: salt, iterations: Self.kdfIterations)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let manifestData = try encoder.encode(manifest)
        guard UInt64(manifestData.count) <= Self.maximumManifestBytes else {
            throw SelectiveRemoteBackupError.fileTooLarge
        }

        var header = Self.magic
        header.appendInteger(Self.schemaVersion)
        header.appendInteger(Self.kdfIterations)
        header.appendInteger(UInt16(salt.count))
        header.append(salt)
        let manifestSealed = try seal(manifestData, key: key, associatedData: header)
        header.appendInteger(UInt64(manifestSealed.count))

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        fileManager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: manifestSealed)
            for descriptor in manifest.files {
                let data = try Data(contentsOf: URL(fileURLWithPath: descriptor.originalPath), options: [.mappedIfSafe])
                let sealed = try seal(data, key: key, associatedData: Data(descriptor.id.uuidString.utf8))
                try handle.write(contentsOf: Data.integer(UInt64(sealed.count)))
                try handle.write(contentsOf: sealed)
            }
            try handle.synchronize()
            try handle.close()
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func createRollbackArchive(password: String) throws -> URL {
        let directory = applicationSupportURL().appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent(
            "Before-Restore-\(formatter.string(from: Date())).srbackup"
        )
        _ = try exportArchive(to: url, password: password, options: .full)
        return url
    }

    private func installFiles(
        _ staged: [UUID: URL],
        descriptors: [SelectiveRemoteBackupFileDescriptor]
    ) throws -> [UUID: String] {
        let support = applicationSupportURL()
        let keyRoot = support.appendingPathComponent("Restored SSH Keys", isDirectory: true)
        let logRoot = support.appendingPathComponent("Session Logs", isDirectory: true)
        try fileManager.createDirectory(at: keyRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        if descriptors.contains(where: { $0.category == .sessionLog }),
           fileManager.fileExists(atPath: logRoot.path) {
            try fileManager.removeItem(at: logRoot)
        }
        var remapped: [UUID: String] = [:]
        for descriptor in descriptors {
            guard let source = staged[descriptor.id] else {
                throw SelectiveRemoteBackupError.invalidArchive
            }
            let destination: URL
            switch descriptor.category {
            case .sshPrivateKey, .sshPublicKey, .sshCertificate, .sshCAPrivateKey, .sshCAPublicKey:
                let owner = descriptor.relatedID?.uuidString ?? "Unassigned"
                let directory = keyRoot.appendingPathComponent(owner, isDirectory: true)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                destination = directory.appendingPathComponent(safeFilename(descriptor.relativePath))
            case .sessionLog:
                destination = logRoot.appendingPathComponent(safeRelativePath(descriptor.relativePath))
            case .connectionActivity:
                destination = support.appendingPathComponent("connection-activity.json")
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: source, to: destination)
            try fileManager.setAttributes(
                [.posixPermissions: descriptor.permissions],
                ofItemAtPath: destination.path
            )
            remapped[descriptor.id] = destination.path
        }
        return remapped
    }

    private func remapKeyPaths(
        in plist: Data,
        descriptors: [SelectiveRemoteBackupFileDescriptor],
        restoredPaths: [UUID: String]
    ) throws -> Data {
        guard var values = try PropertyListSerialization.propertyList(
            from: plist,
            options: [],
            format: nil
        ) as? [String: Any] else { throw SelectiveRemoteBackupError.invalidArchive }

        if let data = values["SelectiveRemote.sshKeys.v1"] as? Data,
           var keys = try? JSONDecoder().decode([SSHKeyRecord].self, from: data) {
            for index in keys.indices {
                let owner = keys[index].id
                if let privatePath = restoredPath(
                    category: .sshPrivateKey,
                    relatedID: owner,
                    descriptors: descriptors,
                    paths: restoredPaths
                ) {
                    keys[index].privateKeyPath = privatePath
                }
                keys[index].publicKeyPath = restoredPath(
                    category: .sshPublicKey,
                    relatedID: owner,
                    descriptors: descriptors,
                    paths: restoredPaths
                ) ?? keys[index].publicKeyPath
            }
            values["SelectiveRemote.sshKeys.v1"] = try JSONEncoder().encode(keys)
        }
        if let data = values["SelectiveRemote.sshCertificateAuthorities.v1"] as? Data,
           var authorities = try? JSONDecoder().decode([SSHCertificateAuthorityRecord].self, from: data) {
            for index in authorities.indices {
                if let publicPath = restoredPath(
                    category: .sshCAPublicKey,
                    relatedID: authorities[index].id,
                    descriptors: descriptors,
                    paths: restoredPaths
                ) {
                    authorities[index].publicKeyPath = publicPath
                }
            }
            values["SelectiveRemote.sshCertificateAuthorities.v1"] = try JSONEncoder().encode(authorities)
        }
        return try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }

    private func restoredPath(
        category: SelectiveRemoteBackupFileCategory,
        relatedID: UUID,
        descriptors: [SelectiveRemoteBackupFileDescriptor],
        paths: [UUID: String]
    ) -> String? {
        descriptors.first {
            $0.category == category && $0.relatedID == relatedID
        }.flatMap { paths[$0.id] }
    }

    private func applicationSupportURL() -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root.appendingPathComponent("Selective Remote", isDirectory: true)
    }

    private func safeFilename(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent.isEmpty
            ? UUID().uuidString
            : URL(fileURLWithPath: path).lastPathComponent
    }

    private func safeRelativePath(_ path: String) -> String {
        path.split(separator: "/")
            .filter { $0 != "." && $0 != ".." }
            .map(String.init)
            .joined(separator: "/")
    }

    private func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw SelectiveRemoteBackupError.cryptoFailure }
        return data
    }

    private static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDF(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        derived.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw SelectiveRemoteBackupError.cryptoFailure }
        return SymmetricKey(data: derived)
    }

    private func seal(_ data: Data, key: SymmetricKey, associatedData: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key, authenticating: associatedData)
        guard let combined = sealed.combined else { throw SelectiveRemoteBackupError.cryptoFailure }
        return combined
    }

    private final class ArchiveReader {
        let manifest: SelectiveRemoteBackupManifest
        private let handle: FileHandle
        private let key: SymmetricKey

        init(url: URL, password: String) throws {
            let openedHandle = try FileHandle(forReadingFrom: url)
            handle = openedHandle
            do {
                let magic = try openedHandle.readExactly(SelectiveRemoteBackupService.magic.count)
                guard magic == SelectiveRemoteBackupService.magic else {
                    throw SelectiveRemoteBackupError.invalidArchive
                }
                let version: UInt16 = try openedHandle.readInteger()
                guard version == SelectiveRemoteBackupService.schemaVersion else {
                    throw SelectiveRemoteBackupError.unsupportedVersion(Int(version))
                }
                let iterations: UInt32 = try openedHandle.readInteger()
                let saltLength: UInt16 = try openedHandle.readInteger()
                guard saltLength >= 16, saltLength <= 64 else {
                    throw SelectiveRemoteBackupError.invalidArchive
                }
                let salt = try openedHandle.readExactly(Int(saltLength))
                var associatedData = SelectiveRemoteBackupService.magic
                associatedData.appendInteger(version)
                associatedData.appendInteger(iterations)
                associatedData.appendInteger(saltLength)
                associatedData.append(salt)
                let manifestLength: UInt64 = try openedHandle.readInteger()
                guard manifestLength <= SelectiveRemoteBackupService.maximumManifestBytes else {
                    throw SelectiveRemoteBackupError.fileTooLarge
                }
                key = try SelectiveRemoteBackupService.deriveKey(
                    password: password,
                    salt: salt,
                    iterations: iterations
                )
                let encrypted = try openedHandle.readExactly(Int(manifestLength))
                let box = try AES.GCM.SealedBox(combined: encrypted)
                let plain: Data
                do {
                    plain = try AES.GCM.open(box, using: key, authenticating: associatedData)
                } catch {
                    throw SelectiveRemoteBackupError.authenticationFailed
                }
                manifest = try PropertyListDecoder().decode(
                    SelectiveRemoteBackupManifest.self,
                    from: plain
                )
                guard manifest.schemaVersion == Int(version) else {
                    throw SelectiveRemoteBackupError.invalidArchive
                }
            } catch {
                try? openedHandle.close()
                throw error
            }
        }

        deinit { try? handle.close() }

        func decryptFiles(to directory: URL) throws -> [UUID: URL] {
            var result: [UUID: URL] = [:]
            for descriptor in manifest.files {
                let length: UInt64 = try handle.readInteger()
                guard length <= SelectiveRemoteBackupService.maximumEntryBytes + 64 else {
                    throw SelectiveRemoteBackupError.fileTooLarge
                }
                let encrypted = try handle.readExactly(Int(length))
                let box = try AES.GCM.SealedBox(combined: encrypted)
                let data: Data
                do {
                    data = try AES.GCM.open(
                        box,
                        using: key,
                        authenticating: Data(descriptor.id.uuidString.utf8)
                    )
                } catch {
                    throw SelectiveRemoteBackupError.authenticationFailed
                }
                guard Int64(data.count) == descriptor.byteCount else {
                    throw SelectiveRemoteBackupError.invalidArchive
                }
                let url = directory.appendingPathComponent(descriptor.id.uuidString)
                try data.write(to: url, options: .atomic)
                result[descriptor.id] = url
            }
            return result
        }
    }
}

private extension Data {
    static func integer<T: FixedWidthInteger>(_ value: T) -> Data {
        var bigEndian = value.bigEndian
        return Swift.withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        append(Self.integer(value))
    }
}

private extension FileHandle {
    func readExactly(_ count: Int) throws -> Data {
        guard count >= 0, let data = try read(upToCount: count), data.count == count else {
            throw SelectiveRemoteBackupError.invalidArchive
        }
        return data
    }

    func readInteger<T: FixedWidthInteger>() throws -> T {
        let data = try readExactly(MemoryLayout<T>.size)
        return data.withUnsafeBytes { bytes in
            T(bigEndian: bytes.loadUnaligned(as: T.self))
        }
    }
}
