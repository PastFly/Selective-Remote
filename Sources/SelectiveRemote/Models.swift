import CoreGraphics
import Foundation

enum AppBrand {
    static let name = "Selective Remote"
    static let tagline = "RDP · SSH · SFTP"
}

enum AppBuildInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
    }

    static var displayText: String { "v\(version)" }
    static var fullText: String { "\(AppBrand.name) \(displayText) · Community" }
}

struct DisplayDescriptor: Identifiable, Hashable {
    let id: String
    let systemID: UInt32
    let name: String
    let frame: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isBuiltIn: Bool
    let isSystemMain: Bool

    var resolutionText: String { "\(pixelWidth) × \(pixelHeight)" }
    var rdpWidthHint: Int { max(1, Int(frame.width.rounded())) }
    var rdpHeightHint: Int { max(1, Int(frame.height.rounded())) }

    var refreshText: String {
        refreshRate > 0 ? "\(Int(refreshRate.rounded())) Гц" : "частота неизвестна"
    }
}

enum DisplaySnapshotStability {
    /// A fullscreen transition can briefly remove or renumber screens in AppKit.
    /// Only a removal present in two snapshots separated by a quiet period is
    /// considered a physical disconnect. An empty snapshot is never destructive;
    /// sleep is handled by NSWorkspace notifications instead.
    static func confirmedRemoved(
        previous: Set<String>,
        first: Set<String>,
        second: Set<String>
    ) -> Set<String> {
        guard !second.isEmpty, first == second else { return [] }
        return previous.subtracting(second)
    }
}

struct VirtualDisplayPosition: Codable, Equatable, Hashable {
    var x: Int
    var y: Int
}

struct DisplayPlacement: Equatable {
    let id: String
    let virtualFrame: CGRect
    let isPrimary: Bool
}

enum DisplayLayoutMode: String, Codable, CaseIterable, Identifiable {
    case automatic
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Автоматически"
        case .custom: "Вручную"
        }
    }
}

enum DisplayArrangementPreset {
    case horizontal
    case vertical
}

enum VirtualTopologyMapper {
    /// Backwards-compatible automatic layout used by existing profiles and tests.
    static func compact(
        displays: [DisplayDescriptor],
        selectedIDs: Set<String>,
        primaryID: String?
    ) -> [DisplayPlacement] {
        layout(
            displays: displays,
            selectedIDs: selectedIDs,
            primaryID: primaryID,
            mode: .automatic,
            customOrigins: [:]
        )
    }

    /// Produces the Windows monitor topology from any currently available displays.
    /// Unknown or disconnected display IDs stay in the profile but are omitted until
    /// macOS reports them again.
    static func layout(
        displays: [DisplayDescriptor],
        selectedIDs: Set<String>,
        primaryID: String?,
        mode: DisplayLayoutMode,
        customOrigins: [String: VirtualDisplayPosition]
    ) -> [DisplayPlacement] {
        let selected = displays
            .filter { selectedIDs.contains($0.id) }
            .sorted {
                if $0.frame.minX == $1.frame.minX { return $0.frame.minY > $1.frame.minY }
                return $0.frame.minX < $1.frame.minX
            }
        guard !selected.isEmpty else { return [] }

        let effectivePrimary = selected.contains(where: { $0.id == primaryID })
            ? primaryID
            : selected.first?.id
        guard let effectivePrimary else { return [] }

        let automatic = automaticOrigins(selected: selected, primaryID: effectivePrimary)
        var origins = automatic
        if mode == .custom {
            for display in selected {
                if let origin = customOrigins[display.id] {
                    origins[display.id] = origin
                }
            }
            origins = normalized(origins, primaryID: effectivePrimary)
        }

        return selected.map { display in
            let origin = origins[display.id] ?? VirtualDisplayPosition(x: 0, y: 0)
            return DisplayPlacement(
                id: display.id,
                virtualFrame: CGRect(
                    x: CGFloat(origin.x),
                    y: CGFloat(origin.y),
                    width: CGFloat(display.rdpWidthHint),
                    height: CGFloat(display.rdpHeightHint)
                ),
                isPrimary: display.id == effectivePrimary
            )
        }
    }

    static func origins(from placements: [DisplayPlacement]) -> [String: VirtualDisplayPosition] {
        Dictionary(uniqueKeysWithValues: placements.map {
            ($0.id, VirtualDisplayPosition(
                x: Int($0.virtualFrame.minX.rounded()),
                y: Int($0.virtualFrame.minY.rounded())
            ))
        })
    }

