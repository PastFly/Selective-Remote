import Foundation
import Darwin

enum SSHServiceError: LocalizedError, Sendable {
    case invalidHost
    case invalidUsername
    case invalidPort
    case invalidInitialDirectory
    case invalidForwardAddress(String)
    case invalidForwardPort(String)
    case missingForwardDestination
    case missingIdentityFile(String)
    case executableUnavailable(String)
    case launchFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            "Укажите корректный hostname, IP-адрес или Host из ~/.ssh/config"
        case .invalidUsername:
            "Имя пользователя SSH содержит недопустимые пробелы или управляющие символы"
        case .invalidPort:
            "Порт SSH должен быть в диапазоне 1…65535"
        case .invalidInitialDirectory:
            "Начальная папка SFTP не должна содержать переносы строк"
        case let .invalidForwardAddress(name):
            "Некорректный адрес в туннеле «\(name)»"
        case let .invalidForwardPort(name):
            "Порты туннеля «\(name)» должны быть в диапазоне 1…65535"
        case .missingForwardDestination:
            "Для локального или удалённого туннеля укажите конечный host и порт"
        case let .missingIdentityFile(path):
            "Файл SSH-ключа недоступен: \(path)"
        case let .executableUnavailable(path):
            "Системная команда недоступна: \(path)"
        case let .launchFailed(message):
            "Не удалось запустить SSH: \(message)"
        case let .commandFailed(message):
            "SSH завершился с ошибкой: \(message)"
        }
    }
}

struct SSHConnectionSettings: Equatable, Sendable {
    let profileID: UUID
    let profileName: String
    let host: String
    let username: String
    let port: Int
    let authenticationMode: SSHAuthenticationMode
    let identity: SSHKeyRecord?
    let proxyMode: SSHProxyMode
    let proxyHost: String
    let proxyPort: Int
    let proxyUsername: String
    let hostKeyPolicy: SSHHostKeyPolicy
    let initialDirectory: String
    let compression: Bool
    let keepAliveSeconds: Int

    init(profile: ConnectionProfile, identity: SSHKeyRecord?) throws {
        let normalizedHost = SSHService.normalizedHost(profile.host)
        let normalizedUser = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialDirectory = profile.sshInitialDirectory
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try SSHService.validateHost(normalizedHost)
        try SSHService.validateUsername(normalizedUser)
        guard (1...65_535).contains(profile.sshPort) else {
            throw SSHServiceError.invalidPort
        }
        guard !initialDirectory.contains(where: \.isNewline) else {
            throw SSHServiceError.invalidInitialDirectory
        }
        if let identity,
           !FileManager.default.isReadableFile(atPath: identity.privateKeyPath) {
            throw SSHServiceError.missingIdentityFile(identity.privateKeyPath)
        }

        profileID = profile.id
        profileName = profile.friendlyName
        host = normalizedHost
        username = normalizedUser
        port = profile.sshPort
        authenticationMode = profile.sshAuthenticationMode
        self.identity = identity
        proxyMode = profile.sshProxyMode
        proxyHost = profile.sshProxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        proxyPort = profile.sshProxyPort
        proxyUsername = profile.sshProxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if proxyMode != .none {
            try SSHService.validateHost(proxyHost)
            guard (1...65_535).contains(proxyPort) else {
                throw SSHServiceError.invalidPort
            }
        }
        if authenticationMode == .key || authenticationMode == .touchIDKey, identity == nil {
            throw SSHServiceError.missingIdentityFile("Выберите SSH-ключ для выбранного способа входа")
        }
        hostKeyPolicy = profile.sshHostKeyPolicy
        self.initialDirectory = initialDirectory.isEmpty ? "." : initialDirectory
        compression = profile.sshCompression
        keepAliveSeconds = min(max(profile.sshKeepAliveSeconds, 0), 3_600)
    }
}

struct RunningSSHTunnel {
    let process: Process
    let logURL: URL
    let logHandle: FileHandle
}

