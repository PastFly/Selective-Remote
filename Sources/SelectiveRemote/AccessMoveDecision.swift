import Foundation

enum AccessMoveDecision: Sendable {
    case persistLegacyOrReorder
    case registeredMappingRequired
    case publicationRequired

    static func decide(formatState: CloudAccessFormatState, changesAncestry: Bool) -> Self {
        guard changesAncestry else { return .persistLegacyOrReorder }
        switch formatState {
        case .v1Active: return .persistLegacyOrReorder
        case .preparing: return .registeredMappingRequired
        case .ready, .active: return .publicationRequired
        }
    }

    static func fetch(teamID: UUID, vaultID: UUID, endpoint: URL,
                      client: SelectiveRemoteCloudAPIClient,
                      changesAncestry: Bool) async throws -> Self {
        guard changesAncestry else { return .persistLegacyOrReorder }
        let reference = try SelectiveRemoteCloudAccessReference(
            teamID: teamID, vaultID: vaultID, resourceID: vaultID, kind: .vault
        )
        let context = try await SelectiveRemoteCloudAccessClient(client: client)
            .context(reference, session: .init(endpoint: endpoint))
        return decide(formatState: context.formatState, changesAncestry: true)
    }

    var explanation: String? {
        switch self {
        case .persistLegacyOrReorder: nil
        case .registeredMappingRequired: CloudAccessLocalization.text(
            "Сначала требуется подтверждённое соответствие записи и папки ресурсам реестра V2. Перенос не сохранён.",
            "A verified mapping from the record and folder to V2 registry resources is required first. The move was not saved."
        )
        case .publicationRequired: CloudAccessLocalization.text(
            "Перенос требует новой криптографической публикации Vault. Изменение не сохранено.",
            "The move requires a new cryptographic Vault publication. The change was not saved."
        )
        }
    }
}
