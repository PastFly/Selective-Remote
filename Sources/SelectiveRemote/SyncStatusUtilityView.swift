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

/// One sidebar service block with independent Cloud and Sync actions.
struct CloudSyncServiceBlockView: View {
    let lifecycle: SyncLifecycle
    let english: Bool
    let cloudSessionAvailable: Bool
    let onCloud: () -> Void
    let onSync: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onCloud) {
                HStack(spacing: 10) {
                    Image(systemName: "cloud")
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    Text(english ? "Cloud Management" : "Управление Cloud")
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Circle()
                        .fill(cloudSessionAvailable ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 11)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(SelectiveRemoteNavigationButtonStyle(selected: false))
            .accessibilityLabel(english ? "Cloud Management" : "Управление Cloud")
            .accessibilityValue(cloudSessionAvailable
                ? (english ? "Cloud session available" : "Сеанс Cloud доступен")
                : (english ? "Cloud sign-in required" : "Требуется вход в Cloud"))
            .help(english ? "Account, Teams, and Team Vaults" : "Аккаунт, команды и Team Vaults")

            SyncStatusUtilityView(lifecycle: lifecycle, english: english, onOpen: onSync)
                .padding(.leading, 43)
                .padding(.trailing, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 22)
        }
        .frame(height: 56)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}