private final class SSHAgentManager: @unchecked Sendable {
    static let shared = SSHAgentManager()

    private struct ManagedAgent {
        let process: Process
        let directoryURL: URL
        let environment: [String: String]
    }

    private let lock = NSLock()
    private var managedAgent: ManagedAgent?
    private let sshAgentPath = "/usr/bin/ssh-agent"
    private let sshAddPath = "/usr/bin/ssh-add"
    private let launchctlPath = "/bin/launchctl"

    private init() {}

    func environment(startIfNeeded: Bool) throws -> [String: String] {
        lock.lock()
        defer { lock.unlock() }

        var base = ProcessInfo.processInfo.environment
        if isUsableAgent(environment: base) {
            return base
        }
        base.removeValue(forKey: "SSH_AUTH_SOCK")
        base.removeValue(forKey: "SSH_AGENT_PID")

        if let managedAgent {
            if managedAgent.process.isRunning,
               isUsableAgent(environment: managedAgent.environment) {
                return managedAgent.environment
            }
            cleanup(managedAgent)
            self.managedAgent = nil
        }

        if let socket = launchdSocket(baseEnvironment: base) {
            var launchdEnvironment = base
            launchdEnvironment["SSH_AUTH_SOCK"] = socket
            if isUsableAgent(environment: launchdEnvironment) {
                return launchdEnvironment
            }
        }

        guard startIfNeeded else { return base }
        let started = try startManagedAgent(baseEnvironment: base)
        managedAgent = started
        return started.environment
    }

    func stopManagedAgent() {
        lock.lock()
        let agent = managedAgent
        managedAgent = nil
        lock.unlock()
        guard let agent else { return }
        cleanup(agent)
    }

    private func startManagedAgent(
        baseEnvironment: [String: String]
    ) throws -> ManagedAgent {
        guard FileManager.default.isExecutableFile(atPath: sshAgentPath) else {
            throw SSHServiceError.executableUnavailable(sshAgentPath)
        }

        let token = String(
            UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
        ).lowercased()
        let directoryURL = URL(
            fileURLWithPath: "/tmp/selectiveremote-agent-\(Darwin.getuid())-\(token)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let socketURL = directoryURL.appendingPathComponent("agent.sock")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshAgentPath)
        process.arguments = ["-D", "-a", socketURL.path]
        process.environment = baseEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw SSHServiceError.launchFailed(
                "не удалось запустить встроенный ssh-agent: \(error.localizedDescription)"
            )
        }

        for _ in 0..<50 {
            if isSocket(at: socketURL.path) {
                var environment = baseEnvironment
                environment["SSH_AUTH_SOCK"] = socketURL.path
                environment["SSH_AGENT_PID"] = String(process.processIdentifier)
                return ManagedAgent(
                    process: process,
                    directoryURL: directoryURL,
                    environment: environment
                )
            }
            if !process.isRunning { break }
            usleep(20_000)
        }

        if process.isRunning {
            process.terminate()
        }
        try? FileManager.default.removeItem(at: directoryURL)
        throw SSHServiceError.launchFailed(
            "встроенный ssh-agent не создал защищённый сокет"
        )
    }

    private func launchdSocket(baseEnvironment: [String: String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchctlPath) else {
            return nil
        }
        let result = run(
            executable: launchctlPath,
            arguments: ["getenv", "SSH_AUTH_SOCK"],
            environment: baseEnvironment
        )
        guard result.status == 0 else { return nil }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func isUsableAgent(environment: [String: String]) -> Bool {
        guard let socket = environment["SSH_AUTH_SOCK"],
              isSocket(at: socket),
              FileManager.default.isExecutableFile(atPath: sshAddPath)
        else {
            return false
        }
        let result = run(
            executable: sshAddPath,
            arguments: ["-l"],
            environment: environment
        )
        return result.status == 0 || result.status == 1
    }

    private func isSocket(at path: String) -> Bool {
        let resolvedPath = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .path
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: resolvedPath
        ) else {
            return false
        }
        let fileType = attributes[.type] as? FileAttributeType
        return fileType == .typeSocket
    }

