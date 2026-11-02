import Foundation
import Testing
@testable import SelectiveRemote

@Test("A legacy single profile is imported once and cannot reappear after deletion")
func legacySingleProfileImportedOnce() throws {
    let suite = "SelectiveRemote.NativeProfileMigration.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let legacyKey = "SelectiveRemote.connectionProfile.v1"
    let profilesKey = try #require(NativeStorageMigration.newKey(for: "SelectiveRemote.connectionProfiles.v2"))
    let legacy = LegacyConnectionProfile(host: "test-only.invalid", username: "test")
    let legacyData = try JSONEncoder().encode(legacy)
    defaults.set(legacyData, forKey: legacyKey)
    try NativeStorageMigration.prepare(defaults)
    try NativeStorageValidation.validate(defaults)
    try NativeStorageValidation.finishLegacyProfileMigration(defaults)
    let profiles = try JSONDecoder().decode([ConnectionProfile].self, from: #require(defaults.data(forKey: profilesKey)))
    #expect(profiles.count == 1)
    #expect(profiles[0].host == "test-only.invalid")
    #expect(defaults.data(forKey: legacyKey) == legacyData)
    defaults.removeObject(forKey: profilesKey)
    try NativeStorageValidation.finishLegacyProfileMigration(defaults)
    #expect(defaults.data(forKey: profilesKey) == nil)
    #expect(defaults.data(forKey: legacyKey) == legacyData)
}

@Test("An empty legacy profile collection still imports the older single profile once")
func legacySingleProfileImportedWhenCollectionEmpty() throws {
    let suite = "SelectiveRemote.NativeEmptyProfileMigration.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let oldList = "SelectiveRemote.connectionProfiles.v2"
    let oldSingle = "SelectiveRemote.connectionProfile.v1"
    let newList = try #require(NativeStorageMigration.newKey(for: oldList))
    let empty = try JSONEncoder().encode([ConnectionProfile]())
    let legacy = try JSONEncoder().encode(LegacyConnectionProfile(host: "legacy-empty.invalid", username: "test"))
    defaults.set(empty, forKey: oldList)
    defaults.set(legacy, forKey: oldSingle)
    try NativeStorageMigration.prepare(defaults)
    try NativeStorageValidation.validate(defaults)
    try NativeStorageValidation.finishLegacyProfileMigration(defaults)
    let profiles = try JSONDecoder().decode([ConnectionProfile].self, from: #require(defaults.data(forKey: newList)))
    #expect(profiles.map(\.host) == ["legacy-empty.invalid"])
    #expect(defaults.data(forKey: oldList) == empty)
    #expect(defaults.data(forKey: oldSingle) == legacy)
    defaults.set(empty, forKey: newList)
    try NativeStorageValidation.finishLegacyProfileMigration(defaults)
    #expect(defaults.data(forKey: newList) == empty)
}
