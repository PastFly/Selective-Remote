import Foundation

struct SelectiveRemotePersonalTeamCopyIdentity: Sendable {
    let hostID: UUID

    static func make(sourceID: UUID) -> Self {
        var next = UUID()
        while next == sourceID { next = UUID() }
        return Self(hostID: next)
    }

    func credentialID(kind: KeychainCredentialKind) -> UUID {
        SelectiveRemotePersonalVaultExporter.derivedID(
            sourceID: hostID, discriminator: "credential:\(kind.rawValue)"
        )
    }

    func remap(_ profile: ConnectionProfile,
               credentials: [SelectiveRemotePersonalVaultCredentialInput])
        -> (ConnectionProfile, [SelectiveRemotePersonalVaultCredentialInput]) {
        var copiedProfile = profile
        copiedProfile.id = hostID
        let copiedCredentials = credentials.map {
            SelectiveRemotePersonalVaultCredentialInput(
                sourceID: hostID, kind: $0.kind, title: $0.title,
                username: $0.username, secret: $0.secret)
        }
        return (copiedProfile, copiedCredentials)
    }
}