    private func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (255, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: data, encoding: .utf8) ?? ""
        )
    }

    private func cleanup(_ agent: ManagedAgent) {
        if agent.process.isRunning {
            agent.process.terminate()
        }
        try? FileManager.default.removeItem(at: agent.directoryURL)
    }
}

struct SSHTunnelSummary: Identifiable, Equatable {
    let id: UUID
    let profileID: UUID
    let profileName: String
    let ruleName: String
    let startedAt: Date
    let logURL: URL
}

enum SSHService {
    static let sshPath = "/usr/bin/ssh"
    private static let allowedHostCharacters = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "._:-")
    )
    private static let allowedForwardHostCharacters = allowedHostCharacters.union(
        CharacterSet(charactersIn: "[]")
    )
    private static let controlDirectoryPath: String = {
        let token = String(
            UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        ).lowercased()
        let path = "/tmp/selectiveremote-\(Darwin.getuid())-\(token)"
        try? FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: path
        )
        return path
    }()

    static func normalizedHost(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    static func validateHost(_ host: String) throws {
        guard !host.isEmpty,
              host.count <= 255,
              !host.hasPrefix("-"),
              host.unicodeScalars.allSatisfy(allowedHostCharacters.contains)
        else {
            throw SSHServiceError.invalidHost
        }
    }

    static func validateUsername(_ username: String) throws {
        guard username.count <= 255,
              !username.contains(where: { $0.isWhitespace || $0.isNewline }),
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw SSHServiceError.invalidUsername
        }
    }

    static func authenticationArguments(settings: SSHConnectionSettings) -> [String] {
        switch settings.authenticationMode {
        case .automatic:
            return ["-o", "PreferredAuthentications=publickey,keyboard-interactive,password"]
        case .password:
            return [
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "PubkeyAuthentication=no"
            ]
        case .key, .touchIDKey:
            return [
                "-o", "PreferredAuthentications=publickey",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "IdentitiesOnly=yes"
            ]
        case .agent:
            return [
                "-o", "PreferredAuthentications=publickey",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no"
            ]
        }
    }

    static func proxyArguments(settings: SSHConnectionSettings) -> [String] {
        guard settings.proxyMode != .none else { return [] }
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("SelectiveRemoteSSHProxy")
        let mode = settings.proxyMode == .http ? "http" : "socks5"
        let secret = "${SELECTIVEREMOTE_PROXY_SECRET_FILE:-}"
        let parts = [
            shellEscaped(helper.path),
            mode,
            shellEscaped(settings.proxyHost),
            String(settings.proxyPort),
            "%h", "%p",
            shellEscaped(settings.proxyUsername),
            "\"\(secret)\""
        ]
        return ["-o", "ProxyCommand=\(parts.joined(separator: " "))"]
    }

    private static func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func commonSSHArguments(
        settings: SSHConnectionSettings,
        batchMode: Bool,
        multiplexing: Bool = true
    ) -> [String] {
        var arguments = [
            "-p", String(settings.port),
            "-o", "StrictHostKeyChecking=\(settings.hostKeyPolicy.openSSHValue)"
        ]
        if multiplexing {
            arguments += [
                "-o", "ControlPath=\(controlPath(settings: settings))",
                "-o", "ControlMaster=auto"
            ]
        } else {
            // A forwarding process must remain attached to its tunnel. If it
            // reuses an existing master connection, OpenSSH can install the
            // forwarding there and immediately terminate this child process.
            arguments += [
                "-S", "none",
                "-o", "ControlMaster=no"
            ]
        }
        if batchMode {
            arguments += ["-o", "BatchMode=yes"]
        }
        if !settings.username.isEmpty {
            arguments += ["-o", "User=\(settings.username)"]
        }
        arguments += authenticationArguments(settings: settings)
        arguments += proxyArguments(settings: settings)
        if let identity = settings.identity, settings.authenticationMode != .password, settings.authenticationMode != .agent {
            arguments += ["-i", identity.privateKeyPath]
            if settings.authenticationMode == .automatic {
                arguments += ["-o", "IdentitiesOnly=yes"]
            }
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
        return arguments
    }

    static func interactiveSSHArguments(settings: SSHConnectionSettings) -> [String] {
        // An explicit authentication mode must not silently reuse a ControlMaster
        // that was authenticated using another credential. This also guarantees
        // that Touch ID gates the connection selected in the profile.
        commonSSHArguments(settings: settings, batchMode: false, multiplexing: false)
            + ["-tt", settings.host]
    }

    /// Installs a public key without ever replacing authorized_keys. The remote
    /// command creates the file if necessary and appends only when the exact key
    /// is not already present. Existing keys and comments are preserved.
    static func appendPublicKeyArguments(
        settings: SSHConnectionSettings,
        publicKeyText: String
    ) -> [String] {
        let normalizedKey = publicKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotedKey = shellQuotedArgument(normalizedKey)
        let remoteCommand = "umask 077; mkdir -p \"$HOME/.ssh\"; "
            + "touch \"$HOME/.ssh/authorized_keys\"; "
            + "chmod 700 \"$HOME/.ssh\"; "
            + "chmod 600 \"$HOME/.ssh/authorized_keys\"; "
            + "grep -qxF -- \(quotedKey) \"$HOME/.ssh/authorized_keys\" "
            + "|| printf '%s\\n' \(quotedKey) >> \"$HOME/.ssh/authorized_keys\""

        var arguments = [
            "-p", String(settings.port),
            "-o", "StrictHostKeyChecking=\(settings.hostKeyPolicy.openSSHValue)",
            "-S", "none",
            "-o", "ControlMaster=no",
            "-o", "PreferredAuthentications=publickey,keyboard-interactive,password",
            "-o", "ServerAliveInterval=\(max(settings.keepAliveSeconds, 30))",
            "-o", "ServerAliveCountMax=3"
        ]
        if !settings.username.isEmpty {
            arguments += ["-o", "User=\(settings.username)"]
        }
        arguments += proxyArguments(settings: settings)
        arguments += [settings.host, remoteCommand]
        return arguments
    }

    private static func shellQuotedArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func copyPublicKeyArguments(
        settings: SSHConnectionSettings,
        publicKeyPath: String
    ) -> [String] {
        var arguments = [
            "-i", publicKeyPath,
            "-p", String(settings.port),
            "-o", "StrictHostKeyChecking=\(settings.hostKeyPolicy.openSSHValue)",
            "-o", "ControlPath=\(controlPath(settings: settings))",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=60"
        ]
        if !settings.username.isEmpty {
            arguments += ["-o", "User=\(settings.username)"]
        }
        arguments += proxyArguments(settings: settings)
        return arguments + [settings.host]
    }

    static func controlPath(
        settings: SSHConnectionSettings,
        processID: Int32 = Darwin.getpid()
    ) -> String {
        let profileToken = settings.profileID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(16)
        let connectionToken = stableToken(
            "\(settings.host)\u{0}\(settings.username)\u{0}\(settings.port)"
        )
        return "\(controlDirectoryPath)/\(processID)-\(profileToken)-\(connectionToken).sock"
    }

    private static func stableToken(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    static func launchTunnel(
        settings: SSHConnectionSettings,
        rule: PortForwardRule,
        passwordCredential: KeychainCredentialReference? = nil,
        fileManager: FileManager = .default
    ) throws -> RunningSSHTunnel {
        let forwarding = try forwardingArguments(rule)
        let executable = sshPath
        guard fileManager.isExecutableFile(atPath: executable) else {
            throw SSHServiceError.executableUnavailable(executable)
        }

        let logURL = try makeLogURL(
            prefix: "ssh-tunnel",
            profileID: settings.profileID,
            fileManager: fileManager
        )
        fileManager.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = commonSSHArguments(
            settings: settings,
            batchMode: false,
            multiplexing: false
        )
            + [
                "-N",
                "-T",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "LogLevel=ERROR",
                "-o", "NumberOfPasswordPrompts=1"
            ]
            + forwarding
            + [settings.host]
        process.environment = try SSHKeyService.backgroundAuthenticationEnvironment(
            passwordCredential: passwordCredential,
            proxyPasswordCredential: settings.proxyMode == .none ? nil : KeychainService.credentialReference(
                profileID: settings.profileID,
                kind: .proxy
            )
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle

        let marker = """
        [SelectiveRemote SSH] Starting \(rule.kind.rawValue) forwarding
        [SelectiveRemote SSH] Profile: \(settings.profileName)
        [SelectiveRemote SSH] Rule: \(rule.name)

        """
        try logHandle.write(contentsOf: Data(marker.utf8))

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw SSHServiceError.launchFailed(error.localizedDescription)
        }
        return RunningSSHTunnel(process: process, logURL: logURL, logHandle: logHandle)
    }

    static func forwardingArguments(_ rule: PortForwardRule) throws -> [String] {
        let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bindAddress = rule.bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...65_535).contains(rule.sourcePort) else {
            throw SSHServiceError.invalidForwardPort(name)
        }
        try validateForwardAddress(bindAddress, name: name, allowEmpty: true)

        let listen = bindAddress.isEmpty
            ? String(rule.sourcePort)
            : "\(bracketIPv6(bindAddress)):\(rule.sourcePort)"
        switch rule.kind {
        case .dynamic:
            return ["-D", listen]
        case .local, .remote:
            let destination = rule.destinationHost
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !destination.isEmpty else {
                throw SSHServiceError.missingForwardDestination
            }
            try validateForwardAddress(destination, name: name, allowEmpty: false)
            guard (1...65_535).contains(rule.destinationPort) else {
                throw SSHServiceError.invalidForwardPort(name)
            }
            let specification = "\(listen):\(bracketIPv6(destination)):\(rule.destinationPort)"
            return [rule.kind == .local ? "-L" : "-R", specification]
        }
    }

    private static func validateForwardAddress(
        _ value: String,
        name: String,
        allowEmpty: Bool
    ) throws {
        if allowEmpty, value.isEmpty { return }
        guard !value.isEmpty,
              value.count <= 255,
              !value.hasPrefix("-"),
              value.unicodeScalars.allSatisfy(allowedForwardHostCharacters.contains)
        else {
            throw SSHServiceError.invalidForwardAddress(name)
        }
    }

    private static func bracketIPv6(_ value: String) -> String {
        guard value.contains(":") else { return value }
        if value.hasPrefix("["), value.hasSuffix("]") { return value }
        return "[\(value)]"
    }

    static func makeLogURL(
        prefix: String,
        profileID: UUID,
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("SelectiveRemote/Logs", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(
            "\(prefix)-\(profileID.uuidString)-\(UUID().uuidString).log"
        )
    }
}

enum SSHKeyServiceError: LocalizedError, Sendable {
    case notPrivateKey
    case inspectionFailed(String)
    case askPassHelperUnavailable
    case agentFailed(String)
    case publicKeyUnavailable
    case invalidGenerationPath
    case generationTargetExists(String)

    var errorDescription: String? {
        switch self {
        case .notPrivateKey:
            "Выберите приватный SSH-ключ, а не файл .pub"
        case let .inspectionFailed(message):
            "Не удалось проверить SSH-ключ: \(message)"
        case .askPassHelperUnavailable:
            "В пакете отсутствует помощник Keychain. Пересоберите приложение scripts/build_app.sh"
        case let .agentFailed(message):
            "ssh-agent не принял ключ: \(message)"
        case .publicKeyUnavailable:
            "Рядом с приватным ключом не найден файл публичного ключа .pub"
        case .invalidGenerationPath:
            "Укажите корректный путь для нового приватного SSH-ключа"
        case let .generationTargetExists(path):
            "Файл уже существует: \(path). Выберите другое имя, чтобы ничего не перезаписать."
        }
    }
}

enum SSHKeyAlgorithm: String, CaseIterable, Identifiable, Hashable, Sendable {
    case ed25519
    case ecdsaP256TouchID
    case rsa4096

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ed25519:
            "Ed25519 — рекомендуется"
        case .ecdsaP256TouchID:
            "Touch ID Key · ECDSA P-256"
        case .rsa4096:
            "RSA 4096 — для старых серверов"
        }
    }

    var defaultFilename: String {
        switch self {
        case .ed25519:
            "id_ed25519_selectiveremote"
        case .ecdsaP256TouchID:
            "id_ecdsa_selectiveremote_touchid"
        case .rsa4096:
            "id_rsa_selectiveremote"
        }
    }

    var keygenArguments: [String] {
        switch self {
        case .ed25519:
            ["-t", "ed25519", "-a", "64"]
        case .ecdsaP256TouchID:
            ["-t", "ecdsa", "-b", "256", "-a", "64"]
        case .rsa4096:
            ["-t", "rsa", "-b", "4096", "-a", "64"]
        }
    }
}

