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

enum RDPFailureKind: Equatable, Sendable {
    case authentication
    case dns
    case timeout
    case unreachable
    case refused
    case transport
    case gateway
    case certificate
    case cancelled
    case unknown
}

struct RDPFailurePresentation: Equatable, Sendable {
    let kind: RDPFailureKind
    let message: String
    let technicalCode: String?
    let retryable: Bool
    let reconnectReason: String
}

enum RDPFailureClassifier {
    static func presentation(status: Int32, log: String) -> RDPFailurePresentation {
        let text = log.lowercased()

        if containsAny(text, [
            "errconnect_account_locked_out",
            "account locked out"
        ]) {
            return item(
                kind: .authentication,
                message: "Учётная запись Windows заблокирована. Разблокируйте её или обратитесь к администратору домена.",
                code: "ERRCONNECT_ACCOUNT_LOCKED_OUT",
                retryable: false,
                reason: "Учётная запись Windows заблокирована"
            )
        }
        if containsAny(text, [
            "errconnect_password_expired",
            "password expired"
        ]) {
            return item(
                kind: .authentication,
                message: "Срок действия RDP-пароля истёк. Смените пароль и повторите подключение.",
                code: "ERRCONNECT_PASSWORD_EXPIRED",
                retryable: false,
                reason: "Срок действия RDP-пароля истёк"
            )
        }
        if containsAny(text, [
            "errconnect_account_expired",
            "account expired"
        ]) {
            return item(
                kind: .authentication,
                message: "Срок действия учётной записи Windows истёк. Проверьте состояние учётной записи.",
                code: "ERRCONNECT_ACCOUNT_EXPIRED",
                retryable: false,
                reason: "Срок действия учётной записи Windows истёк"
            )
        }
        if containsAny(text, [
            "errconnect_logon_failure",
            "logon failed"
        ]) {
            return item(
                kind: .authentication,
                message: "Сервер отклонил имя пользователя или RDP-пароль. Проверьте домен, логин и пароль.",
                code: "ERRCONNECT_LOGON_FAILURE",
                retryable: false,
                reason: "Сервер отклонил RDP-учётные данные"
            )
        }
        if containsAny(text, [
            "errconnect_dns_name_not_found",
            "name or service not known",
            "could not resolve",
            "temporary failure in name resolution"
        ]) {
            return item(
                kind: .dns,
                message: "Не удалось найти RDP-сервер по имени. Проверьте hostname, DNS и подключение к VPN.",
                code: symbolicCode(in: text) ?? "ERRCONNECT_DNS_NAME_NOT_FOUND",
                retryable: false,
                reason: "Не удалось разрешить имя RDP-сервера"
            )
        }
        if containsAny(text, [
            "errconnect_gateway_failed",
            "gateway transport",
            "rd gateway"
        ]) {
            return item(
                kind: .gateway,
                message: "Не удалось подключиться через RD Gateway. Проверьте адрес Gateway, сеть и учётные данные.",
                code: symbolicCode(in: text),
                retryable: false,
                reason: "Не удалось подключиться через RD Gateway"
            )
        }
        if containsAny(text, [
            "errconnect_tls_connect_failed",
            "certificate verify failed",
            "certificate name mismatch",
            "errconnect_security_nego_connect_failed"
        ]) {
            return item(
                kind: .certificate,
                message: "Не удалось установить защищённое RDP-соединение. Проверьте сертификат сервера и параметры TLS/NLA.",
                code: symbolicCode(in: text),
                retryable: false,
                reason: "Ошибка сертификата или защищённого RDP-соединения"
            )
        }
        if containsAny(text, ["network is unreachable", "no route to host"]) {
            return item(
                kind: .unreachable,
                message: "Сеть или маршрут до RDP-сервера недоступны. Проверьте сеть, VPN и маршрутизацию.",
                code: symbolicCode(in: text),
                retryable: true,
                reason: "Сеть или маршрут до RDP-сервера недоступны"
            )
        }
        if containsAny(text, ["connection timed out", "operation timed out"]) {
            return item(
                kind: .timeout,
                message: "RDP-сервер не ответил вовремя. Проверьте сеть, VPN и доступность порта 3389.",
                code: symbolicCode(in: text),
                retryable: true,
                reason: "RDP-соединение потеряно по тайм-ауту"
            )
        }
        if text.contains("connection refused") {
            return item(
                kind: .refused,
                message: "RDP-сервер отклонил соединение. Проверьте, запущена ли служба RDP и доступен ли порт 3389.",
                code: symbolicCode(in: text),
                retryable: true,
                reason: "RDP-сервер временно отклонил соединение"
            )
        }
        if containsAny(text, [
            "errconnect_connect_transport_failed",
            "connection reset by peer",
            "transport connect failed",
            "freerdp_tcp_connect"
        ]) {
            return item(
                kind: .transport,
                message: "Не удалось установить или сохранить сетевое RDP-соединение. Проверьте hostname, VPN и порт 3389.",
                code: symbolicCode(in: text) ?? "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
                retryable: true,
                reason: text.contains("connection reset")
                    ? "RDP-соединение было неожиданно разорвано"
                    : "Временный сбой RDP-транспорта"
            )
        }
        if text.contains("errconnect_connect_cancelled") || text.contains("connection aborted by user") {
            return item(
                kind: .cancelled,
                message: "RDP-подключение было отменено. Если вы не отключали сессию вручную, повторите подключение и проверьте журнал.",
                code: "ERRCONNECT_CONNECT_CANCELLED",
                retryable: false,
                reason: "RDP-подключение было отменено"
            )
        }

        return item(
            kind: .unknown,
            message: "RDP-сессия неожиданно завершилась. Откройте журнал для диагностики. Код процесса: \(status).",
            code: symbolicCode(in: text),
            retryable: false,
            reason: "Неизвестный сбой RDP"
        )
    }

    private static func item(
        kind: RDPFailureKind,
        message: String,
        code: String?,
        retryable: Bool,
        reason: String
    ) -> RDPFailurePresentation {
        let decorated = code.map { "\(message)\nКод FreeRDP: \($0)." } ?? message
        return RDPFailurePresentation(
            kind: kind,
            message: decorated,
            technicalCode: code,
            retryable: retryable,
            reconnectReason: reason
        )
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func symbolicCode(in text: String) -> String? {
        guard let range = text.range(of: "errconnect_") else { return nil }
        let suffix = text[range.lowerBound...]
        let code = suffix.prefix { character in
            character.isLetter || character.isNumber || character == "_"
        }
        guard !code.isEmpty else { return nil }
        return code.uppercased()
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
        return RDPFailureClassifier.presentation(status: status, log: log).retryable
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
        RDPFailureClassifier.presentation(status: 1, log: log).reconnectReason
    }

    private static func containsAuthenticationFailure(_ text: String) -> Bool {
        authenticationFailures.contains { text.contains($0) }
    }
}
