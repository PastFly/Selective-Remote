import AppKit
import AVFoundation
import Combine
import Darwin
import Foundation
import UniformTypeIdentifiers

private enum SelectiveRemoteAppError: LocalizedError {
    case rdpPasswordRequired
    case savedPasswordMissing
    case savedGatewayPasswordMissing
    case selectedDisplaysUnavailable(Int)
    case overlappingDisplays
    case profileAlreadyRunning
    case activeProfileDeletion

    var errorDescription: String? {
        switch self {
        case .rdpPasswordRequired:
            "Введите пароль RDP. Чтобы использовать пустое поле в дальнейшем, сначала нажмите «Сохранить»."
        case .savedPasswordMissing:
            "Отметка о сохранённом RDP-пароле есть, но Keychain не вернул пароль. Введите его заново и нажмите «Сохранить»."
        case .savedGatewayPasswordMissing:
            "Отметка о сохранённом пароле RD Gateway есть, но Keychain не вернул пароль. Введите его заново и нажмите «Сохранить»."
        case let .selectedDisplaysUnavailable(count):
            "Недоступно выбранных дисплеев: \(count). Подключите их или измените профиль перед запуском."
        case .overlappingDisplays:
            "В ручной виртуальной схеме мониторы перекрываются. Разведите их перед подключением."
        case .profileAlreadyRunning:
            "Этот профиль уже подключён. Можно одновременно запускать другие профили."
        case .activeProfileDeletion:
            "Сначала отключите активную RDP/SSH-сессию и остановите SSH-туннели этого профиля."
        }
    }
}

enum SessionTerminationClassifier {
    static func isExpected(
        status: Int32,
        log: String,
        disconnectRequested: Bool
    ) -> Bool {
        if disconnectRequested || status == 0 {
            return true
        }
        if status == SIGTERM || status == SIGKILL {
            return log.contains("[SelectiveRemote Host] SIGTERM:")
        }
        return status == 131
            && log.contains("ERRCONNECT_CONNECT_CANCELLED")
            && log.contains("Connection aborted by user")
    }
}

enum SessionLogClassifier {
    enum CapturePermission: Equatable {
        case microphone
        case camera
    }

    /// Host markers and FreeRDP build warnings appear before authentication.
    /// The GDI framebuffer is created only after the remote desktop is ready.
    static func hasEstablishedDesktop(_ log: String) -> Bool {
        log.contains("[com.freerdp.gdi]")
            && (
                log.contains("Local framebuffer format")
                    || log.contains("Remote framebuffer format")
            )
    }

    static func deniedCapturePermission(_ log: String) -> CapturePermission? {
        if privacyPreflightFailed(log, permission: "camera") {
            return .camera
        }
        if privacyPreflightFailed(log, permission: "microphone")
            || log.contains("audin_mac_close]: not authorized") {
            return .microphone
        }
        if let permission = privacyViolationPermission(log) {
            return permission
        }
        return nil
    }

    static func pendingCapturePermission(_ log: String) -> CapturePermission? {
        for permission: CapturePermission in [.microphone, .camera] {
            let name = permission == .microphone ? "microphone" : "camera"
            guard log.contains("[SelectiveRemote Privacy] requesting \(name)")
            else { continue }
            let resolved = ["authorized", "granted", "denied", "restricted", "timeout", "unknown"]
                .contains { state in
                    log.contains("[SelectiveRemote Privacy] \(state) \(name)")
                }
            if !resolved { return permission }
        }
        return nil
    }

    static func hasCompletedCapturePermissionPreflight(_ log: String) -> Bool {
        log.contains("[SelectiveRemote Privacy] ready capture")
    }

    static func disabledCapturePermissions(_ log: String) -> [CapturePermission] {
        var result: [CapturePermission] = []
        if log.contains("[SelectiveRemote Privacy] disabled microphone")
            || log.contains("audin_mac_close]: not authorized") {
            result.append(.microphone)
        }
        if log.contains("[SelectiveRemote Privacy] disabled camera") {
            result.append(.camera)
        }
        return result
    }

    private static func privacyPreflightFailed(
        _ log: String,
        permission: String
    ) -> Bool {
        ["denied", "restricted", "timeout", "unknown"].contains { state in
            log.contains("[SelectiveRemote Privacy] \(state) \(permission)")
        }
    }

    private static func privacyViolationPermission(
        _ log: String
    ) -> CapturePermission? {
        guard log.contains("__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__")
        else { return nil }

        let microphone = log.range(
            of: "[SelectiveRemote Privacy] requesting microphone",
            options: .backwards
        )
        let camera = log.range(
            of: "[SelectiveRemote Privacy] requesting camera",
            options: .backwards
        )
        if let camera {
            guard let microphone else { return .camera }
            if camera.lowerBound > microphone.lowerBound {
                return .camera
            }
        }
        // Microphone is the safe default for old logs that lack a preflight
        // marker because audin is initialized before RDPECAM.
        return .microphone
    }
}

enum SessionWindowDetector {
    private static let minimumWidth = 640.0
    private static let minimumHeight = 400.0

    /// FreeRDP INFO messages can remain buffered while stdout is redirected to
    /// the session log. WindowServer provides an independent readiness signal
    /// that also works when the fullscreen window lives on another Space.
    static func hasSessionWindow(processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0,
              let windows = CGWindowListCopyWindowInfo(
                .excludeDesktopElements,
                kCGNullWindowID
              ) as? [[String: Any]]
        else { return false }

        return hasSessionWindow(
            processIdentifier: processIdentifier,
            windows: windows
        )
    }

    static func hasSessionWindow(
        processIdentifier: Int32,
        windows: [[String: Any]]
    ) -> Bool {
        windows.contains { window in
            let ownerPID = number(
                window[kCGWindowOwnerPID as String]
            )?.int32Value
            guard ownerPID == processIdentifier,
                  number(window[kCGWindowLayer as String])?.intValue == 0,
                  (number(window[kCGWindowAlpha as String])?.doubleValue ?? 1) > 0.01,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let width = number(bounds["Width"])?.doubleValue,
                  let height = number(bounds["Height"])?.doubleValue
            else { return false }

            return width >= minimumWidth && height >= minimumHeight
        }
    }

    private static func number(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }
}

enum RDPSessionPhase: String, Equatable {
    case starting = "Запускается"
    case connected = "Подключено"
    case disconnecting = "Отключается"
}

struct RDPSessionSummary: Identifiable, Equatable {
    let id: UUID
    let profileName: String
    let host: String
    let startedAt: Date
    let selectedDisplayIDs: Set<String>
    var phase: RDPSessionPhase
    let logURL: URL
}

@MainActor
private final class ManagedRDPSession {
    let profileID: UUID
    let profileName: String
    let host: String
    let selectedDisplayIDs: Set<String>
    let connection: RunningRDPSession
    let startedAt = Date()
    var phase = RDPSessionPhase.starting
    var disconnectRequested = false
    var interruptionReason: String?
    var desktopReadyDetected = false
    var startupWarningShown = false
    var privacyReadyAt: Date?

    init(profile: ConnectionProfile, connection: RunningRDPSession) {
        profileID = profile.id
        profileName = profile.friendlyName
        host = profile.host
        selectedDisplayIDs = profile.selectedDisplayIDs
        self.connection = connection
    }

    var summary: RDPSessionSummary {
        RDPSessionSummary(
            id: profileID,
            profileName: profileName,
            host: host,
            startedAt: startedAt,
            selectedDisplayIDs: selectedDisplayIDs,
            phase: phase,
            logURL: connection.logURL
        )
    }
}

@MainActor
final class AppModel: NSObject, ObservableObject {
    let sftpSession = SFTPBrowserSession()
    let globalSFTPSession = SFTPBrowserSession()
    @Published private(set) var displays: [DisplayDescriptor] = []
    @Published private(set) var cameras: [CameraDeviceDescriptor] = []
    @Published var profiles: [ConnectionProfile] {
        didSet { scheduleProfileSave() }
    }
    @Published var selectedProfileID: UUID? {
        didSet {
            saveSelectedProfileID()
            password = ""
            gatewayPassword = ""
            sshPassword = ""
            proxyPassword = ""
            errorMessage = nil
        }
    }
    @Published var password = ""
    @Published var gatewayPassword = ""
    @Published var sshPassword = ""
    @Published var proxyPassword = ""
    @Published var searchText = ""
    @Published var profileSortMode: ProfileSortMode {
        didSet { UserDefaults.standard.set(profileSortMode.rawValue, forKey: sortModeKey) }
    }
    @Published var statusMessage = ""
    @Published var errorMessage: String?
    @Published var updateMessage: String?
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var availableUpdateURL: URL?
    @Published private(set) var availableReleaseNotesURL: URL?
    @Published private(set) var sessions: [UUID: RDPSessionSummary] = [:]
    @Published private(set) var passwordStoredProfileIDs: Set<String> = []
    @Published private(set) var gatewayPasswordStoredProfileIDs: Set<String> = []
    @Published private(set) var sshPasswordStoredProfileIDs: Set<String> = []
    @Published private(set) var sshPasswordUserPresenceProfileIDs: Set<String> = []
    @Published private(set) var sshKeyUserPresenceProfileIDs: Set<String> = []
    @Published private(set) var forwardingPasswordStoredIDs: Set<String> = []
    @Published private(set) var forwardingPasswordUserPresenceIDs: Set<String> = []
    @Published private(set) var reconnectCandidateProfileIDs: Set<UUID> = []
    @Published var sshKeys: [SSHKeyRecord] {
        didSet { saveSSHKeys() }
    }
    @Published private(set) var sshKeyPassphraseStoredIDs: Set<String> = []
    @Published private(set) var sshTunnels: [UUID: SSHTunnelSummary] = [:]
    @Published private(set) var requestedSSHConsoleProfileID: UUID? = nil
    @Published var independentPortForwards: [IndependentPortForward] {
        didSet { saveIndependentPortForwards() }
    }

    private let displayManager = DisplayManager()
    private let overlay = DisplayNumberOverlay()
    private let freeRDP = FreeRDPService()
    private let profilesKey = "SelectiveRemote.connectionProfiles.v2"
    private let selectedProfileKey = "SelectiveRemote.selectedProfileID.v2"
    private let legacyProfileKey = "SelectiveRemote.connectionProfile.v1"
    private let storedPasswordProfilesKey = "SelectiveRemote.storedPasswordProfiles.v1"
    private let storedGatewayPasswordProfilesKey = "SelectiveRemote.storedGatewayPasswordProfiles.v1"
    private let storedSSHPasswordProfilesKey = "SelectiveRemote.storedSSHPasswordProfiles.v1"
    private let sshPasswordUserPresenceProfilesKey = "SelectiveRemote.sshPasswordUserPresenceProfiles.v1"
    private let sshKeyUserPresenceProfilesKey = "SelectiveRemote.sshKeyUserPresenceProfiles.v1"
    private let storedForwardingPasswordIDsKey = "SelectiveRemote.storedForwardingPasswordIDs.v1"
    private let forwardingPasswordUserPresenceIDsKey = "SelectiveRemote.forwardingPasswordUserPresenceIDs.v1"
    private let sshKeysKey = "SelectiveRemote.sshKeys.v1"
    private let storedSSHKeyPassphrasesKey = "SelectiveRemote.storedSSHKeyPassphrases.v1"
    private let sortModeKey = "SelectiveRemote.profileSortMode.v1"
    private let lastSuccessfulUpdateCheckKey = "SelectiveRemote.lastSuccessfulUpdateCheck.v1"
    private let independentPortForwardsKey = "SelectiveRemote.independentPortForwards.v1"
    private static let globalTerminalWorkspaceID = UUID(
        uuidString: "72A7656C-289F-4E2D-9775-8AC0C24EFD55"
    )!
    private static let globalForwardingProfileID = UUID(
        uuidString: "227C7A86-DA01-48C2-8098-0C995E75DB79"
    )!
    private var managedSessions: [UUID: ManagedRDPSession] = [:]
    private var lastSessionLogURLs: [UUID: URL] = [:]
    private var managedSSHTunnels: [UUID: RunningSSHTunnel] = [:]
    private var lastSSHTunnelLogURLs: [UUID: URL] = [:]
    private var stoppingSSHTunnelIDs: Set<UUID> = []
    private var sshTerminalSessions: [UUID: TerminalSessionModel] = [:]
    private var sshTerminalObservers: [UUID: AnyCancellable] = [:]
    private var terminalWorkspaces: [UUID: TerminalWorkspaceModel] = [:]
    private var terminalWorkspaceObservers: [UUID: AnyCancellable] = [:]
    private var sessionTimer: Timer?
    private var sshTunnelTimer: Timer?
    private var profileSaveTask: Task<Void, Never>?
    private var displayRefreshTask: Task<Void, Never>?
    private var sleepInterruptedProfileIDs: Set<UUID> = []

