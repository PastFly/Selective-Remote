import Combine
import Foundation

enum TerminalWorkspaceLayout: String, Codable, CaseIterable, Identifiable {
    case single
    case splitHorizontal
    case splitVertical
    case grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: "Одна панель"
        case .splitHorizontal: "Разделить слева направо"
        case .splitVertical: "Разделить сверху вниз"
        case .grid: "Сетка до четырёх панелей"
        }
    }

    var systemImage: String {
        switch self {
        case .single: "rectangle"
        case .splitHorizontal: "rectangle.split.2x1"
        case .splitVertical: "rectangle.split.1x2"
        case .grid: "square.grid.2x2"
        }
    }
}

enum TerminalWorkspaceSessionState: Equatable {
    case connecting
    case connected
    case reconnecting
    case stopping
    case disconnected
    case error(Int32)

    static func resolve(
        phase: EmbeddedTerminalPhase,
        isReconnecting: Bool = false
    ) -> TerminalWorkspaceSessionState {
        if isReconnecting {
            return .reconnecting
        }
        switch phase {
        case .idle:
            return .disconnected
        case .starting:
            return .connecting
        case .running:
            return .connected
        case .stopping:
            return .stopping
        case let .finished(code):
            return code == 0 ? .disconnected : .error(code)
        }
    }

    var title: String {
        switch self {
        case .connecting:
            "Подключение…"
        case .connected:
            "Подключено"
        case .reconnecting:
            "Переподключение…"
        case .stopping:
            "Остановка…"
        case .disconnected:
            "Отключено"
        case .error:
            "Ошибка"
        }
    }

    var detail: String? {
        switch self {
        case let .error(code):
            "Exit code \(code)"
        default:
            nil
        }
    }

    var systemImage: String {
        switch self {
        case .connecting:
            "circle.dotted"
        case .connected:
            "checkmark.circle.fill"
        case .reconnecting:
            "arrow.triangle.2.circlepath.circle.fill"
        case .stopping:
            "stop.circle"
        case .disconnected:
            "circle"
        case .error:
            "exclamationmark.triangle.fill"
        }
    }
}

struct TerminalTabConnection: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case savedProfile
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .savedProfile: "Из сохранённых"
            case .custom: "Другой сервер"
            }
        }
    }

    var kind: Kind
    var profileID: UUID?
    var host: String
    var username: String
    var port: Int

    static func savedProfile(_ id: UUID) -> TerminalTabConnection {
        TerminalTabConnection(
            kind: .savedProfile,
            profileID: id,
            host: "",
            username: "",
            port: 22
        )
    }

    static func custom(
        host: String,
        username: String,
        port: Int = 22
    ) -> TerminalTabConnection {
        TerminalTabConnection(
            kind: .custom,
            profileID: nil,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port
        )
    }

    var normalizedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValidCustomConnection: Bool {
        kind == .custom
            && !normalizedHost.isEmpty
            && (1...65_535).contains(port)
            && !normalizedUsername.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    func displayLabel(profiles: [ConnectionProfile]) -> String {
        switch kind {
        case .savedProfile:
            guard let profileID,
                  let profile = profiles.first(where: { $0.id == profileID })
            else { return "Сохранённый профиль недоступен" }
            let user = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = user.isEmpty ? profile.host : "\(user)@\(profile.host)"
            return profile.sshPort == 22 ? destination : "\(destination):\(profile.sshPort)"
        case .custom:
            let destination = normalizedUsername.isEmpty
                ? normalizedHost
                : "\(normalizedUsername)@\(normalizedHost)"
            return port == 22 ? destination : "\(destination):\(port)"
        }
    }
}

struct TerminalWorkspaceTab: Identifiable {
    let id: UUID
    var title: String
    let session: TerminalSessionModel
    var isPrimary: Bool
    var connection: TerminalTabConnection
    var isPinned: Bool
    var colorIndex: Int

    @MainActor var isEmptyPlaceholder: Bool {
        !session.isRunning
            && connection.kind == .custom
            && connection.normalizedHost.isEmpty
            && connection.normalizedUsername.isEmpty
    }
}

