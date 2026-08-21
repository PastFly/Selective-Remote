#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text(encoding="utf-8")

def write(path, text):
    (ROOT / path).write_text(text, encoding="utf-8")

def replace_once(path, old, new):
    text = read(path)
    if old not in text:
        raise SystemExit(f"pattern not found in {path}: {old[:120]!r}")
    write(path, text.replace(old, new, 1))

# --- Shared productivity models, group defaults, variables and editor UI ---
smart_path = "Sources/SelectiveRemote/SmartTerminalFeatures.swift"
smart = read(smart_path)
smart += r'''

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

                if hasGroup {
                    Divider()
                    groupSection
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
'''
write(smart_path, smart)

# --- Profile persistence fields ---
replace_once(
    "Sources/SelectiveRemote/Models.swift",
    '''    var sshAgentForwarding: Bool
    var portForwards: [PortForwardRule]''',
    '''    var sshAgentForwarding: Bool
    var sshStartupSnippetID: UUID?
    var sshStartupSnippetMode: TerminalStartupSnippetMode
    var sshStartupSnippetAfterReconnect: Bool
    var terminalVariables: [TerminalVariable]
    var sshGroupInheritance: SSHGroupInheritance
    var portForwards: [PortForwardRule]'''
)
replace_once(
    "Sources/SelectiveRemote/Models.swift",
    '''        sshAgentForwarding = false
        portForwards = []''',
    '''        sshAgentForwarding = false
        sshStartupSnippetID = nil
        sshStartupSnippetMode = .disabled
        sshStartupSnippetAfterReconnect = false
        terminalVariables = []
        sshGroupInheritance = SSHGroupInheritance()
        portForwards = []'''
)
replace_once(
    "Sources/SelectiveRemote/Models.swift",
    '''        case sshCompression, sshKeepAliveSeconds, sshAgentForwarding, portForwards''',
    '''        case sshCompression, sshKeepAliveSeconds, sshAgentForwarding
        case sshStartupSnippetID, sshStartupSnippetMode, sshStartupSnippetAfterReconnect
        case terminalVariables, sshGroupInheritance, portForwards'''
)
replace_once(
    "Sources/SelectiveRemote/Models.swift",
    '''        sshAgentForwarding = try container.decodeIfPresent(
            Bool.self,
            forKey: .sshAgentForwarding
        ) ?? defaults.sshAgentForwarding
        portForwards = try container.decodeIfPresent(''',
    '''        sshAgentForwarding = try container.decodeIfPresent(
            Bool.self,
            forKey: .sshAgentForwarding
        ) ?? defaults.sshAgentForwarding
        sshStartupSnippetID = try container.decodeIfPresent(UUID.self, forKey: .sshStartupSnippetID)
        sshStartupSnippetMode = try container.decodeIfPresent(
            TerminalStartupSnippetMode.self,
            forKey: .sshStartupSnippetMode
        ) ?? defaults.sshStartupSnippetMode
        sshStartupSnippetAfterReconnect = try container.decodeIfPresent(
            Bool.self,
            forKey: .sshStartupSnippetAfterReconnect
        ) ?? defaults.sshStartupSnippetAfterReconnect
        terminalVariables = try container.decodeIfPresent(
            [TerminalVariable].self,
            forKey: .terminalVariables
        ) ?? defaults.terminalVariables
        sshGroupInheritance = try container.decodeIfPresent(
            SSHGroupInheritance.self,
            forKey: .sshGroupInheritance
        ) ?? defaults.sshGroupInheritance
        portForwards = try container.decodeIfPresent('''
)
replace_once(
    "Sources/SelectiveRemote/Models.swift",
    '''        try container.encode(sshAgentForwarding, forKey: .sshAgentForwarding)
        try container.encode(portForwards, forKey: .portForwards)''',
    '''        try container.encode(sshAgentForwarding, forKey: .sshAgentForwarding)
        try container.encodeIfPresent(sshStartupSnippetID, forKey: .sshStartupSnippetID)
        try container.encode(sshStartupSnippetMode, forKey: .sshStartupSnippetMode)
        try container.encode(sshStartupSnippetAfterReconnect, forKey: .sshStartupSnippetAfterReconnect)
        try container.encode(terminalVariables, forKey: .terminalVariables)
        try container.encode(sshGroupInheritance, forKey: .sshGroupInheritance)
        try container.encode(portForwards, forKey: .portForwards)'''
)

