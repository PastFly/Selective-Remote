import Foundation

struct MoshLaunchConfiguration: Equatable, Sendable {
    let executable: String
    let arguments: [String]
}

enum MoshServiceError: LocalizedError, Equatable {
    case clientNotInstalled
    case invalidUDPPort
    case invalidServerPath

    var errorDescription: String? {
        switch self {
        case .clientNotInstalled:
            "Mosh не установлен на этом Mac. Установите клиент командой «brew install mosh» и повторите подключение."
        case .invalidUDPPort:
            "UDP-порт Mosh должен быть 0 (автоматически) или находиться в диапазоне 1…65535."
        case .invalidServerPath:
            "Путь к mosh-server не должен содержать перевод строки."
        }
    }
}

enum MoshService {
    static let standardExecutablePaths = [
        "/opt/homebrew/bin/mosh",
        "/usr/local/bin/mosh",
        "/opt/local/bin/mosh"
    ]

    static func executablePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var candidates = standardExecutablePaths
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/mosh" }
        }
        return candidates.first(where: isExecutable)
    }

    static func launchConfiguration(
        settings: SSHConnectionSettings,
        executablePath: String? = nil,
        executableLookup: () -> String? = { MoshService.executablePath() }
    ) throws -> MoshLaunchConfiguration {
        let resolvedExecutable = executablePath ?? executableLookup()
        guard let resolvedExecutable else { throw MoshServiceError.clientNotInstalled }
        guard settings.moshUDPPort == 0 || (1...65_535).contains(settings.moshUDPPort) else {
            throw MoshServiceError.invalidUDPPort
        }
        guard !settings.moshServerPath.contains(where: { $0.isNewline }) else {
            throw MoshServiceError.invalidServerPath
        }

        var sshArguments = SSHService.commonSSHArguments(
            settings: settings,
            batchMode: false,
            multiplexing: false
        )
        if settings.agentForwarding {
            sshArguments.append("-A")
        }
        let sshCommand = ([SSHService.sshPath] + sshArguments)
            .map(shellEscaped)
            .joined(separator: " ")

        var arguments = ["--ssh=\(sshCommand)"]
        if settings.moshUDPPort > 0 {
            arguments += ["--port", String(settings.moshUDPPort)]
        }
        let serverPath = settings.moshServerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serverPath.isEmpty {
            arguments.append("--server=\(serverPath)")
        }
        arguments.append(settings.host)
        return MoshLaunchConfiguration(executable: resolvedExecutable, arguments: arguments)
    }

    private static func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
