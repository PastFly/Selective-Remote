import Foundation
import Testing
@testable import SelectiveRemote

@Suite("System diagnostics runtime localization")
struct SystemDiagnosticsRuntimeLocalizationTests {
    @Test("Cached check results are hidden when the app language changes")
    func hidesResultsFromPreviousLanguage() {
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let result = SystemDiagnosticCheckResult(
            id: "camera", category: "Безопасность", title: "Камера", detail: "Разрешено",
            status: .passed, action: nil
        )
        let snapshot = SystemDiagnosticResultSnapshot(
            results: [result], checkedAt: checkedAt, english: false
        )

        #expect(snapshot.visibleResults(english: false).map(\.id) == ["camera"])
        #expect(snapshot.visibleCheckedAt(english: false) == checkedAt)
        #expect(snapshot.visibleResults(english: true).isEmpty)
        #expect(snapshot.visibleCheckedAt(english: true) == nil)
        #expect(snapshot.isStale(english: true))
    }

    @Test("A check finishing after a language switch is not cached")
    func discardsInFlightOldLanguageResults() {
        let snapshot = SystemDiagnosticResultSnapshot.completed(
            results: [], checkedAt: Date(), startedInEnglish: false, currentEnglish: true
        )
        #expect(snapshot == nil)
    }
}
