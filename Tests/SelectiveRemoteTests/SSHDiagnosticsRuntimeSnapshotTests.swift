import Foundation
import Testing
@testable import SelectiveRemote

@Suite("SSH diagnostics language snapshots")
struct SSHDiagnosticsRuntimeSnapshotTests {
    @Test("Completed results are visible only in their generation language")
    func snapshotVisibility() {
        let item = SSHDiagnosticItem(title: "Аутентификация", detail: "Данные", ok: true)
        let snapshot = SSHDiagnosticResultSnapshot(items: [item], english: false)

        #expect(snapshot.visibleItems(english: false).map(\.title) == ["Аутентификация"])
        #expect(snapshot.visibleItems(english: true).isEmpty)
        #expect(snapshot.isStale(english: true))
    }

    @Test("Results finishing after a language switch are discarded")
    func discardInFlightResult() {
        let item = SSHDiagnosticItem(title: "TCP", detail: "reachable", ok: true)
        #expect(SSHDiagnosticResultSnapshot.completed(
            items: [item], startedInEnglish: false, currentEnglish: true
        )?.english == nil)
    }

    @Test("Diagnostic copy uses captured language regardless of current preference")
    func capturedLanguageCopy() {
        #expect(SSHDiagnosticCopy.localized(ru: "Проверка", en: "Check", english: false) == "Проверка")
        #expect(SSHDiagnosticCopy.localized(ru: "Проверка", en: "Check", english: true) == "Check")
    }
}