    static func arrangedOrigins(
        displays: [DisplayDescriptor],
        selectedIDs: Set<String>,
        primaryID: String?,
        preset: DisplayArrangementPreset
    ) -> [String: VirtualDisplayPosition] {
        let selected = displays
            .filter { selectedIDs.contains($0.id) }
            .sorted {
                if $0.frame.minX == $1.frame.minX { return $0.frame.minY > $1.frame.minY }
                return $0.frame.minX < $1.frame.minX
            }
        guard !selected.isEmpty else { return [:] }
        let effectivePrimary = selected.contains(where: { $0.id == primaryID })
            ? primaryID
            : selected.first?.id
        guard let effectivePrimary,
              let primaryIndex = selected.firstIndex(where: { $0.id == effectivePrimary })
        else { return [:] }

        var result: [String: VirtualDisplayPosition] = [:]
        result[effectivePrimary] = VirtualDisplayPosition(x: 0, y: 0)

        switch preset {
        case .horizontal:
            var negative = 0
            if primaryIndex > 0 {
                for index in stride(from: primaryIndex - 1, through: 0, by: -1) {
                    negative -= selected[index].rdpWidthHint
                    result[selected[index].id] = VirtualDisplayPosition(x: negative, y: 0)
                }
            }
            var positive = selected[primaryIndex].rdpWidthHint
            if primaryIndex + 1 < selected.count {
                for index in (primaryIndex + 1)..<selected.count {
                    result[selected[index].id] = VirtualDisplayPosition(x: positive, y: 0)
                    positive += selected[index].rdpWidthHint
                }
            }
        case .vertical:
            var negative = 0
            if primaryIndex > 0 {
                for index in stride(from: primaryIndex - 1, through: 0, by: -1) {
                    negative -= selected[index].rdpHeightHint
                    result[selected[index].id] = VirtualDisplayPosition(x: 0, y: negative)
                }
            }
            var positive = selected[primaryIndex].rdpHeightHint
            if primaryIndex + 1 < selected.count {
                for index in (primaryIndex + 1)..<selected.count {
                    result[selected[index].id] = VirtualDisplayPosition(x: 0, y: positive)
                    positive += selected[index].rdpHeightHint
                }
            }
        }
        return result
    }

    static func hasOverlaps(_ placements: [DisplayPlacement]) -> Bool {
        for lhsIndex in placements.indices {
            for rhsIndex in placements.indices where rhsIndex > lhsIndex {
                if placements[lhsIndex].virtualFrame.intersects(placements[rhsIndex].virtualFrame) {
                    return true
                }
            }
        }
        return false
    }

    private static func automaticOrigins(
        selected: [DisplayDescriptor],
        primaryID: String
    ) -> [String: VirtualDisplayPosition] {
        arrangedOrigins(
            displays: selected,
            selectedIDs: Set(selected.map(\.id)),
            primaryID: primaryID,
            preset: .horizontal
        )
    }

    private static func normalized(
        _ origins: [String: VirtualDisplayPosition],
        primaryID: String
    ) -> [String: VirtualDisplayPosition] {
        guard let primary = origins[primaryID] else { return origins }
        return origins.mapValues {
            VirtualDisplayPosition(x: $0.x - primary.x, y: $0.y - primary.y)
        }
    }
}

enum AudioMode: String, Codable, CaseIterable, Identifiable {
    case local
    case remote
    case muted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "На этом Mac"
        case .remote: "На удалённом компьютере"
        case .muted: "Выключен"
        }
    }
}

enum CameraSelectionMode: String, Codable, Sendable {
    case builtIn
    case automatic
    case specific
}

enum CameraQualityPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case economy
    case balanced
    case high
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .economy: "Экономия"
        case .balanced: "Сбалансированное"
        case .high: "Высокое"
        case .automatic: "Автоматически"
        }
    }

    var details: String {
        switch self {
        case .economy: "640 × 480 · 15 FPS · цель 0,7 Мбит/с"
        case .balanced: "1280 × 720 · 30 FPS · цель 1,25 Мбит/с"
        case .high: "1920 × 1080 · 30 FPS · цель 2,7 Мбит/с"
        case .automatic: "До 1920 × 1080 · удалённая сторона выбирает формат"
        }
    }

    var maximumWidth: Int? {
        switch self {
        case .economy: 640
        case .balanced: 1280
        case .high: 1920
        case .automatic: nil
        }
    }

    var maximumHeight: Int? {
        switch self {
        case .economy: 480
        case .balanced: 720
        case .high: 1080
        case .automatic: nil
        }
    }

    var maximumFramesPerSecond: Int? {
        switch self {
        case .economy: 15
        case .balanced, .high: 30
        case .automatic: nil
        }
    }

    /// FreeRDP passes this value to its H.264 encoder as a target bitrate.
    /// Automatic mode preserves the encoder's own height-based calculation.
    var maximumBitrate: Int? {
        switch self {
        case .economy: 700_000
        case .balanced: 1_250_000
        case .high: 2_700_000
        case .automatic: nil
        }
    }
}

enum ClipboardMode: String, Codable, CaseIterable, Identifiable {
    case bidirectional
    case macToWindows
    case windowsToMac
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bidirectional: "В обе стороны"
        case .macToWindows: "Только Mac → Windows"
        case .windowsToMac: "Только Windows → Mac"
        case .disabled: "Отключён"
        }
    }
}

enum WindowsScale: Int, Codable, CaseIterable, Identifiable {
    case percent100 = 100
    case percent140 = 140
    case percent180 = 180

    var id: Int { rawValue }
    var title: String { "\(rawValue)%" }
}

