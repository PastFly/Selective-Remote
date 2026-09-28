import Testing
@testable import SelectiveRemote

@Suite("Global Sync status utility")
struct SyncStatusUtilityTests {
    @Test("Typed lifecycle produces concise RU and EN service status")
    func localizedStates() {
        let cases: [(SyncLifecycle, String, String, String, String, String)] = [
            (.synced, "Синхронизировано", "Synced", "Синхронизировано", "Synced", "checkmark.circle.fill"),
            (.syncing, "Синхронизация…", "Syncing…", "Синхронизация…", "Syncing…", "arrow.triangle.2.circlepath"),
            (.unknown, "Состояние неизвестно", "Status unknown", "Неизвестно", "Unknown", "questionmark.circle"),
            (.error, "Ошибка синхронизации", "Sync failed", "Ошибка", "Failed", "exclamationmark.triangle.fill"),
            (.conflict, "Конфликт", "Conflict", "Конфликт", "Conflict", "exclamationmark.triangle.fill"),
            (.security, "Требуется действие", "Action required", "Требуется действие", "Action required", "exclamationmark.triangle.fill"),
        ]
        for (lifecycle, russian, english, compactRussian, compactEnglish, symbol) in cases {
            #expect(SyncStatusUtilityDescriptor(lifecycle: lifecycle, english: false).title == russian)
            #expect(SyncStatusUtilityDescriptor(lifecycle: lifecycle, english: true).title == english)
            #expect(SyncStatusUtilityDescriptor(lifecycle: lifecycle, english: false).compactTitle == compactRussian)
            #expect(SyncStatusUtilityDescriptor(lifecycle: lifecycle, english: true).compactTitle == compactEnglish)
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
