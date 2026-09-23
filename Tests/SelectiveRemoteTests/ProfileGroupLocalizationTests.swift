import Foundation
import Testing
@testable import SelectiveRemote

@Suite(.serialized)
@MainActor
struct ProfileGroupLocalizationTests {
    private let languageKey = "SelectiveRemote.applicationLanguage.v1"

    @Test("A user group named No Group stays separate from ungrouped profiles")
    func noGroupNameCollision() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let priorLanguage = UserDefaults.standard.object(forKey: languageKey)
        UserDefaults.standard.set("english", forKey: languageKey)
        defer { UserDefaults.standard.set(priorLanguage, forKey: languageKey) }

        let model = AppModel()
        var ungrouped = ConnectionProfile(connectionType: .ssh)
        ungrouped.group = ""
        var namedGroup = ConnectionProfile(connectionType: .ssh)
        namedGroup.group = "No Group"
        model.profiles = [ungrouped, namedGroup]

        let groups = model.profileGroups
        #expect(groups.count == 2)
        #expect(groups.map(\.name) == ["No Group", "No Group"])
        #expect(groups.map(\.profiles).map { $0.map(\.id) } == [[ungrouped.id], [namedGroup.id]])
        #expect(Set(groups.map(\.id)).count == 2)
    }
}
