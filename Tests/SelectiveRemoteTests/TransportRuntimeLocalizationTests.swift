import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Transport runtime localization", .serialized)
struct TransportRuntimeLocalizationTests {
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

    @Test("SFTP failures retain paths and names in English")
    func sftpErrors() {
        inEnglish {
            #expect(SFTPServiceError.invalidName.errorDescription?.contains("Name must") == true)
            #expect(SFTPServiceError.commandFailed("remote detail").errorDescription == "SFTP error: remote detail")
            #expect(SFTPLocalFileError.targetExists("report.txt").errorDescription == "Local item “report.txt” already exists")
        }
    }

    @Test("Telnet and serial runtime failures use English")
    func terminalTransportErrors() {
        inEnglish {
            #expect(TerminalTransportServiceError.invalidTelnetEndpoint.errorDescription == "Enter a valid Telnet address and port.")
            #expect(TerminalTransportService.userFacingFailure(
                output: "serial: cannot open /dev/cu.usbserial",
                connection: .serial(devicePath: "/dev/cu.usbserial", baudRate: 9600, dataBits: 8, parity: .none, stopBits: 1, flowControl: .none),
                exitCode: 1
            ) == "Could not open the serial device. Check the connection and permissions.")
        }
    }

    @Test("SFTP local loading status uses English")
    @MainActor
    func sftpLocalStatus() {
        inEnglish {
            let model = SFTPLocalBrowserModel()
            #expect(model.statusMessage == "Reading local folder…")
        }
    }
}