# --- History payload carries known variables into xterm.js ---
replace_once(
    "Sources/SelectiveRemote/TerminalCommandHistory.swift",
    '''struct TerminalHistoryContext: Equatable {
    let profileID: UUID
    let snippetTargets: [TerminalSnippetTargetOption]

    init(profileID: UUID, snippetTargets: [TerminalSnippetTargetOption] = []) {
        self.profileID = profileID
        self.snippetTargets = snippetTargets
    }
}''',
    '''struct TerminalHistoryContext: Equatable {
    let profileID: UUID
    let snippetTargets: [TerminalSnippetTargetOption]
    let variables: [String: String]

    init(
        profileID: UUID,
        snippetTargets: [TerminalSnippetTargetOption] = [],
        variables: [String: String] = [:]
    ) {
        self.profileID = profileID
        self.snippetTargets = snippetTargets
        self.variables = variables
    }
}'''
)
replace_once(
    "Sources/SelectiveRemote/TerminalCommandHistory.swift",
    '''    let defaultSnippetTargetID: String
    let remote: TerminalRemoteContextSnapshot''',
    '''    let defaultSnippetTargetID: String
    let variables: [String: String]
    let remote: TerminalRemoteContextSnapshot'''
)
replace_once(
    "Sources/SelectiveRemote/TerminalCommandHistory.swift",
    '''        snippetTargets: [TerminalSnippetTargetOption] = [],
        remote: TerminalRemoteContextSnapshot = .empty''',
    '''        snippetTargets: [TerminalSnippetTargetOption] = [],
        variables: [String: String] = [:],
        remote: TerminalRemoteContextSnapshot = .empty'''
)
replace_once(
    "Sources/SelectiveRemote/TerminalCommandHistory.swift",
    '''            defaultSnippetTargetID: profileID.uuidString,
            remote: remote''',
    '''            defaultSnippetTargetID: profileID.uuidString,
            variables: variables,
            remote: remote'''
)

# --- JS resolves known variables first, prompts only for unresolved placeholders ---
js_path = "Sources/SelectiveRemote/TerminalResources/terminal-host.js"
replace_once(
    js_path,
    '''    const resolveTemplate = (command) => {
        const names = Array.from(new Set(
            Array.from(command.matchAll(/\\$\\{([A-Za-z][A-Za-z0-9_-]{0,39})\\}/g))
                .map((match) => match[1])
        ));
        let resolved = command;
        for (const name of names) {
            const value = window.prompt(`Значение для ${name}:`, "");
            if (value === null) {
                return null;
            }
            resolved = resolved.replaceAll(`\\${${name}}`, value);
        }
        return resolved;
    };''',
    '''    let templateVariables = {};

    const resolveTemplate = (command) => {
        const names = Array.from(new Set(
            Array.from(command.matchAll(/\\$\\{([A-Za-z][A-Za-z0-9_-]{0,39})\\}/g))
                .map((match) => match[1])
        ));
        let resolved = command;
        for (const name of names) {
            const known = Object.prototype.hasOwnProperty.call(templateVariables, name)
                ? String(templateVariables[name] ?? "")
                : null;
            if (known !== null) {
                resolved = resolved.replaceAll(`\\${${name}}`, known);
                continue;
            }
            const value = window.prompt(`Значение для ${name}:`, "");
            if (value === null) {
                return null;
            }
            resolved = resolved.replaceAll(`\\${${name}}`, value);
        }
        return resolved;
    };'''
)
replace_once(
    js_path,
    '''        defaultSnippetTargetID = typeof payload.defaultSnippetTargetID === "string"
            ? payload.defaultSnippetTargetID
            : "";
        if (selectedSnippetID''',
    '''        defaultSnippetTargetID = typeof payload.defaultSnippetTargetID === "string"
            ? payload.defaultSnippetTargetID
            : "";
        templateVariables = payload.variables && typeof payload.variables === "object"
            ? Object.fromEntries(
                Object.entries(payload.variables)
                    .filter(([name, value]) => /^[A-Z_][A-Z0-9_]{0,39}$/.test(name)
                        && typeof value === "string")
            )
            : {};
        if (selectedSnippetID'''
)

# Coordinator forwards per-pane variable dictionary.
replace_once(
    "Sources/SelectiveRemote/EmbeddedTerminalView.swift",
    '''                      for: context.profileID,
                      snippetTargets: context.snippetTargets,
                      remote: remoteContext''',
    '''                      for: context.profileID,
                      snippetTargets: context.snippetTargets,
                      variables: context.variables,
                      remote: remoteContext'''
)

