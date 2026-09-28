import SwiftUI

struct SyncStatusUtilityDescriptor {
    let title: String
    let compactTitle: String
    let symbolName: String
    let tint: Color

    init(lifecycle: SyncLifecycle, english: Bool) {
        switch lifecycle {
        case .synced:
            title = english ? "Synced" : "Синхронизировано"
            compactTitle = title
            symbolName = "checkmark.circle.fill"
            tint = .green
        case .syncing:
            title = english ? "Syncing…" : "Синхронизация…"
            compactTitle = title
            symbolName = "arrow.triangle.2.circlepath"
            tint = .accentColor
        case .unknown:
            title = english ? "Status unknown" : "Состояние неизвестно"
            compactTitle = english ? "Unknown" : "Неизвестно"
            symbolName = "questionmark.circle"
            tint = .secondary
        case .error:
            title = english ? "Sync failed" : "Ошибка синхронизации"
            compactTitle = english ? "Failed" : "Ошибка"
            symbolName = "exclamationmark.triangle.fill"
            tint = .orange
        case .conflict:
            title = english ? "Conflict" : "Конфликт"
            compactTitle = title
            symbolName = "exclamationmark.triangle.fill"
            tint = .orange
        case .security:
            title = english ? "Action required" : "Требуется действие"
            compactTitle = title
            symbolName = "exclamationmark.triangle.fill"
            tint = .orange
        case .offline:
            title = english ? "Offline" : "Нет сети"
            compactTitle = title
            symbolName = "wifi.slash"
            tint = .secondary
        case .pending:
            title = english ? "Awaiting confirmation" : "Ожидает подтверждения"
            compactTitle = english ? "Pending" : "Ожидает проверки"
            symbolName = "clock"
            tint = .secondary
        case .signedOut:
            title = english ? "Sign in required" : "Требуется вход"
            compactTitle = english ? "Sign in" : "Нужен вход"
            symbolName = "person.crop.circle.badge.xmark"
            tint = .secondary
        case .locked:
            title = english ? "Unlock required" : "Требуется разблокировка"
            compactTitle = english ? "Unlock" : "Разблокировать"
            symbolName = "lock.fill"
            tint = .secondary
        case .disabled:
            title = english ? "Sync disabled" : "Синхронизация выключена"
            compactTitle = english ? "Disabled" : "Выключена"
            symbolName = "pause.circle"
            tint = .secondary
        }
    }
}

struct SyncStatusUtilityView: View {
    let lifecycle: SyncLifecycle
    let english: Bool
    let onOpen: () -> Void

    var body: some View {
        let descriptor = SyncStatusUtilityDescriptor(lifecycle: lifecycle, english: english)
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: descriptor.symbolName)
                    .foregroundStyle(descriptor.tint)
                    .accessibilityHidden(true)
                Text(descriptor.compactTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.caption)
            .frame(minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(english ? "Sync status: \(descriptor.title)" : "Состояние синхронизации: \(descriptor.title)")
        .accessibilityHint(english ? "Open Sync Center" : "Открыть Центр синхронизации")
        .help(english ? "Open Sync Center" : "Открыть Центр синхронизации")
    }
}