private struct StoredTerminalWorkspace: Codable {
    struct Tab: Codable {
        let id: UUID
        var title: String
        let isPrimary: Bool
        var connection: TerminalTabConnection?
        var isPinned: Bool?
        var colorIndex: Int?
    }

    var tabs: [Tab]
    var selectedTabID: UUID?
    var secondaryTabID: UUID?
    var layout: TerminalWorkspaceLayout
}

@MainActor
final class TerminalWorkspaceModel: ObservableObject {
    @Published private(set) var tabs: [TerminalWorkspaceTab]
    @Published var selectedTabID: UUID {
        didSet { normalizeSelectionAndPersist() }
    }
    @Published var secondaryTabID: UUID? {
        didSet { normalizeSelectionAndPersist() }
    }
    @Published var layout: TerminalWorkspaceLayout {
        didSet { normalizeSelectionAndPersist() }
    }
    @Published private(set) var remoteContexts: [UUID: TerminalRemoteContextSnapshot] = [:]

    let profileID: UUID

    private let defaults: UserDefaults
    private var sessionObservers: [UUID: AnyCancellable] = [:]
    private var sessionPhaseObservers: [UUID: AnyCancellable] = [:]
    private var isRestoring = true
    private var storageKey: String {
        "SelectiveRemote.terminal.workspace.v1.\(profileID.uuidString)"
    }

    init(
        profileID: UUID,
        primarySession: TerminalSessionModel,
        primaryConnection: TerminalTabConnection? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.profileID = profileID
        self.defaults = defaults

        let initialStorageKey = "SelectiveRemote.terminal.workspace.v1.\(profileID.uuidString)"
        let stored = defaults.data(forKey: initialStorageKey)
            .flatMap { try? JSONDecoder().decode(StoredTerminalWorkspace.self, from: $0) }
        let primaryMetadata = stored?.tabs.first(where: \.isPrimary)
            ?? stored?.tabs.first
            ?? StoredTerminalWorkspace.Tab(
                id: UUID(),
                title: "Терминал 1",
                isPrimary: true,
                connection: nil,
                isPinned: false,
                colorIndex: 0
            )
        var restoredTabs = [
            TerminalWorkspaceTab(
                id: primaryMetadata.id,
                title: Self.normalizedTitle(primaryMetadata.title, fallback: "Терминал 1"),
                session: primarySession,
                isPrimary: true,
                connection: primaryMetadata.connection
                    ?? primaryConnection
                    ?? .savedProfile(profileID),
                isPinned: primaryMetadata.isPinned ?? false,
                colorIndex: primaryMetadata.colorIndex ?? 0
            )
        ]
        let additionalMetadata = Array(
            (stored?.tabs.filter { $0.id != primaryMetadata.id } ?? []).prefix(7)
        )
        for metadata in additionalMetadata {
            restoredTabs.append(
                TerminalWorkspaceTab(
                    id: metadata.id,
                    title: Self.normalizedTitle(
                        metadata.title,
                        fallback: "Терминал \(restoredTabs.count + 1)"
                    ),
                    session: TerminalSessionModel(),
                    isPrimary: false,
                    connection: metadata.connection ?? .savedProfile(profileID),
                    isPinned: metadata.isPinned ?? false,
                    colorIndex: metadata.colorIndex ?? restoredTabs.count % 6
                )
            )
        }
        if let storedOrder = stored?.tabs.map(\.id) {
            let positions = Dictionary(
                uniqueKeysWithValues: storedOrder.enumerated().map {
                    ($0.element, $0.offset)
                }
            )
            restoredTabs.sort {
                positions[$0.id, default: Int.max] < positions[$1.id, default: Int.max]
            }
        }
        tabs = restoredTabs
        selectedTabID = stored?.selectedTabID.flatMap { id in
            restoredTabs.contains(where: { $0.id == id }) ? id : nil
        } ?? restoredTabs[0].id
        secondaryTabID = stored?.secondaryTabID.flatMap { id in
            restoredTabs.contains(where: { $0.id == id }) ? id : nil
        }
        layout = stored?.layout ?? .single
        observeSessions()
        isRestoring = false
        normalizeSelectionAndPersist()
    }

    var selectedTab: TerminalWorkspaceTab {
        tabs.first(where: { $0.id == selectedTabID }) ?? tabs[0]
    }

