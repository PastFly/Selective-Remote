import Foundation
import AppKit
import SwiftUI
import Testing
@testable import SelectiveRemote

struct WorkspaceUXFollowupTests {
    @Test("A Host card click never starts a drag, while movement starts exactly one")
    func hostCardPointerSequence() {
        var pointer = SelectiveRemoteHostCardPointerSequence(threshold: 4)
        pointer.press(at: CGPoint(x: 8, y: 8))
        #expect(pointer.move(to: CGPoint(x: 10, y: 10)) == .none)
        #expect(pointer.release() == .select)

        pointer.press(at: CGPoint(x: 50, y: 20))
        #expect(pointer.move(to: CGPoint(x: 55, y: 20)) == .beginDrag)
        #expect(pointer.move(to: CGPoint(x: 80, y: 20)) == .none)
        #expect(pointer.release() == .none)
    }

    @Test("Card pointer behavior is independent of content position and collection surface")
    func hostCardPointerCoverage() {
        for start in [CGPoint(x: 2, y: 2), CGPoint(x: 35, y: 15),
                      CGPoint(x: 130, y: 40), CGPoint(x: 265, y: 65)] {
            var pointer = SelectiveRemoteHostCardPointerSequence(threshold: 4)
            pointer.press(at: start)
            #expect(pointer.move(to: CGPoint(x: start.x + 6, y: start.y)) == .beginDrag)
            #expect(pointer.release() == .none)
        }
    }

    @Test("Selecting the current Host does not request another workspace transition")
    func hostSelectionTransition() {
        #expect(!SelectiveRemoteHostSelectionTransition.needsTransition(
            currentID: "a", requestedID: "a", detailsVisible: true, alreadyInHosts: true
        ))
        #expect(SelectiveRemoteHostSelectionTransition.needsTransition(
            currentID: "a", requestedID: "b", detailsVisible: true, alreadyInHosts: true
        ))
        #expect(SelectiveRemoteHostSelectionTransition.needsTransition(
            currentID: "a", requestedID: "a", detailsVisible: false, alreadyInHosts: true
        ))
    }

    @Test("Arrow keys choose a card in the requested direction within one surface")
    func hostCardKeyboardNavigation() {
        let cards = [
            CGRect(x: 0, y: 100, width: 100, height: 40),
            CGRect(x: 110, y: 100, width: 100, height: 40),
            CGRect(x: 0, y: 20, width: 100, height: 40),
            CGRect(x: 110, y: 20, width: 100, height: 40)
        ]
        #expect(SelectiveRemoteHostCardNavigation.nextIndex(
            from: 0, direction: .right, frames: cards
        ) == 1)
        #expect(SelectiveRemoteHostCardNavigation.nextIndex(
            from: 0, direction: .down, frames: cards
        ) == 2)
        #expect(SelectiveRemoteHostCardNavigation.nextIndex(
            from: 3, direction: .up, frames: cards
        ) == 1)
        #expect(SelectiveRemoteHostCardNavigation.nextIndex(
            from: 3, direction: .left, frames: cards
        ) == 2)
        #expect(SelectiveRemoteHostCardNavigation.nextIndex(
            from: 0, direction: .up, frames: cards
        ) == nil)
    }

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

    @Test("Team Host creation keeps the selected Vault and folder without copying secrets")
    func teamHostCreateDraft() {
        let vaultID = UUID()
        let context = SelectiveRemoteTeamHostVaultContext(
            id: UUID(), teamID: UUID(), teamName: "Synthetic",
            role: .owner, vaultID: vaultID, vaultName: "Synthetic"
        )
        let request = SelectiveRemoteTeamHostEditorRequest.newDraft(
            in: "Parent/Child", context: context
        )
        #expect(request.context.vaultID == vaultID)
        #expect(request.host == nil)
        #expect(request.seedProfile?.group == "Parent/Child")
        #expect(request.seedProfile?.username.isEmpty == true)
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

    @MainActor
    @Test("Measured toolbar keeps priority actions before reducing to overflow")
    func measuredPriorityToolbarRenderedFit() {
        func actionColor(at width: CGFloat) -> NSColor {
            let view = SelectiveRemoteMeasuredPriorityToolbar {
                Color.gray.frame(height: 32)
            } controls: {
                Color.red.frame(width: 260, height: 32)
            } priority: {
                Color.green.frame(width: 120, height: 32)
            } primary: {
                Color.orange.frame(width: 50, height: 32)
            } overflow: {
                Color.blue.frame(width: 35, height: 32)
            }
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: width, height: 36)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            let image = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: 36,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            )!
            host.cacheDisplay(in: host.bounds, to: image)
            return image.colorAt(x: Int(width) - 20, y: 18)!.usingColorSpace(.deviceRGB)!
        }

        #expect(actionColor(at: 500).redComponent > 0.8)
        #expect(actionColor(at: 380).greenComponent > 0.4)
        #expect(actionColor(at: 210).redComponent > 0.8) // orange primary action
        #expect(actionColor(at: 140).blueComponent > 0.8)
    }

    @Test("Snippet command uses bounded height for one or many lines")
    func snippetCommandHeight() {
        #expect(SelectiveRemoteSnippetCommandLayout.height(for: "ifconfig") == 72)
        #expect(SelectiveRemoteSnippetCommandLayout.height(
            for: Array(repeating: "printf ok", count: 30).joined(separator: "\n")
        ) == 260)
    }
}