# Build terminal variables from the saved profile + optional group inheritance.
replace_once(
    "Sources/SelectiveRemote/EmbeddedTerminalView.swift",
    '''    private func historyContextID(for tab: TerminalWorkspaceTab) -> UUID {''',
    '''    private func terminalVariables(for tab: TerminalWorkspaceTab) -> [String: String] {
        guard let profileID = tab.connection.profileID,
              let raw = sshProfiles.first(where: { $0.id == profileID })
        else { return [:] }
        let group = SSHGroupConfigurationStore.shared.configuration(for: raw.group)
        var effective = raw
        if raw.sshGroupInheritance.username, let value = group?.username, !value.isEmpty {
            effective.username = value
        }
        if raw.sshGroupInheritance.port, let value = group?.port, value > 0 {
            effective.sshPort = value
        }
        return TerminalVariableResolver.dictionary(profile: effective, groupConfiguration: group)
    }

    private func historyContextID(for tab: TerminalWorkspaceTab) -> UUID {'''
)
replace_once(
    "Sources/SelectiveRemote/EmbeddedTerminalView.swift",
    '''                historyContext: TerminalHistoryContext(
                    profileID: historyContextID(for: tab),
                    snippetTargets: sshProfiles.map {''',
    '''                historyContext: TerminalHistoryContext(
                    profileID: historyContextID(for: tab),
                    snippetTargets: sshProfiles.map {'''
)
# Add variables after snippetTargets map block by targeted end of constructor.
replace_once(
    "Sources/SelectiveRemote/EmbeddedTerminalView.swift",
    '''                        )
                    }
                ),
                remoteContext: workspace.remoteContext(for: tab.id) ?? .empty,''',
    '''                        )
                    },
                    variables: terminalVariables(for: tab)
                ),
                remoteContext: workspace.remoteContext(for: tab.id) ?? .empty,'''
)

