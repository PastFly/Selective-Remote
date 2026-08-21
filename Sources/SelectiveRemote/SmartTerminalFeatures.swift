import Foundation
import SwiftUI

struct TerminalHostInsights: Codable, Equatable, Sendable {
    var hostname = ""
    var uptimeSeconds: Int64?
    var load1: Double?
    var load5: Double?
    var load15: Double?
    var memoryUsedBytes: Int64?
    var memoryTotalBytes: Int64?
    var rootDiskUsedBytes: Int64?
    var rootDiskTotalBytes: Int64?
    var rootDiskPercent: Int?
    var updatesAvailable: Int?
    var listeningPorts: Int?
    var loggedInUsers: Int?

    static let empty = TerminalHostInsights()

    var hasData: Bool {
        !hostname.isEmpty
            || uptimeSeconds != nil
            || load1 != nil
            || memoryTotalBytes != nil
            || rootDiskTotalBytes != nil
            || updatesAvailable != nil
            || listeningPorts != nil
            || loggedInUsers != nil
    }

    var uptimeLabel: String? {
        guard let uptimeSeconds else { return nil }
        let days = uptimeSeconds / 86_400
        let hours = (uptimeSeconds % 86_400) / 3_600
        let minutes = (uptimeSeconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    var loadLabel: String? {
        guard let load1 else { return nil }
        let values = [load1, load5, load15].compactMap { $0 }
        return values.map { String(format: "%.2f", $0) }.joined(separator: " / ")
    }

    var memoryLabel: String? {
        guard let used = memoryUsedBytes, let total = memoryTotalBytes, total > 0 else { return nil }
        return "\(Self.bytes(used)) / \(Self.bytes(total))"
    }

    var diskLabel: String? {
        if let percent = rootDiskPercent { return "\(percent)%" }
        guard let used = rootDiskUsedBytes, let total = rootDiskTotalBytes, total > 0 else { return nil }
        return "\(Self.bytes(used)) / \(Self.bytes(total))"
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }
}

struct HostInsightsSummaryView: View {
    let insights: TerminalHostInsights
    var onRun: ((String) -> Void)? = nil

    private struct Metric: Identifiable {
        let id: String
        let title: String
        let value: String
        let systemImage: String
        let command: String?
    }

    private var metrics: [Metric] {
        var result: [Metric] = []
        if let value = insights.uptimeLabel {
            result.append(.init(id: "uptime", title: "Uptime", value: value, systemImage: "clock", command: "uptime"))
        }
        if let value = insights.loadLabel {
            result.append(.init(id: "load", title: "Load", value: value, systemImage: "gauge.with.dots.needle.50percent", command: "uptime"))
        }
        if let value = insights.memoryLabel {
            result.append(.init(id: "memory", title: "RAM", value: value, systemImage: "memorychip", command: "free -h"))
        }
        if let value = insights.diskLabel {
            result.append(.init(id: "disk", title: "Disk /", value: value, systemImage: "internaldrive", command: "df -hT /"))
        }
        if let value = insights.updatesAvailable {
            result.append(.init(id: "updates", title: "Updates", value: String(value), systemImage: "arrow.down.circle", command: nil))
        }
        if let value = insights.listeningPorts {
            result.append(.init(id: "ports", title: "Listening", value: String(value), systemImage: "network", command: "ss -lntup"))
        }
        if let value = insights.loggedInUsers {
            result.append(.init(id: "users", title: "Users", value: String(value), systemImage: "person.2", command: "who"))
        }
        return result
    }

    var body: some View {
        if insights.hasData {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("Host Insights", systemImage: "chart.xyaxis.line")
                        .font(.headline)
                    if !insights.hostname.isEmpty {
                        Text(insights.hostname)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("live probe")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 125), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(metrics) { metric in
                        metricCard(metric)
                    }
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.16))
            }
        }
    }

    @ViewBuilder
    private func metricCard(_ metric: Metric) -> some View {
        let content = HStack(spacing: 8) {
            Image(systemName: metric.systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(metric.value)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))

        if let command = metric.command, let onRun {
            Button { onRun(command) } label: { content }
                .buttonStyle(.plain)
                .help("Выполнить: \(command)")
        } else {
            content
        }
    }
}


