import Foundation
import Testing
@testable import SelectiveRemote

struct WorkspaceUXFollowupTests {
    @Test("Host drag identities remain scoped to their authentication collection")
    func hostDragIdentities() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        #expect(SelectiveRemoteHostDragIdentity.personalHost(id).value == "personal-host:\(id.uuidString)")
        #expect(SelectiveRemoteHostDragIdentity.teamHost(id).value == "team-host:\(id.uuidString)")
        #expect(SelectiveRemoteHostDragIdentity.personalFolder("Work/Test").value == "personal-folder:Work/Test")
        #expect(SelectiveRemoteHostDragIdentity.personalHost(id).value
            != SelectiveRemoteHostDragIdentity.teamHost(id).value)
    }
    @Test("Team folder drag preserves vault and path scope")
    func teamFolderDragIdentity() {
        let vaultID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        #expect(SelectiveRemoteHostDragIdentity.teamFolder(vaultID: vaultID, path: "Work/Test").value
            == "team-folder:\(vaultID.uuidString):Work/Test")
    }

    @Test("Team Host duplication prepares a new record without carrying shared credentials")
    func teamHostDuplicateDraft() {
        let profile = ConnectionProfile(connectionType: .ssh)
        let request = SelectiveRemoteTeamHostEditorRequest.duplicateDraft(
            profile: profile,
            context: .init(
                id: UUID(), teamID: UUID(), teamName: "Synthetic",
                role: .owner, vaultID: UUID(), vaultName: "Synthetic"
            )
        )
        #expect(request.host == nil)
        #expect(request.seedProfile?.id != profile.id)
        #expect(request.seedProfile?.connectionType == profile.connectionType)
    }

    @Test("Host catalog respects saved collapse preference and compact width")
    func hostCatalogVisibility() {
        #expect(SelectiveRemoteHostCatalogLayout.showsCatalog(
            preference: true, availableWidth: 1100, detailVisible: true
        ))
        #expect(!SelectiveRemoteHostCatalogLayout.showsCatalog(
            preference: false, availableWidth: 1100, detailVisible: true
        ))
        #expect(!SelectiveRemoteHostCatalogLayout.showsCatalog(
            preference: true, availableWidth: 600, detailVisible: true
        ))
        #expect(SelectiveRemoteHostCatalogLayout.showsCatalog(
            preference: true, availableWidth: 600, detailVisible: false
        ))
    }

    @Test("Toolbar keeps search useful and moves secondary actions into overflow")
    func adaptiveToolbarContract() {
        #expect(SelectiveRemoteAdaptiveToolbarLayout.mode(
            availableWidth: 1080, regularControlsWidth: 590
        ) == .regular)
        #expect(SelectiveRemoteAdaptiveToolbarLayout.mode(
            availableWidth: 540, regularControlsWidth: 590
        ) == .compact)
        #expect(SelectiveRemoteAdaptiveToolbarLayout.searchWidth(
            availableWidth: 1080, reservedWidth: 590
        ) == 482)
        #expect(SelectiveRemoteAdaptiveToolbarLayout.searchWidth(
            availableWidth: 1080, reservedWidth: 160
        ) == 780)
        #expect(SelectiveRemoteAdaptiveToolbarLayout.searchWidth(
            availableWidth: 300, reservedWidth: 44
        ) >= 190)
        #expect(SelectiveRemoteAdaptiveToolbarLayout.searchWidth(
            availableWidth: 220, reservedWidth: 44
        ) <= 168)
    }

    @Test("SSH Host header prioritizes reachable controls at compact widths")
    func compactSSHHeaderModes() {
        #expect(SelectiveRemoteSSHHeaderLayout.mode(width: 960) == .regular)
        #expect(SelectiveRemoteSSHHeaderLayout.mode(width: 650) == .compact)
        #expect(SelectiveRemoteSSHHeaderLayout.mode(width: 390) == .minimum)
    }

    @Test("Terminal toolbar places secondary actions into overflow before clipping")
    func compactTerminalToolbarModes() {
        #expect(SelectiveRemoteTerminalToolbarLayout.mode(width: 1100) == .regular)
        #expect(SelectiveRemoteTerminalToolbarLayout.mode(width: 620) == .compact)
        #expect(SelectiveRemoteTerminalToolbarLayout.mode(width: 360) == .minimum)
    }

    @Test("Snippet command uses bounded height for one or many lines")
    func snippetCommandHeight() {
        #expect(SelectiveRemoteSnippetCommandLayout.height(for: "ifconfig") == 72)
        #expect(SelectiveRemoteSnippetCommandLayout.height(
            for: Array(repeating: "printf ok", count: 30).joined(separator: "\n")
        ) == 260)
    }
}
