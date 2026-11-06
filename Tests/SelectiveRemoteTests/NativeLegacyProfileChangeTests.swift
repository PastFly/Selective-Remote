import Foundation
import Testing
@testable import SelectiveRemote

private final class IsolatedPreferences: NativePreferencesAccess {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func synchronize() -> Bool { true }
    func dictionaryRepresentation() -> [String: Any] { values }
}

@Test("Late legacy profile writes are detected without modifying either collection")
func detectsLateLegacyProfileWrite() throws {
    let defaults = IsolatedPreferences()
    let key = "SelectiveRemote.connectionProfiles.v2"
    let target = try #require(NativeStorageMigration.newKey(for: key))
    let original = Data("[]".utf8)
    let late = Data("[{\"host\":\"late.invalid\"}]".utf8)
    let current = Data("[{\"host\":\"current.invalid\"}]".utf8)
    defaults.set(original, forKey: key)
    try NativeStorageMigration.prepare(defaults)
    #expect(try !LegacyProfileChangeDetector.hasChanges(defaults))
    defaults.set(current, forKey: target)
    #expect(try !LegacyProfileChangeDetector.hasChanges(defaults))
    defaults.set(late, forKey: key)
    #expect(try LegacyProfileChangeDetector.hasChanges(defaults))
    #expect(defaults.object(forKey: key) as? Data == late)
    #expect(defaults.object(forKey: target) as? Data == current)
    defaults.set(original, forKey: key)
    #expect(try !LegacyProfileChangeDetector.hasChanges(defaults))
}

@Test("Legacy single-profile additions and removals are detected")
func detectsLegacySingleProfileAdditionAndRemoval() throws {
    let defaults = IsolatedPreferences()
    let key = "SelectiveRemote.connectionProfile.v1"
    try NativeStorageMigration.prepare(defaults)
    #expect(try !LegacyProfileChangeDetector.hasChanges(defaults))
    defaults.set(Data("{\"host\":\"late.invalid\"}".utf8), forKey: key)
    #expect(try LegacyProfileChangeDetector.hasChanges(defaults))
    defaults.set(nil, forKey: key)
    #expect(try !LegacyProfileChangeDetector.hasChanges(defaults))
}

@Test("Missing or damaged migration metadata cannot be mistaken for no changes")
func rejectsUnverifiableLegacyComparison() throws {
    let defaults = IsolatedPreferences()
    #expect(throws: NativeStorageMigration.MigrationError.self) {
        try LegacyProfileChangeDetector.hasChanges(defaults)
    }
    try NativeStorageMigration.prepare(defaults)
    defaults.set(Data("invalid".utf8), forKey: "SelectiveRemote.native032.migration.snapshot.v1")
    #expect(throws: NativeStorageMigration.MigrationError.self) {
        try LegacyProfileChangeDetector.hasChanges(defaults)
    }
}

@Test("Equivalent legacy profiles do not warn for JSON ordering or omitted defaults")
func equivalentLegacyProfilesDoNotWarn() throws {
    let defaults = IsolatedPreferences()
    let key = "SelectiveRemote.connectionProfiles.v2"
    let original = Data("""
    [{"id":"00000000-0000-0000-0000-000000000001","host":"same.invalid","username":"demo"}]
    """.utf8)
    let equivalent = Data("""
    [{ "username":"demo", "host":"same.invalid", "group":"", "id":"00000000-0000-0000-0000-000000000001" }]
    """.utf8)
    defaults.set(original, forKey: key)
    try NativeStorageMigration.prepare(defaults)
    defaults.set(equivalent, forKey: key)
    #expect(try !LegacyProfileChangeDetector.hasChanges(defaults))
}

@Test("An unknown legacy profile field change cannot be silently ignored")
func unknownLegacyProfileChangeWarns() throws {
    let defaults = IsolatedPreferences()
    let key = "SelectiveRemote.connectionProfiles.v2"
    defaults.set(Data("[{\"host\":\"same.invalid\",\"futureSetting\":1}]".utf8), forKey: key)
    try NativeStorageMigration.prepare(defaults)
    defaults.set(Data("[{\"host\":\"same.invalid\",\"futureSetting\":2}]".utf8), forKey: key)
    #expect(try LegacyProfileChangeDetector.hasChanges(defaults))
}

@Test("An unknown nested legacy setting cannot be silently ignored")
func unknownNestedLegacyProfileChangeWarns() throws {
    let defaults = IsolatedPreferences()
    let key = "SelectiveRemote.connectionProfiles.v2"
    var profile = ConnectionProfile()
    profile.host = "same.invalid"
    profile.portForwards = [PortForwardRule()]
    let encoded = try JSONEncoder().encode([profile])
    var values = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
    var forwards = try #require(values[0]["portForwards"] as? [[String: Any]])
    forwards[0]["futureOption"] = 1
    values[0]["portForwards"] = forwards
    defaults.set(try JSONSerialization.data(withJSONObject: values), forKey: key)
    try NativeStorageMigration.prepare(defaults)
    forwards[0]["futureOption"] = 2
    values[0]["portForwards"] = forwards
    defaults.set(try JSONSerialization.data(withJSONObject: values), forKey: key)
    #expect(try LegacyProfileChangeDetector.hasChanges(defaults))
}

@Test("Changing or deleting an existing legacy Host is detected")
func detectsLegacyHostEditAndDeletion() throws {
    let defaults = IsolatedPreferences()
    let key = "SelectiveRemote.connectionProfiles.v2"
    var profile = ConnectionProfile()
    profile.host = "before.invalid"
    defaults.set(try JSONEncoder().encode([profile]), forKey: key)
    try NativeStorageMigration.prepare(defaults)
    profile.host = "after.invalid"
    defaults.set(try JSONEncoder().encode([profile]), forKey: key)
    #expect(try LegacyProfileChangeDetector.hasChanges(defaults))
    defaults.set(nil, forKey: key)
    #expect(try LegacyProfileChangeDetector.hasChanges(defaults))
}

@Test("Generated timestamps and display-set ordering do not create a false warning")
func equivalentGeneratedTimestampAndDisplayOrderDoNotWarn() throws {
    let defaults = IsolatedPreferences()
    let key = "SelectiveRemote.connectionProfiles.v2"
    defaults.set(Data("""
    [{"id":"00000000-0000-0000-0000-000000000001","host":"same.invalid","selectedDisplayIDs":["a","b"]}]
    """.utf8), forKey: key)
    try NativeStorageMigration.prepare(defaults)
    defaults.set(Data("""
    [{"id":"00000000-0000-0000-0000-000000000001","host":"same.invalid","createdAt":0,"selectedDisplayIDs":["b","a"]}]
    """.utf8), forKey: key)
    #expect(try !LegacyProfileChangeDetector.hasChanges(defaults))
}

@Test("Malformed changed legacy data produces an unverified state")
func malformedLegacyDataCannotLookUnchanged() throws {
    let defaults = IsolatedPreferences()
    let key = "SelectiveRemote.connectionProfiles.v2"
    defaults.set(Data("[]".utf8), forKey: key)
    try NativeStorageMigration.prepare(defaults)
    defaults.set(Data("broken".utf8), forKey: key)
    #expect(throws: (any Error).self) {
        try LegacyProfileChangeDetector.hasChanges(defaults)
    }
}
