import SwiftUI

struct SyncCenterView: View {
    @ObservedObject private var sync = SyncPresentationStore.shared
    @ObservedObject private var language = AppLanguageStore.shared
    let onOpenCloudSettings: () -> Void
    let onOpenCloudManagement: () -> Void
    let onOpenDiagnostics: () -> Void

    private var english: Bool { language.selection.usesEnglish }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(english ? "Sync Center" : "Центр синхронизации")
                        .font(.title2.bold())
                    Text(sync.aggregate.title(english: english))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: symbol(for: sync.aggregate))
                    .font(.title2)
                    .foregroundStyle(color(for: sync.aggregate))
                    .accessibilityHidden(true)
            }

            scopeCard(sync.personal, title: english ? "Personal Vault" : "Личный Vault")
            scopeCard(sync.team, title: english ? "Team Vaults" : "Командные Vaults")

            HStack {
                Button(english ? "Cloud Settings" : "Настройки Cloud", action: onOpenCloudSettings)
                Button(english ? "Diagnostics" : "Диагностика", action: onOpenDiagnostics)
                Spacer()
            }
        }
        .padding(24)
        }
        .frame(minWidth: 320, idealWidth: 540, minHeight: 360)
    }

    private func scopeCard(_ snapshot: SyncScopeSnapshot, title: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: symbol(for: snapshot.lifecycle))
                    .foregroundStyle(color(for: snapshot.lifecycle))
                    .accessibilityHidden(true)
                Text(title).font(.headline)
                Spacer()
                Text(snapshot.lifecycle.title(english: english))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let date = snapshot.lastConfirmedAt {
                HStack(spacing: 5) {
                    Text(english ? "Last confirmed on this Mac:" : "Последнее подтверждение на этом Mac:")
                    Text(date, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(date.formatted(date: .complete, time: .standard))
            }
            if let revision = snapshot.appliedRevision {
                Text(english ? "Applied revision r\(revision)" : "Применённая ревизия r\(revision)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if snapshot.scope == .team {
                if let count = snapshot.checkedVaultCount {
                    Text(english ? "Vaults checked: \(count)" : "Проверено Vaults: \(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(english
                     ? "Per-Vault confirmation is not available on this Mac yet."
                     : "Подтверждение для каждого Vault на этом Mac пока недоступно.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if snapshot.materialization == .hiddenFailClosed {
                Text(english
                     ? "This Mac has not applied one or more Team Vaults. Review access or key rotation in Cloud."
                     : "Этот Mac не применил один или несколько командных Vaults. Проверьте доступ или ротацию ключа в Cloud.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if snapshot.scope == .team,
               snapshot.issue == .conflict || snapshot.issue == .keyOrWrapperMissing
                || snapshot.issue == .rotationRequired {
                Button(english ? "Open Team management" : "Открыть управление командами",
                       action: onOpenCloudManagement)
            } else if snapshot.scope == .personal, snapshot.issue == .conflict {
                Button(english ? "Open Cloud Settings" : "Открыть настройки Cloud",
                       action: onOpenCloudSettings)
            }
            Button(english ? "Retry \(snapshot.scope == .personal ? "Personal" : "Team")" :
                    "Повторить: \(snapshot.scope == .personal ? "личный Vault" : "командные Vaults")") {
                sync.retry(snapshot.scope)
            }
            .disabled([.syncing, .signedOut, .locked, .disabled].contains(snapshot.lifecycle))
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private func symbol(for lifecycle: SyncLifecycle) -> String {
        switch lifecycle {
        case .security, .error, .conflict: "exclamationmark.triangle.fill"
        case .syncing: "arrow.triangle.2.circlepath"
        case .synced: "checkmark.circle.fill"
        case .offline: "wifi.slash"
        case .locked: "lock.fill"
        default: "questionmark.circle"
        }
    }

    private func color(for lifecycle: SyncLifecycle) -> Color {
        switch lifecycle {
        case .security, .error, .conflict: .orange
        case .synced: .green
        default: .secondary
        }
    }
}
