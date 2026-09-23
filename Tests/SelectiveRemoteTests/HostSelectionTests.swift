import Foundation
import Testing
@testable import SelectiveRemote

struct HostSelectionTests {
    @Test("Search handles hundreds of Hosts and respects Personal and Team scope")
    func filteredHostSelection() {
        let personal = (0 ..< 500).map { index in
            SelectiveRemoteHostSelectionItem(
                id: UUID(), title: "Server \(index)", address: "node\(index).example.invalid",
                folder: index.isMultiple(of: 2) ? "Ops/Linux" : "Dev/Mac",
                scope: .personal
            )
        }
        let team = SelectiveRemoteHostSelectionItem(
            id: UUID(), title: "Server 10", address: "team.example.invalid",
            folder: "Ops/Linux", context: "Platform / Shared Vault", scope: .team
        )
        let items = personal + [team]
        #expect(SelectiveRemoteHostSelectionModel.filtered(items, query: "NODE499", scope: .personal).map(\.id) == [personal[499].id])
        #expect(SelectiveRemoteHostSelectionModel.filtered(items, query: "ops/linux", scope: .team).map(\.id) == [team.id])
        #expect(SelectiveRemoteHostSelectionModel.filtered(items, query: "Shared Vault", scope: .team).map(\.id) == [team.id])
        #expect(SelectiveRemoteHostSelectionModel.filtered(items, query: "server 10", scope: .personal).allSatisfy { $0.scope == .personal })
    }

    @Test("Multi-select acts only on filtered visible Hosts")
    func filteredSelectionActions() {
        let selected = [UUID(), UUID(), UUID()]
        let visible = [selected[0], selected[1]]
        #expect(SelectiveRemoteHostSelectionModel.selectAllFiltered(
            current: [selected[2]], visibleIDs: visible
        ) == Set(selected))
        #expect(SelectiveRemoteHostSelectionModel.clearFiltered(
            current: Set(selected), visibleIDs: visible
        ) == [selected[2]])
    }
}