struct SSHKeyGenerationRequest: Sendable {
    var algorithm: SSHKeyAlgorithm
    var path: String
    var comment: String
    var protectUseWithUserPresence: Bool = true
}

struct SSHKeyGenerationCommand: Sendable {
    let privateKeyURL: URL
    let arguments: [String]
}

enum SSHKeyService {
    static let sshKeygenPath = "/usr/bin/ssh-keygen"
    static let sshCopyIDPath = "/usr/bin/ssh-copy-id"
    private static let sshAddPath = "/usr/bin/ssh-add"

    static func shouldLoadIdentityIntoAgent(
        hasIdentity: Bool,
        hasActiveControlSession: Bool
    ) -> Bool {
        hasIdentity && !hasActiveControlSession
    }

    static func processEnvironment(
        startAgentIfNeeded: Bool = false
    ) -> [String: String] {
        (try? SSHAgentManager.shared.environment(startIfNeeded: startAgentIfNeeded))
            ?? ProcessInfo.processInfo.environment
    }

    static func backgroundAuthenticationEnvironment(
        passwordCredential: KeychainCredentialReference? = nil,
        proxyPasswordCredential: KeychainCredentialReference? = nil
    ) throws -> [String: String] {
        var environment = processEnvironment(startAgentIfNeeded: true)
        guard let helper = askPassHelperURL() else { return environment }
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        environment["SSH_ASKPASS"] = helper.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment.removeValue(forKey: "SELECTIVEREMOTE_KEYCHAIN_SERVICE")
        environment.removeValue(forKey: "SELECTIVEREMOTE_KEYCHAIN_ACCOUNT")
        environment.removeValue(forKey: "SELECTIVEREMOTE_ASKPASS_SECRET_FILE")
        environment.removeValue(forKey: "SELECTIVEREMOTE_PROXY_SECRET_FILE")

        if let passwordCredential {
            let requiresTouchID = KeychainService.requiresTouchID(reference: passwordCredential)
            let hasCurrentSecret = KeychainService.passwordExists(reference: passwordCredential)
            if requiresTouchID && hasCurrentSecret {
                try KeychainService.authenticateTouchID(
                    reason: "Подтвердите Touch ID для использования SSH-пароля"
                )
            }
            if let password = try KeychainService.readPassword(
                reference: passwordCredential
            ), !password.isEmpty {
                let secretURL = try makeAskPassSecretFile(password)
                environment["SELECTIVEREMOTE_ASKPASS_SECRET_FILE"] = secretURL.path
            }
        }
        if let proxyPasswordCredential,
           let proxyPassword = try KeychainService.readPassword(reference: proxyPasswordCredential),
           !proxyPassword.isEmpty {
            let secretURL = try makeSecretFile(proxyPassword, prefix: "proxy")
            environment["SELECTIVEREMOTE_PROXY_SECRET_FILE"] = secretURL.path
        }
        return environment
    }

