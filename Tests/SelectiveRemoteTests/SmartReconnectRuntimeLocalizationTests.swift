import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Smart reconnect runtime localization", .serialized)
struct SmartReconnectRuntimeLocalizationTests {
    private func inEnglish(_ body: () -> Void) {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let key = "SelectiveRemote.applicationLanguage.v1"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set("english", forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    @Test("Reconnect progress labels follow English runtime language")
    func progress() {
        inEnglish {
            let now = Date(timeIntervalSince1970: 1_000)
            let progress = SmartReconnectProgress(
                attempt: 2,
                maximumAttempts: 3,
                nextAttemptAt: now.addingTimeInterval(5),
                reason: "network"
            )
            #expect(progress.attemptLabel == "Attempt 2/3")
            #expect(progress.countdownText(now: now) == "Next attempt in 5 sec")
            #expect(progress.countdownText(now: now.addingTimeInterval(5)) == "Reconnecting…")
        }
    }

    @Test("RDP failure presentations translate text and preserve technical code")
    func rdpPresentation() {
        inEnglish {
            let failure = RDPFailureClassifier.presentation(
                status: 1,
                log: "ERRCONNECT_LOGON_FAILURE"
            )
            #expect(failure.kind == .authentication)
            #expect(failure.retryable == false)
            #expect(failure.technicalCode == "ERRCONNECT_LOGON_FAILURE")
            #expect(failure.message == "The server rejected the username or RDP password. Check the domain, username, and password.\nFreeRDP code: ERRCONNECT_LOGON_FAILURE.")
            #expect(failure.reconnectReason == "The server rejected the RDP credentials")
        }
    }

    @Test("SSH classifier translates reasons without changing matching")
    func sshReason() {
        inEnglish {
            #expect(SmartReconnectClassifier.shouldRetrySSH(exitCode: 255, output: "Connection reset by peer"))
            #expect(SmartReconnectClassifier.sshReason(output: "Connection reset by peer") == "The SSH connection was unexpectedly reset")
            #expect(SmartReconnectClassifier.sshReason(output: "Connection refused") == "The SSH server temporarily refused the connection")
        }
    }
}
