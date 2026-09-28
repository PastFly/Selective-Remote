import SwiftUI

struct SyncStatusUtilityDescriptor {
    let title: String
    let symbolName: String
    let tint: Color

    init(lifecycle: SyncLifecycle, english: Bool) {
        switch lifecycle {
        case .synced:
            title = english ? "Synced" : "Синхронизировано"
            symbolName = "checkmark.circle.fill"
            tint = .green
        case .syncing:
            title = english ? "Syncing…" : "Синхронизация…"
            symbolName = "arrow.triangle.2.circlepath"
            tint = .accentColor
        case .unknown:
            title = english ? "Status unknown" : "Состояние неизвестно"
            symbolName = "questionmark.circle"
            tint = .secondary
        case .error:
            title = english ? "Sync failed" : "Ошибка синхронизации"
            symbolName = "exclamationmark.triangle.fill"
            tint = .orange
        case .conflict:
            title = english ? "Conflict" : "Конфликт"
            symbolName = "exclamationmark.triangle.fill"
            tint = .orange
        case .security:
            title = english ? "Action required" : "Требуется действие"
            symbolName = "exclamationmark.triangle.fill"
            tint = .orange
        case .offline:
            title = english ? "Offline" : "Нет сети"
            symbolName = "wifi.slash"
            tint = .secondary
        case .pending:
            title = english ? "Awaiting confirmation" : "Ожидает подтверждения"
            symbolName = "clock"
            tint = .secondary
        case .signedOut:
            title = english ? "Sign in required" : "Требуется вход"
            symbolName = "person.crop.circle.badge.xmark"
            tint = .secondary
        case .locked:
            title = english ? "Unlock required" : "Требуется разблокировка"
            symbolName = "lock.fill"
            tint = .secondary
        case .disabled:
            title = english ? "Sync disabled" : "Синхронизация выключена"
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
                Text(descriptor.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background(descriptor.tint.opacity(0.09), in: Capsule())
            .overlay(Capsule().strokeBorder(descriptor.tint.opacity(0.22)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(english ? "Sync status: \(descriptor.title)" : "Состояние синхронизации: \(descriptor.title)")
        .accessibilityHint(english ? "Open Sync Center" : "Открыть Центр синхронизации")
        .help(english ? "Open Sync Center" : "Открыть Центр синхронизации")
    }
}