enum RDPQualityPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case high
    case balanced
    case economy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Автоматически"
        case .high: "Макс. качество"
        case .balanced: "Сбалансировано"
        case .economy: "Экономия"
        }
    }

    var details: String {
        switch self {
        case .automatic:
            "Без принудительного сетевого профиля — поведение совместимо с предыдущими версиями."
        case .high:
            "Профиль LAN для быстрой стабильной сети: максимум визуальных эффектов."
        case .balanced:
            "Профиль быстрого интернета: баланс качества изображения, отклика и трафика."
        case .economy:
            "Профиль медленного интернета: меньше визуальных эффектов и сетевого трафика."
        }
    }

    var freeRDPArgument: String? {
        switch self {
        case .automatic: nil
        case .high: "/network:lan"
        case .balanced: "/network:broadband-high"
        case .economy: "/network:broadband-low"
        }
    }
}

enum CertificatePolicy: String, Codable, CaseIterable, Identifiable {
    case trustOnFirstUse
    case strict
    case ignore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trustOnFirstUse: "Доверять при первом подключении"
        case .strict: "Только доверенный сертификат"
        case .ignore: "Не проверять сертификат"
        }
    }
}

enum ConnectionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case rdp
    case ssh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rdp: "RDP"
        case .ssh: "SSH"
        }
    }

    var systemImage: String {
        switch self {
        case .rdp: "desktopcomputer"
        case .ssh: "terminal"
        }
    }
}


enum SSHAuthenticationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case password
    case key
    case touchIDKey
    case agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Автоматически"
        case .password: "Пароль"
        case .key: "SSH-ключ"
        case .touchIDKey: "Touch ID Key"
        case .agent: "ssh-agent / ~/.ssh/config"
        }
    }

    var systemImage: String {
        switch self {
        case .automatic: "wand.and.stars"
        case .password: "ellipsis.rectangle.fill"
        case .key: "key.horizontal.fill"
        case .touchIDKey: "touchid"
        case .agent: "terminal.fill"
        }
    }
}

enum SSHProxyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case http
    case socks5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Без прокси"
        case .http: "HTTP CONNECT"
        case .socks5: "SOCKS5"
        }
    }
}

enum SSHHostKeyPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case acceptNew
    case strict

    var id: String { rawValue }

    var title: String {
        switch self {
        case .acceptNew: "Принимать только новые ключи"
        case .strict: "Только уже известные ключи"
        }
    }

    var openSSHValue: String {
        switch self {
        case .acceptNew: "accept-new"
        case .strict: "yes"
        }
    }
}

enum PortForwardKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case remote
    case dynamic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Локальный"
        case .remote: "Удалённый"
        case .dynamic: "SOCKS"
        }
    }

    var systemImage: String {
        switch self {
        case .local: "arrow.right"
        case .remote: "arrow.left"
        case .dynamic: "point.3.connected.trianglepath.dotted"
        }
    }
}

struct PortForwardRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var kind: PortForwardKind
    var bindAddress: String
    var sourcePort: Int
    var destinationHost: String
    var destinationPort: Int

    init(kind: PortForwardKind = .local) {
        self.kind = kind
        switch kind {
        case .local:
            name = "Локальный туннель"
            bindAddress = "127.0.0.1"
            sourcePort = 8080
            destinationHost = "127.0.0.1"
            destinationPort = 80
        case .remote:
            name = "Удалённый туннель"
            bindAddress = "127.0.0.1"
            sourcePort = 8080
            destinationHost = "127.0.0.1"
            destinationPort = 80
        case .dynamic:
            name = "SOCKS-прокси"
            bindAddress = "127.0.0.1"
            sourcePort = 1080
            destinationHost = ""
            destinationPort = 0
        }
    }
}

struct IndependentPortForward: Codable, Equatable, Identifiable {
    var id: UUID
    var connection: TerminalTabConnection
    var rule: PortForwardRule

    init(
        id: UUID = UUID(),
        connection: TerminalTabConnection,
        kind: PortForwardKind = .local
    ) {
        self.id = id
        self.connection = connection
        rule = PortForwardRule(kind: kind)
        rule.id = id
    }
}

struct SSHKeyRecord: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var privateKeyPath: String
    var publicKeyPath: String?
    var fingerprint: String
    var algorithm: String
    var createdAt = Date()
}

enum ProfileSortMode: String, CaseIterable, Identifiable {
    case favoritesAndName
    case name
    case host
    case recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favoritesAndName: "Избранное и название"
        case .name: "Название"
        case .host: "Hostname"
        case .recent: "Последнее подключение"
        }
    }
}

struct ProfileGroupSection: Identifiable {
    let name: String
    let profiles: [ConnectionProfile]
    var id: String { name }
}

enum RDPWindowMode: String, Codable, CaseIterable, Identifiable {
    case fullScreen
    case dynamicWindow
    case fixedWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullScreen: "Полный экран"
        case .dynamicWindow: "Окно · менять разрешение"
        case .fixedWindow: "Окно · фиксированный размер"
        }
    }
}

enum RDPRemappableKey: String, Codable, CaseIterable, Identifiable {
    case leftCommand
    case rightCommand
    case leftOption
    case rightOption
    case capsLock
    case escape
    case leftControl
    case rightControl
    case leftWindows
    case rightWindows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftCommand: "Левый Command"
        case .rightCommand: "Правый Command"
        case .leftOption: "Левый Option"
        case .rightOption: "Правый Option"
        case .capsLock: "Caps Lock"
        case .escape: "Escape"
        case .leftControl: "Левый Control"
        case .rightControl: "Правый Control"
        case .leftWindows: "Левая Windows"
        case .rightWindows: "Правая Windows"
        }
    }

    var rdpScancode: String {
        switch self {
        case .leftCommand, .leftWindows: "0x15b"
        case .rightCommand, .rightWindows: "0x15c"
        case .leftOption: "0x38"
        case .rightOption: "0x138"
        case .capsLock: "0x3a"
        case .escape: "0x01"
        case .leftControl: "0x1d"
        case .rightControl: "0x11d"
        }
    }
}