    private static func makeSecretFile(_ secret: String, prefix: String) throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp/selectiveremote-secrets-\(Darwin.getuid())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(secret.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw SSHServiceError.launchFailed("не удалось подготовить защищённый канал секрета")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 180) { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private static func makeAskPassSecretFile(_ password: String) throws -> URL {
        try makeSecretFile(password, prefix: "askpass")
    }

    static func stopManagedAgent() {
        SSHAgentManager.shared.stopManagedAgent()
    }

    static func defaultPrivateKeyPath(for algorithm: SSHKeyAlgorithm) -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent(algorithm.defaultFilename)
            .path
    }

    static func prepareGeneration(
        _ request: SSHKeyGenerationRequest,
        fileManager: FileManager = .default
    ) throws -> SSHKeyGenerationCommand {
        let expanded = NSString(string: request.path).expandingTildeInPath
        guard !expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              NSString(string: expanded).isAbsolutePath,
              !expanded.contains(where: \.isNewline),
              !expanded.contains("\0"),
              !expanded.hasSuffix("/"),
              URL(fileURLWithPath: expanded).pathExtension.lowercased() != "pub"
        else {
            throw SSHKeyServiceError.invalidGenerationPath
        }

        let privateURL = URL(fileURLWithPath: expanded).standardizedFileURL
        let publicURL = URL(fileURLWithPath: privateURL.path + ".pub")
        for candidate in [privateURL, publicURL] where fileManager.fileExists(atPath: candidate.path) {
            throw SSHKeyServiceError.generationTargetExists(candidate.path)
        }
        guard fileManager.isExecutableFile(atPath: sshKeygenPath) else {
            throw SSHServiceError.executableUnavailable(sshKeygenPath)
        }

        let parent = privateURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else if !isDirectory.boolValue {
            throw SSHKeyServiceError.invalidGenerationPath
        }

        let normalizedComment = request.comment
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = request.algorithm.keygenArguments
            + ["-f", privateURL.path]
        if request.algorithm == .ecdsaP256TouchID {
            // Touch ID is the app-level approval gate for this key. Keeping the
            // generated key passphrase-free avoids loading it into ssh-agent, so
            // each Selective Remote connection can require fresh biometrics.
            arguments += ["-N", ""]
        }
        if !normalizedComment.isEmpty, !normalizedComment.contains(where: \.isNewline) {
            arguments += ["-C", normalizedComment]
        }
        return SSHKeyGenerationCommand(
            privateKeyURL: privateURL,
            arguments: arguments
        )
    }

