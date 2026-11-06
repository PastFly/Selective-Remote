import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Personal Vault imported numeric fields")
struct PersonalVaultImportNumberSafetyTests {
    @Test("out-of-range and fractional ports cannot trap or become a port", arguments: [
        Double(Int.max), Double(Int.min).nextDown, Double.greatestFiniteMagnitude, 22.5
    ])
    func ignoresInvalidPort(_ port: Double) throws {
        let profile = try importedProfile(port: port)
        #expect(profile.sshPort == 22)
    }

    @Test("valid browser ports survive import", arguments: [1, 22, 65_535])
    func preservesValidPort(_ port: Int) throws {
        let profile = try importedProfile(port: Double(port))
        #expect(profile.sshPort == port)
    }

    private func importedProfile(port: Double) throws -> ConnectionProfile {
        let record = try SelectiveRemoteVaultRecord(
            id: UUID(),
            type: .host,
            version: .init([UUID(): 1]),
            modifiedAt: "2026-10-28T00:00:00.000Z",
            data: .object([
                "title": .string("Synthetic host"),
                "address": .string("synthetic.example.invalid"),
                "connectionType": .string("ssh"),
                "port": .number(port)
            ])
        )
        let document = try SelectiveRemoteVaultDocument(records: [record])
        // Exercise the actual JSON decode and browser-record import boundary.
        let decoded = try SelectiveRemoteVaultDocument.decode(document.encoded())
        return try #require(SelectiveRemotePersonalVaultImporter.decode(decoded).profiles.first)
    }
}
