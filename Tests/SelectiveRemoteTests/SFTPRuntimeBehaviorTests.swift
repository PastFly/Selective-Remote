import Dispatch
import Foundation
import Testing
@testable import SelectiveRemote

@Test("SFTP progress polling backs off and skips paused transfers")
func sftpProgressPollingPolicyIsAdaptive() {
    #expect(SFTPTransferPollPolicy.shouldProbe(phase: .running))
    #expect(!SFTPTransferPollPolicy.shouldProbe(phase: .paused))
    #expect(!SFTPTransferPollPolicy.shouldProbe(phase: .cancelled))

    #expect(
        SFTPTransferPollPolicy.delayMilliseconds(
            elapsed: 0,
            phase: .running
        ) == 800
    )
    #expect(
        SFTPTransferPollPolicy.delayMilliseconds(
            elapsed: 10,
            phase: .running
        ) == 1_500
    )
    #expect(
        SFTPTransferPollPolicy.delayMilliseconds(
            elapsed: 45,
            phase: .running
        ) == 2_000
    )
    #expect(
        SFTPTransferPollPolicy.delayMilliseconds(
            elapsed: 45,
            phase: .paused
        ) == 500
    )
}

@Test("Different SFTP ControlPaths do not block each other")
func sftpControlPathGateAllowsIndependentConnections() {
    let gate = SFTPControlPathGate()
    let firstEntered = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let firstFinished = DispatchSemaphore(value: 0)
    let secondEntered = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInitiated).async {
        gate.withLock("server-a") {
            firstEntered.signal()
            releaseFirst.wait()
        }
        firstFinished.signal()
    }

    #expect(firstEntered.wait(timeout: .now() + 1) == .success)

    DispatchQueue.global(qos: .userInitiated).async {
        gate.withLock("server-b") {
            secondEntered.signal()
        }
    }

    #expect(secondEntered.wait(timeout: .now() + 0.5) == .success)
    releaseFirst.signal()
    #expect(firstFinished.wait(timeout: .now() + 1) == .success)
}

@Test("The same SFTP ControlPath remains serialized")
func sftpControlPathGateSerializesOneConnection() {
    let gate = SFTPControlPathGate()
    let firstEntered = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let firstFinished = DispatchSemaphore(value: 0)
    let secondEntered = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInitiated).async {
        gate.withLock("shared-server") {
            firstEntered.signal()
            releaseFirst.wait()
        }
        firstFinished.signal()
    }

    #expect(firstEntered.wait(timeout: .now() + 1) == .success)

    DispatchQueue.global(qos: .userInitiated).async {
        gate.withLock("shared-server") {
            secondEntered.signal()
        }
    }

    #expect(secondEntered.wait(timeout: .now() + 0.15) == .timedOut)
    releaseFirst.signal()
    #expect(firstFinished.wait(timeout: .now() + 1) == .success)
    #expect(secondEntered.wait(timeout: .now() + 1) == .success)
}

@Test("SFTP process cancellation terminates the attached subprocess")
@MainActor
func sftpProcessCancellationTerminatesAttachedProcess() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    try process.run()
    defer {
        if process.isRunning {
            process.terminate()
        }
    }

    let control = SFTPProcessControl(forceKillDelay: 0.1)
    control.attach(process)
    control.cancel()

    for _ in 0..<40 where process.isRunning {
        try await Task.sleep(for: .milliseconds(50))
    }

    #expect(!process.isRunning)
    control.detach(process)
}
