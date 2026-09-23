import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Session service errors", .serialized)
struct SessionServiceErrorLocalizationTests {
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

    @Test("Terminal process and startup errors use English and preserve details")
    func terminalErrors() {
        inEnglish {
            #expect(PTYProcessError.executableUnavailable("/bin/missing").errorDescription == "System command is unavailable: /bin/missing")
            #expect(PTYProcessError.spawnFailed("errno 5").errorDescription == "Could not create pseudo-terminal: errno 5")
            #expect(TerminalStartupSnippetSequenceError.tooManySnippets.errorDescription == "Startup Sequence can contain no more than 8 Snippets.")
            #expect(TerminalRemoteContextError.commandFailed("remote detail").errorDescription == "Could not retrieve server information: remote detail")
        }
    }

    @Test("RDP and Mosh errors use English and preserve monitor names")
    func connectionErrors() {
        inEnglish {
            #expect(FreeRDPError.monitorMappingFailed("Studio Display").errorDescription == "FreeRDP could not map monitor “Studio Display”")
            #expect(FreeRDPError.invalidHost.errorDescription == "Enter the remote computer hostname")
            #expect(MoshServiceError.invalidUDPPort.errorDescription == "The Mosh UDP port must be 0 (automatic) or between 1 and 65535.")
        }
    }

    @Test("SSH certificate authority errors use English and preserve file paths")
    func certificateErrors() {
        inEnglish {
            #expect(SSHCertificateAuthorityError.invalidPublicKey.errorDescription == "Select a public SSH CA key (*.pub)")
            #expect(SSHCertificateAuthorityError.privateKeyUnavailable("/tmp/ca-key").errorDescription == "Private CA key is unavailable: /tmp/ca-key")
            #expect(SSHCertificateAuthorityError.signingFailed("OpenSSH detail").errorDescription == "Could not sign SSH certificate: OpenSSH detail")
        }
    }
}
