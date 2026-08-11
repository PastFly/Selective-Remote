import Combine
import Foundation

enum TerminalWorkspaceLayout: String, Codable, CaseIterable, Identifiable {
    case single
    case splitHorizontal
    case splitVertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: "Одна панель"
        case .splitHorizontal: "Разделить слева направо"
        case .splitVertical: "Разделить сверху вниз"
        }
    }
}

struct TerminalWorkspaceTab: Identifiable {
    let id: UUID
    var title: String
    let session: TerminalSessionModel
    let isPrimary: Bool
}

private struct StoredTerminalWorkspace: Codable {
    struct Tab: Codable {
        let id: UUID
        var title: String
        let isPrimary: Bool
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

    let profileID: UUID

    private let defaults: UserDefaults
    private var sessionObservers: [UUID: AnyCancellable] = [:]
    private var isRestoring = true
    private var storageKey: String {
        "SelectiveRemote.terminal.workspace.v1.\(profileID.uuidString)"
    }

    init(
        profileID: UUID,
        primarySession: TerminalSessionModel,
        defaults: UserDefaults = .standard
    ) {
        self.profileID = profileID
        self.defaults = defaults

        let initialStorageKey = "SelectiveRemote.terminal.workspace.v1.\(profileID.uuidString)"
        let stored = defaults.data(forKey: initialStorageKey)
            .flatMap { try? JSONDecoder().decode(StoredTerminalWorkspace.self, from: $0) }
        let primaryMetadata = stored?.tabs.first(where: \.isPrimary)
            ?? StoredTerminalWorkspace.Tab(id: UUID(), title: "Терминал 1", isPrimary: true)
        var restoredTabs = [
            TerminalWorkspaceTab(
                id: primaryMetadata.id,
                title: Self.normalizedTitle(primaryMetadata.title, fallback: "Терминал 1"),
                session: primarySession,
                isPrimary: true
            )
        ]
        let additionalMetadata = Array(
            (stored?.tabs.filter { !$0.isPrimary } ?? []).prefix(7)
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
                    isPrimary: false
                )
            )
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

    @discardableResult
    func addTab(select: Bool = true) -> TerminalWorkspaceTab? {
        guard tabs.count < 8 else { return nil }
        let tab = TerminalWorkspaceTab(
            id: UUID(),
            title: "Терминал \(tabs.count + 1)",
            session: TerminalSessionModel(),
            isPrimary: false
        )
        tabs.append(tab)
        observe(tab)
        if select { selectedTabID = tab.id }
        persist()
        objectWillChange.send()
        return tab
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              !tabs[index].isPrimary
        else { return }
        tabs[index].session.stop()
        sessionObservers[id] = nil
        tabs.remove(at: index)
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

    func setLayout(_ newLayout: TerminalWorkspaceLayout) {
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

    private func observeSessions() {
        tabs.forEach(observe)
    }

    private func observe(_ tab: TerminalWorkspaceTab) {
        sessionObservers[tab.id] = tab.session.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
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
                    isPrimary: $0.isPrimary
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
