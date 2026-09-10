import Foundation
import SwiftUI

struct SelectiveRemoteTeamHostPersonalSettings: Codable, Equatable {
    var preferredUsername: String
    var windowsScale: WindowsScale
    var rdpQuality: RDPQualityPreset
    var audioMode: AudioMode
    var clipboardMode: ClipboardMode
    var mapCommandToControl: Bool
    var mapOptionToWindows: Bool
    var mapRightCommandToWindows: Bool
    var fnSwitchesWindowsLanguage: Bool
    var autoReconnect: Bool
    var reconnectAfterWake: Bool
    var adminSession: Bool
    var rdpWindowMode: RDPWindowMode
    var windowWidth: Int
    var windowHeight: Int
    var selectedDisplayIDs: Set<String>?
    var primaryDisplayID: String?
    var displayLayoutMode: DisplayLayoutMode?

    init(profile: ConnectionProfile) {
        preferredUsername = profile.username
        windowsScale = profile.windowsScale
        rdpQuality = profile.rdpQuality
        audioMode = profile.audioMode
        clipboardMode = profile.clipboardMode
        mapCommandToControl = profile.mapCommandToControl
        mapOptionToWindows = profile.mapOptionToWindows
        mapRightCommandToWindows = profile.mapRightCommandToWindows
        fnSwitchesWindowsLanguage = profile.fnSwitchesWindowsLanguage
        autoReconnect = profile.autoReconnect
        reconnectAfterWake = profile.reconnectAfterWake
        adminSession = profile.adminSession
        rdpWindowMode = profile.rdpWindowMode
        windowWidth = profile.windowWidth
        windowHeight = profile.windowHeight
        selectedDisplayIDs = profile.selectedDisplayIDs.isEmpty ? nil : profile.selectedDisplayIDs
        primaryDisplayID = profile.primaryDisplayID
        displayLayoutMode = profile.displayLayoutMode
    }

    func applying(to sharedProfile: ConnectionProfile) -> ConnectionProfile {
        var profile = sharedProfile
        profile.username = preferredUsername
        profile.windowsScale = windowsScale
        profile.rdpQuality = rdpQuality
        profile.audioMode = audioMode
        profile.clipboardMode = clipboardMode
        profile.mapCommandToControl = mapCommandToControl
        profile.mapOptionToWindows = mapOptionToWindows
        profile.mapRightCommandToWindows = mapRightCommandToWindows
        profile.fnSwitchesWindowsLanguage = fnSwitchesWindowsLanguage
        profile.autoReconnect = autoReconnect
        profile.reconnectAfterWake = reconnectAfterWake
        profile.adminSession = adminSession
        profile.rdpWindowMode = rdpWindowMode
        profile.startFullScreen = rdpWindowMode == .fullScreen
        profile.windowWidth = min(max(windowWidth, 640), 16_384)
        profile.windowHeight = min(max(windowHeight, 480), 16_384)
        if let selectedDisplayIDs, !selectedDisplayIDs.isEmpty {
            profile.selectedDisplayIDs = selectedDisplayIDs
            profile.primaryDisplayID = primaryDisplayID.flatMap {
                selectedDisplayIDs.contains($0) ? $0 : nil
            } ?? selectedDisplayIDs.sorted().first
            profile.displayLayoutMode = displayLayoutMode ?? .automatic
            profile.virtualDisplayOrigins = [:]
        }
        return profile
    }

    var normalized: Self {
        var value = self
        value.preferredUsername = String(
            preferredUsername
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(256)
        )
        value.windowWidth = min(max(windowWidth, 640), 16_384)
        value.windowHeight = min(max(windowHeight, 480), 16_384)
        return value
    }
}

@MainActor
final class SelectiveRemoteTeamHostPersonalSettingsStore: ObservableObject {
    static let shared = SelectiveRemoteTeamHostPersonalSettingsStore()