# --- AppModel: effective group settings + startup snippet lifecycle ---
replace_once(
    "Sources/SelectiveRemote/AppModel.swift",
    '''    private func sshJumpHostProfile(for profile: ConnectionProfile) -> ConnectionProfile? {
        guard let jumpID = profile.sshJumpHostProfileID, jumpID != profile.id else { return nil }
        return profiles.first(where: { $0.id == jumpID && $0.connectionType == .ssh })
    }''',
    '''    func effectiveSSHProfile(_ source: ConnectionProfile) -> ConnectionProfile {
        guard source.connectionType == .ssh,
              let group = SSHGroupConfigurationStore.shared.configuration(for: source.group)
        else { return source }
        var profile = source
        let inherit = source.sshGroupInheritance
        if inherit.username, !group.username.isEmpty { profile.username = group.username }
        if inherit.port, group.port > 0 { profile.sshPort = group.port }
        if inherit.jumpHost { profile.sshJumpHostProfileID = group.jumpHostProfileID }
        if inherit.keepAlive { profile.sshKeepAliveSeconds = max(0, group.keepAliveSeconds) }
        if inherit.startupSnippet {
            profile.sshStartupSnippetID = group.startupSnippetID
            profile.sshStartupSnippetMode = group.startupMode
            profile.sshStartupSnippetAfterReconnect = group.startupAfterReconnect
        }
        if inherit.variables {
            profile.terminalVariables = TerminalVariableResolver.mergedVariables(
                group: group.variables,
                profile: source.terminalVariables
            )
        }
        return profile
    }

    private func sshJumpHostProfile(for profile: ConnectionProfile) -> ConnectionProfile? {
        guard let jumpID = profile.sshJumpHostProfileID, jumpID != profile.id,
              let source = profiles.first(where: { $0.id == jumpID && $0.connectionType == .ssh })
        else { return nil }
        return effectiveSSHProfile(source)
    }'''
)
replace_once(
    "Sources/SelectiveRemote/AppModel.swift",
    '''        guard let profile = profiles.first(where: { $0.id == profileID }),
              profile.connectionType == .ssh
        else { return nil }
        let identity = profile.sshIdentityID.flatMap''',
    '''        guard let source = profiles.first(where: { $0.id == profileID }),
              source.connectionType == .ssh
        else { return nil }
        let profile = effectiveSSHProfile(source)
        let identity = profile.sshIdentityID.flatMap'''
)
# prepareSSHConnection jump user-presence path should respect inherited jump host.
replace_once(
    "Sources/SelectiveRemote/AppModel.swift",
    '''               let sourceProfile = profiles.first(where: { $0.id == sourceProfileID }),
               let jumpProfile = sshJumpHostProfile(for: sourceProfile) {''',
    '''               let rawSourceProfile = profiles.first(where: { $0.id == sourceProfileID }),
               let jumpProfile = sshJumpHostProfile(for: effectiveSSHProfile(rawSourceProfile)) {'''
)
# Schedule startup snippet after the PTY launches.
replace_once(
    "Sources/SelectiveRemote/AppModel.swift",
    '''            terminalRuntimeSettings[tabID] = settings
            terminalStartedAt[tabID] = Date()
            if let smartReconnectAttempt {''',
    '''            terminalRuntimeSettings[tabID] = settings
            terminalStartedAt[tabID] = Date()
            scheduleStartupSnippetIfNeeded(
                connection: connection,
                tabID: tabID,
                session: session,
                isReconnect: smartReconnectAttempt != nil
            )
            if let smartReconnectAttempt {'''
)
# Insert helper before existing queued snippet helper.
replace_once(
    "Sources/SelectiveRemote/AppModel.swift",
    '''    private func enqueueSnippetInputAfterConnect(
        _ input: Data,''',
    r'''    private func scheduleStartupSnippetIfNeeded(
        connection: TerminalTabConnection,
        tabID: UUID,
        session: TerminalSessionModel,
        isReconnect: Bool
    ) {
        guard connection.kind == .savedProfile,
              let profileID = connection.profileID,
              let raw = profiles.first(where: { $0.id == profileID })
        else { return }
        let profile = effectiveSSHProfile(raw)
        guard profile.sshStartupSnippetMode != .disabled,
              (!isReconnect || profile.sshStartupSnippetAfterReconnect),
              let snippetID = profile.sshStartupSnippetID,
              let snippet = TerminalCommandHistoryStore.shared.template(id: snippetID)
        else { return }
        let group = SSHGroupConfigurationStore.shared.configuration(for: raw.group)
        let variables = TerminalVariableResolver.dictionary(
            profile: profile,
            groupConfiguration: group
        )
        let command = TerminalVariableResolver.resolve(snippet.command, variables: variables)
        guard let input = TerminalSnippetExecution.inputData(for: command) else { return }

        Task { @MainActor [weak self, weak session] in
            var runningTicks = 0
            for _ in 0..<400 {
                guard let self, let session else { return }
                if case .running = session.phase {
                    runningTicks += 1
                    if runningTicks >= 10,
                       self.snippetShellAppearsReady(session.recentOutputText()) || runningTicks >= 300 {
                        if profile.sshStartupSnippetMode == .ask {
                            let alert = NSAlert()
                            alert.alertStyle = .informational
                            alert.messageText = "Выполнить Startup Snippet?"
                            alert.informativeText = "\(profile.friendlyName)\n\n\(snippet.title)\n\(command)"
                            alert.addButton(withTitle: "Выполнить")
                            alert.addButton(withTitle: "Пропустить")
                            guard alert.runModal() == .alertFirstButtonReturn else { return }
                        }
                        _ = TerminalCommandHistoryStore.shared.record(
                            command: command,
                            profileID: profileID
                        )
                        session.sendInput(input)
                        self.statusMessage = "Startup Snippet «\(snippet.title)» выполнен"
                        return
                    }
                } else {
                    runningTicks = 0
                }
                if case .finished = session.phase { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func enqueueSnippetInputAfterConnect(
        _ input: Data,'''
)