struct RDPKeyMapping: Codable, Equatable, Identifiable {
    var id = UUID()
    var source: RDPRemappableKey
    var target: RDPRemappableKey
    var isEnabled = true
}

struct ConnectionProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var connectionType: ConnectionType
    var friendlyName: String
    var group: String
    var profileDescription: String
    var host: String
    var username: String
    var sshPort: Int
    var sshAuthenticationMode: SSHAuthenticationMode
    var sshIdentityID: UUID?
    var sshProxyMode: SSHProxyMode
    var sshProxyHost: String
    var sshProxyPort: Int
    var sshProxyUsername: String
    var sshJumpHostProfileID: UUID?
    var sshHostKeyPolicy: SSHHostKeyPolicy
    var sshInitialDirectory: String
    var sshCompression: Bool
    var sshKeepAliveSeconds: Int
    var portForwards: [PortForwardRule]
    var gatewayHost: String
    var gatewayUsername: String
    var isFavorite: Bool
    var selectedDisplayIDs: Set<String>
    var primaryDisplayID: String?
    var displayLayoutMode: DisplayLayoutMode
    var virtualDisplayOrigins: [String: VirtualDisplayPosition]
    var windowsScale: WindowsScale
    var rdpQuality: RDPQualityPreset
    var audioMode: AudioMode
    var clipboardMode: ClipboardMode
    var mapCommandToControl: Bool
    var mapOptionToWindows: Bool
    var mapRightCommandToWindows: Bool
    var fnSwitchesWindowsLanguage: Bool
    var customKeyMappings: [RDPKeyMapping]
    var redirectMicrophone: Bool
    var redirectCamera: Bool
    var cameraSelectionMode: CameraSelectionMode
    var cameraDeviceID: String?
    var cameraDeviceName: String?
    var cameraQuality: CameraQualityPreset
    var redirectPrinters: Bool
    var redirectedFolders: [String]
    var autoReconnect: Bool
    var reconnectAfterWake: Bool
    var adminSession: Bool
    var startFullScreen: Bool
    var rdpWindowMode: RDPWindowMode
    var windowWidth: Int
    var windowHeight: Int
    var certificatePolicy: CertificatePolicy
    var createdAt: Date
    var lastConnectedAt: Date?

    init(connectionType: ConnectionType = .rdp) {
        id = UUID()
        self.connectionType = connectionType
        friendlyName = connectionType == .rdp ? "Новое подключение" : "Новое SSH-подключение"
        group = ""
        profileDescription = ""
        host = ""
        username = ""
        sshPort = 22
        sshAuthenticationMode = .automatic
        sshIdentityID = nil
        sshProxyMode = .none
        sshProxyHost = ""
        sshProxyPort = 1080
        sshProxyUsername = ""
        sshJumpHostProfileID = nil
        sshHostKeyPolicy = .acceptNew
        sshInitialDirectory = "."
        sshCompression = false
        sshKeepAliveSeconds = 30
        portForwards = []
        gatewayHost = ""
        gatewayUsername = ""
        isFavorite = false
        selectedDisplayIDs = []
        primaryDisplayID = nil
        displayLayoutMode = .automatic
        virtualDisplayOrigins = [:]
        windowsScale = .percent100
        rdpQuality = .automatic
        audioMode = .local
        clipboardMode = .bidirectional
        mapCommandToControl = true
        mapOptionToWindows = false
        mapRightCommandToWindows = true
        fnSwitchesWindowsLanguage = true
        customKeyMappings = []
        redirectMicrophone = false
        redirectCamera = false
        cameraSelectionMode = .builtIn
        cameraDeviceID = nil
        cameraDeviceName = nil
        cameraQuality = .balanced
        redirectPrinters = false
        redirectedFolders = []
        autoReconnect = true
        reconnectAfterWake = false
        adminSession = false
        startFullScreen = true
        rdpWindowMode = .fullScreen
        windowWidth = 1440
        windowHeight = 900
        certificatePolicy = .trustOnFirstUse
        createdAt = Date()
        lastConnectedAt = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, connectionType, friendlyName, group, profileDescription, host, username
        case sshPort, sshAuthenticationMode, sshIdentityID, sshProxyMode, sshProxyHost, sshProxyPort, sshProxyUsername, sshJumpHostProfileID, sshHostKeyPolicy, sshInitialDirectory
        case sshCompression, sshKeepAliveSeconds, portForwards
        case gatewayHost, gatewayUsername
        case isFavorite, selectedDisplayIDs, primaryDisplayID
        case displayLayoutMode, virtualDisplayOrigins, windowsScale, rdpQuality
        case audioMode, clipboardMode, redirectClipboard, mapCommandToControl
        case mapOptionToWindows, mapRightCommandToWindows
        case fnSwitchesWindowsLanguage, customKeyMappings
        case redirectMicrophone, redirectCamera
        case cameraSelectionMode, cameraDeviceID, cameraDeviceName, cameraQuality
        case redirectPrinters, redirectedFolders
        case autoReconnect, reconnectAfterWake, adminSession, startFullScreen
        case rdpWindowMode, windowWidth, windowHeight
        case certificatePolicy, createdAt, lastConnectedAt
    }

    init(from decoder: Decoder) throws {
        let defaults = ConnectionProfile()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? defaults.id
        connectionType = try container.decodeIfPresent(ConnectionType.self, forKey: .connectionType)
            ?? defaults.connectionType
        friendlyName = try container.decodeIfPresent(String.self, forKey: .friendlyName)
            ?? defaults.friendlyName
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? defaults.group
        profileDescription = try container.decodeIfPresent(
            String.self,
            forKey: .profileDescription
        ) ?? defaults.profileDescription
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? defaults.host
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? defaults.username
        sshPort = try container.decodeIfPresent(Int.self, forKey: .sshPort) ?? defaults.sshPort
        sshAuthenticationMode = try container.decodeIfPresent(SSHAuthenticationMode.self, forKey: .sshAuthenticationMode) ?? defaults.sshAuthenticationMode
        sshIdentityID = try container.decodeIfPresent(UUID.self, forKey: .sshIdentityID)
        sshProxyMode = try container.decodeIfPresent(SSHProxyMode.self, forKey: .sshProxyMode) ?? defaults.sshProxyMode
        sshProxyHost = try container.decodeIfPresent(String.self, forKey: .sshProxyHost) ?? defaults.sshProxyHost
        sshProxyPort = try container.decodeIfPresent(Int.self, forKey: .sshProxyPort) ?? defaults.sshProxyPort
        sshProxyUsername = try container.decodeIfPresent(String.self, forKey: .sshProxyUsername) ?? defaults.sshProxyUsername
        sshJumpHostProfileID = try container.decodeIfPresent(UUID.self, forKey: .sshJumpHostProfileID)
        sshHostKeyPolicy = try container.decodeIfPresent(
            SSHHostKeyPolicy.self,
            forKey: .sshHostKeyPolicy
        ) ?? defaults.sshHostKeyPolicy
        sshInitialDirectory = try container.decodeIfPresent(
            String.self,
            forKey: .sshInitialDirectory
        ) ?? defaults.sshInitialDirectory
        sshCompression = try container.decodeIfPresent(Bool.self, forKey: .sshCompression)
            ?? defaults.sshCompression
        sshKeepAliveSeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .sshKeepAliveSeconds
        ) ?? defaults.sshKeepAliveSeconds
        portForwards = try container.decodeIfPresent(
            [PortForwardRule].self,
            forKey: .portForwards
        ) ?? defaults.portForwards
        gatewayHost = try container.decodeIfPresent(String.self, forKey: .gatewayHost)
            ?? defaults.gatewayHost
        gatewayUsername = try container.decodeIfPresent(String.self, forKey: .gatewayUsername)
            ?? defaults.gatewayUsername
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite)
            ?? defaults.isFavorite
        selectedDisplayIDs = try container.decodeIfPresent(Set<String>.self, forKey: .selectedDisplayIDs)
            ?? defaults.selectedDisplayIDs
        primaryDisplayID = try container.decodeIfPresent(String.self, forKey: .primaryDisplayID)
        displayLayoutMode = try container.decodeIfPresent(DisplayLayoutMode.self, forKey: .displayLayoutMode)
            ?? defaults.displayLayoutMode
        virtualDisplayOrigins = try container.decodeIfPresent(
            [String: VirtualDisplayPosition].self,
            forKey: .virtualDisplayOrigins
        ) ?? defaults.virtualDisplayOrigins
        windowsScale = try container.decodeIfPresent(WindowsScale.self, forKey: .windowsScale)
            ?? defaults.windowsScale
        rdpQuality = try container.decodeIfPresent(RDPQualityPreset.self, forKey: .rdpQuality)
            ?? defaults.rdpQuality
        audioMode = try container.decodeIfPresent(AudioMode.self, forKey: .audioMode)
            ?? defaults.audioMode
        if let clipboard = try container.decodeIfPresent(ClipboardMode.self, forKey: .clipboardMode) {
            clipboardMode = clipboard
        } else if let legacy = try container.decodeIfPresent(Bool.self, forKey: .redirectClipboard) {
            clipboardMode = legacy ? .bidirectional : .disabled
        } else {
            clipboardMode = defaults.clipboardMode
        }
        mapCommandToControl = try container.decodeIfPresent(
            Bool.self,
            forKey: .mapCommandToControl
        ) ?? defaults.mapCommandToControl
        mapOptionToWindows = try container.decodeIfPresent(
            Bool.self,
            forKey: .mapOptionToWindows
        ) ?? defaults.mapOptionToWindows
        mapRightCommandToWindows = try container.decodeIfPresent(
            Bool.self,
            forKey: .mapRightCommandToWindows
        ) ?? defaults.mapRightCommandToWindows
        fnSwitchesWindowsLanguage = try container.decodeIfPresent(
            Bool.self,
            forKey: .fnSwitchesWindowsLanguage
        ) ?? defaults.fnSwitchesWindowsLanguage
        customKeyMappings = try container.decodeIfPresent(
            [RDPKeyMapping].self,
            forKey: .customKeyMappings
        ) ?? defaults.customKeyMappings
        redirectMicrophone = try container.decodeIfPresent(Bool.self, forKey: .redirectMicrophone)
            ?? defaults.redirectMicrophone
        redirectCamera = try container.decodeIfPresent(Bool.self, forKey: .redirectCamera)
            ?? defaults.redirectCamera
        cameraSelectionMode = try container.decodeIfPresent(
            CameraSelectionMode.self,
            forKey: .cameraSelectionMode
        ) ?? defaults.cameraSelectionMode
        cameraDeviceID = try container.decodeIfPresent(String.self, forKey: .cameraDeviceID)
        cameraDeviceName = try container.decodeIfPresent(String.self, forKey: .cameraDeviceName)
        cameraQuality = try container.decodeIfPresent(
            CameraQualityPreset.self,
            forKey: .cameraQuality
        ) ?? defaults.cameraQuality
        redirectPrinters = try container.decodeIfPresent(Bool.self, forKey: .redirectPrinters)
            ?? defaults.redirectPrinters
        redirectedFolders = try container.decodeIfPresent([String].self, forKey: .redirectedFolders)
            ?? defaults.redirectedFolders
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect)
            ?? defaults.autoReconnect
        reconnectAfterWake = try container.decodeIfPresent(Bool.self, forKey: .reconnectAfterWake)
            ?? defaults.reconnectAfterWake
        adminSession = try container.decodeIfPresent(Bool.self, forKey: .adminSession)
            ?? defaults.adminSession
        startFullScreen = try container.decodeIfPresent(Bool.self, forKey: .startFullScreen)
            ?? defaults.startFullScreen
        rdpWindowMode = try container.decodeIfPresent(RDPWindowMode.self, forKey: .rdpWindowMode)
            ?? (startFullScreen ? .fullScreen : .fixedWindow)
        windowWidth = max(640, try container.decodeIfPresent(Int.self, forKey: .windowWidth)
            ?? defaults.windowWidth)
        windowHeight = max(480, try container.decodeIfPresent(Int.self, forKey: .windowHeight)
            ?? defaults.windowHeight)
        certificatePolicy = try container.decodeIfPresent(CertificatePolicy.self, forKey: .certificatePolicy)
            ?? defaults.certificatePolicy
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? defaults.createdAt
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(connectionType, forKey: .connectionType)
        try container.encode(friendlyName, forKey: .friendlyName)
        try container.encode(group, forKey: .group)
        try container.encode(profileDescription, forKey: .profileDescription)
        try container.encode(host, forKey: .host)
        try container.encode(username, forKey: .username)
        try container.encode(sshPort, forKey: .sshPort)
        try container.encode(sshAuthenticationMode, forKey: .sshAuthenticationMode)
        try container.encodeIfPresent(sshIdentityID, forKey: .sshIdentityID)
        try container.encode(sshProxyMode, forKey: .sshProxyMode)
        try container.encode(sshProxyHost, forKey: .sshProxyHost)
        try container.encode(sshProxyPort, forKey: .sshProxyPort)
        try container.encode(sshProxyUsername, forKey: .sshProxyUsername)
        try container.encodeIfPresent(sshJumpHostProfileID, forKey: .sshJumpHostProfileID)
        try container.encode(sshHostKeyPolicy, forKey: .sshHostKeyPolicy)
        try container.encode(sshInitialDirectory, forKey: .sshInitialDirectory)
        try container.encode(sshCompression, forKey: .sshCompression)
        try container.encode(sshKeepAliveSeconds, forKey: .sshKeepAliveSeconds)
        try container.encode(portForwards, forKey: .portForwards)
        try container.encode(gatewayHost, forKey: .gatewayHost)
        try container.encode(gatewayUsername, forKey: .gatewayUsername)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(selectedDisplayIDs, forKey: .selectedDisplayIDs)
        try container.encodeIfPresent(primaryDisplayID, forKey: .primaryDisplayID)
        try container.encode(displayLayoutMode, forKey: .displayLayoutMode)
        try container.encode(virtualDisplayOrigins, forKey: .virtualDisplayOrigins)
        try container.encode(windowsScale, forKey: .windowsScale)
        try container.encode(rdpQuality, forKey: .rdpQuality)
        try container.encode(audioMode, forKey: .audioMode)
        try container.encode(clipboardMode, forKey: .clipboardMode)
        try container.encode(mapCommandToControl, forKey: .mapCommandToControl)
        try container.encode(mapOptionToWindows, forKey: .mapOptionToWindows)
        try container.encode(mapRightCommandToWindows, forKey: .mapRightCommandToWindows)
        try container.encode(fnSwitchesWindowsLanguage, forKey: .fnSwitchesWindowsLanguage)
        try container.encode(customKeyMappings, forKey: .customKeyMappings)
        try container.encode(redirectMicrophone, forKey: .redirectMicrophone)
        try container.encode(redirectCamera, forKey: .redirectCamera)
        try container.encode(cameraSelectionMode, forKey: .cameraSelectionMode)
        try container.encodeIfPresent(cameraDeviceID, forKey: .cameraDeviceID)
        try container.encodeIfPresent(cameraDeviceName, forKey: .cameraDeviceName)
        try container.encode(cameraQuality, forKey: .cameraQuality)
        try container.encode(redirectPrinters, forKey: .redirectPrinters)
        try container.encode(redirectedFolders, forKey: .redirectedFolders)
        try container.encode(autoReconnect, forKey: .autoReconnect)
        try container.encode(reconnectAfterWake, forKey: .reconnectAfterWake)
        try container.encode(adminSession, forKey: .adminSession)
        try container.encode(startFullScreen, forKey: .startFullScreen)
        try container.encode(rdpWindowMode, forKey: .rdpWindowMode)
        try container.encode(windowWidth, forKey: .windowWidth)
        try container.encode(windowHeight, forKey: .windowHeight)
        try container.encode(certificatePolicy, forKey: .certificatePolicy)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastConnectedAt, forKey: .lastConnectedAt)
    }
}