    @Published private(set) var values: [String: SelectiveRemoteTeamHostPersonalSettings]

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "SelectiveRemote.team-host.personal-settings.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(
               [String: SelectiveRemoteTeamHostPersonalSettings].self,
               from: data
           ) {
            values = decoded
        } else {
            values = [:]
        }
    }

    func settings(
        for host: SelectiveRemoteTeamHost,
        endpoint: String
    ) -> SelectiveRemoteTeamHostPersonalSettings {
        values[key(for: host, endpoint: endpoint)] ?? .init(profile: host.profile)
    }

    func hasSettings(for host: SelectiveRemoteTeamHost, endpoint: String) -> Bool {
        values[key(for: host, endpoint: endpoint)] != nil
    }

    func save(
        _ settings: SelectiveRemoteTeamHostPersonalSettings,
        for host: SelectiveRemoteTeamHost,
        endpoint: String
    ) {
        values[key(for: host, endpoint: endpoint)] = settings.normalized
        persist()
    }

    func reset(for host: SelectiveRemoteTeamHost, endpoint: String) {
        values.removeValue(forKey: key(for: host, endpoint: endpoint))
        persist()
    }

    func appliedProfile(
        for host: SelectiveRemoteTeamHost,
        endpoint: String
    ) -> ConnectionProfile {
        settings(for: host, endpoint: endpoint).applying(to: host.profile)
    }

    private func key(for host: SelectiveRemoteTeamHost, endpoint: String) -> String {
        [
            endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            host.teamID.uuidString.lowercased(),
            host.vaultID.uuidString.lowercased(),
            host.recordID.uuidString.lowercased()
        ].joined(separator: "/")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

@MainActor
struct SelectiveRemoteTeamHostPersonalSettingsView: View {
    let host: SelectiveRemoteTeamHost
    let endpoint: String
    @ObservedObject var store: SelectiveRemoteTeamHostPersonalSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SelectiveRemoteTeamHostPersonalSettings
    @State private var displays: [DisplayDescriptor]

    init(
        host: SelectiveRemoteTeamHost,
        endpoint: String,
        store: SelectiveRemoteTeamHostPersonalSettingsStore
    ) {
        self.host = host
        self.endpoint = endpoint
        self.store = store
        let currentDisplays = DisplayManager().currentDisplays()
        var settings = store.settings(for: host, endpoint: endpoint)
        if host.profile.connectionType == .rdp,
           settings.selectedDisplayIDs?.isEmpty != false {
            let external = currentDisplays.filter { !$0.isBuiltIn }
            let initial = external.isEmpty ? currentDisplays : external
            settings.selectedDisplayIDs = Set(initial.map(\.id))
            settings.primaryDisplayID = initial.first?.id
            settings.displayLayoutMode = .automatic
        }
        _draft = State(initialValue: settings)
        _displays = State(initialValue: currentDisplays)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(UpdateLocalization.text(
                    ru: "Мои настройки Host",
                    en: "My Host Settings"
                ))
                .font(.title2.bold())
                Text(host.profile.friendlyName)
                    .foregroundStyle(.secondary)
            }

            Form {
                Section(UpdateLocalization.text(ru: "Учётная запись", en: "Account")) {
                    TextField(
                        UpdateLocalization.text(ru: "Мой пользователь", en: "My Username"),
                        text: $draft.preferredUsername
                    )
                }

                if host.profile.connectionType == .rdp {
                    Section(UpdateLocalization.text(ru: "Мониторы", en: "Displays")) {
                        if displays.isEmpty {
                            Text(UpdateLocalization.text(
                                ru: "macOS не обнаружила доступные мониторы",
                                en: "macOS did not report any available displays"
                            ))
                            .foregroundStyle(.secondary)
                        } else {
                            MonitorMapView(
                                displays: displays,
                                selectedIDs: draft.selectedDisplayIDs ?? [],
                                primaryID: draft.primaryDisplayID,
                                onToggle: toggleDisplay,
                                onPrimary: setPrimaryDisplay
                            )
                            .frame(height: 220)
                            Text(UpdateLocalization.text(
                                ru: "Щёлкните монитор, чтобы включить или исключить его; звезда выбирает основной экран Windows.",
                                en: "Click a display to include or exclude it; the star selects the primary Windows display."
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Button(
                                UpdateLocalization.text(ru: "Обновить мониторы", en: "Refresh Displays"),
                                systemImage: "arrow.clockwise"
                            ) {
                                refreshDisplays()
                            }
                        }
                    }

                    Section("RDP") {
                        Picker(
                            UpdateLocalization.text(ru: "Режим окна", en: "Window Mode"),
                            selection: $draft.rdpWindowMode
                        ) {
                            ForEach(RDPWindowMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        if draft.rdpWindowMode == .fixedWindow {
                            HStack {
                                TextField(
                                    UpdateLocalization.text(ru: "Ширина", en: "Width"),
                                    value: $draft.windowWidth,
                                    format: .number
                                )
                                TextField(
                                    UpdateLocalization.text(ru: "Высота", en: "Height"),
                                    value: $draft.windowHeight,
                                    format: .number
                                )
                            }
                        }
                        Picker(
                            UpdateLocalization.text(ru: "Масштаб Windows", en: "Windows Scale"),
                            selection: $draft.windowsScale
                        ) {
                            ForEach(WindowsScale.allCases) { scale in
                                Text(scale.title).tag(scale)
                            }
                        }
                        Picker(
                            UpdateLocalization.text(ru: "Качество", en: "Quality"),
                            selection: $draft.rdpQuality
                        ) {
                            ForEach(RDPQualityPreset.allCases) { quality in
                                Text(quality.title).tag(quality)
                            }
                        }
                        Picker(
                            UpdateLocalization.text(ru: "Буфер обмена", en: "Clipboard"),
                            selection: $draft.clipboardMode
                        ) {
                            ForEach(ClipboardMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        Picker(
                            UpdateLocalization.text(ru: "Звук", en: "Audio"),
                            selection: $draft.audioMode
                        ) {
                            ForEach(AudioMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        Toggle(
                            UpdateLocalization.text(ru: "Command → Control", en: "Command → Control"),
                            isOn: $draft.mapCommandToControl
                        )
                        Toggle(
                            UpdateLocalization.text(ru: "Option → Windows", en: "Option → Windows"),
                            isOn: $draft.mapOptionToWindows
                        )
                        Toggle(
                            UpdateLocalization.text(ru: "Правый Command → Windows", en: "Right Command → Windows"),
                            isOn: $draft.mapRightCommandToWindows
                        )
                        Toggle(
                            UpdateLocalization.text(ru: "Fn меняет язык Windows", en: "Fn switches Windows language"),
                            isOn: $draft.fnSwitchesWindowsLanguage
                        )
                        Toggle(
                            UpdateLocalization.text(ru: "Автопереподключение", en: "Auto Reconnect"),
                            isOn: $draft.autoReconnect
                        )
                        Toggle(
                            UpdateLocalization.text(ru: "Переподключаться после сна", en: "Reconnect After Wake"),
                            isOn: $draft.reconnectAfterWake
                        )
                        Toggle(
                            UpdateLocalization.text(ru: "Административная сессия", en: "Administrative Session"),
                            isOn: $draft.adminSession
                        )
                    }
                }
            }
            .formStyle(.grouped)

            Label(
                UpdateLocalization.text(
                    ru: "Эти параметры хранятся только на этом Mac и не меняют общий Host.",
                    en: "These settings are stored only on this Mac and do not change the shared Host."
                ),
                systemImage: "person.crop.circle.badge.checkmark"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button(
                    UpdateLocalization.text(ru: "Сбросить мои настройки", en: "Reset My Settings"),
                    role: .destructive
                ) {
                    store.reset(for: host, endpoint: endpoint)
                    dismiss()
                }
                .disabled(!store.hasSettings(for: host, endpoint: endpoint))
                Spacer()
                Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel")) {
                    dismiss()
                }
                Button(UpdateLocalization.text(ru: "Сохранить", en: "Save")) {
                    store.save(draft, for: host, endpoint: endpoint)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    draft.preferredUsername.contains(where: { $0.isNewline })
                        || draft.preferredUsername.count > 256
                )
            }
        }
        .padding(24)
        .frame(width: 620, height: host.profile.connectionType == .rdp ? 840 : 300)
    }

    private func toggleDisplay(_ display: DisplayDescriptor) {
        var selected = draft.selectedDisplayIDs ?? []
        if selected.contains(display.id) {
            guard selected.count > 1 else { return }
            selected.remove(display.id)
            if draft.primaryDisplayID == display.id {
                draft.primaryDisplayID = displays.first(where: { selected.contains($0.id) })?.id
            }
        } else {
            selected.insert(display.id)
            if draft.primaryDisplayID == nil { draft.primaryDisplayID = display.id }
        }
        draft.selectedDisplayIDs = selected
        draft.displayLayoutMode = .automatic
    }

    private func setPrimaryDisplay(_ display: DisplayDescriptor) {
        var selected = draft.selectedDisplayIDs ?? []
        selected.insert(display.id)
        draft.selectedDisplayIDs = selected
        draft.primaryDisplayID = display.id
        draft.displayLayoutMode = .automatic
    }

    private func refreshDisplays() {
        displays = DisplayManager().currentDisplays()
        let available = Set(displays.map(\.id))
        var selected = (draft.selectedDisplayIDs ?? []).intersection(available)
        if selected.isEmpty {
            let external = displays.filter { !$0.isBuiltIn }
            selected = Set((external.isEmpty ? displays : external).map(\.id))
        }
        draft.selectedDisplayIDs = selected
        if let primary = draft.primaryDisplayID, !selected.contains(primary) {
            draft.primaryDisplayID = displays.first(where: { selected.contains($0.id) })?.id
        }
    }
}