struct TerminalVariable: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }

    static func normalizedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard name.range(of: #"^[A-Z_][A-Z0-9_]{0,39}$"#, options: .regularExpression) != nil,
              !isSensitiveName(name),
              !TerminalVariableResolver.builtInNames.contains(name)
        else { return nil }
        return name
    }

    static func isSensitiveName(_ raw: String) -> Bool {
        let name = raw.uppercased()
        let markers = ["PASSWORD", "PASS", "TOKEN", "SECRET", "PRIVATE", "CREDENTIAL", "AUTH", "API_KEY", "APIKEY"]
        return markers.contains { name.contains($0) }
    }
}

enum TerminalStartupSnippetMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case disabled
    case ask
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: "Выключено"
        case .ask: "Спрашивать"
        case .automatic: "Автоматически"
        }
    }
}

struct SSHGroupInheritance: Codable, Equatable, Sendable {
    var username = false
    var port = false
    var jumpHost = false
    var keepAlive = false
    var startupSnippet = false
    var variables = false
}

struct SSHGroupConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var groupName: String
    var username: String = ""
    var port: Int = 22
    var jumpHostProfileID: UUID?
    var keepAliveSeconds: Int = 30
    var startupSnippetID: UUID?
    var startupMode: TerminalStartupSnippetMode = .disabled
    var startupAfterReconnect = false
    var variables: [TerminalVariable] = []

    init(groupName: String) {
        self.groupName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class SSHGroupConfigurationStore: ObservableObject {
    static let shared = SSHGroupConfigurationStore()

    @Published private(set) var configurations: [SSHGroupConfiguration]
    private let defaults: UserDefaults
    private let key = "SelectiveRemote.ssh.groupConfigurations.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SSHGroupConfiguration].self, from: data) {
            configurations = decoded
        } else {
            configurations = []
        }
    }

    func configuration(for rawGroup: String) -> SSHGroupConfiguration? {
        let group = normalizedGroup(rawGroup)
        guard !group.isEmpty else { return nil }
        return configurations.first {
            normalizedGroup($0.groupName) == group
        }
    }

    func configurationCreatingIfNeeded(for rawGroup: String) -> SSHGroupConfiguration? {
        let trimmed = rawGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = configuration(for: trimmed) { return existing }
        let created = SSHGroupConfiguration(groupName: trimmed)
        configurations.append(created)
        persist()
        return created
    }

    func update(groupName: String, _ mutate: (inout SSHGroupConfiguration) -> Void) {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = normalizedGroup(trimmed)
        if let index = configurations.firstIndex(where: {
            normalizedGroup($0.groupName) == normalized
        }) {
            mutate(&configurations[index])
            configurations[index].groupName = trimmed
        } else {
            var created = SSHGroupConfiguration(groupName: trimmed)
            mutate(&created)
            configurations.append(created)
        }
        persist()
    }

    func remove(groupName: String) {
        let normalized = normalizedGroup(groupName)
        configurations.removeAll { normalizedGroup($0.groupName) == normalized }
        persist()
    }

    private func normalizedGroup(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        defaults.set(data, forKey: key)
    }
}

enum TerminalVariableResolver {
    static let builtInNames: Set<String> = ["HOST", "USER", "PORT", "PROFILE", "GROUP", "OS", "OS_ID"]

