import Foundation
import Testing
@testable import SelectiveRemote

struct WorkspaceUXFollowupTests {
    @Test("Host drag waits for movement and ignores interactive controls")
    func hostCardDragThreshold() {
        #expect(!SelectiveRemoteHostCardDragPolicy.shouldStart(
            horizontal: 7, vertical: 0, isInteractiveControl: false
        ))
        #expect(SelectiveRemoteHostCardDragPolicy.shouldStart(
            horizontal: 8, vertical: 0, isInteractiveControl: false
        ))
        #expect(!SelectiveRemoteHostCardDragPolicy.shouldStart(
            horizontal: 20, vertical: 0, isInteractiveControl: true
        ))
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
        ) == 420)
        #expect(SelectiveRemoteAdaptiveToolbarLayout.searchWidth(
            availableWidth: 300, reservedWidth: 44
        ) >= 190)
    }

    @Test("Snippet command uses bounded height for one or many lines")
    func snippetCommandHeight() {
        #expect(SelectiveRemoteSnippetCommandLayout.height(for: "ifconfig") == 72)
        #expect(SelectiveRemoteSnippetCommandLayout.height(
            for: Array(repeating: "printf ok", count: 30).joined(separator: "\n")
        ) == 260)
    }
}
