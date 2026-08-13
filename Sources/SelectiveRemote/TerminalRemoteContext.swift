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
    var canRetry: Bool
    var osID: String = ""
    var osLike: String = ""
    var availableCommands: [String] = []
    var services: [TerminalRemoteService] = []
    var containers: [TerminalRemoteContainer] = []

    func hasCommand(_ name: String) -> Bool {
        availableCommands.contains(name)
    }

    static let empty = TerminalRemoteContextSnapshot(
        hostLabel: "",
        systemLabel: "",
        refreshedAt: nil,
        suggestions: [],
        message: "Подключите SSH и обновите сведения о сервере",
        canRetry: false
    )

    static func loading(hostLabel: String) -> TerminalRemoteContextSnapshot {
        TerminalRemoteContextSnapshot(
            hostLabel: hostLabel,
            systemLabel: hostLabel,
            refreshedAt: nil,
            suggestions: [],
            message: "Получаем сведения о сервере…",
            canRetry: false
        )
    }
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
if [ -r /etc/os-release ]; then
    . /etc/os-release
    printf '%s %s\n' "${NAME:-Linux}" "${VERSION_ID:-}"
    printf 'OS\t%s\t%s\n' "${ID:-}" "${ID_LIKE:-}"
else
    uname -srm
fi
for command_name in systemctl journalctl docker podman kubectl helm git nginx apachectl caddy ufw firewall-cmd apt apt-get dnf yum pacman zypper brew uptime uname hostnamectl free vmstat ip ss ping traceroute tracepath dig nslookup resolvectl df lsblk findmnt mount du dmesg last who w users getenforce sestatus fail2ban-client sort tail; do
    if command -v "$command_name" >/dev/null 2>&1; then printf 'COMMAND\t%s\n' "$command_name"; fi
done
if command -v systemctl >/dev/null 2>&1; then
    systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null \
        | awk 'NR <= 100 { if ($1 != "") print "SERVICE\t" $1 "\t" $3 "\t" $4 }'
fi
if command -v docker >/dev/null 2>&1; then
    docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null | head -60 \
        | while IFS='|' read -r name status; do printf 'CONTAINER\tdocker\t%s\t%s\n' "$name" "$status"; done