    override init() {
        let savedProfiles: [ConnectionProfile]
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([ConnectionProfile].self, from: data),
           !decoded.isEmpty {
            savedProfiles = decoded
        } else if let data = UserDefaults.standard.data(forKey: legacyProfileKey),
                  let legacy = try? JSONDecoder().decode(LegacyConnectionProfile.self, from: data) {
            var migrated = ConnectionProfile()
            migrated.friendlyName = legacy.host.isEmpty ? "Первое подключение" : legacy.host
            migrated.host = legacy.host
            migrated.username = legacy.username
            migrated.selectedDisplayIDs = legacy.selectedDisplayIDs
            migrated.primaryDisplayID = legacy.primaryDisplayID
            savedProfiles = [migrated]
        } else {
            savedProfiles = [ConnectionProfile()]
        }
        if let data = UserDefaults.standard.data(forKey: sshKeysKey),
           let decoded = try? JSONDecoder().decode([SSHKeyRecord].self, from: data) {
            sshKeys = decoded
        } else {
            sshKeys = []
        }
        if let data = UserDefaults.standard.data(forKey: independentPortForwardsKey),
           let decoded = try? JSONDecoder().decode(
               [IndependentPortForward].self,
               from: data
           ) {
            independentPortForwards = decoded
        } else {
            independentPortForwards = []
        }

        profiles = savedProfiles
        let savedSort = UserDefaults.standard.string(forKey: sortModeKey)
        profileSortMode = ProfileSortMode(rawValue: savedSort ?? "") ?? .favoritesAndName
        if let rawID = UserDefaults.standard.string(forKey: selectedProfileKey),
           let savedID = UUID(uuidString: rawID),
           savedProfiles.contains(where: { $0.id == savedID }) {
            selectedProfileID = savedID
        } else {
            selectedProfileID = savedProfiles.first?.id
        }

        super.init()
        passwordStoredProfileIDs = Set(
            UserDefaults.standard.stringArray(forKey: storedPasswordProfilesKey) ?? []
        )
        gatewayPasswordStoredProfileIDs = Set(
            UserDefaults.standard.stringArray(forKey: storedGatewayPasswordProfilesKey) ?? []
        )
        sshPasswordStoredProfileIDs = Set(
            UserDefaults.standard.stringArray(forKey: storedSSHPasswordProfilesKey) ?? []
        )
        sshPasswordUserPresenceProfileIDs = Set(
            UserDefaults.standard.stringArray(forKey: sshPasswordUserPresenceProfilesKey) ?? []
        )
        sshKeyUserPresenceProfileIDs = Set(
            UserDefaults.standard.stringArray(forKey: sshKeyUserPresenceProfilesKey) ?? []
        )
        forwardingPasswordStoredIDs = Set(
            UserDefaults.standard.stringArray(forKey: storedForwardingPasswordIDsKey) ?? []
        )
        forwardingPasswordUserPresenceIDs = Set(
            UserDefaults.standard.stringArray(forKey: forwardingPasswordUserPresenceIDsKey) ?? []
        )
        sshKeyPassphraseStoredIDs = Set(
            UserDefaults.standard.stringArray(forKey: storedSSHKeyPassphrasesKey) ?? []
        )
        refreshDisplays(configureEmptyProfile: true)
        refreshCameras(announce: false)
        installNotifications()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.checkForUpdatesAutomatically()
        }
    }

    var selectedProfile: ConnectionProfile {
        profiles.first(where: { $0.id == selectedProfileID }) ?? profiles[0]
    }

    var placements: [DisplayPlacement] {
        guard let profile = DisplaySelectionResolver.runtimeProfile(
            from: selectedProfile,
            displays: displays
        ) else { return [] }
        return VirtualTopologyMapper.layout(
            displays: displays,
            selectedIDs: profile.selectedDisplayIDs,
            primaryID: profile.primaryDisplayID,
            mode: profile.displayLayoutMode,
            customOrigins: profile.virtualDisplayOrigins
        )
    }

    var hasOverlappingPlacements: Bool {
        selectedProfile.displayLayoutMode == .custom
            && VirtualTopologyMapper.hasOverlaps(placements)
    }

    var unavailableSelectedDisplayCount: Int {
        let available = Set(displays.map(\.id))
        return selectedProfile.selectedDisplayIDs.subtracting(available).count
    }

    var effectiveSelectedDisplayIDs: Set<String> {
        DisplaySelectionResolver.runtimeProfile(
            from: selectedProfile,
            displays: displays
        )?.selectedDisplayIDs ?? []
    }

    var effectivePrimaryDisplayID: String? {
        DisplaySelectionResolver.runtimeProfile(
            from: selectedProfile,
            displays: displays
        )?.primaryDisplayID
    }

    var canConnect: Bool {
        let hostPresent = !selectedProfile.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        switch selectedProfile.connectionType {
        case .rdp:
            return hostPresent
                && !placements.isEmpty
                && !hasOverlappingPlacements
                && !isSessionRunning(profileID: selectedProfile.id)
        case .ssh:
            return hostPresent && (1...65_535).contains(selectedProfile.sshPort)
        }
    }

    var isSessionRunning: Bool { !sessions.isEmpty }
    var runningSessionCount: Int { sessions.count }
    var runningSSHTunnelCount: Int { sshTunnels.count }
    var runningSSHTerminalCount: Int {
        let workspaceProfileIDs = Set(terminalWorkspaces.keys)
        let workspaceCount = terminalWorkspaces.values.reduce(0) {
            $0 + $1.runningSessionCount
        }
        let legacyCount = sshTerminalSessions
            .filter { !workspaceProfileIDs.contains($0.key) && $0.value.isRunning }
            .count
        return workspaceCount + legacyCount
    }
    var isSelectedSessionRunning: Bool { isSessionRunning(profileID: selectedProfile.id) }
    var selectedProfileHasActiveTunnels: Bool {
        sshTunnels.values.contains(where: { $0.profileID == selectedProfile.id })
    }
    var isSelectedSSHTerminalRunning: Bool {
        isSSHTerminalRunning(profileID: selectedProfile.id)
    }
    var selectedProfileHasSavedPassword: Bool {
        passwordStoredProfileIDs.contains(selectedProfile.id.uuidString)
    }
    var selectedProfileHasSavedGatewayPassword: Bool {
        gatewayPasswordStoredProfileIDs.contains(selectedProfile.id.uuidString)
    }
    var selectedProfileHasSavedSSHPassword: Bool {
        hasSavedSSHPassword(profileID: selectedProfile.id)
    }
    var selectedSSHPasswordRequiresUserPresence: Bool {
        sshPasswordRequiresUserPresence(profileID: selectedProfile.id)
    }
    func hasSavedSSHPassword(profileID: UUID) -> Bool {
        sshPasswordStoredProfileIDs.contains(profileID.uuidString)
    }
    func sshPasswordRequiresUserPresence(profileID: UUID) -> Bool {
        sshPasswordUserPresenceProfileIDs.contains(profileID.uuidString)
    }
    var selectedProfileHasSavedProxyPassword: Bool {
        KeychainService.passwordExists(
            reference: KeychainService.credentialReference(profileID: selectedProfile.id, kind: .proxy)
        )
    }
    var selectedSSHKeyRequiresUserPresence: Bool {
        sshKeyRequiresUserPresence(profileID: selectedProfile.id)
    }
    func sshKeyRequiresUserPresence(profileID: UUID) -> Bool {
        sshKeyUserPresenceProfileIDs.contains(profileID.uuidString)
    }
    var touchIDAvailable: Bool {
        KeychainService.touchIDAvailable
    }

    func hasSavedForwardingPassword(_ tunnelID: UUID) -> Bool {
        forwardingPasswordStoredIDs.contains(tunnelID.uuidString)
    }
    func forwardingPasswordRequiresUserPresence(_ tunnelID: UUID) -> Bool {
        forwardingPasswordUserPresenceIDs.contains(tunnelID.uuidString)
    }
    var sessionLogURL: URL? {
        guard selectedProfile.connectionType == .rdp else { return nil }
        return sessions[selectedProfile.id]?.logURL ?? lastSessionLogURLs[selectedProfile.id]
    }
    var runningSessions: [RDPSessionSummary] {
        sessions.values.sorted { $0.startedAt < $1.startedAt }
    }
    var favoriteRDPProfiles: [ConnectionProfile] {
        profiles.filter { $0.connectionType == .rdp && $0.isFavorite }
            .sorted { $0.friendlyName.localizedCaseInsensitiveCompare($1.friendlyName) == .orderedAscending }
    }
    var canReconnectSelectedProfile: Bool {
        selectedProfile.connectionType == .rdp
            && reconnectCandidateProfileIDs.contains(selectedProfile.id)
            && !isSelectedSessionRunning
    }

    var selectedSSHKey: SSHKeyRecord? {
        guard let keyID = selectedProfile.sshIdentityID else { return nil }
        return sshKeys.first(where: { $0.id == keyID })
    }

    func hasSavedSSHKeyPassphrase(keyID: UUID) -> Bool {
        sshKeyPassphraseStoredIDs.contains(keyID.uuidString)
    }

    func isSSHTunnelRunning(ruleID: UUID) -> Bool {
        managedSSHTunnels[ruleID]?.process.isRunning == true
    }

    func isSSHTerminalRunning(profileID: UUID) -> Bool {
        terminalWorkspaces[profileID]?.hasRunningSession == true
            || sshTerminalSessions[profileID]?.isRunning == true
    }

    func terminalSession(profileID: UUID) -> TerminalSessionModel {
        if let existing = sshTerminalSessions[profileID] {
            return existing
        }
        let session = TerminalSessionModel()
        sshTerminalSessions[profileID] = session
        sshTerminalObservers[profileID] = session.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
        return session
    }

    func terminalWorkspace(
        profileID: UUID,
        primaryConnection: TerminalTabConnection? = nil
    ) -> TerminalWorkspaceModel {
        if let existing = terminalWorkspaces[profileID] {
            return existing
        }
        let workspace = TerminalWorkspaceModel(
            profileID: profileID,
            primarySession: terminalSession(profileID: profileID),
            primaryConnection: primaryConnection
        )
        terminalWorkspaces[profileID] = workspace
        terminalWorkspaceObservers[profileID] = workspace.objectWillChange.sink {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
        return workspace
    }

    func globalTerminalWorkspace() -> TerminalWorkspaceModel {
        let initialConnection = profiles.first(where: { $0.connectionType == .ssh })
            .map { TerminalTabConnection.savedProfile($0.id) }
            ?? .custom(host: "", username: "")
        return terminalWorkspace(
            profileID: Self.globalTerminalWorkspaceID,
            primaryConnection: initialConnection
        )
    }

    func consumeSSHConsoleNavigationRequest() {
        requestedSSHConsoleProfileID = nil
    }

    var cameraSelectionToken: String {
        switch selectedProfile.cameraSelectionMode {
        case .builtIn:
            CameraSelectionToken.builtIn
        case .automatic:
            CameraSelectionToken.automatic
        case .specific:
            selectedProfile.cameraDeviceID.map(CameraSelectionToken.device)
                ?? CameraSelectionToken.builtIn
        }
    }

    var selectedCameraUnavailable: Bool {
        guard selectedProfile.cameraSelectionMode == .specific,
              let id = selectedProfile.cameraDeviceID
        else { return false }
        return !cameras.contains(where: { $0.id == id })
    }

    var cameraSelectionDescription: String {
        switch selectedProfile.cameraSelectionMode {
        case .builtIn:
            if let camera = cameras.first(where: { $0.kind == .builtIn }) {
                return "\(camera.name) · встроенная"
            }
            return "Встроенная камера не обнаружена · будет выбрана доступная"
        case .automatic:
            return "macOS выберет системную камеру"
        case .specific:
            guard let id = selectedProfile.cameraDeviceID else {
                return "Устройство не выбрано · будет использована встроенная камера"
            }
            if let camera = cameras.first(where: { $0.id == id }) {
                return camera.displayName
            }
            let savedName = selectedProfile.cameraDeviceName ?? "Сохранённая камера"
            return "\(savedName) · сейчас недоступна, будет использована встроенная"
        }
    }

    var profileGroups: [ProfileGroupSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [ConnectionProfile]
        if query.isEmpty {
            filtered = profiles
        } else {
            filtered = profiles.filter { profile in
                profile.friendlyName.localizedCaseInsensitiveContains(query)
                    || profile.host.localizedCaseInsensitiveContains(query)
                    || profile.username.localizedCaseInsensitiveContains(query)
                    || profile.group.localizedCaseInsensitiveContains(query)
                    || profile.connectionType.title.localizedCaseInsensitiveContains(query)
            }
        }
        let grouped = Dictionary(grouping: filtered) { profile in
            let value = profile.group.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "Без группы" : value
        }
        return grouped.keys.sorted { lhs, rhs in
            if lhs == rhs { return false }
            if lhs == "Без группы" { return true }
            if rhs == "Без группы" { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }.map { group in
            ProfileGroupSection(name: group, profiles: sortProfiles(grouped[group] ?? []))
        }
    }

    func isSessionRunning(profileID: UUID) -> Bool {
        sessions[profileID] != nil
    }

    func updateSelectedProfile(_ updated: ConnectionProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == updated.id }),
              profiles[index] != updated
        else { return }
        profiles[index] = updated
    }

    func mutateSelectedProfile(_ update: (inout ConnectionProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        var updated = profiles[index]
        update(&updated)
        guard updated != profiles[index] else { return }
        profiles[index] = updated
    }

    func selectProfile(_ id: UUID) {
        selectedProfileID = id
        if let session = sessions[id] {
            statusMessage = session.phase.rawValue
        } else if let profile = profiles.first(where: { $0.id == id }) {
            statusMessage = "\(profile.connectionType.title)-профиль выбран"
        }
    }

    func addProfile(connectionType: ConnectionType = .rdp) {
        var profile = ConnectionProfile(connectionType: connectionType)
        if connectionType == .rdp {
            configureDefaultDisplays(for: &profile)
        }
        profiles.append(profile)
        selectedProfileID = profile.id
        statusMessage = "Создан новый \(connectionType.title)-профиль"
    }

    @discardableResult
    func saveManualSSHProfile(
        host: String,
        username: String,
        port: Int,
        name: String,
        password: String = ""
    ) -> UUID? {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, (1...65535).contains(port) else {
            errorMessage = "Укажите корректный SSH-адрес и порт"
            return nil
        }
        let normalizedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveUser = normalizedUser.isEmpty ? "root" : normalizedUser
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        var profile = ConnectionProfile(connectionType: .ssh)
        profile.friendlyName = normalizedName.isEmpty ? normalizedHost : normalizedName
        profile.host = normalizedHost
        profile.username = effectiveUser
        profile.sshPort = port
        profile.sshAuthenticationMode = password.isEmpty ? .automatic : .password
        profiles.append(profile)

        if !password.isEmpty {
            do {
                try KeychainService.savePassword(password, profileID: profile.id, kind: .ssh)
                setPasswordStored(true, profileID: profile.id, kind: .ssh)
            } catch {
                profiles.removeAll { $0.id == profile.id }
                errorMessage = error.localizedDescription
                return nil
            }
        }

        statusMessage = "SSH-подключение «\(profile.friendlyName)» сохранено"
        errorMessage = nil
        return profile.id
    }

    func duplicateSelectedProfile() {
        var copy = selectedProfile
        copy.id = UUID()
        copy.friendlyName += " — копия"
        copy.isFavorite = false
        copy.createdAt = Date()
        copy.lastConnectedAt = nil
        copy.portForwards = copy.portForwards.map { rule in
            var value = rule
            value.id = UUID()
            return value
        }
        profiles.append(copy)
        selectedProfileID = copy.id
        statusMessage = "Профиль скопирован без паролей"
    }

    func deleteSelectedProfile() {
        guard let id = selectedProfileID else { return }
        guard !isSessionRunning(profileID: id),
              !isSSHTerminalRunning(profileID: id),
              !sshTunnels.values.contains(where: { $0.profileID == id })
        else {
            errorMessage = SelectiveRemoteAppError.activeProfileDeletion.localizedDescription
            return
        }
        try? KeychainService.deleteAllPasswords(profileID: id)
        setPasswordStored(false, profileID: id, kind: .rdp)
        setPasswordStored(false, profileID: id, kind: .gateway)
        setPasswordStored(false, profileID: id, kind: .ssh)
        reconnectCandidateProfileIDs.remove(id)
        sshTerminalSessions.removeValue(forKey: id)
        sshTerminalObservers.removeValue(forKey: id)
        terminalWorkspaces.removeValue(forKey: id)
        terminalWorkspaceObservers.removeValue(forKey: id)
        UserDefaults.standard.removeObject(
            forKey: "SelectiveRemote.terminal.workspace.v1.\(id.uuidString)"
        )
        profiles.removeAll { $0.id == id }
        if profiles.isEmpty {
            var replacement = ConnectionProfile()
            configureDefaultDisplays(for: &replacement)
            profiles = [replacement]
        }
        selectedProfileID = profiles.first?.id
        statusMessage = "Профиль удалён"
    }

    func toggleFavorite() {
        mutateSelectedProfile { $0.isFavorite.toggle() }
    }

    func refreshDisplays() {
        refreshDisplays(configureEmptyProfile: true)
    }

    func refreshCameras() {
        refreshCameras(announce: true)
    }

    func setCameraSelectionToken(_ token: String) {
        mutateSelectedProfile { profile in
            switch token {
            case CameraSelectionToken.builtIn:
                profile.cameraSelectionMode = .builtIn
                profile.cameraDeviceID = nil
                profile.cameraDeviceName = nil
            case CameraSelectionToken.automatic:
                profile.cameraSelectionMode = .automatic
                profile.cameraDeviceID = nil
                profile.cameraDeviceName = nil
            default:
                guard let id = CameraSelectionToken.deviceID(from: token),
                      let device = cameras.first(where: { $0.id == id })
                else { return }
                profile.cameraSelectionMode = .specific
                profile.cameraDeviceID = device.id
                profile.cameraDeviceName = device.name
            }
        }
        statusMessage = "Камера: \(cameraSelectionDescription)"
    }

    func forgetUnavailableDisplays() {
        let availableIDs = Set(displays.map(\.id))
        mutateSelectedProfile { profile in
            profile.selectedDisplayIDs.formIntersection(availableIDs)
            profile.virtualDisplayOrigins = profile.virtualDisplayOrigins.filter {
                availableIDs.contains($0.key)
            }
            if let primary = profile.primaryDisplayID,
               !profile.selectedDisplayIDs.contains(primary) {
                profile.primaryDisplayID = displays.first(where: {
                    profile.selectedDisplayIDs.contains($0.id)
                })?.id
            }
        }
        reconnectCandidateProfileIDs.remove(selectedProfile.id)
        statusMessage = "Недоступные мониторы удалены из профиля"
    }

    func toggleSelection(_ display: DisplayDescriptor) {
        mutateSelectedProfile { profile in
            if profile.selectedDisplayIDs.contains(display.id) {
                profile.selectedDisplayIDs.remove(display.id)
                profile.virtualDisplayOrigins.removeValue(forKey: display.id)
                if profile.primaryDisplayID == display.id {
                    profile.primaryDisplayID = displays.first(where: {
                        profile.selectedDisplayIDs.contains($0.id)
                    })?.id
                }
            } else {
                if profile.displayLayoutMode == .custom && profile.virtualDisplayOrigins.isEmpty {
                    let existing = VirtualTopologyMapper.layout(
                        displays: displays,
                        selectedIDs: profile.selectedDisplayIDs,
                        primaryID: profile.primaryDisplayID,
                        mode: .automatic,
                        customOrigins: [:]
                    )
                    profile.virtualDisplayOrigins = VirtualTopologyMapper.origins(from: existing)
                }
                profile.selectedDisplayIDs.insert(display.id)
                if profile.primaryDisplayID == nil { profile.primaryDisplayID = display.id }
                if profile.displayLayoutMode == .custom {
                    let existing = VirtualTopologyMapper.layout(
                        displays: displays,
                        selectedIDs: profile.selectedDisplayIDs.subtracting([display.id]),
                        primaryID: profile.primaryDisplayID,
                        mode: .custom,
                        customOrigins: profile.virtualDisplayOrigins
                    )
                    let nextX = existing.map(\.virtualFrame.maxX).max() ?? 0
                    profile.virtualDisplayOrigins[display.id] = VirtualDisplayPosition(
                        x: Int(nextX.rounded()),
                        y: 0
                    )
                }
            }
        }
    }

    func setPrimary(_ display: DisplayDescriptor) {
        mutateSelectedProfile { profile in
            profile.selectedDisplayIDs.insert(display.id)
            profile.primaryDisplayID = display.id
            normalizeCustomOrigins(profile: &profile)
        }
    }

    func setDisplayLayoutMode(_ mode: DisplayLayoutMode) {
        mutateSelectedProfile { profile in
            if mode == .custom && profile.displayLayoutMode != .custom {
                let automatic = VirtualTopologyMapper.layout(
                    displays: displays,
                    selectedIDs: profile.selectedDisplayIDs,
                    primaryID: profile.primaryDisplayID,
                    mode: .automatic,
                    customOrigins: [:]
                )
                profile.virtualDisplayOrigins = VirtualTopologyMapper.origins(from: automatic)
            }
            profile.displayLayoutMode = mode
        }
    }

    func moveVirtualDisplay(_ id: String, to position: VirtualDisplayPosition) {
        mutateSelectedProfile { profile in
            profile.displayLayoutMode = .custom
            profile.virtualDisplayOrigins[id] = position
            normalizeCustomOrigins(profile: &profile)
        }
    }

    func arrangeVirtualDisplays(_ preset: DisplayArrangementPreset) {
        mutateSelectedProfile { profile in
            profile.displayLayoutMode = .custom
            profile.virtualDisplayOrigins = VirtualTopologyMapper.arrangedOrigins(
                displays: displays,
                selectedIDs: profile.selectedDisplayIDs,
                primaryID: profile.primaryDisplayID,
                preset: preset
            )
        }
    }

    func resetVirtualLayout() {
        mutateSelectedProfile { profile in
            profile.displayLayoutMode = .automatic
            profile.virtualDisplayOrigins = [:]
        }
    }

    func showNumbers() {
        overlay.show(displays: displays)
    }

    func savePassword() {
        saveCredential(password, kind: .rdp)
    }

    func deleteSavedPassword() {
        deleteCredential(kind: .rdp)
    }

    func saveGatewayPassword() {
        saveCredential(gatewayPassword, kind: .gateway)
    }

    func deleteSavedGatewayPassword() {
        deleteCredential(kind: .gateway)
    }

    func saveSSHPassword() {
        saveCredential(
            sshPassword,
            kind: .ssh,
            requiresUserPresence: selectedSSHPasswordRequiresUserPresence
        )
    }

    func saveProxyPassword() {
        guard !proxyPassword.isEmpty else { return }
        do {
            try KeychainService.savePassword(proxyPassword, profileID: selectedProfile.id, kind: .proxy)
            proxyPassword = ""
            statusMessage = "Пароль прокси сохранён в Keychain"
            errorMessage = nil
            objectWillChange.send()
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteSavedProxyPassword() {
        do {
            try KeychainService.deletePassword(profileID: selectedProfile.id, kind: .proxy)
            proxyPassword = ""
            statusMessage = "Пароль прокси удалён из Keychain"
            errorMessage = nil
            objectWillChange.send()
        } catch { errorMessage = error.localizedDescription }
    }

    func setSelectedSSHPasswordUserPresence(_ enabled: Bool) {
        setSSHPasswordUserPresence(enabled, profileID: selectedProfile.id)
    }

    func setSelectedSSHKeyUserPresence(_ enabled: Bool) {
        setSSHKeyUserPresenceForProfile(enabled, profileID: selectedProfile.id)
    }

    func setSSHKeyUserPresenceForProfile(_ enabled: Bool, profileID: UUID) {
        do {
            try setSSHKeyUserPresence(enabled, profileID: profileID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSSHKeyUserPresence(
        _ enabled: Bool,
        profileID: UUID,
        announce: Bool = true
    ) throws {
        if enabled && !KeychainService.touchIDAvailable {
            throw KeychainError.touchIDUnavailable(
                "Touch ID недоступен на этом Mac или для текущего пользователя."
            )
        }
        try KeychainService.setSSHKeyUseProtection(profileID: profileID, enabled: enabled)
        let key = profileID.uuidString
        if enabled { sshKeyUserPresenceProfileIDs.insert(key) }
        else { sshKeyUserPresenceProfileIDs.remove(key) }
        UserDefaults.standard.set(
            sshKeyUserPresenceProfileIDs.sorted(),
            forKey: sshKeyUserPresenceProfilesKey
        )
        if announce {
            statusMessage = enabled
                ? "Для использования SSH-ключа требуется Touch ID"
                : "Touch ID перед использованием SSH-ключа отключён"
        }
        errorMessage = nil
    }

    func deleteSavedSSHPassword() {
        deleteCredential(kind: .ssh)
    }

    func deleteSavedSSHPassword(profileID: UUID) {
        do {
            try KeychainService.deletePassword(profileID: profileID, kind: .ssh)
            setPasswordStored(false, profileID: profileID, kind: .ssh)
            sshPasswordUserPresenceProfileIDs.remove(profileID.uuidString)
            UserDefaults.standard.set(
                sshPasswordUserPresenceProfileIDs.sorted(),
                forKey: sshPasswordUserPresenceProfilesKey
            )
            if profileID == selectedProfile.id {
                sshPassword = ""
            }
            statusMessage = "SSH-пароль удалён из Keychain"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func repairSelectedSSHCredentialAccess() {
        repairSSHCredentialAccess(profileID: selectedProfile.id)
    }

    func repairSSHCredentialAccess(profileID: UUID) {
        do {
            try KeychainService.repairPasswordAccess(profileID: profileID, kind: .ssh)
            setPasswordStored(false, profileID: profileID, kind: .ssh)
            sshPasswordUserPresenceProfileIDs.remove(profileID.uuidString)
            UserDefaults.standard.set(
                sshPasswordUserPresenceProfileIDs.sorted(),
                forKey: sshPasswordUserPresenceProfilesKey
            )
            if profileID == selectedProfile.id {
                sshPassword = ""
            }
            statusMessage = "Проблемная запись SSH-пароля удалена. Откройте профиль и сохраните пароль заново."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func repairForwardingCredentialAccess(_ tunnelID: UUID) {
        do {
            try KeychainService.repairPasswordAccess(profileID: tunnelID, kind: .forwarding)
            setForwardingPasswordStored(false, tunnelID: tunnelID)
            forwardingPasswordUserPresenceIDs.remove(tunnelID.uuidString)
            UserDefaults.standard.set(
                forwardingPasswordUserPresenceIDs.sorted(),
                forKey: forwardingPasswordUserPresenceIDsKey
            )
            statusMessage = "Проблемная запись пароля туннеля удалена. Сохраните SSH-пароль заново."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveForwardingPassword(_ password: String, tunnelID: UUID) {
        guard !password.isEmpty else { return }
        do {
            try KeychainService.savePassword(
                password,
                profileID: tunnelID,
                kind: .forwarding,
                requiresUserPresence: forwardingPasswordRequiresUserPresence(tunnelID)
            )
            setForwardingPasswordStored(true, tunnelID: tunnelID)
            statusMessage = "SSH-пароль туннеля сохранён в Keychain"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setForwardingPasswordUserPresence(_ enabled: Bool, tunnelID: UUID) {
        setForwardingPasswordUserPresencePreference(enabled, tunnelID: tunnelID)
    }

    func deleteSavedForwardingPassword(_ tunnelID: UUID) {
        do {
            try KeychainService.deletePassword(profileID: tunnelID, kind: .forwarding)
            setForwardingPasswordStored(false, tunnelID: tunnelID)
            setForwardingPasswordUserPresencePreference(false, tunnelID: tunnelID)
            statusMessage = "Сохранённый SSH-пароль туннеля удалён"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importSSHKey() {
        importSSHKey(
            assignToProfileID: selectedProfile.connectionType == .ssh
                ? selectedProfile.id
                : nil
        )
    }

    func importSSHKey(assignToProfileID profileID: UUID?) {
        let panel = NSOpenPanel()
        panel.title = "Выберите приватный SSH-ключ"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let result = try registerSSHKey(
                at: url,
                forProfileID: profileID
            )
            if result.wasExisting {
                statusMessage = profileID == nil
                    ? "SSH-ключ уже зарегистрирован"
                    : "SSH-ключ уже зарегистрирован и выбран"
            } else {
                statusMessage = "SSH-ключ «\(result.key.name)» добавлен"
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func generateSSHKey(
        _ request: SSHKeyGenerationRequest,
        session: TerminalSessionModel
    ) -> Bool {
        guard selectedProfile.connectionType == .ssh else {
            errorMessage = "Создайте или выберите SSH-профиль перед генерацией ключа"
            return false
        }
        return generateSSHKey(
            request,
            session: session,
            profileID: selectedProfile.id
        )
    }

    @discardableResult
    func generateSSHKeyGlobally(
        _ request: SSHKeyGenerationRequest,
        session: TerminalSessionModel
    ) -> Bool {
        generateSSHKey(request, session: session, profileID: nil)
    }

    private func generateSSHKey(
        _ request: SSHKeyGenerationRequest,
        session: TerminalSessionModel,
        profileID: UUID?
    ) -> Bool {
        guard !session.isRunning else {
            errorMessage = "Дождитесь завершения текущей генерации SSH-ключа"
            return false
        }

        do {
            let command = try SSHKeyService.prepareGeneration(request)
            try session.start(
                executable: SSHKeyService.sshKeygenPath,
                arguments: command.arguments,
                title: "Генерация \(request.algorithm.title)"
            ) { [weak self] exitCode in
                guard let self else { return }
                if exitCode == 0 {
                    do {
                        let result = try registerSSHKey(
                            at: command.privateKeyURL,
                            forProfileID: profileID
                        )
                        if request.protectUseWithUserPresence, let profileID {
                            try setSSHKeyUserPresence(
                                true,
                                profileID: profileID,
                                announce: false
                            )
                        }
                        if request.algorithm == .ecdsaP256TouchID,
                           let profileID,
                           let index = profiles.firstIndex(where: { $0.id == profileID }) {
                            profiles[index].sshAuthenticationMode = .touchIDKey
                        }
                        if profileID == nil {
                            statusMessage = result.wasExisting
                                ? "Созданный SSH-ключ уже зарегистрирован"
                                : "SSH-ключ «\(result.key.name)» создан. Назначьте его SSH-профилю для использования Touch ID."
                        } else {
                            statusMessage = result.wasExisting
                                ? "Созданный SSH-ключ выбран"
                                : "SSH-ключ «\(result.key.name)» создан и выбран"
                        }
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } else {
                    statusMessage = "Генерация SSH-ключа не завершена"
                }
            }
            statusMessage = "Введите passphrase нового ключа в отдельном терминале"
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func registerSSHKey(
        at url: URL,
        forProfileID profileID: UUID?
    ) throws -> (key: SSHKeyRecord, wasExisting: Bool) {
        let inspected = try SSHKeyService.inspectPrivateKey(at: url)
        let existing = sshKeys.first {
            $0.privateKeyPath == inspected.privateKeyPath
                || (
                    inspected.fingerprint != "не определён"
                        && $0.fingerprint == inspected.fingerprint
                )
        }
        let record: SSHKeyRecord
        if let existing {
            record = existing
        } else {
            sshKeys.append(inspected)
            record = inspected
        }
        if let profileID,
           let index = profiles.firstIndex(where: { $0.id == profileID }) {
            profiles[index].sshIdentityID = record.id
        }
        return (record, existing != nil)
    }

    func updateSSHKey(_ updated: SSHKeyRecord) {
        guard let index = sshKeys.firstIndex(where: { $0.id == updated.id }),
              sshKeys[index] != updated
        else { return }
        sshKeys[index] = updated
    }

    func removeSSHKey(_ keyID: UUID) {
        guard let key = sshKeys.first(where: { $0.id == keyID }) else { return }
        if let activeRule = sshTunnels.values.first(where: { summary in
            guard let profile = profiles.first(where: { $0.id == summary.profileID })
            else { return false }
            return profile.sshIdentityID == keyID
        }) {
            errorMessage = "Сначала остановите SSH-туннель «\(activeRule.ruleName)»"
            return
        }
        try? SSHKeyService.removeFromAgentAndKeychain(key)
        setSSHKeyPassphraseStored(false, keyID: keyID)
        sshKeys.removeAll { $0.id == keyID }
        profiles = profiles.map { profile in
            var updated = profile
            if updated.sshIdentityID == keyID {
                updated.sshIdentityID = nil
            }
            return updated
        }
        statusMessage = "Ключ удалён из \(AppBrand.name); исходный файл не изменён"
        errorMessage = nil
    }

    func removeSSHKeyFromAgentAndKeychain(_ keyID: UUID) {
        guard let key = sshKeys.first(where: { $0.id == keyID }) else { return }
        do {
            try SSHKeyService.removeFromAgentAndKeychain(key)
            setSSHKeyPassphraseStored(false, keyID: keyID)
            statusMessage = "SSH-ключ удалён из ssh-agent и Keychain OpenSSH"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addSSHKeyToAgent(_ keyID: UUID) {
        guard let key = sshKeys.first(where: { $0.id == keyID }) else { return }
        do {
            try SSHKeyService.addToAgent(
                key,
                useStoredPassphrase: hasSavedSSHKeyPassphrase(keyID: keyID)
            )
            setSSHKeyPassphraseStored(true, keyID: keyID)
            statusMessage = "SSH-ключ «\(key.name)» добавлен в ssh-agent"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeSSHKeyFromAgent(_ keyID: UUID) {
        guard let key = sshKeys.first(where: { $0.id == keyID }) else { return }
        do {
            try SSHKeyService.removeFromAgent(key)
            statusMessage = "SSH-ключ «\(key.name)» удалён из ssh-agent"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copySSHPublicKey(_ keyID: UUID) {
        guard let key = sshKeys.first(where: { $0.id == keyID }) else { return }
        do {
            let value = try SSHKeyService.publicKeyText(for: key)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            statusMessage = "Публичный SSH-ключ скопирован"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealSSHKey(_ keyID: UUID) {
        guard let path = sshKeys.first(where: { $0.id == keyID })?.privateKeyPath else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openKeychainAccess() {
        errorMessage = nil
        statusMessage = "Секретами Selective Remote нужно управлять из карточки подключения; приложение «Пароли» не показывает generic-password записи и SSH-файлы."
    }

    func selectedSSHConnectionSettings() -> SSHConnectionSettings? {
        sshConnectionSettings(profileID: selectedProfile.id)
    }

    func sshConnectionSettings(profileID: UUID) -> SSHConnectionSettings? {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              profile.connectionType == .ssh
        else { return nil }
        let identity = profile.sshIdentityID.flatMap { keyID in
            sshKeys.first(where: { $0.id == keyID })
        }
        if profile.sshIdentityID != nil, identity == nil {
            errorMessage = "Выбранный SSH-ключ больше недоступен. Выберите другой ключ."
            return nil
        }
        if profile.sshAuthenticationMode == .touchIDKey,
           let identity,
           !SSHKeyService.isTouchIDCompatible(identity) {
            errorMessage = "Touch ID Key использует только ECDSA-ключи. Выберите ECDSA Touch ID Key или создайте новый."
            return nil
        }
        do {
            let settings = try SSHConnectionSettings(
                profile: profile,
                identity: identity
            )
            errorMessage = nil
            return settings
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func prepareSelectedSSHConnection(
        requiresIndependentAuthentication: Bool = false
    ) -> SSHConnectionSettings? {
        prepareSSHConnection(
            connection: .savedProfile(selectedProfile.id),
            clientID: selectedProfile.id,
            requiresIndependentAuthentication: requiresIndependentAuthentication
        )
    }

    func prepareSSHConnection(
        connection: TerminalTabConnection,
        clientID: UUID,
        requiresIndependentAuthentication: Bool = false
    ) -> SSHConnectionSettings? {
        guard let settings = sshConnectionSettings(
            connection: connection,
            tabID: clientID
        ) else { return nil }
        do {
            let matchingTerminalIsRunning = connection.profileID.map {
                isSSHTerminalRunning(profileID: $0)
            } ?? false
            let hasActiveControlSession = !requiresIndependentAuthentication
                && matchingTerminalIsRunning
            if let key = settings.identity,
               let profileID = connection.profileID,
               (settings.authenticationMode == .touchIDKey
                    || (settings.authenticationMode == .key
                        && sshKeyUserPresenceProfileIDs.contains(profileID.uuidString))) {
                try KeychainService.authorizeSSHKeyUse(
                    profileID: profileID,
                    reason: "Подтвердите Touch ID для использования SSH-ключа «\(key.name)»"
                )
            }
            if (settings.authenticationMode == .automatic || settings.authenticationMode == .key),
               let key = settings.identity,
               SSHKeyService.shouldLoadIdentityIntoAgent(
                   hasIdentity: true,
                   hasActiveControlSession: hasActiveControlSession
               ) {
                try SSHKeyService.addToAgent(
                    key,
                    useStoredPassphrase: hasSavedSSHKeyPassphrase(keyID: key.id)
                )
                setSSHKeyPassphraseStored(true, keyID: key.id)
            }
            errorMessage = nil
            return settings
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func installSelectedSSHPublicKey() {
        guard let keyID = selectedProfile.sshIdentityID else {
            errorMessage = "Выберите SSH-ключ, который нужно установить на сервер"
            return
        }
        installSSHPublicKey(keyID: keyID, profileID: selectedProfile.id)
    }

    func installSSHPublicKey(keyID: UUID, profileID: UUID) {
        guard var profile = profiles.first(where: {
            $0.id == profileID && $0.connectionType == .ssh
        }), let key = sshKeys.first(where: { $0.id == keyID }) else {
            errorMessage = "Выберите SSH-профиль и ключ, который нужно установить на сервер"
            return
        }
        guard let publicKeyPath = key.publicKeyPath else {
            errorMessage = SSHKeyServiceError.publicKeyUnavailable.localizedDescription
            return
        }
        profile.sshIdentityID = keyID
        let settings: SSHConnectionSettings
        do {
            settings = try SSHConnectionSettings(profile: profile, identity: key)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let session = terminalSession(profileID: profileID)
        guard !session.isRunning else {
            errorMessage = "Сначала завершите текущую SSH-сессию"
            return
        }
        guard FileManager.default.isExecutableFile(atPath: SSHService.sshPath) else {
            errorMessage = SSHServiceError.executableUnavailable(
                SSHService.sshPath
            ).localizedDescription
            return
        }

        do {
            let publicKeyText = try String(contentsOfFile: publicKeyPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try session.start(
                executable: SSHService.sshPath,
                arguments: SSHService.appendPublicKeyArguments(
                    settings: settings,
                    publicKeyText: publicKeyText
                ),
                title: "Установка ключа «\(key.name)»",
                environment: try SSHKeyService.backgroundAuthenticationEnvironment(
                    passwordCredential: KeychainService.credentialReference(
                        profileID: settings.profileID,
                        kind: .ssh
                    ),
                    proxyPasswordCredential: settings.proxyMode == .none ? nil : KeychainService.credentialReference(
                        profileID: settings.profileID,
                        kind: .proxy
                    )
                )
            ) { [weak self] exitCode in
                guard let self else { return }
                statusMessage = exitCode == 0
                    ? "Публичный SSH-ключ установлен на сервер"
                    : "Установка SSH-ключа завершилась с кодом \(exitCode)"
            }
            requestedSSHConsoleProfileID = settings.profileID
            statusMessage = hasSavedSSHPassword(profileID: profileID)
                ? "Ключ безопасно добавляется в authorized_keys с сохранённым SSH-паролем"
                : "Ключ будет добавлен в authorized_keys без удаления существующих ключей; при необходимости введите пароль сервера"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addPortForward(_ kind: PortForwardKind) {
        mutateSelectedProfile { $0.portForwards.append(PortForwardRule(kind: kind)) }
        statusMessage = "Добавлено правило: \(kind.title)"
    }

    func addIndependentPortForward(_ kind: PortForwardKind) {
        let connection = profiles.first(where: { $0.connectionType == .ssh })
            .map { TerminalTabConnection.savedProfile($0.id) }
            ?? .custom(host: "", username: "")
        independentPortForwards.append(
            IndependentPortForward(connection: connection, kind: kind)
        )
        statusMessage = "Добавлен независимый SSH-туннель"
    }

    @discardableResult
    func duplicateIndependentPortForward(_ id: UUID) -> UUID? {
        guard let source = independentPortForwards.first(where: { $0.id == id }) else { return nil }
        var copy = source
        let newID = UUID()
        copy.id = newID
        copy.rule.id = newID
        copy.rule.name += " — копия"
        independentPortForwards.append(copy)
        statusMessage = "Туннель скопирован"
        return newID
    }

    func updateIndependentPortForward(_ updated: IndependentPortForward) {
        guard let index = independentPortForwards.firstIndex(where: {
            $0.id == updated.id
        }), !isSSHTunnelRunning(ruleID: updated.id) else { return }
        var normalized = updated
        normalized.rule.id = updated.id
        independentPortForwards[index] = normalized
    }

    func removeIndependentPortForward(_ id: UUID) {
        guard !isSSHTunnelRunning(ruleID: id) else {
            errorMessage = "Сначала остановите этот SSH-туннель"
            return
        }
        independentPortForwards.removeAll { $0.id == id }
        try? KeychainService.deletePassword(profileID: id, kind: .forwarding)
        setForwardingPasswordStored(false, tunnelID: id)
        lastSSHTunnelLogURLs.removeValue(forKey: id)
    }

    func restartIndependentPortForward(_ id: UUID) {
        if !isSSHTunnelRunning(ruleID: id) {
            startIndependentPortForward(id)
            return
        }
        stopSSHTunnel(id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<30 {
                if !self.isSSHTunnelRunning(ruleID: id) {
                    self.startIndependentPortForward(id)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self.errorMessage = "Не удалось перезапустить туннель: предыдущий процесс ещё завершается"
        }
    }

    func startIndependentPortForward(_ id: UUID) {
        guard !isSSHTunnelRunning(ruleID: id),
              let item = independentPortForwards.first(where: { $0.id == id }),
              let settings = sshConnectionSettings(
                  connection: item.connection,
                  tabID: Self.globalForwardingProfileID
              )
        else { return }

        do {
            if let identity = settings.identity,
               let profileID = item.connection.profileID,
               (settings.authenticationMode == .touchIDKey
                    || sshKeyUserPresenceProfileIDs.contains(profileID.uuidString)) {
                try KeychainService.authorizeSSHKeyUse(
                    profileID: profileID,
                    reason: "Подтвердите Touch ID для SSH-туннеля и ключа «\(identity.name)»"
                )
            }
            if settings.authenticationMode != .touchIDKey,
               let identity = settings.identity,
               SSHKeyService.shouldLoadIdentityIntoAgent(
                   hasIdentity: true,
                   hasActiveControlSession: false
               ) {
                try SSHKeyService.addToAgent(
                    identity,
                    useStoredPassphrase: hasSavedSSHKeyPassphrase(keyID: identity.id)
                )
                setSSHKeyPassphraseStored(true, keyID: identity.id)
            }
            let credential: KeychainCredentialReference?
            switch item.connection.kind {
            case .savedProfile:
                credential = item.connection.profileID.map {
                    KeychainService.credentialReference(profileID: $0, kind: .ssh)
                }
            case .custom:
                credential = KeychainService.credentialReference(
                    profileID: item.id,
                    kind: .forwarding
                )
            }
            let effectiveCredential = (settings.authenticationMode == .automatic || settings.authenticationMode == .password)
                ? credential
                : nil
            let running = try SSHService.launchTunnel(
                settings: settings,
                rule: item.rule,
                passwordCredential: effectiveCredential
            )
            managedSSHTunnels[id] = running
            sshTunnels[id] = SSHTunnelSummary(
                id: id,
                profileID: Self.globalForwardingProfileID,
                profileName: settings.profileName,
                ruleName: item.rule.name,
                startedAt: Date(),
                logURL: running.logURL
            )
            lastSSHTunnelLogURLs[id] = running.logURL
            stoppingSSHTunnelIDs.remove(id)
            startSSHTunnelMonitorIfNeeded()
            statusMessage = "Независимый SSH-туннель «\(item.rule.name)» запущен"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "SSH-туннель не запущен"
        }
    }

    func removePortForward(_ ruleID: UUID) {
        guard !isSSHTunnelRunning(ruleID: ruleID) else {
            errorMessage = "Сначала остановите этот SSH-туннель"
            return
        }
        mutateSelectedProfile { $0.portForwards.removeAll { $0.id == ruleID } }
        lastSSHTunnelLogURLs.removeValue(forKey: ruleID)
        statusMessage = "Правило forwarding удалено"
    }

    func startSSHTunnel(_ ruleID: UUID) {
        guard !isSSHTunnelRunning(ruleID: ruleID),
              let rule = selectedProfile.portForwards.first(where: { $0.id == ruleID }),
              let settings = prepareSelectedSSHConnection(
                  requiresIndependentAuthentication: true
              )
        else { return }

        do {
            let credential: KeychainCredentialReference? =
                (settings.authenticationMode == .automatic || settings.authenticationMode == .password)
                ? KeychainService.credentialReference(
                    profileID: selectedProfile.id,
                    kind: .ssh
                )
                : nil
            let running = try SSHService.launchTunnel(
                settings: settings,
                rule: rule,
                passwordCredential: credential
            )
            managedSSHTunnels[ruleID] = running
            sshTunnels[ruleID] = SSHTunnelSummary(
                id: ruleID,
                profileID: selectedProfile.id,
                profileName: selectedProfile.friendlyName,
                ruleName: rule.name,
                startedAt: Date(),
                logURL: running.logURL
            )
            lastSSHTunnelLogURLs[ruleID] = running.logURL
            stoppingSSHTunnelIDs.remove(ruleID)
            startSSHTunnelMonitorIfNeeded()
            statusMessage = "SSH-туннель «\(rule.name)» запущен"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "SSH-туннель не запущен"
        }
    }

    func stopSSHTunnel(_ ruleID: UUID) {
        guard let running = managedSSHTunnels[ruleID] else { return }
        stoppingSSHTunnelIDs.insert(ruleID)
        if running.process.isRunning {
            running.process.terminate()
            Task { @MainActor [weak self, weak process = running.process] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, let process, process.isRunning,
                      self.managedSSHTunnels[ruleID]?.process === process
                else { return }
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        } else {
            finishSSHTunnel(ruleID, status: running.process.terminationStatus)
        }
    }

    func revealSSHTunnelLog(_ ruleID: UUID) {
        guard let url = sshTunnels[ruleID]?.logURL ?? lastSSHTunnelLogURLs[ruleID] else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Выберите папку для удалённой сессии"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mutateSelectedProfile { profile in
            if !profile.redirectedFolders.contains(url.path) {
                profile.redirectedFolders.append(url.path)
            }
        }
    }

    func removeFolder(_ path: String) {
        mutateSelectedProfile { $0.redirectedFolders.removeAll { $0 == path } }
    }

    func importProfiles() {
        let panel = NSOpenPanel()
        panel.title = "Импорт подключений"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["rdp", "selectiveremote", "json"].compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK else { return }

        do {
            var imported: [ConnectionProfile] = []
            for url in panel.urls {
                let data = try Data(contentsOf: url)
                if url.pathExtension.lowercased() == "rdp" {
                    var profile = try RDPFileCodec.decode(
                        data,
                        suggestedName: url.deletingPathExtension().lastPathComponent
                    )
                    configureDefaultDisplays(for: &profile)
                    imported.append(profile)
                } else {
                    imported.append(contentsOf: try SelectiveRemoteProfileCodec.decode(data))
                }
            }
            guard !imported.isEmpty else { throw ProfileTransferError.emptyDocument }
            var usedIDs = Set(profiles.map(\.id))
            var usedRuleIDs = Set(profiles.flatMap { $0.portForwards.map(\.id) })
            for index in imported.indices {
                while usedIDs.contains(imported[index].id) {
                    imported[index].id = UUID()
                }
                usedIDs.insert(imported[index].id)
                for ruleIndex in imported[index].portForwards.indices {
                    while usedRuleIDs.contains(imported[index].portForwards[ruleIndex].id) {
                        imported[index].portForwards[ruleIndex].id = UUID()
                    }
                    usedRuleIDs.insert(imported[index].portForwards[ruleIndex].id)
                }
                if let keyID = imported[index].sshIdentityID,
                   !sshKeys.contains(where: { $0.id == keyID }) {
                    imported[index].sshIdentityID = nil
                }
            }
            profiles.append(contentsOf: imported)
            selectedProfileID = imported.first?.id
            statusMessage = "Импортировано профилей: \(imported.count). Пароли и SSH-ключи не импортировались."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportAllProfiles() {
        do {
            let panel = NSSavePanel()
            panel.title = "Экспорт профилей без паролей и SSH-ключей"
            panel.nameFieldStringValue = "Selective-Remote-Profiles.selectiveremote"
            panel.allowedContentTypes = [UTType(filenameExtension: "selectiveremote") ?? .json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try SelectiveRemoteProfileCodec.encode(profiles).write(to: url, options: .atomic)
            statusMessage = "Профили экспортированы без паролей и SSH-ключей"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportSelectedRDP() {
        guard selectedProfile.connectionType == .rdp else {
            errorMessage = "Формат .rdp доступен только для RDP-профилей"
            return
        }
        do {
            let panel = NSSavePanel()
            panel.title = "Экспорт подключения .rdp без паролей"
            panel.nameFieldStringValue = "\(safeFilename(selectedProfile.friendlyName)).rdp"
            panel.allowedContentTypes = [UTType(filenameExtension: "rdp") ?? .data]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try RDPFileCodec.encode(selectedProfile).write(to: url, options: .atomic)
            statusMessage = "Файл .rdp экспортирован без паролей"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connect() {
        switch selectedProfile.connectionType {
        case .rdp:
            connectProfile(
                selectedProfile.id,
                typedPassword: password,
                typedGatewayPassword: gatewayPassword,
                automatic: false
            )
        case .ssh:
            let workspace = terminalWorkspace(profileID: selectedProfile.id)
            let tab = workspace.tabs.first(where: \.isPrimary) ?? workspace.selectedTab
            connectSSHTerminal(
                connection: tab.connection,
                tabID: tab.id,
                session: tab.session
            )
            requestedSSHConsoleProfileID = selectedProfile.id
        }
    }

    func sshConnectionSettings(
        connection: TerminalTabConnection,
        tabID: UUID
    ) -> SSHConnectionSettings? {
        switch connection.kind {
        case .savedProfile:
            guard let profileID = connection.profileID else {
                errorMessage = "Сохранённый SSH-профиль больше недоступен"
                return nil
            }
            return sshConnectionSettings(profileID: profileID)
        case .custom:
            var profile = ConnectionProfile(connectionType: .ssh)
            profile.id = tabID
            profile.friendlyName = connection.normalizedUsername.isEmpty
                ? connection.normalizedHost
                : "\(connection.normalizedUsername)@\(connection.normalizedHost)"
            profile.host = connection.normalizedHost
            profile.username = connection.normalizedUsername
            profile.sshPort = connection.port
            do {
                let settings = try SSHConnectionSettings(profile: profile, identity: nil)
                errorMessage = nil
                return settings
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
        }
    }

    func connectSSHTerminal(
        connection: TerminalTabConnection,
        tabID: UUID,
        session: TerminalSessionModel,
        temporaryPassword: String? = nil
    ) {
        guard let settings = sshConnectionSettings(
            connection: connection,
            tabID: tabID
        ) else { return }
        guard !session.isRunning else {
            statusMessage = "Эта вкладка SSH уже подключена"
            return
        }
        do {
            if connection.kind == .custom,
               let temporaryPassword,
               !temporaryPassword.isEmpty {
                try KeychainService.savePassword(
                    temporaryPassword,
                    profileID: tabID,
                    kind: .ssh
                )
            }
            if let profileID = connection.profileID,
               (settings.authenticationMode == .touchIDKey
                    || (settings.authenticationMode == .key
                        && sshKeyUserPresenceProfileIDs.contains(profileID.uuidString))),
               let identity = settings.identity {
                try KeychainService.authorizeSSHKeyUse(
                    profileID: profileID,
                    reason: "Подтвердите Touch ID для SSH-сессии и ключа «\(identity.name)»"
                )
            }
            let credential: KeychainCredentialReference?
            if settings.authenticationMode == .automatic || settings.authenticationMode == .password {
                switch connection.kind {
                case .savedProfile:
                    credential = connection.profileID.map {
                        KeychainService.credentialReference(profileID: $0, kind: .ssh)
                    }
                case .custom:
                    credential = temporaryPassword?.isEmpty == false
                        ? KeychainService.credentialReference(profileID: tabID, kind: .ssh)
                        : nil
                }
            } else {
                credential = nil
            }
            try session.start(
                executable: "/usr/bin/ssh",
                arguments: SSHService.interactiveSSHArguments(settings: settings),
                title: "SSH · \(settings.profileName)",
                environment: try SSHKeyService.backgroundAuthenticationEnvironment(
                    passwordCredential: credential,
                    proxyPasswordCredential: settings.proxyMode == .none ? nil : KeychainService.credentialReference(
                        profileID: settings.profileID,
                        kind: .proxy
                    )
                )
            ) { [weak self] exitCode in
                guard let self else { return }
                if connection.kind == .custom, temporaryPassword?.isEmpty == false {
                    try? KeychainService.deletePassword(profileID: tabID, kind: .ssh)
                }
                statusMessage = exitCode == 0
                    ? "SSH-сессия завершена"
                    : "SSH-сессия завершилась с кодом \(exitCode)"
            }
            if connection.kind == .savedProfile,
               let profileID = connection.profileID,
               let index = profiles.firstIndex(where: { $0.id == profileID }) {
                profiles[index].lastConnectedAt = Date()
            }
            statusMessage = "SSH подключается к \(settings.host)"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "SSH не запущен"
        }
    }

    func discoverTerminalContext(
        connection: TerminalTabConnection,
        tabID: UUID
    ) async throws -> TerminalRemoteContextSnapshot {
        guard let settings = sshConnectionSettings(
            connection: connection,
            tabID: tabID
        ) else {
            throw TerminalRemoteContextError.commandFailed(
                "подключение SSH больше недоступно"
            )
        }
        return try await TerminalRemoteContextService.discover(
            settings: settings,
            environment: SSHKeyService.processEnvironment()
        )
    }

    func reconnectSelectedProfile() {
        guard selectedProfile.connectionType == .rdp else { return }
        reconnectCandidateProfileIDs.remove(selectedProfile.id)
        connectProfile(
            selectedProfile.id,
            typedPassword: password,
            typedGatewayPassword: gatewayPassword,
            automatic: false
        )
    }

    func connectFavorite(profileID: UUID) {
        connectProfile(
            profileID,
            typedPassword: "",
            typedGatewayPassword: "",
            automatic: false
        )
    }

    func sendRDPCommand(_ command: RDPSessionCommand, profileID: UUID) {
        guard let runtime = managedSessions[profileID] else { return }
        if command == .disconnect {
            requestDisconnect(profileID: profileID, interruptionReason: nil)
            return
        }
        do {
            try RDPSessionCommandSender.send(
                command,
                to: runtime.connection.commandPipeURL
            )
            statusMessage = "Команда «\(command.title)» отправлена в «\(runtime.profileName)»"
            errorMessage = nil
        } catch {
            if connection.kind == .custom, temporaryPassword?.isEmpty == false {
                try? KeychainService.deletePassword(profileID: tabID, kind: .ssh)
            }
            errorMessage = error.localizedDescription
        }
    }

    func showRDPControlPanel() {
        RDPSessionControlPanelController.shared.show(model: self)
    }

    func setMicrophoneEnabled(_ enabled: Bool, profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].redirectMicrophone = enabled
        statusMessage = "Настройка микрофона сохранена; переподключите RDP для применения"
    }

    func setCameraEnabled(_ enabled: Bool, profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].redirectCamera = enabled
        statusMessage = "Настройка камеры сохранена; переподключите RDP для применения"
    }

    func setSoundEnabled(_ enabled: Bool, profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].audioMode = enabled ? .local : .muted
        statusMessage = "Настройка звука сохранена; переподключите RDP для применения"
    }

    func reconnect(profileID: UUID) {
        guard managedSessions[profileID] != nil else {
            connectFavorite(profileID: profileID)
            return
        }
        requestDisconnect(profileID: profileID, interruptionReason: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<30 {
                if self.managedSessions[profileID] == nil {
                    self.connectFavorite(profileID: profileID)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            self.errorMessage = "RDP не успел завершиться; повторите переподключение"
        }
    }

    func disconnect() {
        disconnect(profileID: selectedProfile.id)
    }

    func disconnect(profileID: UUID) {
        if isSSHTerminalRunning(profileID: profileID) {
            if let workspace = terminalWorkspaces[profileID] {
                workspace.stopAll()
                statusMessage = "Завершаем SSH-сессии профиля…"
            } else {
                sshTerminalSessions[profileID]?.stop()
                statusMessage = "Завершаем SSH-сессию…"
            }
        } else {
            requestDisconnect(profileID: profileID, interruptionReason: nil)
        }
    }

    func disconnectAll() {
        for profileID in Array(managedSessions.keys) {
            requestDisconnect(profileID: profileID, interruptionReason: nil)
        }
        for terminal in sshTerminalSessions.values where terminal.isRunning {
            terminal.stop()
        }
        terminalWorkspaces.values.forEach { $0.stopAll() }
    }

    func stopAllSSHTunnels() {
        for ruleID in Array(managedSSHTunnels.keys) {
            stopSSHTunnel(ruleID)
        }
    }

    func stopAllSSHTerminals() {
        for terminal in sshTerminalSessions.values where terminal.isRunning {
            terminal.stop()
        }
        terminalWorkspaces.values.forEach { $0.stopAll() }
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) })
        window?.makeKeyAndOrderFront(nil)
    }

    func quitApplication() {
        SSHKeyService.stopManagedAgent()
        NSApp.terminate(nil)
    }

    func revealSessionLog(profileID: UUID? = nil) {
        let id = profileID ?? selectedProfile.id
        guard let url = sessions[id]?.logURL ?? lastSessionLogURLs[id] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func checkForUpdates() {
        checkForUpdates(announcesUpToDate: true)
    }

    private func checkForUpdatesAutomatically() {
        let lastCheck = UserDefaults.standard.double(forKey: lastSuccessfulUpdateCheckKey)
        let day: TimeInterval = 24 * 60 * 60
        guard Date().timeIntervalSince1970 - lastCheck >= day else { return }
        checkForUpdates(announcesUpToDate: false)
    }

    private func checkForUpdates(announcesUpToDate: Bool) {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        updateMessage = nil
        availableUpdateURL = nil
        availableReleaseNotesURL = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCheckingForUpdates = false }
            do {
                let feedURL = try UpdateService.configuredFeedURL()
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    ?? "0.0.0"
                let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
                let result = try await UpdateService.check(
                    feedURL: feedURL,
                    currentVersion: version,
                    currentBuild: build
                )
                UserDefaults.standard.set(
                    Date().timeIntervalSince1970,
                    forKey: lastSuccessfulUpdateCheckKey
                )
                switch result {
                case .upToDate:
                    if announcesUpToDate {
                        updateMessage = "Установлена актуальная версия \(AppBrand.name) \(version)."
                    }
                case let .available(manifest):
                    availableUpdateURL = manifest.downloadURL
                    availableReleaseNotesURL = manifest.releaseNotesURL
                    updateMessage = "Доступна новая версия \(AppBrand.name) \(manifest.version)."
                case let .incompatible(manifest):
                    availableReleaseNotesURL = manifest.releaseNotesURL
                    let minimum = manifest.minimumMacOS ?? "более новая версия macOS"
                    updateMessage = "Доступна \(AppBrand.name) \(manifest.version), "
                        + "но для неё требуется macOS \(minimum) или новее."
                }
            } catch {
                if announcesUpToDate {
                    updateMessage = "Не удалось проверить обновления: \(error.localizedDescription)"
                }
            }
        }
    }

    func openAvailableUpdate() {
        guard let availableUpdateURL else { return }
        NSWorkspace.shared.open(availableUpdateURL)
    }

    func openAvailableReleaseNotes() {
        guard let availableReleaseNotesURL else { return }
        NSWorkspace.shared.open(availableReleaseNotesURL)
    }

    private func connectProfile(
        _ profileID: UUID,
        typedPassword: String,
        typedGatewayPassword: String,
        automatic: Bool
    ) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        guard profile.connectionType == .rdp else { return }
        guard !isSessionRunning(profileID: profileID) else {
            if !automatic { errorMessage = SelectiveRemoteAppError.profileAlreadyRunning.localizedDescription }
            return
        }

        let availableIDs = Set(displays.map(\.id))
        let missingCount = profile.selectedDisplayIDs.subtracting(availableIDs).count
        guard let runtimeProfile = DisplaySelectionResolver.runtimeProfile(
            from: profile,
            displays: displays
        ) else {
            reconnectCandidateProfileIDs.insert(profileID)
            if !automatic {
                if missingCount > 0 {
                    errorMessage = SelectiveRemoteAppError.selectedDisplaysUnavailable(missingCount).localizedDescription
                } else {
                    errorMessage = FreeRDPError.noSelectedMonitors.localizedDescription
                }
            }
            return
        }
        let currentPlacements = VirtualTopologyMapper.layout(
            displays: displays,
            selectedIDs: runtimeProfile.selectedDisplayIDs,
            primaryID: runtimeProfile.primaryDisplayID,
            mode: runtimeProfile.displayLayoutMode,
            customOrigins: runtimeProfile.virtualDisplayOrigins
        )
        guard !currentPlacements.isEmpty else {
            if !automatic { errorMessage = FreeRDPError.noSelectedMonitors.localizedDescription }
            return
        }
        guard runtimeProfile.displayLayoutMode != .custom
                || !VirtualTopologyMapper.hasOverlaps(currentPlacements)
        else {
            if !automatic { errorMessage = SelectiveRemoteAppError.overlappingDisplays.localizedDescription }
            return
        }

        do {
            let connectionPassword = try resolvedPassword(
                typed: typedPassword,
                profileID: profileID,
                kind: .rdp
            )
            let resolvedGatewayPassword: String
            if profile.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resolvedGatewayPassword = ""
            } else {
                resolvedGatewayPassword = try resolvedPassword(
                    typed: typedGatewayPassword,
                    profileID: profileID,
                    kind: .gateway,
                    required: false
                )
            }

            let connection = try freeRDP.launch(
                profile: runtimeProfile,
                displays: displays,
                password: connectionPassword,
                gatewayPassword: resolvedGatewayPassword
            )
            let runtime = ManagedRDPSession(profile: runtimeProfile, connection: connection)
            managedSessions[profileID] = runtime
            sessions[profileID] = runtime.summary
            reconnectCandidateProfileIDs.remove(profileID)
            if selectedProfileID == profileID {
                password = ""
                gatewayPassword = ""
            }
            if let index = profiles.firstIndex(where: { $0.id == profileID }) {
                profiles[index].lastConnectedAt = Date()
            }
            startSessionMonitorIfNeeded()
            if missingCount > 0 {
                statusMessage = "FreeRDP запущен; недоступные мониторы временно пропущены: \(missingCount)"
            } else {
                statusMessage = "FreeRDP запущен для «\(profile.friendlyName)», ожидаем окно…"
            }
            errorMessage = nil
        } catch {
            if !automatic || selectedProfileID == profileID {
                errorMessage = error.localizedDescription
                statusMessage = "Подключение не запущено"
            }
            reconnectCandidateProfileIDs.insert(profileID)
        }
    }

    private func resolvedPassword(
        typed: String,
        profileID: UUID,
        kind: KeychainCredentialKind,
        required: Bool = true
    ) throws -> String {
        if !typed.isEmpty { return typed }
        let marker = kind == .rdp
            ? passwordStoredProfileIDs.contains(profileID.uuidString)
            : gatewayPasswordStoredProfileIDs.contains(profileID.uuidString)
        if marker {
            if let stored = try KeychainService.readPassword(profileID: profileID, kind: kind),
               !stored.isEmpty {
                return stored
            }
            setPasswordStored(false, profileID: profileID, kind: kind)
            throw kind == .rdp
                ? SelectiveRemoteAppError.savedPasswordMissing
                : SelectiveRemoteAppError.savedGatewayPasswordMissing
        }
        if required { throw SelectiveRemoteAppError.rdpPasswordRequired }
        return ""
    }

    private func requestDisconnect(profileID: UUID, interruptionReason: String?) {
        guard let runtime = managedSessions[profileID] else { return }
        runtime.disconnectRequested = true
        runtime.interruptionReason = interruptionReason
        runtime.phase = .disconnecting
        sessions[profileID] = runtime.summary
        if let interruptionReason {
            reconnectCandidateProfileIDs.insert(profileID)
            statusMessage = interruptionReason
        } else {
            statusMessage = "Завершаем «\(runtime.profileName)»…"
        }

        let process = runtime.connection.process
        guard process.isRunning else {
            finishSession(profileID: profileID, status: process.terminationStatus)
            return
        }
        let reason = interruptionReason ?? "Отключение запрошено пользователем"
        if let marker = "\n[SelectiveRemote Host] SIGTERM: \(reason)\n".data(using: .utf8) {
            try? runtime.connection.logHandle.write(contentsOf: marker)
        }
        process.terminate()
        Task { @MainActor [weak self, weak process] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, let process, process.isRunning,
                  self.managedSessions[profileID]?.connection.process === process
            else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
            self.statusMessage = "Сессия «\(runtime.profileName)» принудительно остановлена"
        }
    }

    private func startSessionMonitorIfNeeded() {
        guard sessionTimer == nil else { return }
        sessionTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(checkSessionProcesses),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func checkSessionProcesses() {
        guard !managedSessions.isEmpty else {
            sessionTimer?.invalidate()
            sessionTimer = nil
            return
        }
        let ended = managedSessions.compactMap { profileID, runtime -> (UUID, Int32)? in
            if runtime.connection.process.isRunning {
                checkSessionStartup(runtime)
                return nil
            }
            return (profileID, runtime.connection.process.terminationStatus)
        }
        for (profileID, status) in ended {
            finishSession(profileID: profileID, status: status)
        }
    }

    private func startSSHTunnelMonitorIfNeeded() {
        guard sshTunnelTimer == nil else { return }
        sshTunnelTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(checkSSHTunnelProcesses),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func checkSSHTunnelProcesses() {
        guard !managedSSHTunnels.isEmpty else {
            sshTunnelTimer?.invalidate()
            sshTunnelTimer = nil
            return
        }
        let ended = managedSSHTunnels.compactMap { ruleID, running -> (UUID, Int32)? in
            running.process.isRunning
                ? nil
                : (ruleID, running.process.terminationStatus)
        }
        for (ruleID, status) in ended {
            finishSSHTunnel(ruleID, status: status)
        }
    }

    private func finishSSHTunnel(_ ruleID: UUID, status: Int32) {
        guard let running = managedSSHTunnels.removeValue(forKey: ruleID) else { return }
        let summary = sshTunnels.removeValue(forKey: ruleID)
        let requested = stoppingSSHTunnelIDs.remove(ruleID) != nil
        let termination = running.process.terminationReason == .exit
            ? "код \(status)"
            : "сигнал \(status)"
        let marker = "\n[SelectiveRemote SSH] Process finished: \(termination)\n"
        try? running.logHandle.write(contentsOf: Data(marker.utf8))
        try? running.logHandle.synchronize()
        try? running.logHandle.close()

        if requested {
            statusMessage = "SSH-туннель «\(summary?.ruleName ?? "Без названия")» остановлен"
            return
        }

        let log = (try? String(contentsOf: running.logURL, encoding: .utf8)) ?? ""
        let details = log.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = details.isEmpty
            ? "процесс завершился: \(termination)"
            : String(details.suffix(3_000))
        if summary?.profileID == selectedProfileID
            || summary?.profileID == Self.globalForwardingProfileID {
            errorMessage = "SSH-туннель «\(summary?.ruleName ?? "Без названия")» остановлен:\n\(message)"
        }
        statusMessage = "SSH-туннель неожиданно завершён"
    }

    private func checkSessionStartup(_ runtime: ManagedRDPSession) {
        guard !runtime.desktopReadyDetected else { return }
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: runtime.connection.logURL.path
        )
        let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let log = byteCount > 0
            ? try? String(contentsOf: runtime.connection.logURL, encoding: .utf8)
            : nil
        if let log {
            if SessionLogClassifier.hasEstablishedDesktop(log) {
                markSessionReady(runtime, detectedFromWindow: false)
                return
            }

            if let permission = SessionLogClassifier.pendingCapturePermission(log) {
                runtime.startupWarningShown = false
                if selectedProfileID == runtime.profileID {
                    let name = permission == .microphone ? "микрофону" : "камере"
                    statusMessage = "Ожидаем разрешение macOS на доступ к \(name)…"
                    errorMessage = nil
                }
                return
            }

            if runtime.privacyReadyAt == nil,
               SessionLogClassifier.hasCompletedCapturePermissionPreflight(log) {
                runtime.privacyReadyAt = Date()
                if selectedProfileID == runtime.profileID {
                    statusMessage = "Проверка разрешений завершена, запускаем FreeRDP…"
                }
            }
        }

        if SessionWindowDetector.hasSessionWindow(
            processIdentifier: runtime.connection.process.processIdentifier
        ) {
            markSessionReady(runtime, detectedFromWindow: true)
            return
        }

        guard !runtime.startupWarningShown,
              Date().timeIntervalSince(runtime.privacyReadyAt ?? runtime.startedAt) >= 8
        else { return }
        runtime.startupWarningShown = true
        if selectedProfileID == runtime.profileID {
            statusMessage = "FreeRDP запускается дольше обычного — процесс остаётся активным"
        }
    }

    private func markSessionReady(
        _ runtime: ManagedRDPSession,
        detectedFromWindow: Bool
    ) {
        runtime.desktopReadyDetected = true
        runtime.phase = .connected
        sessions[runtime.profileID] = runtime.summary

        if detectedFromWindow,
           let marker = (
               "[SelectiveRemote Host] Session window detected by macOS; "
                   + "buffered FreeRDP INFO output is not required for readiness\n"
           ).data(using: .utf8) {
            try? runtime.connection.logHandle.write(contentsOf: marker)
        }

        if selectedProfileID == runtime.profileID {
            let log = (try? String(
                contentsOf: runtime.connection.logURL,
                encoding: .utf8
            )) ?? ""
            let disabled = SessionLogClassifier.disabledCapturePermissions(log)
            if disabled.isEmpty {
                statusMessage = "RDP подключён — верхний край или правый ⇧ + D завершают сессию"
            } else {
                let names = disabled.map {
                    $0 == .microphone ? "микрофон" : "камера"
                }.joined(separator: " и ")
                statusMessage = "RDP подключён; \(names) не передаются из-за разрешений macOS"
            }
            if runtime.startupWarningShown {
                errorMessage = nil
            }
        }
    }

    private func finishSession(profileID: UUID, status: Int32) {
        guard let runtime = managedSessions[profileID] else { return }
        try? runtime.connection.logHandle.close()
        try? FileManager.default.removeItem(at: runtime.connection.commandPipeURL)
        let log = (try? String(contentsOf: runtime.connection.logURL, encoding: .utf8)) ?? ""
        let endedNormally = SessionTerminationClassifier.isExpected(
            status: status,
            log: log,
            disconnectRequested: runtime.disconnectRequested
        )
        lastSessionLogURLs[profileID] = runtime.connection.logURL
        managedSessions.removeValue(forKey: profileID)
        sessions.removeValue(forKey: profileID)
        if managedSessions.isEmpty {
            sessionTimer?.invalidate()
            sessionTimer = nil
        }

        if selectedProfileID == profileID {
            if endedNormally {
                statusMessage = runtime.interruptionReason ?? "RDP-сессия завершена"
                errorMessage = nil
            } else {
                statusMessage = "FreeRDP завершился с кодом \(status)"
                errorMessage = sessionFailureMessage(log: log, status: status)
            }
        }
    }

    private func sessionFailureMessage(log: String, status: Int32) -> String {
        // An ordinary denial is non-fatal and is handled as a disabled
        // optional channel. Keep a focused message only for an actual TCC
        // process crash caused by a malformed/missing usage declaration.
        if log.contains("__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__") {
            switch SessionLogClassifier.deniedCapturePermission(log) {
            case .microphone:
                return "macOS аварийно остановила доступ к микрофону. Переустановите полную сборку приложения и повторите подключение."
            case .camera:
                return "macOS аварийно остановила доступ к камере. Переустановите полную сборку приложения и повторите подключение."
            case nil:
                break
            }
        }
        if log.contains("ERRCONNECT_LOGON_FAILURE") || log.contains("Logon failed") {
            return "Сервер отклонил имя пользователя или RDP-пароль. Проверьте домен, логин и пароль."
        }
        if log.contains("ERRCONNECT_CONNECT_CANCELLED") {
            return "FreeRDP отменил подключение. Если вы не закрывали окно RDP, повторите запуск. "
                + "При повторении проверьте сеть, сертификат и последние строки журнала."
        }
        if log.contains("ERRCONNECT_CONNECT_TRANSPORT_FAILED") {
            return "Не удалось установить сетевое соединение. Проверьте hostname, VPN и порт 3389."
        }
        if status == SIGTERM || status == SIGKILL {
            return "RDP-процесс был остановлен без штатной команды \(AppBrand.name). Откройте журнал — причина внутреннего отключения помечается совместимой строкой «SelectiveRemote Host»."
        }
        return "FreeRDP завершился с кодом \(status). Откройте журнал для диагностики."
    }

    private func saveCredential(
        _ value: String,
        kind: KeychainCredentialKind,
        requiresUserPresence: Bool = false
    ) {
        guard !value.isEmpty else {
            switch kind {
            case .rdp: statusMessage = "Введите новый RDP-пароль перед сохранением"
            case .gateway: statusMessage = "Введите новый пароль RD Gateway перед сохранением"
            case .ssh: statusMessage = "Введите SSH-пароль перед сохранением"
            case .forwarding, .sshKeyAuthorization, .proxy: return
            }
            return
        }
        do {
            try KeychainService.savePassword(
                value,
                profileID: selectedProfile.id,
                kind: kind,
                requiresUserPresence: requiresUserPresence
            )
            setPasswordStored(true, profileID: selectedProfile.id, kind: kind)
            switch kind {
            case .rdp:
                password = ""
                statusMessage = "RDP-пароль сохранён в Keychain"
            case .gateway:
                gatewayPassword = ""
                statusMessage = "Пароль RD Gateway сохранён в Keychain"
            case .ssh:
                sshPassword = ""
                statusMessage = "SSH-пароль сохранён в Keychain"
            case .forwarding, .sshKeyAuthorization, .proxy:
                break
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteCredential(kind: KeychainCredentialKind) {
        do {
            try KeychainService.deletePassword(profileID: selectedProfile.id, kind: kind)
            setPasswordStored(false, profileID: selectedProfile.id, kind: kind)
            switch kind {
            case .rdp:
                password = ""
                statusMessage = "Сохранённый RDP-пароль удалён"
            case .gateway:
                gatewayPassword = ""
                statusMessage = "Сохранённый пароль RD Gateway удалён"
            case .ssh:
                sshPassword = ""
                sshPasswordUserPresenceProfileIDs.remove(selectedProfile.id.uuidString)
                UserDefaults.standard.set(
                    sshPasswordUserPresenceProfileIDs.sorted(),
                    forKey: sshPasswordUserPresenceProfilesKey
                )
                statusMessage = "Сохранённый SSH-пароль удалён"
            case .forwarding, .sshKeyAuthorization, .proxy:
                break
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setPasswordStored(
        _ stored: Bool,
        profileID: UUID,
        kind: KeychainCredentialKind
    ) {
        let key = profileID.uuidString
        switch kind {
        case .rdp:
            if stored { passwordStoredProfileIDs.insert(key) }
            else { passwordStoredProfileIDs.remove(key) }
            UserDefaults.standard.set(
                passwordStoredProfileIDs.sorted(),
                forKey: storedPasswordProfilesKey
            )
        case .gateway:
            if stored { gatewayPasswordStoredProfileIDs.insert(key) }
            else { gatewayPasswordStoredProfileIDs.remove(key) }
            UserDefaults.standard.set(
                gatewayPasswordStoredProfileIDs.sorted(),
                forKey: storedGatewayPasswordProfilesKey
            )
        case .ssh:
            if stored { sshPasswordStoredProfileIDs.insert(key) }
            else { sshPasswordStoredProfileIDs.remove(key) }
            UserDefaults.standard.set(
                sshPasswordStoredProfileIDs.sorted(),
                forKey: storedSSHPasswordProfilesKey
            )
        case .forwarding, .sshKeyAuthorization, .proxy:
            break
        }
    }

    private func setSSHPasswordUserPresence(_ enabled: Bool, profileID: UUID) {
        if enabled && !KeychainService.touchIDAvailable {
            errorMessage = "Touch ID недоступен на этом Mac или для текущего пользователя."
            return
        }
        let key = profileID.uuidString
        if selectedProfileHasSavedSSHPassword {
            do {
                let existing = try KeychainService.readPassword(
                    profileID: profileID,
                    kind: .ssh,
                    authenticationPrompt: "Подтвердите изменение защиты SSH-пароля"
                )
                if let existing {
                    try KeychainService.savePassword(
                        existing,
                        profileID: profileID,
                        kind: .ssh,
                        requiresUserPresence: enabled
                    )
                }
            } catch let error as KeychainError where error.needsCredentialRepair {
                errorMessage = error.localizedDescription
                return
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        if enabled { sshPasswordUserPresenceProfileIDs.insert(key) }
        else { sshPasswordUserPresenceProfileIDs.remove(key) }
        UserDefaults.standard.set(
            sshPasswordUserPresenceProfileIDs.sorted(),
            forKey: sshPasswordUserPresenceProfilesKey
        )
        statusMessage = enabled
            ? "SSH-пароль будет выдаваться только после Touch ID"
            : "Touch ID-защита SSH-пароля отключена"
        errorMessage = nil
    }

    private func setForwardingPasswordUserPresencePreference(_ enabled: Bool, tunnelID: UUID) {
        if enabled && !KeychainService.touchIDAvailable {
            errorMessage = "Touch ID недоступен на этом Mac или для текущего пользователя."
            return
        }
        let key = tunnelID.uuidString
        if hasSavedForwardingPassword(tunnelID) {
            do {
                let existing = try KeychainService.readPassword(
                    profileID: tunnelID,
                    kind: .forwarding,
                    authenticationPrompt: "Подтвердите изменение защиты пароля туннеля"
                )
                if let existing {
                    try KeychainService.savePassword(
                        existing,
                        profileID: tunnelID,
                        kind: .forwarding,
                        requiresUserPresence: enabled
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        if enabled { forwardingPasswordUserPresenceIDs.insert(key) }
        else { forwardingPasswordUserPresenceIDs.remove(key) }
        UserDefaults.standard.set(
            forwardingPasswordUserPresenceIDs.sorted(),
            forKey: forwardingPasswordUserPresenceIDsKey
        )
        statusMessage = enabled
            ? "Пароль туннеля будет выдаваться только после Touch ID"
            : "Touch ID-защита пароля туннеля отключена"
        errorMessage = nil
    }

    private func setForwardingPasswordStored(_ stored: Bool, tunnelID: UUID) {
        let key = tunnelID.uuidString
        if stored { forwardingPasswordStoredIDs.insert(key) }
        else { forwardingPasswordStoredIDs.remove(key) }
        UserDefaults.standard.set(
            forwardingPasswordStoredIDs.sorted(),
            forKey: storedForwardingPasswordIDsKey
        )
    }

    private func configureDefaultDisplays(for profile: inout ConnectionProfile) {
        let external = displays.filter { !$0.isBuiltIn }
        let initial = external.isEmpty ? displays : external
        profile.selectedDisplayIDs = Set(initial.map(\.id))
        profile.primaryDisplayID = initial.first?.id
        profile.displayLayoutMode = .automatic
        profile.virtualDisplayOrigins = [:]
    }

    private func normalizeCustomOrigins(profile: inout ConnectionProfile) {
        guard profile.displayLayoutMode == .custom,
              let primaryID = profile.primaryDisplayID,
              let primary = profile.virtualDisplayOrigins[primaryID]
        else { return }
        profile.virtualDisplayOrigins = profile.virtualDisplayOrigins.mapValues {
            VirtualDisplayPosition(x: $0.x - primary.x, y: $0.y - primary.y)
        }
    }

    private func refreshDisplays(configureEmptyProfile: Bool) {
        freeRDP.invalidateMonitorCache()
        displays = displayManager.currentDisplays()
        if configureEmptyProfile,
           selectedProfile.connectionType == .rdp,
           selectedProfile.selectedDisplayIDs.isEmpty {
            mutateSelectedProfile { profile in configureDefaultDisplays(for: &profile) }
        }
        statusMessage = "Обнаружено дисплеев: \(displays.count)"
    }

    private func refreshCameras(announce: Bool) {
        cameras = CameraDiscovery.currentDevices()
        if announce {
            statusMessage = cameras.isEmpty
                ? "Камеры не обнаружены"
                : "Обнаружено камер: \(cameras.count)"
        }
    }

    private func handleConfirmedDisplayChange(
        previousIDs: Set<String>,
        firstSnapshot: [DisplayDescriptor],
        secondSnapshot: [DisplayDescriptor]
    ) {
        freeRDP.invalidateMonitorCache()
        let firstIDs = Set(firstSnapshot.map(\.id))
        let currentIDs = Set(secondSnapshot.map(\.id))
        displays = secondSnapshot
        let removed = DisplaySnapshotStability.confirmedRemoved(
            previous: previousIDs,
            first: firstIDs,
            second: currentIDs
        )
        guard !removed.isEmpty else {
            statusMessage = "Конфигурация дисплеев обновлена: \(displays.count)"
            return
        }

        for (profileID, runtime) in managedSessions
        where !runtime.selectedDisplayIDs.isDisjoint(with: removed) {
            requestDisconnect(
                profileID: profileID,
                interruptionReason: "Монитор отключён — сессия «\(runtime.profileName)» безопасно завершена"
            )
        }
    }

    private func installNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(captureDevicesChanged(_:)),
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(captureDevicesChanged(_:)),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func captureDevicesChanged(_ notification: Notification) {
        _ = notification
        refreshCameras(announce: false)
        statusMessage = "Список камер обновлён: \(cameras.count)"
    }

    @objc private func screenParametersChanged() {
        let previousIDs = Set(displays.map(\.id))
        displayRefreshTask?.cancel()
        displayRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // SDL fullscreen startup produces transient screen notifications on
            // macOS. Sample once after the transition begins, then confirm the
            // same topology six seconds later before stopping any RDP session.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let first = displayManager.currentDisplays()
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            let second = displayManager.currentDisplays()
            handleConfirmedDisplayChange(
                previousIDs: previousIDs,
                firstSnapshot: first,
                secondSnapshot: second
            )
        }
    }

    @objc private func workspaceWillSleep() {
        sleepInterruptedProfileIDs = Set(managedSessions.keys)
        for profileID in managedSessions.keys {
            guard let runtime = managedSessions[profileID] else { continue }
            requestDisconnect(
                profileID: profileID,
                interruptionReason: "Mac переходит в сон — сессия «\(runtime.profileName)» приостановлена"
            )
        }
    }

    @objc private func workspaceDidWake() {
        let interrupted = sleepInterruptedProfileIDs
        sleepInterruptedProfileIDs = []
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            refreshDisplays(configureEmptyProfile: false)
            for profileID in interrupted {
                reconnectCandidateProfileIDs.insert(profileID)
                guard let profile = profiles.first(where: { $0.id == profileID }),
                      profile.autoReconnect,
                      profile.reconnectAfterWake,
                      passwordStoredProfileIDs.contains(profileID.uuidString)
                else { continue }
                connectProfile(
                    profileID,
                    typedPassword: "",
                    typedGatewayPassword: "",
                    automatic: true
                )
            }
            if !reconnectCandidateProfileIDs.isEmpty {
                statusMessage = "Mac вышел из сна — доступно восстановление прерванных сессий"
            }
        }
    }

    @objc private func applicationWillTerminate() {
        profileSaveTask?.cancel()
        profileSaveTask = nil
        saveProfiles()
        displayRefreshTask?.cancel()
        sessionTimer?.invalidate()
        sshTunnelTimer?.invalidate()
        for runtime in managedSessions.values where runtime.connection.process.isRunning {
            Darwin.kill(runtime.connection.process.processIdentifier, SIGKILL)
        }
        for running in managedSSHTunnels.values where running.process.isRunning {
            Darwin.kill(running.process.processIdentifier, SIGKILL)
            try? running.logHandle.close()
        }
        for terminal in sshTerminalSessions.values where terminal.isRunning {
            terminal.stop()
        }
    }

    private func sortProfiles(_ values: [ConnectionProfile]) -> [ConnectionProfile] {
        values.sorted { lhs, rhs in
            switch profileSortMode {
            case .favoritesAndName:
                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
                return lhs.friendlyName.localizedCaseInsensitiveCompare(rhs.friendlyName)
                    == .orderedAscending
            case .name:
                return lhs.friendlyName.localizedCaseInsensitiveCompare(rhs.friendlyName)
                    == .orderedAscending
            case .host:
                return lhs.host.localizedCaseInsensitiveCompare(rhs.host) == .orderedAscending
            case .recent:
                return (lhs.lastConnectedAt ?? .distantPast) > (rhs.lastConnectedAt ?? .distantPast)
            }
        }
    }

    private func scheduleProfileSave() {
        profileSaveTask?.cancel()
        profileSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            profileSaveTask = nil
            saveProfiles()
        }
    }

    private func saveProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: profilesKey)
    }

    private func saveIndependentPortForwards() {
        guard let data = try? JSONEncoder().encode(independentPortForwards) else {
            return
        }
        UserDefaults.standard.set(data, forKey: independentPortForwardsKey)
    }

    private func saveSSHKeys() {
        guard let data = try? JSONEncoder().encode(sshKeys) else { return }
        UserDefaults.standard.set(data, forKey: sshKeysKey)
    }

    private func setSSHKeyPassphraseStored(_ stored: Bool, keyID: UUID) {
        let key = keyID.uuidString
        if stored {
            sshKeyPassphraseStoredIDs.insert(key)
        } else {
            sshKeyPassphraseStoredIDs.remove(key)
        }
        UserDefaults.standard.set(
            sshKeyPassphraseStoredIDs.sorted(),
            forKey: storedSSHKeyPassphrasesKey
        )
    }

    private func saveSelectedProfileID() {
        UserDefaults.standard.set(selectedProfileID?.uuidString, forKey: selectedProfileKey)
    }

    private func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let result = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let name = String(result).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? AppBrand.name : name
    }
}