/// Builds a temporary profile containing only displays that can actually be
/// used for the current launch. Disconnected display UUIDs remain stored in
/// the original profile so that a multi-monitor layout can be restored later.
///
/// When macOS currently exposes exactly one display, that display is used as a
/// safe fallback even if the saved profile only contains UUIDs of monitors that
/// are presently disconnected. With a single physical display there is no
/// ambiguity about the intended launch target.
enum DisplaySelectionResolver {
    static func runtimeProfile(
        from profile: ConnectionProfile,
        displays: [DisplayDescriptor]
    ) -> ConnectionProfile? {
        guard !displays.isEmpty else { return nil }

        let availableIDs = Set(displays.map(\.id))
        var selectedIDs = profile.selectedDisplayIDs.intersection(availableIDs)
        if selectedIDs.isEmpty, displays.count == 1, let onlyDisplay = displays.first {
            selectedIDs = [onlyDisplay.id]
        }
        guard !selectedIDs.isEmpty else { return nil }

        var resolved = profile
        resolved.selectedDisplayIDs = selectedIDs
        resolved.virtualDisplayOrigins = profile.virtualDisplayOrigins.filter {
            selectedIDs.contains($0.key)
        }

        if let primary = profile.primaryDisplayID, selectedIDs.contains(primary) {
            resolved.primaryDisplayID = primary
        } else {
            resolved.primaryDisplayID = displays.first(where: {
                selectedIDs.contains($0.id) && $0.isSystemMain
            })?.id ?? displays.first(where: { selectedIDs.contains($0.id) })?.id
        }

        // A custom topology cannot add value for one display and stale custom
        // coordinates have caused avoidable startup failures in older profiles.
        if selectedIDs.count == 1 {
            resolved.displayLayoutMode = .automatic
            resolved.virtualDisplayOrigins = [:]
        }
        return resolved
    }
}

