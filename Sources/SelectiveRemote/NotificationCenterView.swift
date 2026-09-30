import SwiftUI

extension NotificationKind {
    func title(english: Bool) -> String {
        switch self {
        case .deviceApproval: english ? "Device waiting for approval" : "Устройство ожидает одобрения"
        case .invitation: english ? "Team invitation" : "Приглашение в команду"
        case .syncError: english ? "Sync needs attention" : "Синхронизация требует внимания"
        case .conflict: english ? "Conflict needs review" : "Конфликт требует проверки"
        case .failClosed: english ? "Team Vault needs attention" : "Командному Vault требуется внимание"
        case .wrapperIssue: english ? "Team key access needs attention" : "Требуется доступ к ключу команды"
        case .hostIdentity: english ? "Host identity changed" : "Идентичность хоста изменилась"
        case .accessGained: english ? "Team access added" : "Добавлен доступ команды"
        case .accessLost: english ? "Team access removed" : "Доступ команды удалён"
        }
    }

    func detail(english: Bool) -> String {
        switch self {
        case .deviceApproval: english ? "Review its key before approving." : "Проверьте ключ перед одобрением."
        case .invitation: english ? "An invitation awaits your decision." : "Приглашение ожидает вашего решения."
        case .syncError: english ? "Changes are not confirmed on this Mac." : "Изменения не подтверждены на этом Mac."
        case .conflict: english ? "Choose a version in the existing resolver." : "Выберите версию в существующем мастере."
        case .failClosed: english ? "Team Vaults remain safely hidden." : "Командные Vaults остаются безопасно скрытыми."
        case .wrapperIssue: english ? "Review device access in Team management." : "Проверьте доступ устройства в управлении командой."
        case .hostIdentity: english ? "The connection was stopped." : "Подключение остановлено."
        case .accessGained, .accessLost: english ? "Review access in the Team Vault." : "Проверьте доступ в Team Vault."
        }
    }

    func actionTitle(english: Bool) -> String {
        switch self {
        case .deviceApproval: english ? "Review Device" : "Проверить устройство"
        case .invitation: english ? "Open Invitation" : "Открыть приглашение"
        case .syncError: english ? "Open Sync Center" : "Открыть центр синхронизации"
        case .conflict: english ? "Review Conflict" : "Проверить конфликт"
        case .failClosed, .wrapperIssue: english ? "Review Team" : "Проверить команду"
        case .hostIdentity: english ? "Review Host Key" : "Проверить ключ хоста"
        case .accessGained, .accessLost: english ? "Review Team" : "Проверить команду"
        }
    }
}

struct NotificationCenterView: View {
    @ObservedObject var center: MacNotificationCenter
    @ObservedObject private var language = AppLanguageStore.shared
    @State private var filter: Filter = .all
    let onOpen: (NotificationItem) -> Void

    private enum Filter: String, CaseIterable {
        case all, needsAction, sync, security

        func title(english: Bool) -> String {
            switch self {
            case .all: english ? "All" : "Все"
            case .needsAction: english ? "Needs Action" : "Требуют действия"
            case .sync: "Sync"
            case .security: english ? "Security" : "Безопасность"
            }
        }
    }

    private var english: Bool { language.selection.usesEnglish }

    private var visible: [NotificationItem] {
        center.items.filter { item in
            switch filter {
            case .all: true
            case .needsAction: item.resolvedAt == nil
            case .sync: [.syncError, .conflict, .failClosed, .wrapperIssue].contains(item.kind)
            case .security: [.deviceApproval, .failClosed, .wrapperIssue, .hostIdentity, .accessGained, .accessLost].contains(item.kind)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(english ? "Notifications" : "Уведомления")
                    .font(.title3.bold())
                Spacer()
                Text(english ? "\(center.unreadCount) unread" : "Непрочитанных: \(center.unreadCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Filter.allCases, id: \.self) { option in
                        Button(option.title(english: english)) { filter = option }
                            .buttonStyle(.bordered)
                            .tint(filter == option ? .accentColor : .secondary)
                            .accessibilityAddTraits(filter == option ? [.isSelected] : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if visible.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(english ? "You're all caught up." : "Всё в порядке.")
                                .font(.headline)
                            Text(english ? "No items need your attention." :
                                    "Нет событий, требующих вашего внимания.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 20)
                    } else {
                        ForEach(visible.prefix(20)) { item in card(item) }
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 300, idealWidth: 370, maxWidth: 390, minHeight: 250, maxHeight: 530)
    }

    private func card(_ item: NotificationItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.kind.title(english: english)).font(.subheadline.bold())
                Spacer(minLength: 4)
                if item.readAt == nil && item.resolvedAt == nil {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                        .accessibilityLabel(english ? "Unread" : "Не прочитано")
                }
            }
            Text(item.kind.detail(english: english))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.lastObservedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if item.resolvedAt == nil {
                ViewThatFits(in: .horizontal) {
                    HStack { actions(item) }
                    VStack(alignment: .leading) { actions(item) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actions(_ item: NotificationItem) -> some View {
        Button(item.kind.actionTitle(english: english)) {
            center.markRead(item.id)
            onOpen(item)
        }
        if item.readAt == nil {
            Button(english ? "Mark read" : "Отметить прочитанным") {
                center.markRead(item.id)
            }
            .buttonStyle(.borderless)
        }
    }
}
