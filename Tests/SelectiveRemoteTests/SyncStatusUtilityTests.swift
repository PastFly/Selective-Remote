import Testing
@testable import SelectiveRemote

@Suite("Global Sync status utility")
struct SyncStatusUtilityTests {
    @Test("Typed lifecycle produces concise RU and EN service status")
    func localizedStates() {
        let cases: [(SyncLifecycle, String, String, String)] = [
            (.synced, "Синхронизировано", "Synced", "checkmark.circle.fill"),
            (.syncing, "Синхронизация…", "Syncing…", "arrow.triangle.2.circlepath"),
            (.unknown, "Состояние неизвестно", "Status unknown", "questionmark.circle"),
            (.error, "Ошибка синхронизации", "Sync failed", "exclamationmark.triangle.fill"),
            (.conflict, "Конфликт", "Conflict", "exclamationmark.triangle.fill"),
            (.security, "Требуется действие", "Action required", "exclamationmark.triangle.fill"),
        ]
        for (lifecycle, russian, english, symbol) in cases {
            #expect(SyncStatusUtilityDescriptor(lifecycle: lifecycle, english: false).title == russian)
            #expect(SyncStatusUtilityDescriptor(lifecycle: lifecycle, english: true).title == english)
            #expect(SyncStatusUtilityDescriptor(lifecycle: lifecycle, english: true).symbolName == symbol)
        }
    }

    @Test("Prerequisite states do not present a false synced state")
    func prerequisites() {
        for lifecycle in [SyncLifecycle.signedOut, .locked, .disabled, .offline, .pending] {
            let descriptor = SyncStatusUtilityDescriptor(lifecycle: lifecycle, english: true)
            #expect(descriptor.title != "Synced")
            #expect(!descriptor.title.isEmpty)
        }
    }
}
