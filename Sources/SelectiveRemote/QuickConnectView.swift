import SwiftUI

enum QuickConnectAction {
    case terminal
    case sftp
    case connect
}

struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    let onOpenProfile: (UUID, QuickConnectAction) -> Void

    @State private var query = ""
    @State private var configHosts: [SSHConfigHost] = []

    private var matchingProfiles: [ConnectionProfile] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = model.profiles.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            let left = $0.lastConnectedAt ?? .distantPast
            let right = $1.lastConnectedAt ?? .distantPast
            if left != right { return left > right }
            return $0.friendlyName.localizedStandardCompare($1.friendlyName) == .orderedAscending
        }
        guard !needle.isEmpty else { return Array(source.prefix(12)) }
        return source.filter {
            $0.friendlyName.localizedCaseInsensitiveContains(needle)
                || $0.host.localizedCaseInsensitiveContains(needle)
                || $0.username.localizedCaseInsensitiveContains(needle)
                || $0.group.localizedCaseInsensitiveContains(needle)
        }
    }

    private var matchingConfigHosts: [SSHConfigHost] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let importedAliases = Set(
            model.profiles
                .filter { $0.connectionType == .ssh }
                .map { $0.host.lowercased() }
        )
        let source = configHosts.filter { !importedAliases.contains($0.alias.lowercased()) }
        guard !needle.isEmpty else { return Array(source.prefix(8)) }
        return source.filter {
            $0.alias.localizedCaseInsensitiveContains(needle)
                || $0.hostName.localizedCaseInsensitiveContains(needle)
                || $0.user.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Color.accentColor)
                TextField("Hostname, профиль, группа…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(.regularMaterial)

            Divider()

            List {
                if !matchingProfiles.isEmpty {
                    Section("Подключения") {
                        ForEach(matchingProfiles) { profile in
                            HStack(spacing: 12) {
                                Image(systemName: profile.connectionType.systemImage)
                                    .frame(width: 28, height: 28)
                                    .foregroundStyle(profile.connectionType == .ssh ? Color.purple : Color.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(profile.friendlyName.isEmpty ? profile.host : profile.friendlyName)
                                            .font(.body.weight(.semibold))
                                        if profile.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                                    }
                                    Text(profile.host.isEmpty ? "Hostname не указан" : profile.host)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if profile.connectionType == .ssh {
                                    Button("Terminal") { open(profile.id, .terminal) }
                                        .buttonStyle(.bordered)
                                    Button("SFTP") { open(profile.id, .sftp) }
                                        .buttonStyle(.bordered)
                                } else {
                                    Button("RDP") { open(profile.id, .connect) }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                open(profile.id, profile.connectionType == .ssh ? .terminal : .connect)
                            }
                        }
                    }
                }

                if !matchingConfigHosts.isEmpty {
                    Section("~/.ssh/config") {
                        ForEach(matchingConfigHosts) { host in
                            HStack(spacing: 12) {
                                Image(systemName: "terminal.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.alias).font(.body.weight(.semibold))
                                    Text(host.displayDestination)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    if let proxyJump = host.proxyJump, !proxyJump.isEmpty {
                                        Label("через \(proxyJump)", systemImage: "arrow.triangle.branch")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Импортировать") {
                                    if let id = model.importSSHConfigHost(host) {
                                        open(id, .terminal)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }

                if matchingProfiles.isEmpty && matchingConfigHosts.isEmpty {
                    ContentUnavailableView(
                        "Ничего не найдено",
                        systemImage: "magnifyingglass",
                        description: Text("Попробуйте hostname, имя профиля или группу.")
                    )
                    .frame(minHeight: 220)
                }
            }
            .listStyle(.inset)

            HStack {
                Text("⌘K · Quick Connect")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 720, height: 560)
        .onAppear { configHosts = SSHConfigService.loadHosts() }
    }

    private func open(_ id: UUID, _ action: QuickConnectAction) {
        dismiss()
        onOpenProfile(id, action)
    }
}