struct LegacyConnectionProfile: Codable {
    var host = ""
    var username = ""
    var selectedDisplayIDs: Set<String> = []
    var primaryDisplayID: String?
}

struct SDLMonitor: Equatable {
    let id: Int
    let name: String
    let width: Int
    let height: Int
    let x: Int
    let y: Int
    let isSystemPrimary: Bool
}

struct SDLDisplayMapping: Equatable {
    let displayID: String
    let monitor: SDLMonitor
}

struct SDLMonitorPlacement: Equatable {
    let monitorID: Int
    let x: Int
    let y: Int
    let isPrimary: Bool

    var environmentEntry: String {
        "\(monitorID):\(x):\(y):\(isPrimary ? 1 : 0)"
    }
}

enum SDLTopologyMapper {
    static func compact(
        mappings: [SDLDisplayMapping],
        primaryDisplayID: String?
    ) -> [SDLMonitorPlacement] {
        arrange(
            mappings: mappings,
            primaryDisplayID: primaryDisplayID,
            mode: .automatic,
            customOrigins: [:]
        )
    }

    static func arrange(
        mappings: [SDLDisplayMapping],
        primaryDisplayID: String?,
        mode: DisplayLayoutMode,
        customOrigins: [String: VirtualDisplayPosition]
    ) -> [SDLMonitorPlacement] {
        let sorted = mappings.sorted {
            if $0.monitor.x == $1.monitor.x { return $0.monitor.y < $1.monitor.y }
            return $0.monitor.x < $1.monitor.x
        }
        guard !sorted.isEmpty else { return [] }

        let effectivePrimary = sorted.contains(where: { $0.displayID == primaryDisplayID })
            ? primaryDisplayID
            : sorted.first?.displayID
        guard let effectivePrimary,
              let primaryIndex = sorted.firstIndex(where: { $0.displayID == effectivePrimary })
        else { return [] }

        var origins: [String: VirtualDisplayPosition] = [:]
        var leftX = 0
        if primaryIndex > 0 {
            for index in stride(from: primaryIndex - 1, through: 0, by: -1) {
                leftX -= sorted[index].monitor.width
                origins[sorted[index].displayID] = VirtualDisplayPosition(x: leftX, y: 0)
            }
        }
        origins[effectivePrimary] = VirtualDisplayPosition(x: 0, y: 0)
        var rightX = sorted[primaryIndex].monitor.width
        if primaryIndex + 1 < sorted.count {
            for index in (primaryIndex + 1)..<sorted.count {
                origins[sorted[index].displayID] = VirtualDisplayPosition(x: rightX, y: 0)
                rightX += sorted[index].monitor.width
            }
        }

        if mode == .custom {
            for mapping in sorted {
                if let custom = customOrigins[mapping.displayID] {
                    origins[mapping.displayID] = custom
                }
            }
            if let primary = origins[effectivePrimary] {
                origins = origins.mapValues {
                    VirtualDisplayPosition(x: $0.x - primary.x, y: $0.y - primary.y)
                }
            }

            // FreeRDP rejects a multimon topology when selected monitors have
            // even a tiny gap. The editor historically snapped coordinates to
            // a 20-point grid, so a 2056-wide Retina display could be stored at
            // x=-2060 and leave a four-pixel hole before the primary at x=0.
            // Preserve the user's perpendicular offset, but snap the nearest
            // monitor edge so every custom layout is connected at runtime.
            origins = connectedCustomOrigins(
                origins,
                mappings: sorted,
                primaryDisplayID: effectivePrimary
            )
        }

        let physicalOrder = sorted.map { mapping in
            let origin = origins[mapping.displayID] ?? VirtualDisplayPosition(x: 0, y: 0)
            return SDLMonitorPlacement(
                monitorID: mapping.monitor.id,
                x: origin.x,
                y: origin.y,
                isPrimary: mapping.displayID == effectivePrimary
            )
        }
        let primary = physicalOrder.first(where: { $0.isPrimary }) ?? physicalOrder[0]
        let remaining = physicalOrder.filter { !$0.isPrimary }.sorted {
            if $0.y == $1.y { return $0.x < $1.x }
            return $0.y < $1.y
        }
        return [primary] + remaining
    }