# --- Profile editor: expose startup snippets, group inheritance and variables ---
replace_once(
    "Sources/SelectiveRemote/ContentView.swift",
    '''            GroupBox("SSH Agent Forwarding") {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle(
                        "Разрешить Terminal перенаправлять локальный ssh-agent",
                        isOn: profileBinding.sshAgentForwarding
                    )
                    Text(
                        "Позволяет подключаться с этого сервера дальше по SSH или к Git, "
                            + "используя ключи из ssh-agent на Mac без копирования приватного ключа на сервер."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Label(
                        "Включайте только для доверенных серверов. Опция применяется только к интерактивному Terminal; SFTP и Forwarding её не используют.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                .padding(8)
            }
        }
    }''',
    '''            GroupBox("SSH Agent Forwarding") {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle(
                        "Разрешить Terminal перенаправлять локальный ssh-agent",
                        isOn: profileBinding.sshAgentForwarding
                    )
                    Text(
                        "Позволяет подключаться с этого сервера дальше по SSH или к Git, "
                            + "используя ключи из ssh-agent на Mac без копирования приватного ключа на сервер."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Label(
                        "Включайте только для доверенных серверов. Опция применяется только к интерактивному Terminal; SFTP и Forwarding её не используют.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                .padding(8)
            }

            SSHAutomationSettingsView(
                profile: profileBinding,
                sshProfiles: model.profiles.filter { $0.connectionType == .ssh }
            )
        }
    }'''
)

# Regression coverage for migration-safe profile fields, safe variables and group inheritance.
test_path = "Tests/SelectiveRemoteTests/TerminalProductivity0260Tests.swift"
tests = read(test_path)
tests += r'''

@Test("SSH automation fields preserve legacy defaults through Codable")
func sshAutomationCodableDefaults() throws {
    let legacyJSON = #"{"connectionType":"ssh","friendlyName":"Legacy","host":"example.test","username":"admin"}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: legacyJSON)
    #expect(decoded.sshStartupSnippetID == nil)
    #expect(decoded.sshStartupSnippetMode == .disabled)
    #expect(decoded.sshStartupSnippetAfterReconnect == false)
    #expect(decoded.terminalVariables.isEmpty)
    #expect(decoded.sshGroupInheritance == SSHGroupInheritance())

    var profile = ConnectionProfile(connectionType: .ssh)
    profile.sshStartupSnippetMode = .automatic
    profile.terminalVariables = [TerminalVariable(name: "PROJECT_PATH", value: "/opt/app")]
    profile.sshGroupInheritance.keepAlive = true
    let roundTrip = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
    #expect(roundTrip.sshStartupSnippetMode == .automatic)
    #expect(roundTrip.terminalVariables.first?.name == "PROJECT_PATH")
    #expect(roundTrip.sshGroupInheritance.keepAlive)
}

@Test("Terminal variables reject secrets and profile overrides group")
func terminalVariableSafetyAndPrecedence() {
    #expect(TerminalVariable.normalizedName("project_path") == "PROJECT_PATH")
    #expect(TerminalVariable.normalizedName("api_token") == nil)
    #expect(TerminalVariable.normalizedName("HOST") == nil)
    let merged = TerminalVariableResolver.mergedVariables(
        group: [TerminalVariable(name: "PROJECT_PATH", value: "/group")],
        profile: [TerminalVariable(name: "PROJECT_PATH", value: "/profile")]
    )
    #expect(merged.count == 1)
    #expect(merged.first?.value == "/profile")
}

@Test("Group configuration persists and inherited SSH settings stay granular")
@MainActor
func groupSSHInheritance() {
    let suite = "SelectiveRemoteTests.Group.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SSHGroupConfigurationStore(defaults: defaults)
    store.update(groupName: "Production") { config in
        config.username = "deploy"
        config.port = 2222
        config.keepAliveSeconds = 45
        config.variables = [TerminalVariable(name: "PROJECT_PATH", value: "/srv/app")]
    }
    #expect(store.configuration(for: "production")?.username == "deploy")
    #expect(store.configuration(for: "Production")?.port == 2222)
}

@Test("Terminal history payload carries non-secret variables")
@MainActor
func historyPayloadCarriesVariables() throws {
    let suite = "SelectiveRemoteTests.HistoryVariables.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TerminalCommandHistoryStore(defaults: defaults)
    let id = UUID()
    let json = try #require(store.webPayload(
        for: id,
        variables: ["PROJECT_PATH": "/opt/app", "HOST": "example.test"]
    ))
    #expect(json.contains("PROJECT_PATH"))
    #expect(json.contains("/opt/app"))
}

@Test("Terminal JS substitutes known template variables before prompting")
func knownTemplateVariablesSourceRegression() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/TerminalResources/terminal-host.js"),
        encoding: .utf8
    )
    #expect(source.contains("let templateVariables = {}"))
    #expect(source.contains("hasOwnProperty.call(templateVariables, name)"))
    #expect(source.contains("payload.variables"))
}
'''
write(test_path, tests)

print("v0.26.0 phase 2 patch applied")
