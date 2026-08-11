import Foundation

struct TerminalRemoteSuggestion: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let command: String
    let description: String
    let category: String
    let keywords: String
}

struct TerminalRemoteContextSnapshot: Codable, Equatable, Sendable {
    var hostLabel: String
    var systemLabel: String
    var refreshedAt: Date?
    var suggestions: [TerminalRemoteSuggestion]
    var message: String

    static let empty = TerminalRemoteContextSnapshot(
        hostLabel: "",
        systemLabel: "",
        refreshedAt: nil,
        suggestions: [],
        message: "Подключите SSH и обновите сведения о сервере"
    )
}

enum TerminalRemoteContextError: LocalizedError {
    case executableUnavailable
    case timedOut
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            "Системный /usr/bin/ssh недоступен"
        case .timedOut:
            "Сервер не ответил за 10 секунд"
        case let .commandFailed(message):
            message.isEmpty
                ? "Не удалось получить сведения о сервере"
                : "Не удалось получить сведения: \(message)"
        }
    }
}

private final class TerminalProbeTimeout: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var didExpire = false

    init(process: Process) {
        self.process = process
    }

    func expire() {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        didExpire = true
        process.terminate()
    }

    var expired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExpire
    }
}

enum TerminalRemoteContextService {
    private static let probeCommand = #"""
LC_ALL=C; export LC_ALL
printf 'SYSTEM\t'
if [ -r /etc/os-release ]; then . /etc/os-release; printf '%s %s\n' "${NAME:-Linux}" "${VERSION_ID:-}"; else uname -srm; fi
for command_name in systemctl journalctl docker podman kubectl helm git nginx apachectl caddy ufw firewall-cmd apt apt-get dnf yum pacman zypper brew; do
    if command -v "$command_name" >/dev/null 2>&1; then printf 'COMMAND\t%s\n' "$command_name"; fi
done
if command -v systemctl >/dev/null 2>&1; then
    systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk 'NR <= 80 { sub(/[[:space:]].*/, "", $1); if ($1 != "") print "SERVICE\t" $1 }'
fi
if command -v docker >/dev/null 2>&1; then
    docker ps -a --format 'CONTAINER\t{{.Names}}' 2>/dev/null | head -60
fi
if command -v podman >/dev/null 2>&1; then
    podman ps -a --format 'CONTAINER\t{{.Names}}' 2>/dev/null | head -60
fi
"""#

    static func discover(
        settings: SSHConnectionSettings,
        environment: [String: String]
    ) async throws -> TerminalRemoteContextSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(
                        returning: try runProbe(settings: settings, environment: environment)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runProbe(
        settings: SSHConnectionSettings,
        environment: [String: String]
    ) throws -> TerminalRemoteContextSnapshot {
        let executable = "/usr/bin/ssh"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw TerminalRemoteContextError.executableUnavailable
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = SSHService.commonSSHArguments(
            settings: settings,
            batchMode: true
        ) + [
            "-o", "ConnectTimeout=8",
            "-o", "ConnectionAttempts=1",
            "-o", "LogLevel=ERROR",
            settings.host,
            probeCommand
        ]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw TerminalRemoteContextError.commandFailed(error.localizedDescription)
        }
        let timeout = TerminalProbeTimeout(process: process)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
            timeout.expire()
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if timeout.expired { throw TerminalRemoteContextError.timedOut }

        let output = String(decoding: data.prefix(256 * 1_024), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = output
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw TerminalRemoteContextError.commandFailed(String(message.prefix(240)))
        }
        return parse(output: output, settings: settings)
    }

    static func parse(
        output: String,
        settings: SSHConnectionSettings
    ) -> TerminalRemoteContextSnapshot {
        var systemLabel = "Удалённый сервер"
        var commands = Set<String>()
        var services: [String] = []
        var containers: [String] = []
        let safeName = try? NSRegularExpression(pattern: #"^[A-Za-z0-9@_.:-]{1,160}$"#)

        for rawLine in output.split(whereSeparator: \.isNewline).prefix(500) {
            let parts = rawLine.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let kind = parts[0]
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if kind == "SYSTEM" {
                systemLabel = String(value.prefix(120))
                continue
            }
            let range = NSRange(value.startIndex..., in: value)
            guard safeName?.firstMatch(in: value, range: range) != nil else { continue }
            switch kind {
            case "COMMAND": commands.insert(value)
            case "SERVICE" where services.count < 80: services.append(value)
            case "CONTAINER" where containers.count < 80: containers.append(value)
            default: break
            }
        }

        var suggestions: [TerminalRemoteSuggestion] = []
        func add(_ command: String, _ description: String, _ category: String, _ keywords: String) {
            guard suggestions.count < 360 else { return }
            suggestions.append(
                TerminalRemoteSuggestion(
                    id: "remote-\(suggestions.count)-\(command.hashValue)",
                    command: command,
                    description: description,
                    category: category,
                    keywords: keywords
                )
            )
        }

        if commands.contains("systemctl") {
            for service in services {
                add("systemctl status \(service)", "Состояние службы \(service)", "Службы сервера", "status service unit")
                add("sudo systemctl restart \(service)", "Перезапустить службу \(service)", "Службы сервера", "restart service unit")
                if commands.contains("journalctl") {
                    add("journalctl -u \(service) -n 100 --no-pager", "Последние записи журнала \(service)", "Журналы сервера", "logs journal service")
                }
            }
        }
        let containerTool = commands.contains("docker") ? "docker" : (commands.contains("podman") ? "podman" : nil)
        if let containerTool {
            for container in containers {
                add("\(containerTool) logs --tail 100 -f \(container)", "Следить за журналом контейнера \(container)", "Контейнеры сервера", "logs container")
                add("\(containerTool) restart \(container)", "Перезапустить контейнер \(container)", "Контейнеры сервера", "restart container")
                add("\(containerTool) exec -it \(container) sh", "Открыть shell контейнера \(container)", "Контейнеры сервера", "exec shell container")
            }
        }
        if commands.contains("apt") || commands.contains("apt-get") {
            add("sudo apt update && apt list --upgradable", "Проверить обновления пакетов", "Пакеты сервера", "apt update upgrade")
        } else if commands.contains("dnf") {
            add("sudo dnf check-update", "Проверить обновления пакетов", "Пакеты сервера", "dnf update")
        } else if commands.contains("pacman") {
            add("sudo pacman -Syu", "Обновить пакеты Arch Linux", "Пакеты сервера", "pacman update")
        }

        return TerminalRemoteContextSnapshot(
            hostLabel: settings.host,
            systemLabel: systemLabel,
            refreshedAt: Date(),
            suggestions: suggestions,
            message: suggestions.isEmpty
                ? "Подходящие службы и контейнеры не обнаружены"
                : "Найдено команд: \(suggestions.count)"
        )
    }
}