    static func mergedVariables(group: [TerminalVariable], profile: [TerminalVariable]) -> [TerminalVariable] {
        var byName: [String: TerminalVariable] = [:]
        for variable in group + profile {
            guard let name = TerminalVariable.normalizedName(variable.name) else { continue }
            var normalized = variable
            normalized.name = name
            byName[name] = normalized
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    static func dictionary(
        profile: ConnectionProfile,
        groupConfiguration: SSHGroupConfiguration? = nil
    ) -> [String: String] {
        let inherited = profile.sshGroupInheritance.variables
            ? (groupConfiguration?.variables ?? [])
            : []
        let merged = mergedVariables(group: inherited, profile: profile.terminalVariables)
        var result = Dictionary(uniqueKeysWithValues: merged.map { ($0.name, $0.value) })
        result["HOST"] = profile.host
        result["USER"] = profile.username
        result["PORT"] = String(profile.sshPort)
        result["PROFILE"] = profile.friendlyName
        result["GROUP"] = profile.group
        result["OS"] = profile.detectedOperatingSystem
        result["OS_ID"] = profile.detectedOperatingSystemID
        return result
    }

    static func resolve(_ command: String, variables: [String: String]) -> String {
        var resolved = command
        for (name, value) in variables {
            resolved = resolved.replacingOccurrences(of: "${\(name)}", with: value)
        }
        return resolved
    }
}

struct SSHAutomationSettingsView: View {
    @Binding var profile: ConnectionProfile
    let sshProfiles: [ConnectionProfile]
    @ObservedObject private var snippets = TerminalCommandHistoryStore.shared
    @ObservedObject private var groups = SSHGroupConfigurationStore.shared

    private var snippetOptions: [TerminalCommandTemplate] { snippets.templates() }
    private var groupConfiguration: SSHGroupConfiguration? { groups.configuration(for: profile.group) }
    private var hasGroup: Bool { !profile.group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        GroupBox("Автоматизация SSH") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Picker("Startup Snippet", selection: $profile.sshStartupSnippetID) {
                        Text("Не выбран").tag(UUID?.none)
                        ForEach(snippetOptions) { snippet in
                            Text(snippet.title).tag(Optional(snippet.id))
                        }
                    }
                    .frame(maxWidth: 360)
                    Picker("Запуск", selection: $profile.sshStartupSnippetMode) {
                        ForEach(TerminalStartupSnippetMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .frame(width: 190)
                    Toggle("После reconnect", isOn: $profile.sshStartupSnippetAfterReconnect)
                        .disabled(profile.sshStartupSnippetMode == .disabled)
                }

                Text("Startup Snippet выполняется только после появления shell prompt. Режим «Спрашивать» всегда требует подтверждения перед отправкой команды.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                variableEditor(
                    title: "Переменные профиля",
                    variables: $profile.terminalVariables,
                    help: "Используйте в Snippets как ${PROJECT_PATH}. HOST, USER, PORT, PROFILE, GROUP, OS и OS_ID подставляются автоматически."
                )

                Label(
                    "Переменные хранятся как обычные настройки профиля и не предназначены для паролей, токенов и других секретов — для них используйте Keychain.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.orange)

                Divider()
                if hasGroup {
                    groupSection
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Наследование настроек группы", systemImage: "square.stack.3d.up")
                            .font(.headline)
                        Text("У этого SSH-профиля пока нет группы. Назначьте группу во вкладке «Основное» — здесь сразу появятся общие username, порт, Jump Host, Keepalive, Startup Snippet и переменные группы.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var groupSection: some View {
        let name = profile.group.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Настройки группы «\(name)»", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer()
                if groupConfiguration != nil {
                    Button("Сбросить группу", role: .destructive) {
                        groups.remove(groupName: name)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text("Каждый параметр наследуется отдельно. Если переключатель выключен, используется значение самого профиля.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                GridRow {
                    Toggle("Пользователь", isOn: inheritanceBinding(\.username))
                    TextField("admin", text: groupStringBinding(\.username, fallback: ""))
                        .textFieldStyle(.roundedBorder)
                        .disabled(!profile.sshGroupInheritance.username)
                }
                GridRow {
                    Toggle("SSH-порт", isOn: inheritanceBinding(\.port))
                    TextField("22", value: groupIntBinding(\.port, fallback: 22), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .disabled(!profile.sshGroupInheritance.port)
                }
                GridRow {
                    Toggle("Jump Host", isOn: inheritanceBinding(\.jumpHost))
                    Picker("", selection: groupOptionalUUIDBinding(\.jumpHostProfileID)) {
                        Text("Нет").tag(UUID?.none)
                        ForEach(sshProfiles.filter { $0.id != profile.id }) { candidate in
                            Text(candidate.friendlyName.isEmpty ? candidate.host : candidate.friendlyName)
                                .tag(Optional(candidate.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(!profile.sshGroupInheritance.jumpHost)
                }
                GridRow {
                    Toggle("Keepalive", isOn: inheritanceBinding(\.keepAlive))
                    TextField("30", value: groupIntBinding(\.keepAliveSeconds, fallback: 30), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .disabled(!profile.sshGroupInheritance.keepAlive)
                }
                GridRow {
                    Toggle("Startup Snippet", isOn: inheritanceBinding(\.startupSnippet))
                    HStack {
                        Picker("", selection: groupOptionalUUIDBinding(\.startupSnippetID)) {
                            Text("Не выбран").tag(UUID?.none)
                            ForEach(snippetOptions) { snippet in
                                Text(snippet.title).tag(Optional(snippet.id))
                            }
                        }
                        .labelsHidden()
                        Picker("", selection: groupStartupModeBinding()) {
                            ForEach(TerminalStartupSnippetMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    .disabled(!profile.sshGroupInheritance.startupSnippet)
                }
            }

            Toggle("Наследовать переменные группы", isOn: inheritanceBinding(\.variables))
            groupVariableEditor(groupName: name)
                .disabled(!profile.sshGroupInheritance.variables)
                .opacity(profile.sshGroupInheritance.variables ? 1 : 0.55)
        }
    }

    @ViewBuilder
    private func variableEditor(title: String, variables: Binding<[TerminalVariable]>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button("Добавить", systemImage: "plus") {
                    variables.wrappedValue.append(TerminalVariable(name: "VARIABLE", value: ""))
                }
                .buttonStyle(.borderless)
            }
            ForEach(variables.wrappedValue) { variable in
                HStack(spacing: 8) {
                    TextField("NAME", text: profileVariableBinding(variable.id, \.name))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    TextField("Значение", text: profileVariableBinding(variable.id, \.value))
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        variables.wrappedValue.removeAll { $0.id == variable.id }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    if TerminalVariable.normalizedName(variable.name) == nil && !variable.name.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Имя недопустимо, зарезервировано или похоже на секрет")
                    }
                }
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func groupVariableEditor(groupName: String) -> some View {
        let variables = groupConfiguration?.variables ?? []
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Переменные группы").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Добавить", systemImage: "plus") {
                    groups.update(groupName: groupName) { config in
                        config.variables.append(TerminalVariable(name: "VARIABLE", value: ""))
                    }
                }
                .buttonStyle(.borderless)
            }
            ForEach(variables) { variable in
                HStack(spacing: 8) {
                    TextField("NAME", text: groupVariableBinding(groupName, variable.id, \.name))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    TextField("Значение", text: groupVariableBinding(groupName, variable.id, \.value))
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        groups.update(groupName: groupName) { config in
                            config.variables.removeAll { $0.id == variable.id }
                        }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private func profileVariableBinding(_ id: UUID, _ keyPath: WritableKeyPath<TerminalVariable, String>) -> Binding<String> {
        Binding(
            get: { profile.terminalVariables.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { newValue in
                if let index = profile.terminalVariables.firstIndex(where: { $0.id == id }) {
                    profile.terminalVariables[index][keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func groupVariableBinding(_ groupName: String, _ id: UUID, _ keyPath: WritableKeyPath<TerminalVariable, String>) -> Binding<String> {
        Binding(
            get: { groups.configuration(for: groupName)?.variables.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { newValue in
                groups.update(groupName: groupName) { config in
                    if let index = config.variables.firstIndex(where: { $0.id == id }) {
                        config.variables[index][keyPath: keyPath] = newValue
                    }
                }
            }
        )
    }

    private func inheritanceBinding(_ keyPath: WritableKeyPath<SSHGroupInheritance, Bool>) -> Binding<Bool> {
        Binding(
            get: { profile.sshGroupInheritance[keyPath: keyPath] },
            set: { profile.sshGroupInheritance[keyPath: keyPath] = $0 }
        )
    }

    private func groupStringBinding(_ keyPath: WritableKeyPath<SSHGroupConfiguration, String>, fallback: String) -> Binding<String> {
        let name = profile.group
        return Binding(
            get: { groups.configuration(for: name)?[keyPath: keyPath] ?? fallback },
            set: { value in groups.update(groupName: name) { $0[keyPath: keyPath] = value } }
        )
    }

    private func groupIntBinding(_ keyPath: WritableKeyPath<SSHGroupConfiguration, Int>, fallback: Int) -> Binding<Int> {
        let name = profile.group
        return Binding(
            get: { groups.configuration(for: name)?[keyPath: keyPath] ?? fallback },
            set: { value in groups.update(groupName: name) { $0[keyPath: keyPath] = max(0, value) } }
        )
    }

    private func groupOptionalUUIDBinding(_ keyPath: WritableKeyPath<SSHGroupConfiguration, UUID?>) -> Binding<UUID?> {
        let name = profile.group
        return Binding(
            get: { groups.configuration(for: name)?[keyPath: keyPath] },
            set: { value in groups.update(groupName: name) { $0[keyPath: keyPath] = value } }
        )
    }

    private func groupStartupModeBinding() -> Binding<TerminalStartupSnippetMode> {
        let name = profile.group
        return Binding(
            get: { groups.configuration(for: name)?.startupMode ?? .disabled },
            set: { value in groups.update(groupName: name) { $0.startupMode = value } }
        )
    }
}


struct NamedTerminalWorkspace: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let scopeID: UUID
    var name: String
    var snapshot: TerminalWorkspaceSnapshot
    let createdAt: Date
    var updatedAt: Date
}

@MainActor
final class TerminalNamedWorkspaceStore: ObservableObject {
    static let shared = TerminalNamedWorkspaceStore()

    @Published private(set) var workspaces: [NamedTerminalWorkspace]
    private let defaults: UserDefaults
    private let key = "SelectiveRemote.terminal.namedWorkspaces.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([NamedTerminalWorkspace].self, from: data) {
            workspaces = decoded
        } else {
            workspaces = []
        }
    }

    func workspaces(for scopeID: UUID) -> [NamedTerminalWorkspace] {
        workspaces
            .filter { $0.scopeID == scopeID }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    @discardableResult
    func save(
        name rawName: String,
        scopeID: UUID,
        snapshot: TerminalWorkspaceSnapshot,
        now: Date = Date()
    ) -> NamedTerminalWorkspace? {
        guard let name = normalizedName(rawName), !snapshot.tabs.isEmpty else { return nil }
        if let index = workspaces.firstIndex(where: {
            $0.scopeID == scopeID && sameName($0.name, name)
        }) {
            workspaces[index].name = name
            workspaces[index].snapshot = snapshot
            workspaces[index].updatedAt = now
            persist()
            return workspaces[index]
        }
        let entry = NamedTerminalWorkspace(
            id: UUID(),
            scopeID: scopeID,
            name: name,
            snapshot: snapshot,
            createdAt: now,
            updatedAt: now
        )
        workspaces.append(entry)
        persist()
        return entry
    }

    func remove(id: UUID) {
        let previous = workspaces.count
        workspaces.removeAll { $0.id == id }
        if workspaces.count != previous { persist() }
    }

    private func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(60))
    }

    private func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        defaults.set(data, forKey: key)
    }
}

struct TerminalNamedWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: TerminalNamedWorkspaceStore
    @ObservedObject var workspace: TerminalWorkspaceModel
    @State private var name = ""
    @State private var feedback: String?

    private var entries: [NamedTerminalWorkspace] {
        store.workspaces(for: workspace.profileID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Рабочие пространства")
                        .font(.title3.weight(.semibold))
                    Text("Сохраняют вкладки, компоновку, подключения и оформление")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                TextField("Например, Production", text: $name)
                    .textFieldStyle(.roundedBorder)
                Button("Сохранить текущее", systemImage: "square.and.arrow.down") {
                    guard store.save(
                        name: name,
                        scopeID: workspace.profileID,
                        snapshot: workspace.workspaceSnapshot()
                    ) != nil else {
                        feedback = "Введите название рабочего пространства"
                        return
                    }
                    feedback = "Рабочее пространство сохранено"
                    name = ""
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if workspace.hasRunningSession {
                Label(
                    "Для загрузки другого Workspace сначала отключите активные терминалы. Сохранение текущего состояния доступно.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Label(
                    "Загрузка восстанавливает структуру, но никогда не подключается к серверам автоматически.",
                    systemImage: "shield.checkered"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            if entries.isEmpty {
                ContentUnavailableView(
                    "Нет сохранённых Workspaces",
                    systemImage: "rectangle.3.group",
                    description: Text("Соберите нужные вкладки и панели, затем сохраните текущее состояние.")
                )
                .frame(minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entries) { entry in
                            workspaceRow(entry)
                        }
                    }
                }
                .frame(maxHeight: 330)
            }

            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func workspaceRow(_ entry: NamedTerminalWorkspace) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.snapshot.layout.systemImage)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(entry.snapshot.tabs.count) вкладок · \(entry.snapshot.layout.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Загрузить") {
                if workspace.restoreWorkspaceSnapshot(entry.snapshot) {
                    feedback = "Workspace «\(entry.name)» загружен"
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(workspace.hasRunningSession)
            Button(role: .destructive) {
                store.remove(id: entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .help("Удалить Workspace")
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
