import SwiftUI

struct SelectiveRemoteCloudTeamInvitationPrompt: ViewModifier {
    @AppStorage("SelectiveRemote.cloud.endpoint.v1")
    private var endpoint = SelectiveRemoteCloudEndpoint.production

    @State private var invitation: SelectiveRemoteCloudTeamInvitation?
    @State private var dismissedInvitationIDs: Set<UUID> = []
    @State private var isAccepting = false
    @State private var errorMessage: String?

    private let client = SelectiveRemoteCloudAPIClient()

    func body(content: Content) -> some View {
        content
            .task { await pollForInvitations() }
            .sheet(item: $invitation) { value in
                invitationSheet(value)
            }
    }

    @ViewBuilder
    private func invitationSheet(_ value: SelectiveRemoteCloudTeamInvitation) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label {
                Text(UpdateLocalization.text(
                    ru: "Приглашение в команду",
                    en: "Team invitation"
                ))
                .font(.title2.bold())
            } icon: {
                Image(systemName: "person.3.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(value.teamName ?? "Team")
                    .font(.headline)
                Text(UpdateLocalization.text(
                    ru: "Вас пригласили с ролью «\(roleTitle(value.role))». После принятия общие хосты и Vaults появятся в приложении автоматически.",
                    en: "You were invited as \(roleTitle(value.role)). Shared hosts and Vaults will appear automatically after you accept."
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            HStack {
                Button(UpdateLocalization.text(ru: "Позже", en: "Later")) {
                    dismissedInvitationIDs.insert(value.id)
                    invitation = nil
                    errorMessage = nil
                }
                .disabled(isAccepting)
                Spacer()
                Button(UpdateLocalization.text(ru: "Принять", en: "Accept")) {
                    accept(value)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAccepting)
            }
        }
        .padding(28)
        .frame(width: 470)
        .interactiveDismissDisabled()
    }

    @MainActor
    private func pollForInvitations() async {
        while !Task.isCancelled {
            await refreshInvitation()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    @MainActor
    private func refreshInvitation() async {
        guard invitation == nil,
              let url = try? SelectiveRemoteCloudEndpoint.normalized(endpoint),
              await client.hasStoredSession(endpoint: url)
        else { return }
        do {
            invitation = try await client.pendingTeamInvitations(endpoint: url)
                .first { !dismissedInvitationIDs.contains($0.id) }
        } catch {
            // A missing or expired Cloud session must not interrupt local-only work.
        }
    }

    private func accept(_ value: SelectiveRemoteCloudTeamInvitation) {
        guard let url = try? SelectiveRemoteCloudEndpoint.normalized(endpoint) else { return }
        isAccepting = true
        errorMessage = nil
        Task { @MainActor in
            do {
                _ = try await client.acceptTeamInvitation(endpoint: url, invitationID: value.id)
                invitation = nil
                NotificationCenter.default.post(
                    name: .selectiveRemoteCloudTeamMembershipChanged,
                    object: nil
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isAccepting = false
        }
    }

    private func roleTitle(_ role: SelectiveRemoteCloudTeamRole) -> String {
        switch role {
        case .owner: UpdateLocalization.text(ru: "Владелец", en: "Owner")
        case .admin: UpdateLocalization.text(ru: "Администратор", en: "Admin")
        case .editor: UpdateLocalization.text(ru: "Редактор", en: "Editor")
        case .viewer: UpdateLocalization.text(ru: "Наблюдатель", en: "Viewer")
        }
    }
}