    static func inspectPrivateKey(at url: URL) throws -> SSHKeyRecord {
        let path = url.standardizedFileURL.path
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let prefix = String(decoding: data.prefix(4_096), as: UTF8.self)
        guard url.pathExtension.lowercased() != "pub",
              prefix.contains("PRIVATE KEY")
        else {
            throw SSHKeyServiceError.notPrivateKey
        }

        let result = try run(
            executable: sshKeygenPath,
            arguments: ["-l", "-f", path]
        )
        guard result.status == 0 else {
            throw SSHKeyServiceError.inspectionFailed(cleanOutput(result.output))
        }

        let fields = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
        let fingerprint = fields.count > 1 ? String(fields[1]) : "не определён"
        let algorithm = fields.last.map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        } ?? "SSH"
        let publicURL = URL(fileURLWithPath: path + ".pub")

        return SSHKeyRecord(
            name: url.deletingPathExtension().lastPathComponent,
            privateKeyPath: path,
            publicKeyPath: FileManager.default.isReadableFile(atPath: publicURL.path)
                ? publicURL.path
                : nil,
            fingerprint: fingerprint,
            algorithm: algorithm
        )
    }

    static func addToAgent(
        _ key: SSHKeyRecord,
        useStoredPassphrase: Bool
    ) throws {
        let environment = try agentEnvironment()
        if try isLoadedInAgent(key, environment: environment) { return }

        if useStoredPassphrase {
            let storedResult = try run(
                executable: sshAddPath,
                arguments: ["--apple-load-keychain", key.privateKeyPath],
                environment: environment
            )
            if storedResult.status == 0 { return }
        }

        guard let helper = askPassHelperURL() else {
            throw SSHKeyServiceError.askPassHelperUnavailable
        }
        var askPassEnvironment = environment
        askPassEnvironment["DISPLAY"] = askPassEnvironment["DISPLAY"] ?? ":0"
        askPassEnvironment["SSH_ASKPASS"] = helper.path
        askPassEnvironment["SSH_ASKPASS_REQUIRE"] = "force"
        let result = try run(
            executable: sshAddPath,
            arguments: ["--apple-use-keychain", key.privateKeyPath],
            environment: askPassEnvironment
        )
        guard result.status == 0 else {
            throw SSHKeyServiceError.agentFailed(cleanOutput(result.output))
        }
    }

    static func removeFromAgentAndKeychain(_ key: SSHKeyRecord) throws {
        let environment = try agentEnvironment()
        let result = try run(
            executable: sshAddPath,
            arguments: ["--apple-use-keychain", "-d", key.privateKeyPath],
            environment: environment
        )
        let normalizedOutput = result.output.lowercased()
        guard result.status == 0
                || normalizedOutput.contains("not found")
                || normalizedOutput.contains("no identities")
        else {
            throw SSHKeyServiceError.agentFailed(cleanOutput(result.output))
        }
    }

    static func isLoadedInAgent(_ key: SSHKeyRecord) throws -> Bool {
        try isLoadedInAgent(key, environment: agentEnvironment())
    }

    private static func isLoadedInAgent(
        _ key: SSHKeyRecord,
        environment: [String: String]
    ) throws -> Bool {
        let result = try run(
            executable: sshAddPath,
            arguments: ["-l"],
            environment: environment
        )
        if result.status == 1 { return false }
        guard result.status == 0 else {
            throw SSHKeyServiceError.agentFailed(cleanOutput(result.output))
        }
        return result.output.contains(key.fingerprint)
    }

    static func removeFromAgent(_ key: SSHKeyRecord) throws {
        let environment = try agentEnvironment()
        let result = try run(
            executable: sshAddPath,
            arguments: ["-d", key.privateKeyPath],
            environment: environment
        )
        let normalizedOutput = result.output.lowercased()
        guard result.status == 0 || normalizedOutput.contains("no identities") else {
            throw SSHKeyServiceError.agentFailed(cleanOutput(result.output))
        }
    }

    static func publicKeyText(for key: SSHKeyRecord) throws -> String {
        guard let path = key.publicKeyPath else {
            throw SSHKeyServiceError.publicKeyUnavailable
        }
        return try String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func askPassHelperURL() -> URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("SelectiveRemoteSSHAskPass")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private static func agentEnvironment() throws -> [String: String] {
        do {
            return try SSHAgentManager.shared.environment(startIfNeeded: true)
        } catch {
            throw SSHKeyServiceError.agentFailed(error.localizedDescription)
        }
    }

    private static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String) {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw SSHServiceError.executableUnavailable(executable)
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw SSHServiceError.launchFailed(error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: data, encoding: .utf8) ?? ""
        )
    }

    private static func cleanOutput(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "неизвестная ошибка" : String(trimmed.suffix(2_000))
    }
}