    var secondaryTab: TerminalWorkspaceTab? {
        guard layout != .single,
              let secondaryTabID,
              secondaryTabID != selectedTabID
        else { return nil }
        return tabs.first(where: { $0.id == secondaryTabID })
    }

    var runningSessionCount: Int {
        tabs.filter { $0.session.isRunning }.count
    }

    var hasRunningSession: Bool { runningSessionCount > 0 }

    var isEmptyState: Bool {
        tabs.count == 1 && tabs[0].isEmptyPlaceholder
    }

    var displayedTabs: [TerminalWorkspaceTab] {
        isEmptyState ? [] : tabs
    }

    func visibleTabs(limit: Int = 4) -> [TerminalWorkspaceTab] {
        Array(displayedTabs.prefix(max(1, limit)))
    }

    func orderedSplitTabs() -> [TerminalWorkspaceTab] {
        guard let secondaryTab else { return [selectedTab] }
        let visibleIDs = Set([selectedTab.id, secondaryTab.id])
        return tabs.filter { visibleIDs.contains($0.id) }
    }

    func moveTab(_ draggedID: UUID, to targetID: UUID) {
        guard draggedID != targetID,
              let sourceIndex = tabs.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetID })
        else { return }
        let draggedTab = tabs.remove(at: sourceIndex)
        let destinationIndex = min(targetIndex, tabs.endIndex)
        tabs.insert(draggedTab, at: destinationIndex)
        persist()
        objectWillChange.send()
    }

    @discardableResult
    func addTab(
        connection: TerminalTabConnection? = nil,
        title: String? = nil,
        select: Bool = true
    ) -> TerminalWorkspaceTab? {
        if isEmptyState {
            let resolvedConnection = connection ?? .savedProfile(profileID)
            tabs[0].connection = resolvedConnection
            tabs[0].title = Self.normalizedTitle(
                title ?? "Терминал 1",
                fallback: "Терминал 1"
            )
            selectedTabID = tabs[0].id
            persist()
            objectWillChange.send()
            return tabs[0]
        }
        guard tabs.count < 8 else { return nil }
        let tab = TerminalWorkspaceTab(
            id: UUID(),
            title: Self.normalizedTitle(
                title ?? "Терминал \(tabs.count + 1)",
                fallback: "Терминал \(tabs.count + 1)"
            ),
            session: TerminalSessionModel(),
            isPrimary: false,
            connection: connection ?? .savedProfile(profileID),
            isPinned: false,
            colorIndex: tabs.count % 6
        )
        tabs.append(tab)
        observe(tab)
        if select { selectedTabID = tab.id }
        persist()
        objectWillChange.send()
        return tab
    }

    @discardableResult
    func duplicateTab(_ id: UUID) -> TerminalWorkspaceTab? {
        guard let source = tabs.first(where: { $0.id == id }), tabs.count < 8 else { return nil }
        let baseTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let created = addTab(
            connection: source.connection,
            title: baseTitle.isEmpty ? "Копия терминала" : "\(baseTitle) · копия"
        ) else { return nil }
        if let index = tabs.firstIndex(where: { $0.id == created.id }) {
            tabs[index].colorIndex = source.colorIndex
            tabs[index].isPinned = false
            persist()
            objectWillChange.send()
        }
        return tabs.first(where: { $0.id == created.id })
    }

    func togglePinned(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isPinned.toggle()
        persist()
        objectWillChange.send()
    }

    func cycleColor(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].colorIndex = (tabs[index].colorIndex + 1) % 6
        persist()
        objectWillChange.send()
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), !tabs[index].isPinned else { return }
        if tabs.count == 1 {
            tabs[0].session.stop()
            remoteContexts[id] = nil
            tabs[0].title = "Новый терминал"
            tabs[0].connection = .custom(host: "", username: "")
            tabs[0].isPrimary = true
            layout = .single
            secondaryTabID = nil
            persist()
            objectWillChange.send()
            return
        }
        let wasPrimary = tabs[index].isPrimary
        tabs[index].session.stop()
        remoteContexts[id] = nil
        sessionObservers[id] = nil
        sessionPhaseObservers[id] = nil
        tabs.remove(at: index)
        if wasPrimary {
            tabs[0].isPrimary = true
        }
        if selectedTabID == id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
        if secondaryTabID == id { secondaryTabID = nil }
        normalizeSelectionAndPersist()
        objectWillChange.send()
    }

    func renameTab(_ id: UUID, to rawTitle: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].title = Self.normalizedTitle(
            rawTitle,
            fallback: "Терминал \(index + 1)"
        )
        persist()
        objectWillChange.send()
    }

    @discardableResult
    func updateConnection(
        tabID: UUID,
        connection: TerminalTabConnection,
        suggestedTitle: String
    ) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              !tabs[index].session.isRunning
        else { return false }
        tabs[index].connection = connection
        remoteContexts[tabID] = nil
        tabs[index].title = Self.normalizedTitle(
            suggestedTitle,
            fallback: "Терминал \(index + 1)"
        )
        persist()
        objectWillChange.send()
        return true
    }

    func remoteContext(for tabID: UUID) -> TerminalRemoteContextSnapshot? {
        remoteContexts[tabID]
    }

    func setRemoteContext(
        _ context: TerminalRemoteContextSnapshot?,
        for tabID: UUID
    ) {
        if let context {
            remoteContexts[tabID] = context
        } else {
            remoteContexts.removeValue(forKey: tabID)
        }
    }

    func invalidateRemoteContext(for tabID: UUID) {
        remoteContexts.removeValue(forKey: tabID)
    }

    func setLayout(_ newLayout: TerminalWorkspaceLayout) {
        guard !isEmptyState else {
            layout = .single
            return
        }
        if newLayout != .single, tabs.count == 1 {
            _ = addTab(select: false)
        }
        layout = newLayout
        if newLayout != .single {
            secondaryTabID = tabs.first(where: { $0.id != selectedTabID })?.id
        }
    }

    func selectSecondary(_ id: UUID?) {
        guard let id,
              id != selectedTabID,
              tabs.contains(where: { $0.id == id })
        else {
            secondaryTabID = nil
            return
        }
        secondaryTabID = id
    }

    func stopAll() {
        tabs.forEach { $0.session.stop() }
    }

    func sendInput(
        _ data: Data,
        from sourceTabID: UUID,
        broadcast: Bool
    ) {
        guard let source = tabs.first(where: { $0.id == sourceTabID }) else { return }
        source.session.sendInput(data)
        guard broadcast else { return }
        for tab in tabs where tab.id != sourceTabID && tab.session.isRunning {
            tab.session.sendInput(data)
        }
    }

    private func observeSessions() {
        for tab in tabs {
            observe(tab)
        }
    }

    private func observe(_ tab: TerminalWorkspaceTab) {
        sessionObservers[tab.id] = tab.session.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
        sessionPhaseObservers[tab.id] = tab.session.$phase.sink { [weak self] phase in
            guard !phase.isRunning else { return }
            Task { @MainActor [weak self] in
                self?.invalidateRemoteContext(for: tab.id)
            }
        }
    }

    private func normalizeSelectionAndPersist() {
        guard !isRestoring, !tabs.isEmpty else { return }
        if !tabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = tabs[0].id
            return
        }
        if layout == .single {
            if secondaryTabID != nil { secondaryTabID = nil }
        } else {
            let secondaryExists = secondaryTabID.map { secondaryID in
                tabs.contains(where: { $0.id == secondaryID })
            } ?? false
            if secondaryTabID == selectedTabID || !secondaryExists {
                let replacement = tabs.first(where: { $0.id != selectedTabID })?.id
                if secondaryTabID != replacement { secondaryTabID = replacement }
            }
        }
        persist()
    }

    private func persist() {
        guard !isRestoring else { return }
        let value = StoredTerminalWorkspace(
            tabs: tabs.map {
                StoredTerminalWorkspace.Tab(
                    id: $0.id,
                    title: $0.title,
                    isPrimary: $0.isPrimary,
                    connection: $0.connection,
                    isPinned: $0.isPinned,
                    colorIndex: $0.colorIndex
                )
            },
            selectedTabID: selectedTabID,
            secondaryTabID: secondaryTabID,
            layout: layout
        )
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func normalizedTitle(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(40))
    }
}
