import Foundation

struct SmartReconnectProgress: Equatable, Sendable {
    let attempt: Int
    let maximumAttempts: Int
    let nextAttemptAt: Date?
    private let originalReason: String
    let displayReason: RDPDisplayStatus?

    var reason: String { displayReason?.text ?? originalReason }

    init(
        attempt: Int,
        maximumAttempts: Int,
        nextAttemptAt: Date?,
        reason: String,
        displayReason: RDPDisplayStatus? = nil
    ) {
        self.attempt = attempt
        self.maximumAttempts = maximumAttempts
        self.nextAttemptAt = nextAttemptAt
        originalReason = reason
        self.displayReason = displayReason
    }

    var attemptLabel: String {
        UpdateLocalization.text(ru: "Попытка \(attempt)/\(maximumAttempts)", en: "Attempt \(attempt)/\(maximumAttempts)")
    }

    func countdownText(now: Date = Date()) -> String? {
        guard let nextAttemptAt else { return nil }
        let seconds = max(0, Int(ceil(nextAttemptAt.timeIntervalSince(now))))
        return seconds == 0
            ? UpdateLocalization.text(ru: "Повторное подключение…", en: "Reconnecting…")
            : UpdateLocalization.text(ru: "Следующая попытка через \(seconds) с", en: "Next attempt in \(seconds) sec")
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
                message: UpdateLocalization.text(ru: "Учётная запись Windows заблокирована. Разблокируйте её или обратитесь к администратору домена.", en: "The Windows account is locked. Unlock it or contact your domain administrator."),
                code: "ERRCONNECT_ACCOUNT_LOCKED_OUT",
                retryable: false,
                reason: UpdateLocalization.text(ru: "Учётная запись Windows заблокирована", en: "The Windows account is locked")
            )
        }
        if containsAny(text, [
            "errconnect_password_expired",
            "password expired"
        ]) {
            return item(
                kind: .authentication,
                message: UpdateLocalization.text(ru: "Срок действия RDP-пароля истёк. Смените пароль и повторите подключение.", en: "The RDP password has expired. Change it and reconnect."),
                code: "ERRCONNECT_PASSWORD_EXPIRED",
                retryable: false,
                reason: UpdateLocalization.text(ru: "Срок действия RDP-пароля истёк", en: "The RDP password has expired")
            )
        }
        if containsAny(text, [
            "errconnect_account_expired",
            "account expired"
        ]) {
            return item(
                kind: .authentication,
                message: UpdateLocalization.text(ru: "Срок действия учётной записи Windows истёк. Проверьте состояние учётной записи.", en: "The Windows account has expired. Check the account status."),
                code: "ERRCONNECT_ACCOUNT_EXPIRED",
                retryable: false,
                reason: UpdateLocalization.text(ru: "Срок действия учётной записи Windows истёк", en: "The Windows account has expired")
            )
        }
        if containsAny(text, [
            "errconnect_logon_failure",
            "logon failed"
        ]) {
            return item(
                kind: .authentication,
                message: UpdateLocalization.text(ru: "Сервер отклонил имя пользователя или RDP-пароль. Проверьте домен, логин и пароль.", en: "The server rejected the username or RDP password. Check the domain, username, and password."),
                code: "ERRCONNECT_LOGON_FAILURE",
                retryable: false,
                reason: UpdateLocalization.text(ru: "Сервер отклонил RDP-учётные данные", en: "The server rejected the RDP credentials")
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
                message: UpdateLocalization.text(ru: "Не удалось найти RDP-сервер по имени. Проверьте hostname, DNS и подключение к VPN.", en: "Could not resolve the RDP server name. Check the hostname, DNS, and VPN connection."),
                code: symbolicCode(in: text) ?? "ERRCONNECT_DNS_NAME_NOT_FOUND",
                retryable: false,
                reason: UpdateLocalization.text(ru: "Не удалось разрешить имя RDP-сервера", en: "Could not resolve the RDP server name")
            )
        }
        if containsAny(text, [
            "errconnect_gateway_failed",
            "gateway transport",
            "rd gateway"
        ]) {
            return item(
                kind: .gateway,
                message: UpdateLocalization.text(ru: "Не удалось подключиться через RD Gateway. Проверьте адрес Gateway, сеть и учётные данные.", en: "Could not connect through RD Gateway. Check the gateway address, network, and credentials."),
                code: symbolicCode(in: text),
                retryable: false,
                reason: UpdateLocalization.text(ru: "Не удалось подключиться через RD Gateway", en: "Could not connect through RD Gateway")
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
                message: UpdateLocalization.text(ru: "Не удалось установить защищённое RDP-соединение. Проверьте сертификат сервера и параметры TLS/NLA.", en: "Could not establish a secure RDP connection. Check the server certificate and TLS/NLA settings."),
                code: symbolicCode(in: text),
                retryable: false,
                reason: UpdateLocalization.text(ru: "Ошибка сертификата или защищённого RDP-соединения", en: "Certificate or secure RDP connection error")
            )
        }
        if containsAny(text, ["network is unreachable", "no route to host"]) {
            return item(
                kind: .unreachable,
                message: UpdateLocalization.text(ru: "Сеть или маршрут до RDP-сервера недоступны. Проверьте сеть, VPN и маршрутизацию.", en: "The network or route to the RDP server is unavailable. Check the network, VPN, and routing."),
                code: symbolicCode(in: text),
                retryable: true,
                reason: UpdateLocalization.text(ru: "Сеть или маршрут до RDP-сервера недоступны", en: "The network or route to the RDP server is unavailable")
            )
        }
        if containsAny(text, ["connection timed out", "operation timed out"]) {
            return item(
                kind: .timeout,
                message: UpdateLocalization.text(ru: "RDP-сервер не ответил вовремя. Проверьте сеть, VPN и доступность порта 3389.", en: "The RDP server did not respond in time. Check the network, VPN, and port 3389."),
                code: symbolicCode(in: text),
                retryable: true,
                reason: UpdateLocalization.text(ru: "RDP-соединение потеряно по тайм-ауту", en: "The RDP connection timed out")
            )
        }
        if text.contains("connection refused") {
            return item(
                kind: .refused,
                message: UpdateLocalization.text(ru: "RDP-сервер отклонил соединение. Проверьте, запущена ли служба RDP и доступен ли порт 3389.", en: "The RDP server refused the connection. Check that the RDP service is running and port 3389 is reachable."),
                code: symbolicCode(in: text),
                retryable: true,
                reason: UpdateLocalization.text(ru: "RDP-сервер временно отклонил соединение", en: "The RDP server temporarily refused the connection")
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
                message: UpdateLocalization.text(ru: "Не удалось установить или сохранить сетевое RDP-соединение. Проверьте hostname, VPN и порт 3389.", en: "Could not establish or maintain the RDP network connection. Check the hostname, VPN, and port 3389."),
                code: symbolicCode(in: text) ?? "ERRCONNECT_CONNECT_TRANSPORT_FAILED",
                retryable: true,
                reason: text.contains("connection reset")
                    ? UpdateLocalization.text(ru: "RDP-соединение было неожиданно разорвано", en: "The RDP connection was unexpectedly reset")
                    : UpdateLocalization.text(ru: "Временный сбой RDP-транспорта", en: "Temporary RDP transport failure")
            )
        }
        if text.contains("errconnect_connect_cancelled") || text.contains("connection aborted by user") {
            return item(
                kind: .cancelled,
                message: UpdateLocalization.text(ru: "RDP-подключение было отменено. Если вы не отключали сессию вручную, повторите подключение и проверьте журнал.", en: "The RDP connection was cancelled. If you did not disconnect manually, reconnect and check the log."),
                code: "ERRCONNECT_CONNECT_CANCELLED",
                retryable: false,
                reason: UpdateLocalization.text(ru: "RDP-подключение было отменено", en: "The RDP connection was cancelled")
            )
        }

        return item(
            kind: .unknown,
            message: UpdateLocalization.text(ru: "RDP-сессия неожиданно завершилась. Откройте журнал для диагностики. Код процесса: \(status).", en: "The RDP session ended unexpectedly. Open the log for diagnostics. Process code: \(status)."),
            code: symbolicCode(in: text),
            retryable: false,
            reason: UpdateLocalization.text(ru: "Неизвестный сбой RDP", en: "Unknown RDP failure")
        )
    }

    private static func item(
        kind: RDPFailureKind,
        message: String,
        code: String?,
        retryable: Bool,
        reason: String
    ) -> RDPFailurePresentation {
        let decorated = code.map {
            UpdateLocalization.text(
                ru: "\(message)\nКод FreeRDP: \($0).",
                en: "\(message)\nFreeRDP code: \($0)."
            )
        } ?? message
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
            return UpdateLocalization.text(ru: "Не удалось разрешить имя SSH-сервера", en: "Could not resolve the SSH server name")
        }
        if text.contains("network is unreachable") || text.contains("no route to host") {
            return UpdateLocalization.text(ru: "Сеть или маршрут до SSH-сервера недоступны", en: "The network or route to the SSH server is unavailable")
        }
        if text.contains("timed out") {
            return UpdateLocalization.text(ru: "SSH-соединение потеряно по тайм-ауту", en: "The SSH connection timed out")
        }
        if text.contains("broken pipe") || text.contains("connection reset") {
            return UpdateLocalization.text(ru: "SSH-соединение было неожиданно разорвано", en: "The SSH connection was unexpectedly reset")
        }
        if text.contains("connection refused") {
            return UpdateLocalization.text(ru: "SSH-сервер временно отклонил соединение", en: "The SSH server temporarily refused the connection")
        }
        return UpdateLocalization.text(ru: "Временный сбой SSH-транспорта", en: "Temporary SSH transport failure")
    }

    static func rdpReason(log: String) -> String {
        RDPFailureClassifier.presentation(status: 1, log: log).reconnectReason
    }

    private static func containsAuthenticationFailure(_ text: String) -> Bool {
        authenticationFailures.contains { text.contains($0) }
    }
}
