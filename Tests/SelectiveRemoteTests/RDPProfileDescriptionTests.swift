import Foundation
import Testing
@testable import SelectiveRemote

struct RDPProfileDescriptionTests {
    @Test("Old profiles without description remain compatible")
    func legacyProfileWithoutDescriptionDecodes() throws {
        let data = Data(
            #"{"friendlyName":"Legacy RDP","host":"legacy.example.local"}"#.utf8
        )
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)

        #expect(profile.friendlyName == "Legacy RDP")
        #expect(profile.host == "legacy.example.local")
        #expect(profile.profileDescription.isEmpty)
    }

    @Test("Profile description survives Codable round trip")
    func descriptionCodableRoundTrip() throws {
        var profile = ConnectionProfile(connectionType: .rdp)
        profile.friendlyName = "Accounting PC"
        profile.profileDescription = "Primary workstation for the accounting team."

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)

        #expect(decoded.profileDescription == profile.profileDescription)
    }

    @Test("Selective Remote archive preserves profile description")
    func archivePreservesDescription() throws {
        var profile = ConnectionProfile(connectionType: .rdp)
        profile.friendlyName = "Archive Test"
        profile.profileDescription = "Saved note"

        let data = try SelectiveRemoteProfileCodec.encode([profile])
        let decoded = try SelectiveRemoteProfileCodec.decode(data)

        #expect(decoded.count == 1)
        #expect(decoded.first?.profileDescription == "Saved note")
    }
}
