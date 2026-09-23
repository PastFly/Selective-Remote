import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Generated terminal copy localization", .serialized)
struct TerminalGeneratedCopyLocalizationTests {
    private func inEnglish(_ body: () throws -> Void) rethrows {
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
        try body()
    }

    @Test("Failed launch writes English app text while retaining OS detail")
    @MainActor
    func failedLaunchText() {
        inEnglish {
            let session = TerminalSessionModel()
            do {
                try session.start(executable: "/private/tmp/no-such-terminal-helper", arguments: [], title: "User title")
            } catch {
                // The process error is expected; inspect the user-visible terminal buffer.
            }
            let output = session.recentOutputText()
            #expect(output.contains("Could not launch command:"))
            #expect(output.contains("/private/tmp/no-such-terminal-helper"))
        }
    }

    @Test("Process exit messages preserve exit code in English")
    @MainActor
    func processExitText() {
        inEnglish {
            #expect(TerminalSessionModel.terminationLine(exitCode: 7, requested: false).contains("Process exited with code 7."))
            #expect(TerminalSessionModel.terminationLine(exitCode: 0, requested: true).contains("Session disconnected by user."))
        }
    }

    @Test("Workspace summary translates generated count and layout")
    func workspaceSummary() {
        inEnglish {
            #expect(TerminalWorkspaceLayout.splitHorizontal.localizedSummary(tabCount: 2) == "2 tabs · Split left to right")
            #expect(TerminalGroupSettingsCopy.title(for: "Моя группа") == "Group settings for “Моя группа”")
        }
        #expect(TerminalWorkspaceLayout.single.localizedSummary(tabCount: 1, english: false) == "1 вкладка · Одна панель")
        #expect(TerminalWorkspaceLayout.single.localizedSummary(tabCount: 2, english: false) == "2 вкладки · Одна панель")
        #expect(TerminalWorkspaceLayout.single.localizedSummary(tabCount: 5, english: false) == "5 вкладок · Одна панель")
    }

    @Test("Closing the last tab tracks a generated empty title without changing custom names")
    @MainActor
    func resetTitleProvenance() throws {
        let suiteName = "TerminalGeneratedCopy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let language = AppLanguageStore(defaults: defaults)
        language.selection = .english
        let workspace = TerminalWorkspaceModel(
            profileID: UUID(),
            primarySession: TerminalSessionModel(),
            defaults: defaults,
            language: language
        )
        let tabID = workspace.tabs[0].id
        workspace.renameTab(tabID, to: "Legacy user title")
        language.selection = .russian
        #expect(workspace.tabs[0].title == "Legacy user title")
        language.selection = .english
        workspace.closeTab(tabID)
        #expect(workspace.tabs[0].title == "New Terminal")
        language.selection = .russian
        #expect(workspace.tabs[0].title == "Новый терминал")
    }

    @Test("Working directory panel title uses English")
    @MainActor
    func panelTitle() {
        inEnglish {
            #expect(LocalTerminalView.workingDirectoryPanelTitle == "Local Terminal Working Folder")
        }
    }
}
