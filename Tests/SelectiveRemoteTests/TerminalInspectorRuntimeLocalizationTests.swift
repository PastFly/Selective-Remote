import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Terminal inspector runtime localization", .serialized)
struct TerminalInspectorRuntimeLocalizationTests {
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

    @Test("Inspector mode titles use runtime language")
    func modeTitles() {
        inEnglish {
            #expect(TerminalWorkspaceInspectorMode.history.localizedTitle == "History")
            #expect(TerminalWorkspaceInspectorMode.snippets.localizedTitle == "Snippets")
        }
    }

    @Test("Command feedback translates while preserving user terminal name")
    func commandFeedback() {
        inEnglish {
            #expect(TerminalWorkspaceInspectorCopy.commandSent(to: "Мой сервер") == "Command sent to Мой сервер")
            #expect(TerminalWorkspaceInspectorCopy.favoriteDescription == "Saved command")
        }
    }
}