    private static func connectedCustomOrigins(
        _ origins: [String: VirtualDisplayPosition],
        mappings: [SDLDisplayMapping],
        primaryDisplayID: String
    ) -> [String: VirtualDisplayPosition] {
        guard mappings.count > 1 else { return origins }

        let mappingByID = Dictionary(
            uniqueKeysWithValues: mappings.map { ($0.displayID, $0) }
        )
        guard mappingByID[primaryDisplayID] != nil else { return origins }

        var result = origins
        var connected: Set<String> = [primaryDisplayID]
        var pending = mappings
            .map(\.displayID)
            .filter { $0 != primaryDisplayID }

        while !pending.isEmpty {
            var bestIndex: Int?
            var bestPosition: VirtualDisplayPosition?
            var bestDistance = Int.max

            for (pendingIndex, displayID) in pending.enumerated() {
                guard
                    let mapping = mappingByID[displayID],
                    let position = result[displayID]
                else { continue }

                let width = mapping.monitor.width
                let height = mapping.monitor.height

                for anchorID in connected {
                    guard
                        let anchorMapping = mappingByID[anchorID],
                        let anchor = result[anchorID]
                    else { continue }

                    let anchorWidth = anchorMapping.monitor.width
                    let anchorHeight = anchorMapping.monitor.height

                    let verticalOverlap =
                        min(position.y + height, anchor.y + anchorHeight)
                        - max(position.y, anchor.y)
                    if verticalOverlap > 0 {
                        for candidateX in [
                            anchor.x - width,
                            anchor.x + anchorWidth
                        ] {
                            let distance = abs(position.x - candidateX)
                            if distance < bestDistance {
                                bestDistance = distance
                                bestIndex = pendingIndex
                                bestPosition = VirtualDisplayPosition(
                                    x: candidateX,
                                    y: position.y
                                )
                            }
                        }
                    }

                    let horizontalOverlap =
                        min(position.x + width, anchor.x + anchorWidth)
                        - max(position.x, anchor.x)
                    if horizontalOverlap > 0 {
                        for candidateY in [
                            anchor.y - height,
                            anchor.y + anchorHeight
                        ] {
                            let distance = abs(position.y - candidateY)
                            if distance < bestDistance {
                                bestDistance = distance
                                bestIndex = pendingIndex
                                bestPosition = VirtualDisplayPosition(
                                    x: position.x,
                                    y: candidateY
                                )
                            }
                        }
                    }
                }
            }

            if let bestIndex, let bestPosition {
                let displayID = pending.remove(at: bestIndex)
                result[displayID] = bestPosition
                connected.insert(displayID)
                continue
            }

            let displayID = pending.removeFirst()
            guard
                let mapping = mappingByID[displayID],
                let requested = result[displayID],
                let primaryMapping = mappingByID[primaryDisplayID],
                let primary = result[primaryDisplayID]
            else { continue }

            let height = mapping.monitor.height
            let attachLeft = requested.x < primary.x
            let x = attachLeft
                ? primary.x - mapping.monitor.width
                : primary.x + primaryMapping.monitor.width
            let minimumY = primary.y - height + 1
            let maximumY = primary.y + primaryMapping.monitor.height - 1
            let y = min(max(requested.y, minimumY), maximumY)
            result[displayID] = VirtualDisplayPosition(x: x, y: y)
            connected.insert(displayID)
        }

        return result
    }

    static func environmentValue(_ placements: [SDLMonitorPlacement]) -> String {
        placements.map(\.environmentEntry).joined(separator: ";")
    }
}
