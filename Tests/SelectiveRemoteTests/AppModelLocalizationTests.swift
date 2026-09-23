import Foundation
import Testing
@testable import SelectiveRemote

@Suite(.serialized)
@MainActor
struct AppModelLocalizationTests {
    private let languageKey = "SelectiveRemote.applicationLanguage.v1"

    @Test("English profile and tag actions keep user names but translate product copy")
    func englishProfileAndTagMessages() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let priorLanguage = UserDefaults.standard.object(forKey: languageKey)
        UserDefaults.standard.set("english", forKey: languageKey)
        defer { UserDefaults.standard.set(priorLanguage, forKey: languageKey) }

        let model = AppModel()
        model.addProfile(connectionType: .ssh)
        #expect(model.statusMessage == "New SSH profile created")

        let profileID = model.selectedProfile.id
        #expect(model.addProfileTag("Сервер А", to: profileID))
        #expect(model.statusMessage == "Tag “Сервер А” added")
    }

    @Test("English validation errors use English copy")
    func englishProfileValidationError() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let priorLanguage = UserDefaults.standard.object(forKey: languageKey)
        UserDefaults.standard.set("english", forKey: languageKey)
        defer { UserDefaults.standard.set(priorLanguage, forKey: languageKey) }

        let model = AppModel()
        model.addProfile(connectionType: .ssh)
        _ = model.saveManualSSHProfile(host: "", username: "root", port: 22, name: "Host")
        #expect(model.errorMessage == "Enter a valid SSH address and port")
    }

    @Test("English RDP password error uses English copy")
    func englishRDPPasswordError() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let priorLanguage = UserDefaults.standard.object(forKey: languageKey)
        UserDefaults.standard.set("english", forKey: languageKey)
        defer { UserDefaults.standard.set(priorLanguage, forKey: languageKey) }

        let model = AppModel()
        model.addProfile(connectionType: .rdp)
        model.connect()
        #expect(model.errorMessage == "Enter the RDP password. To use an empty password later, press Save first.")
    }

    @Test("English Connection Center details translate labels and retain the profile name")
    func englishConnectionCenterDetails() throws {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let priorLanguage = UserDefaults.standard.object(forKey: languageKey)
        UserDefaults.standard.set("english", forKey: languageKey)
        defer { UserDefaults.standard.set(priorLanguage, forKey: languageKey) }

        let model = AppModel()
        model.addProfile(connectionType: .ssh)
        let profileID = model.selectedProfile.id
        model.mutateSelectedProfile { profile in
            profile.friendlyName = "Сервер А"
            profile.host = "example.invalid"
            profile.username = "operator"
        }
        let workspace = model.terminalWorkspace(
            profileID: profileID,
            primaryConnection: .savedProfile(profileID)
        )
        let tab = try #require(workspace.tabs.first)
        tab.session.setReconnectProgress(.init(
            attempt: 1,
            maximumAttempts: 3,
            nextAttemptAt: nil,
            reason: "Network interruption"
        ))

        let item = try #require(model.connectionCenterSnapshot().items.first {
            $0.profileName == "Сервер А"
        })
        #expect(item.profileName == "Сервер А")
        #expect(item.detailSections.map(\.title) == ["General", "Authentication", "Route", "Session"])
        #expect(item.detailSections[0].rows.map(\.label) == ["Profile", "Tab", "Host", "Port", "Protocol"])
        #expect(item.detailSections[1].rows.first?.label == "Method")
        #expect(item.detailSections[2].rows.first?.label == "Route")
    }
}
