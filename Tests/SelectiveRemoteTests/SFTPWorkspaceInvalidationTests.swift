import Combine
import Foundation
import Testing
@testable import SelectiveRemote

@Test("SFTP transfer activity ignores progress-only changes")
func sftpTransferActivityIgnoresProgressOnlyChanges() {
    let running = transferItem(
        phase: .running,
        transferredBytes: 10,
        bytesPerSecond: 100
    )
    let progressed = transferItem(
        id: running.id,
        phase: .running,
        transferredBytes: 80,
        bytesPerSecond: 700
    )

    #expect(
        SFTPTransferActivitySnapshot(items: [running])
            == SFTPTransferActivitySnapshot(items: [progressed])
    )
}

@Test("SFTP transfer activity changes for pause and completion")
func sftpTransferActivityTracksLifecycleChanges() {
    let id = UUID()
    let running = SFTPTransferActivitySnapshot(items: [
        transferItem(id: id, phase: .running)
    ])
    let paused = SFTPTransferActivitySnapshot(items: [
        transferItem(id: id, phase: .paused)
    ])
    let completed = SFTPTransferActivitySnapshot(items: [
        transferItem(id: id, phase: .completed)
    ])

    #expect(running.hasItems)
    #expect(running.activeCount == 1)
    #expect(!running.hasPausedTransfers)

    #expect(paused.activeCount == 1)
    #expect(paused.hasPausedTransfers)
    #expect(paused != running)

    #expect(completed.hasItems)
    #expect(completed.activeCount == 0)
    #expect(!completed.hasPausedTransfers)
    #expect(completed != paused)
}

@MainActor
@Test("SFTP pane does not bubble file-list leaf updates")
func sftpPaneDoesNotBubbleLeafUpdates() {
    let pane = SFTPWorkspacePane(kind: .local)
    var changeCount = 0
    let cancellable = pane.objectWillChange.sink {
        changeCount += 1
    }

    let baseline = changeCount
    pane.session.local.filterText = "local-filter"
    pane.session.remote.filterText = "remote-filter"

    #expect(changeCount == baseline)
    _ = cancellable
}

@MainActor
@Test("SFTP pane still publishes structural changes")
func sftpPanePublishesStructuralChanges() {
    let pane = SFTPWorkspacePane(kind: .local)
    var changeCount = 0
    let cancellable = pane.objectWillChange.sink {
        changeCount += 1
    }

    let baseline = changeCount
    pane.title = "Renamed pane"

    #expect(changeCount > baseline)
    _ = cancellable
}

private func transferItem(
    id: UUID = UUID(),
    phase: SFTPTransferPhase,
    transferredBytes: Int64 = 0,
    bytesPerSecond: Double = 0
) -> SFTPTransferItem {
    SFTPTransferItem(
        id: id,
        direction: .upload,
        name: "test.bin",
        source: "/tmp/test.bin",
        destination: "/remote/test.bin",
        totalBytes: 100,
        createdAt: Date(timeIntervalSince1970: 0),
        phase: phase,
        transferredBytes: transferredBytes,
        bytesPerSecond: bytesPerSecond,
        errorMessage: nil
    )
}