fi
if command -v podman >/dev/null 2>&1; then
    podman ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null | head -60 \
        | while IFS='|' read -r name status; do printf 'CONTAINER\tpodman\t%s\t%s\n' "$name" "$status"; done
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

    static func probeArguments(settings: SSHConnectionSettings) -> [String] {
        // The terminal itself deliberately does not expose a reusable ControlMaster.
        // Run the probe as a separate OpenSSH command, but keep the exact same
        // destination/authentication/proxy/jump/certificate settings and allow
        // SSH_ASKPASS to supply Keychain-backed credentials.
        SSHService.commonSSHArguments(
            settings: settings,
            batchMode: false,
            multiplexing: false
        ) + [
            "-T",
            "-o", "ConnectTimeout=8",
            "-o", "ConnectionAttempts=1",
            "-o", "LogLevel=ERROR",
            "-o", "NumberOfPasswordPrompts=1",
            settings.host,
            probeCommand
        ]
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
        process.arguments = probeArguments(settings: settings)
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
        var osID = ""
        var osLike = ""
        var commands = Set<String>()
        var services: [TerminalRemoteService] = []
        var containers: [TerminalRemoteContainer] = []
        let safeName = try? NSRegularExpression(pattern: #"^[A-Za-z0-9@_.:-]{1,160}$"#)

        for rawLine in output.split(whereSeparator: \.isNewline).prefix(800) {
            let parts = rawLine.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            let kind = parts[0]
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if kind == "SYSTEM" {
                systemLabel = String(value.prefix(120))
                continue
            }
            if kind == "OS" {
                osID = String(value.prefix(80)).lowercased()
                if parts.count >= 3 {
                    osLike = String(parts[2].trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)).lowercased()
                }
                continue
            }
            let range = NSRange(value.startIndex..., in: value)
            guard safeName?.firstMatch(in: value, range: range) != nil else { continue }
            switch kind {
            case "COMMAND":
                commands.insert(value)
            case "SERVICE" where services.count < 100:
                let active = parts.count >= 3
                    ? String(parts[2].trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                    : "unknown"
                let sub = parts.count >= 4
                    ? String(parts[3].trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                    : ""
                services.append(
                    TerminalRemoteService(name: value, activeState: active, subState: sub)
                )
            case "CONTAINER" where containers.count < 80:
                let tool: String
                let name: String
                let status: String
                if parts.count >= 3 {
                    tool = value
                    name = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    status = parts.count >= 4
                        ? String(parts[3].trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
                        : ""
                } else {
                    // Compatibility with the original probe format: CONTAINER\t<name>.
                    tool = commands.contains("docker") ? "docker" : (commands.contains("podman") ? "podman" : "")
                    name = value
                    status = ""
                }
                let nameRange = NSRange(name.startIndex..., in: name)
                guard ["docker", "podman"].contains(tool),
                      safeName?.firstMatch(in: name, range: nameRange) != nil
                else { continue }
                containers.append(
                    TerminalRemoteContainer(tool: tool, name: name, status: status)
                )
            default:
                break
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
                add("systemctl status \(service.name) --no-pager", "Состояние службы \(service.name)", "Службы сервера", "status service unit")
                add("sudo systemctl restart \(service.name)", "Перезапустить службу \(service.name)", "Службы сервера", "restart service unit")
                add("sudo systemctl reload \(service.name)", "Перечитать конфигурацию службы \(service.name)", "Службы сервера", "reload service unit")
                if commands.contains("journalctl") {
                    add("journalctl -u \(service.name) -n 100 --no-pager", "Последние записи журнала \(service.name)", "Журналы сервера", "logs journal service")
                }
            }
        }
        for container in containers {
            add("\(container.tool) logs --tail 100 -f \(container.name)", "Следить за журналом контейнера \(container.name)", "Контейнеры сервера", "logs container")
            add("\(container.tool) restart \(container.name)", "Перезапустить контейнер \(container.name)", "Контейнеры сервера", "restart container")
            add("\(container.tool) exec -it \(container.name) sh", "Открыть shell контейнера \(container.name)", "Контейнеры сервера", "exec shell container")
        }
        if commands.contains("apt") || commands.contains("apt-get") {
            add("sudo apt update && apt list --upgradable", "Проверить обновления пакетов", "Пакеты сервера", "apt update upgrade")
        } else if commands.contains("dnf") {
            add("sudo dnf check-update", "Проверить обновления пакетов", "Пакеты сервера", "dnf update")
        } else if commands.contains("pacman") {
            add("sudo pacman -Syu", "Обновить пакеты Arch Linux", "Пакеты сервера", "pacman update")
        }

        if commands.contains("ip") {
            add("ip -brief address", "Сетевые интерфейсы и адреса", "Сеть сервера", "network ip address")
            add("ip route", "Таблица маршрутизации", "Сеть сервера", "network route")
        }
        if commands.contains("ss") {
            add("ss -lntup", "Слушающие TCP/UDP порты", "Сеть сервера", "network sockets ports")
        }
        if commands.contains("df") {
            add("df -hT", "Использование файловых систем", "Диски сервера", "disk filesystem space")
        }
        if commands.contains("lsblk") {
            add("lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS", "Блочные устройства и точки монтирования", "Диски сервера", "disk block mount")
        }
        if commands.contains("journalctl") {
            add("journalctl -p warning -n 100 --no-pager", "Последние предупреждения systemd journal", "Журналы сервера", "logs warning journal")
        }
        if commands.contains("who") {
            add("who", "Активные пользовательские сеансы", "Безопасность сервера", "security users sessions")
        }

        return TerminalRemoteContextSnapshot(
            hostLabel: settings.host,
            systemLabel: systemLabel,
            refreshedAt: Date(),
            suggestions: suggestions,
            message: suggestions.isEmpty
                ? "Подходящие команды для сервера не обнаружены"
                : "Найдено команд: \(suggestions.count)",
            canRetry: false,
            osID: osID,
            osLike: osLike,
            availableCommands: commands.sorted(),
            services: services.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            containers: containers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
    }
}
