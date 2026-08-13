import Foundation

struct SmartReconnectProgress: Equatable, Sendable {
    let attempt: Int
    let maximumAttempts: Int
    let nextAttemptAt: Date?
    let reason: String

    var attemptLabel: String {
        "Попытка \(attempt)/\(maximumAttempts)"
    }

    func countdownText(now: Date = Date()) -> String? {
        guard let nextAttemptAt else { return nil }
        let seconds = max(0, Int(ceil(nextAttemptAt.timeIntervalSince(now))))
        return seconds == 0 ? "Повторное подключение…" : "Следующая попытка через \(seconds) с"
    }
}

enum SmartReconnectPolicy {
    static let maximumAttempts = 3

    static func delay(for attempt: Int) -> Duration {
        switch attempt {
        case ...1: .seconds(1)
        case 2: .seconds(3)
        default: .seconds(7)
        }
    }

    static func nextAttemptDate(for attempt: Int, now: Date = Date()) -> Date {
        let seconds: TimeInterval = switch attempt {
        case ...1: 1
        case 2: 3
        default: 7
        }
        return now.addingTimeInterval(seconds)
    }
}

enum SmartReconnectClassifier {
    private static let authenticationFailures = [
        "permission denied",
        "authentication failed",
        "too many authentication failures",
        "host key verification failed",
        "remote host identification has changed",
        "no supported authentication methods available",
        "errconnect_logon_failure",
        "logon failed",
        "certificate verify failed",
        "certificate name mismatch"
    ]

    private static let sshTransportFailures = [
        "broken pipe",
        "connection reset by peer",
        "connection timed out",
        "operation timed out",
        "network is unreachable",
        "no route to host",
        "connection closed by remote host",
        "connection closed by",
        "connection refused",
        "could not resolve hostname",
        "temporary failure in name resolution",
        "client_loop: send disconnect",
        "kex_exchange_identification: read: connection reset",
        "ssh_exchange_identification: read: connection reset"
    ]

    private static let rdpTransportFailures = [
        "errconnect_connect_transport_failed",
        "connection reset by peer",
        "connection timed out",
        "operation timed out",
        "network is unreachable",
        "no route to host",
        "transport connect failed",
        "freerdp_tcp_connect"
    ]

    static func shouldRetrySSH(exitCode: Int32, output: String) -> Bool {
        guard exitCode != 0 else { return false }
        let text = output.lowercased()
        guard !containsAuthenticationFailure(text) else { return false }
        return sshTransportFailures.contains { text.contains($0) }
    }

    static func shouldRetryTunnel(status: Int32, log: String) -> Bool {
        shouldRetrySSH(exitCode: status, output: log)
    }

    static func shouldRetryRDP(status: Int32, log: String) -> Bool {
        guard status != 0 else { return false }
        let text = log.lowercased()
        guard !containsAuthenticationFailure(text) else { return false }
        return rdpTransportFailures.contains { text.contains($0) }
    }

    static func sshReason(output: String) -> String {
        let text = output.lowercased()
        if text.contains("could not resolve hostname") || text.contains("name resolution") {
            return "Не удалось разрешить имя SSH-сервера"
        }
        if text.contains("network is unreachable") || text.contains("no route to host") {
            return "Сеть или маршрут до SSH-сервера недоступны"
        }
        if text.contains("timed out") {
            return "SSH-соединение потеряно по тайм-ауту"
        }
        if text.contains("broken pipe") || text.contains("connection reset") {
            return "SSH-соединение было неожиданно разорвано"
        }
        if text.contains("connection refused") {
            return "SSH-сервер временно отклонил соединение"
        }
        return "Временный сбой SSH-транспорта"
    }

    static func rdpReason(log: String) -> String {
        let text = log.lowercased()
        if text.contains("network is unreachable") || text.contains("no route to host") {
            return "Сеть или маршрут до RDP-сервера недоступны"
        }
        if text.contains("timed out") {
            return "RDP-соединение потеряно по тайм-ауту"
        }
        if text.contains("connection reset") {
            return "RDP-соединение было неожиданно разорвано"
        }
        return "Временный сбой RDP-транспорта"
    }

    private static func containsAuthenticationFailure(_ text: String) -> Bool {
        authenticationFailures.contains { text.contains($0) }
    }
}
