import Foundation
import Testing
@testable import SelectiveRemote

@Suite("macOS Team Vault conflict review")
struct CloudVaultConflictReviewTests {
    @Test("review summaries expose bounded metadata but no credential or snippet contents")
    func redactedSummaries() throws {
        let scenario = try SelectiveRemoteVaultConflictReviewScenario.synthetic()
        #expect(scenario.conflicts.count == 2)

        let summaries = scenario.conflicts.flatMap { conflict in
            [
                SelectiveRemoteVaultConflictPresentation.side(conflict.local),
                SelectiveRemoteVaultConflictPresentation.side(conflict.remote)
            ]
        }
        let rendered = summaries.map { "\($0.title) \($0.metadata)" }.joined(separator: " ")
        #expect(rendered.contains("Production SSH"))
        #expect(rendered.contains("credential"))
        #expect(rendered.contains("must-not-render") == false)
        #expect(summaries.contains { $0.isDeletion })
    }

    @Test("manual review stays blocked until every synthetic conflict has one choice")
    func completeChoiceSet() throws {
        let scenario = try SelectiveRemoteVaultConflictReviewScenario.synthetic()
        let first = try #require(scenario.conflicts.first)
        #expect(throws: SelectiveRemoteVaultDocumentError.incompleteConflictResolutions) {
            try scenario.resolve([.init(id: first.id, choice: .local)])
        }

        let choices = scenario.conflicts.map { conflict in
            SelectiveRemoteVaultConflictResolution(
                id: conflict.id,
                choice: conflict.id == first.id ? .remote : .local
            )
        }
        let resolved = try scenario.resolve(choices)
        #expect(resolved.records.count == 2)
        #expect(resolved.tombstones.isEmpty)
        #expect(resolved.records.allSatisfy {
            $0.version.counters[scenario.resolverDeviceID] == 1
        })
    }

    @Test("choosing the remote deletion produces one joined tombstone")
    func deletionChoice() throws {
        let scenario = try SelectiveRemoteVaultConflictReviewScenario.synthetic()
        let choices = scenario.conflicts.map { conflict in
            SelectiveRemoteVaultConflictResolution(
                id: conflict.id,
                choice: SelectiveRemoteVaultConflictPresentation.side(conflict.remote).isDeletion
                    ? .remote
                    : .local
            )
        }
        let resolved = try scenario.resolve(choices)
        #expect(resolved.records.count == 1)
        #expect(resolved.tombstones.count == 1)
        #expect(resolved.tombstones[0].version.counters[scenario.resolverDeviceID] == 1)
    }
}
