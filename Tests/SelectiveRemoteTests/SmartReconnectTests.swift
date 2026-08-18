import Foundation
import Testing
@testable import SelectiveRemote

@Test("Smart Reconnect использует ограниченный backoff из трёх попыток")
func smartReconnectUsesBoundedBackoff() {
    #expect(SmartReconnectPolicy.maximumAttempts == 3)
    let base = Date(timeIntervalSince1970: 1_000)
    #expect(SmartReconnectPolicy.nextAttemptDate(for: 1, now: base) == base.addingTimeInterval(1))
    #expect(SmartReconnectPolicy.nextAttemptDate(for: 2, now: base) == base.addingTimeInterval(3))
    #expect(SmartReconnectPolicy.nextAttemptDate(for: 3, now: base) == base.addingTimeInterval(7))
}

@Test("Smart Reconnect повторяет SSH только при подтверждённой transport-ошибке")
func smartReconnectClassifiesSSHTransportFailures() {
    #expect(
        SmartReconnectClassifier.shouldRetrySSH(
            exitCode: 255,
            output: "client_loop: send disconnect: Broken pipe"
        )
    )
    #expect(
        SmartReconnectClassifier.shouldRetrySSH(
            exitCode: 255,
            output: "ssh: connect to host server port 22: Network is unreachable"
        )
    )
    #expect(
        !SmartReconnectClassifier.shouldRetrySSH(
            exitCode: 255,
            output: "Permission denied (publickey,password)."
        )
    )
    #expect(
        !SmartReconnectClassifier.shouldRetrySSH(
            exitCode: 0,
            output: "Connection closed by remote host"
        )
    )
}

@Test("Smart Reconnect не зацикливает RDP authentication failure")
func smartReconnectClassifiesRDPTransportFailures() {
    #expect(
        SmartReconnectClassifier.shouldRetryRDP(
            status: 1,
            log: "ERRCONNECT_CONNECT_TRANSPORT_FAILED"
        )
    )
    #expect(
        !SmartReconnectClassifier.shouldRetryRDP(
            status: 1,
            log: "ERRCONNECT_LOGON_FAILURE Logon failed"
        )
    )
}

@Test("RDP DNS-ошибка получает понятное сообщение и сохраняет технический код")
func rdpDNSFailurePresentation() {
    let failure = RDPFailureClassifier.presentation(
        status: 1,
        log: "ERRCONNECT_DNS_NAME_NOT_FOUND [0x00020005]"
    )

    #expect(failure.kind == .dns)
    #expect(!failure.retryable)
    #expect(failure.technicalCode == "ERRCONNECT_DNS_NAME_NOT_FOUND")
    #expect(failure.message.contains("Проверьте hostname, DNS и подключение к VPN"))
    #expect(failure.message.contains("ERRCONNECT_DNS_NAME_NOT_FOUND"))
}

@Test("RDP transport failure остаётся retryable, а authentication failure — нет")
func rdpFailureClassifierPreservesReconnectPolicy() {
    #expect(
        RDPFailureClassifier.presentation(
            status: 1,
            log: "ERRCONNECT_CONNECT_TRANSPORT_FAILED"
        ).retryable
    )
    #expect(
        !RDPFailureClassifier.presentation(
            status: 1,
            log: "ERRCONNECT_LOGON_FAILURE Logon failed"
        ).retryable
    )
}

@Test("Только смена monitor topology запускает controlled Smart Reconnect")
func rdpControlledInterruptionPolicy() {
    #expect(RDPSessionInterruption.monitorTopologyChanged.shouldAttemptSmartReconnect)
    #expect(!RDPSessionInterruption.userRequested.shouldAttemptSmartReconnect)
    #expect(!RDPSessionInterruption.sleep.shouldAttemptSmartReconnect)
}

@Test("Smart Reconnect progress показывает номер попытки и countdown")
func smartReconnectProgressFormatsRuntimeState() {
    let now = Date(timeIntervalSince1970: 2_000)
    let progress = SmartReconnectProgress(
        attempt: 2,
        maximumAttempts: 3,
        nextAttemptAt: now.addingTimeInterval(4),
        reason: "Network drop"
    )
    #expect(progress.attemptLabel == "Попытка 2/3")
    #expect(progress.countdownText(now: now) == "Следующая попытка через 4 с")
}

@Test("Phase 4 подключён к Terminal, Forwarding и RDP без отдельного session manager")
func smartReconnectIntegrationContract() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let appModel = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/AppModel.swift"),
        encoding: .utf8
    )
    let terminal = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/EmbeddedTerminalView.swift"),
        encoding: .utf8
    )
    let pty = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/PTYSession.swift"),
        encoding: .utf8
    )
    let forwarding = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/ForwardingManager.swift"),
        encoding: .utf8
    )
    let contentView = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )

    #expect(appModel.contains("scheduleTerminalSmartReconnect"))
    #expect(appModel.contains("scheduleSSHTunnelSmartReconnect"))
    #expect(appModel.contains("scheduleRDPSmartReconnect"))
    #expect(appModel.contains("workspaceWillSleep"))
    #expect(appModel.contains("workspaceDidWake"))
    #expect(appModel.contains("sshProfileRequiresUserPresenceForReconnect"))
    #expect(appModel.contains("sshTunnelReconnectSummaries"))
    #expect(appModel.contains("interruption: .monitorTopologyChanged"))
    #expect(appModel.contains("interruption.shouldAttemptSmartReconnect"))
    if let removed = appModel.range(of: "managedSessions.removeValue(forKey: profileID)"),
       let reconnect = appModel.range(of: "if interruption.shouldAttemptSmartReconnect") {
        #expect(removed.lowerBound < reconnect.lowerBound)
    } else {
        Issue.record("Controlled RDP reconnect must start only after the old process is removed")
    }
    #expect(pty.contains("lastTerminationWasRequested"))
    #expect(terminal.contains("Smart Reconnect"))
    #expect(forwarding.contains("Smart Reconnect"))
    #expect(!contentView.contains("Button(\"Забыть недоступные\")"))
    #expect(!contentView.contains("Недоступные мониторы временно пропущены"))
    #expect(!appModel.contains("SmartReconnectSessionManager"))
}
