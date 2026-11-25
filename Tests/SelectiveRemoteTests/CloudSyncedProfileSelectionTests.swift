import Foundation
import Testing
@testable import SelectiveRemote

@Suite(.serialized)
@MainActor
struct CloudSyncedProfileSelectionTests {
    @Test("An empty Cloud snapshot remains empty and clears the selected host")
    func emptySnapshot() throws {
        let defaults = UserDefaults.standard
        let profilesKey = try #require(NativeStorageMigration.newKey(for: "SelectiveRemote.connectionProfiles.v2"))
        let selectedKey = try #require(NativeStorageMigration.newKey(for: "SelectiveRemote.selectedProfileID.v2"))
        let previousProfiles = defaults.object(forKey: profilesKey)
        let previousSelection = defaults.object(forKey: selectedKey)
        defer {
            defaults.set(previousProfiles, forKey: profilesKey)
            defaults.set(previousSelection, forKey: selectedKey)
        }

        let model = AppModel()
        let first = ConnectionProfile(connectionType: .ssh)
        let second = ConnectionProfile(connectionType: .rdp)
        model.replaceSyncedProfiles([first, second])
        model.selectProfile(second.id)
        model.password = "synthetic in-memory test value"

        model.replaceSyncedProfiles([])

        #expect(model.profiles.isEmpty)
        #expect(model.selectedProfileID == nil)
        #expect(model.selectedProfileOrNil == nil)
        #expect(model.password.isEmpty)

        let renderValue = model.selectedProfile
        #expect(renderValue.host.isEmpty)
        #expect(model.selectedProfile.id == renderValue.id)
        model.updateSelectedProfile(renderValue)
        model.duplicateSelectedProfile()
        model.connect()
        #expect(model.profiles.isEmpty)
        #expect(model.selectedProfileID == nil)

        // A restart must also preserve an explicitly persisted empty host list.
        defaults.set(try JSONEncoder().encode([ConnectionProfile]()), forKey: profilesKey)
        let restarted = AppModel()
        #expect(restarted.profiles.isEmpty)
        #expect(restarted.selectedProfileOrNil == nil)

        model.replaceSyncedProfiles([first, second])
        #expect(model.selectedProfileID == first.id)
        model.selectProfile(second.id)
        model.replaceSyncedProfiles([second, first])
        #expect(model.selectedProfileID == second.id)
        model.replaceSyncedProfiles([first])
        #expect(model.selectedProfileID == first.id)
    }
}
