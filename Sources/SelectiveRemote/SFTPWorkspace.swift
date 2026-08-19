import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum SFTPWorkspacePaneKind: String, Equatable, Sendable {
    case empty
    case local
    case remote
}

struct SFTPWorkspaceOpenRequest: Identifiable, Equatable {
    let id = UUID()
    let connection: TerminalTabConnection
    let path: String?
}

@MainActor
final class SFTPWorkspacePane: ObservableObject, Identifiable {
    let id: UUID
    let session: SFTPBrowserSession

    @Published var kind: SFTPWorkspacePaneKind
    @Published var connection: TerminalTabConnection?
    @Published var title: String

    private var observers: Set<AnyCancellable> = []

    init(
        id: UUID = UUID(),
        kind: SFTPWorkspacePaneKind = .empty
    ) {
        self.id = id
        self.kind = kind
        connection = nil
        title = kind == .local ? "Этот Mac" : "Подключить"
        session = SFTPBrowserSession()
        observeChildren()
    }

    var settings: SSHConnectionSettings? { session.settings }
    var isReady: Bool {
        switch kind {
        case .empty:
            false
        case .local:
            true
        case .remote:
            session.settings != nil && session.connectionState == .connected
        }
    }

    var systemImage: String {
        switch kind {
        case .empty: "plus.rectangle.on.folder"
        case .local: "laptopcomputer"
        case .remote: "server.rack"
        }
    }

    func setLocal() {
        session.disconnect()
        kind = .local
        connection = nil
        title = "Этот Mac"
    }

    func clear() {
        session.disconnect()
        kind = .empty
        connection = nil
        title = "Подключить"
    }

    func beginRemote(connection: TerminalTabConnection, title: String) {
        session.disconnect()
        self.connection = connection
        self.title = title
        kind = .remote
        session.prepare(for: id)
    }

    private func observeChildren() {
        session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observers)
        session.local.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observers)
        session.remote.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observers)
        session.transfers.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observers)
    }
}

@MainActor
final class SFTPWorkspaceTab: ObservableObject, Identifiable {
    let id: UUID
    let left: SFTPWorkspacePane
    let right: SFTPWorkspacePane

    private var observers: Set<AnyCancellable> = []

    init(
        id: UUID = UUID(),
        leftKind: SFTPWorkspacePaneKind = .local,
        rightKind: SFTPWorkspacePaneKind = .empty
    ) {
        self.id = id
        left = SFTPWorkspacePane(kind: leftKind)
        right = SFTPWorkspacePane(kind: rightKind)

        left.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observers)
        right.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observers)
    }

    var title: String {
        "\(left.title) ↔ \(right.title)"
    }

    var remoteConnectionCount: Int {
        [left, right].filter { $0.kind == .remote && $0.settings != nil }.count
    }
}

@MainActor
final class SFTPWorkspaceModel: ObservableObject {
    @Published private(set) var tabs: [SFTPWorkspaceTab]
    @Published var selectedTabID: UUID
    @Published private(set) var pendingOpenRequest: SFTPWorkspaceOpenRequest?

    private var observers: [UUID: AnyCancellable] = [:]
    private let maximumTabs = 8

    init() {
        let first = SFTPWorkspaceTab()
        tabs = [first]
        selectedTabID = first.id
        observe(first)
    }

    var selectedTab: SFTPWorkspaceTab {
        tabs.first(where: { $0.id == selectedTabID }) ?? tabs[0]
    }

    var activeRemoteCount: Int {
    tabs.reduce(0) { $0 + $1.remoteConnectionCount }
}

    var transferQueues: [SFTPTransferQueue] {
    tabs.flatMap { [$0.left.session.transfers, $0.right.session.transfers] }
}

    var activeTransferCount: Int {
    transferQueues.reduce(0) { $0 + $1.activeCount }
}

    var hasTransferItems: Bool {
    transferQueues.contains { !$0.items.isEmpty }
}

    var hasPausedTransfers: Bool {
    transferQueues.contains { queue in
        queue.items.contains { $0.phase == .paused }
    }
}

    func pauseAllTransfers() {
    transferQueues.forEach { $0.pauseAll() }
}

    func resumeAllTransfers() {
    transferQueues.forEach { $0.resumeAll() }
}

    func cancelAllTransfers() {
    transferQueues.forEach { $0.cancelAll() }
}

    @discardableResult
    func addTab(select: Bool = true) -> SFTPWorkspaceTab? {
        guard tabs.count < maximumTabs else { return nil }
        let tab = SFTPWorkspaceTab()
        tabs.append(tab)
        observe(tab)
        if select {
            selectedTabID = tab.id
        }
        return tab
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].left.clear()
        tabs[index].right.clear()
        observers[id] = nil

        if tabs.count == 1 {
            tabs[0].left.setLocal()
            tabs[0].right.clear()
            selectedTabID = tabs[0].id
            objectWillChange.send()
            return
        }

        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func requestOpen(connection: TerminalTabConnection, path: String? = nil) {
        pendingOpenRequest = SFTPWorkspaceOpenRequest(
            connection: connection,
            path: path
        )
    }

    func consumeOpenRequest(_ id: UUID) {
        guard pendingOpenRequest?.id == id else { return }
        pendingOpenRequest = nil
    }

    func pane(id: UUID) -> SFTPWorkspacePane? {
        for tab in tabs {
            if tab.left.id == id { return tab.left }
            if tab.right.id == id { return tab.right }
        }
        return nil
    }

    func tab(containing paneID: UUID) -> SFTPWorkspaceTab? {
        tabs.first { $0.left.id == paneID || $0.right.id == paneID }
    }

    func preferredPane(for connection: TerminalTabConnection) -> SFTPWorkspacePane? {
        for tab in tabs {
            for pane in [tab.left, tab.right]
            where pane.kind == .remote && pane.connection == connection {
                selectedTabID = tab.id
                return pane
            }
        }

        let selected = selectedTab
        if selected.right.kind == .empty {
            return selected.right
        }
        if selected.left.kind == .empty {
            return selected.left
        }

        guard let tab = addTab() else { return nil }
        return tab.right
    }

    private func observe(_ tab: SFTPWorkspaceTab) {
        observers[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

private struct SFTPWorkspaceConnectionRequest: Identifiable {
    let id = UUID()
    let paneID: UUID
    let initialConnection: TerminalTabConnection
    let path: String?
}

struct SFTPWorkspaceView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var workspace: SFTPWorkspaceModel

    @State private var connectionRequest: SFTPWorkspaceConnectionRequest?
    @State private var transferError: String?
    @State private var showsTransfers = true

    private var sshProfiles: [ConnectionProfile] {
        appModel.profiles
            .filter { $0.connectionType == .ssh }
            .sorted {
                $0.friendlyName.localizedStandardCompare($1.friendlyName)
                    == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 10) {
            workspaceToolbar
            workspaceTabBar

            let tab = workspace.selectedTab
            HSplitView {
                SFTPWorkspacePaneView(
                    pane: tab.left,
                    opposite: tab.right,
                    profiles: sshProfiles,
                    selectLocal: { tab.left.setLocal() },
                    selectSavedProfile: { profileID in
                        connect(
                            pane: tab.left,
                            connection: .savedProfile(profileID),
                            path: nil
                        )
                    },
                    selectCustom: {
                        connectionRequest = SFTPWorkspaceConnectionRequest(
                            paneID: tab.left.id,
                            initialConnection: tab.left.connection
                                ?? sshProfiles.first.map { .savedProfile($0.id) }
                                ?? .custom(host: "", username: ""),
                            path: nil
                        )
                    },
                    disconnect: { tab.left.clear() },
                    copyToOpposite: { copy(from: tab.left, to: tab.right) }
                )
                .frame(minWidth: 390)

                SFTPWorkspacePaneView(
                    pane: tab.right,
                    opposite: tab.left,
                    profiles: sshProfiles,
                    selectLocal: { tab.right.setLocal() },
                    selectSavedProfile: { profileID in
                        connect(
                            pane: tab.right,
                            connection: .savedProfile(profileID),
                            path: nil
                        )
                    },
                    selectCustom: {
                        connectionRequest = SFTPWorkspaceConnectionRequest(
                            paneID: tab.right.id,
                            initialConnection: tab.right.connection
                                ?? sshProfiles.first.map { .savedProfile($0.id) }
                                ?? .custom(host: "", username: ""),
                            path: nil
                        )
                    },
                    disconnect: { tab.right.clear() },
                    copyToOpposite: { copy(from: tab.right, to: tab.left) }
                )
                .frame(minWidth: 390)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            transferSummary(tab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $connectionRequest) { request in
            TerminalConnectionEditor(
                profiles: sshProfiles,
                initialConnection: request.initialConnection,
                allowsInteractivePassword: true,
                actionTitle: "Подключить SFTP",
                heading: "Подключение SFTP",
                message: "Выберите сохранённый сервер или укажите временный SFTP-адрес для этой панели.",
                customAuthenticationMessage: "Пароль временного сервера используется только для этой панели и удаляется после подключения.",
                onSave: { connection, _, temporaryPassword in
                    guard let pane = workspace.pane(id: request.paneID) else { return }
                    connect(
                        pane: pane,
                        connection: connection,
                        temporaryPassword: temporaryPassword,
                        path: request.path
                    )
                }
            )
        }
        .alert(
            "SFTP",
            isPresented: Binding(
                get: { transferError != nil },
                set: { if !$0 { transferError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { transferError = nil }
        } message: {
            Text(transferError ?? "")
        }
        .task(id: workspace.pendingOpenRequest?.id) {
            guard let request = workspace.pendingOpenRequest else { return }
            defer { workspace.consumeOpenRequest(request.id) }
            guard let pane = workspace.preferredPane(for: request.connection) else {
                transferError = "Достигнут лимит SFTP-вкладок"
                return
            }
            if pane.kind == .remote,
               pane.connection == request.connection,
               pane.settings != nil {
                if let path = request.path {
                    navigateRemote(pane, to: path)
                }
            } else {
                connect(
                    pane: pane,
                    connection: request.connection,
                    path: request.path
                )
            }
        }
    }

    private var workspaceToolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SFTP Workspace")
                    .font(.headline)
                Text("Каждая панель может быть этим Mac или отдельным SSH/SFTP-сервером")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if workspace.activeRemoteCount > 0 {
                Label(
                    "Серверов: \(workspace.activeRemoteCount)",
                    systemImage: "server.rack"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            }
            Button("Новая вкладка", systemImage: "plus") {
                if workspace.addTab() == nil {
                    transferError = "Достигнут лимит SFTP-вкладок"
                }
            }
            .disabled(workspace.tabs.count >= 8)
        }
    }

    private var workspaceTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(workspace.tabs) { tab in
                    let selected = tab.id == workspace.selectedTabID
                    HStack(spacing: 5) {
                        Button {
                            workspace.selectedTabID = tab.id
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(
                                        tab.remoteConnectionCount > 0
                                            ? Color.green
                                            : Color.secondary.opacity(0.45)
                                    )
                                    .frame(width: 7, height: 7)
                                Text(tab.title)
                                    .lineLimit(1)
                                    .fontWeight(selected ? .semibold : .regular)
                            }
                        }
                        .buttonStyle(.plain)

                        if workspace.tabs.count > 1 {
                            Button {
                                workspace.closeTab(tab.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .help("Закрыть SFTP-вкладку")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        selected
                            ? Color.accentColor.opacity(0.18)
                            : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                selected
                                    ? Color.accentColor.opacity(0.75)
                                    : Color.primary.opacity(0.06)
                            )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transferSummary(_ tab: SFTPWorkspaceTab) -> some View {
        let panes = [tab.left, tab.right]
        let queuesWithItems = panes.filter { !$0.session.transfers.items.isEmpty }
        if !queuesWithItems.isEmpty {
            DisclosureGroup(isExpanded: $showsTransfers) {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(queuesWithItems) { pane in
                            let queue = pane.session.transfers
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 8) {
                                    Label(pane.title, systemImage: pane.systemImage)
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Picker("При совпадении имён", selection: Binding(
                                        get: { queue.conflictPolicy },
                                        set: { queue.conflictPolicy = $0 }
                                    )) {
                                        ForEach(SFTPConflictPolicy.allCases) { policy in
                                            Text(policy.title).tag(policy)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: 180)

                                    if queue.items.contains(where: { $0.phase == .paused }) {
                                        Button("Продолжить все", systemImage: "play.fill") {
                                            queue.resumeAll()
                                        }
                                        .labelStyle(.iconOnly)
                                    } else if queue.items.contains(where: { $0.phase == .running }) {
                                        Button("Пауза", systemImage: "pause.fill") {
                                            queue.pauseAll()
                                        }
                                        .labelStyle(.iconOnly)
                                    }
                                    Button("Отменить все", systemImage: "xmark") {
                                        queue.cancelAll()
                                    }
                                    .labelStyle(.iconOnly)
                                    .disabled(queue.activeCount == 0)
                                    Button("Очистить завершённые", systemImage: "trash") {
                                        queue.clearFinished()
                                    }
                                    .labelStyle(.iconOnly)
                                    .disabled(!queue.items.contains(where: { $0.phase.isTerminal }))
                                }

                                ForEach(queue.items.reversed()) { item in
                                    transferRow(item, queue: queue)
                                }
                            }
                            .padding(8)
                            .background(
                                Color.primary.opacity(0.025),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                        }
                    }
                    .padding(.top, 7)
                }
                .frame(maxHeight: 220)
            } label: {
                let active = panes.reduce(0) { $0 + $1.session.transfers.activeCount }
                Label(
                    "Передачи · активных: \(active)",
                    systemImage: "arrow.up.arrow.down.circle"
                )
                .font(.headline)
            }
        }
    }

    private func transferRow(
        _ item: SFTPTransferItem,
        queue: SFTPTransferQueue
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.direction.systemImage)
                .foregroundStyle(item.phase == .failed ? Color.red : Color.blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(item.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text("· \(item.direction.title)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(item.phase.title)
                        .font(.caption)
                        .foregroundStyle(item.phase == .failed ? Color.red : Color.secondary)
                }

                HStack(spacing: 5) {
                    Text(item.source).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "arrow.right")
                    Text(item.destination).lineLimit(1).truncationMode(.middle)
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .help("\(item.source) → \(item.destination)")

                if let fraction = item.fractionCompleted {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else if item.phase == .running {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                HStack(spacing: 5) {
                    Text(item.progressText)
                    if let fraction = item.fractionCompleted {
                        Text("· \(Int((fraction * 100).rounded()))%")
                    }
                    if let speed = item.speedText {
                        Text("· \(speed)")
                    }
                    if let eta = item.etaText {
                        Text("· ETA \(eta)")
                    }
                    if let error = item.errorMessage {
                        Text("· \(error)")
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            switch item.phase {
            case .running:
                Button("Пауза", systemImage: "pause.fill") { queue.pause(item.id) }
                    .labelStyle(.iconOnly)
            case .paused:
                Button("Продолжить", systemImage: "play.fill") { queue.resume(item.id) }
                    .labelStyle(.iconOnly)
            case .failed, .cancelled:
                Button("Повторить", systemImage: "arrow.clockwise") { queue.retry(item.id) }
                    .labelStyle(.iconOnly)
            default:
                EmptyView()
            }
            if !item.phase.isTerminal {
                Button("Отменить", systemImage: "xmark") { queue.cancel(item.id) }
                    .labelStyle(.iconOnly)
            }
        }
    }

    private func connect(
        pane: SFTPWorkspacePane,
        connection: TerminalTabConnection,
        temporaryPassword: String? = nil,
        path: String?
    ) {
        let clientID = pane.id
        let hasTemporaryPassword = connection.kind == .custom
            && temporaryPassword?.isEmpty == false

        if hasTemporaryPassword, let temporaryPassword {
            do {
                try KeychainService.savePassword(
                    temporaryPassword,
                    profileID: clientID,
                    kind: .ssh
                )
            } catch {
                transferError = error.localizedDescription
                return
            }
        }

        guard let settings = appModel.prepareSSHConnection(
            connection: connection,
            clientID: clientID
        ) else {
            if hasTemporaryPassword {
                try? KeychainService.deletePassword(profileID: clientID, kind: .ssh)
            }
            return
        }

        pane.beginRemote(
            connection: connection,
            title: displayTitle(for: connection)
        )
        pane.session.connect(settings) { success in
            if hasTemporaryPassword {
                try? KeychainService.deletePassword(profileID: clientID, kind: .ssh)
            }
            if success, let path {
                navigateRemote(pane, to: path)
            }
        }
    }

    private func displayTitle(for connection: TerminalTabConnection) -> String {
        if connection.kind == .savedProfile,
           let profileID = connection.profileID,
           let profile = sshProfiles.first(where: { $0.id == profileID }) {
            return profile.friendlyName.isEmpty ? profile.host : profile.friendlyName
        }
        return connection.displayLabel(profiles: sshProfiles)
    }

    private func navigateRemote(_ pane: SFTPWorkspacePane, to rawPath: String) {
        guard let settings = pane.settings else { return }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        pane.session.remote.load(
            settings: settings,
            directory: path
        ) { success in
            guard !success else { return }
            let parent = SFTPService.parentRemotePath(path)
            guard parent != path else { return }
            let name = path
                .split(separator: "/", omittingEmptySubsequences: true)
                .last
                .map(String.init)
            pane.session.remote.load(
                settings: settings,
                directory: parent
            ) { parentSuccess in
                guard parentSuccess, let name else { return }
                if pane.session.remote.entries.contains(where: { $0.name == name }) {
                    pane.session.remote.selectedEntryIDs = [name]
                }
            }
        }
    }

    private func copy(from source: SFTPWorkspacePane, to target: SFTPWorkspacePane) {
        guard target.isReady else {
            transferError = "Сначала выберите Local или подключите сервер в целевой панели."
            return
        }

        switch (source.kind, target.kind) {
        case (.local, .local):
            let entries = source.session.local.selectedEntries
            guard !entries.isEmpty else { return }
            target.session.local.copyItems(
                entries.map(\.url),
                to: target.session.local.currentDirectory
            )

        case (.local, .remote):
            guard let settings = target.settings else { return }
            let entries = source.session.local.selectedEntries
            guard !entries.isEmpty else { return }
            target.session.remote.upload(
                localURLs: entries.map(\.url),
                settings: settings,
                sizeHints: Dictionary(
                    uniqueKeysWithValues: entries.compactMap { entry in
                        entry.size.map { (entry.url.path, $0) }
                    }
                )
            )

        case (.remote, .local):
            guard let settings = source.settings else { return }
            let entries = source.session.remote.selectedEntries
            guard !entries.isEmpty else { return }
            for entry in entries {
                source.session.remote.download(
                    entry,
                    to: target.session.local.currentDirectory,
                    settings: settings
                )
            }

        case (.remote, .remote):
            guard let sourceSettings = source.settings,
                  let destinationSettings = target.settings
            else { return }
            let entries = source.session.remote.selectedEntries
            guard !entries.isEmpty else { return }
            target.session.remote.copyRemote(
                entries,
                from: source.session.remote.currentPath,
                sourceSettings: sourceSettings,
                destinationSettings: destinationSettings
            )

        case (.empty, _):
            transferError = "Сначала выберите источник в этой панели."

        case (_, .empty):
            transferError = "Сначала выберите целевую панель."
        }
    }
}

private struct SFTPWorkspacePaneView: View {
    @ObservedObject var pane: SFTPWorkspacePane
    @ObservedObject var opposite: SFTPWorkspacePane

    let profiles: [ConnectionProfile]
    let selectLocal: () -> Void
    let selectSavedProfile: (UUID) -> Void
    let selectCustom: () -> Void
    let disconnect: () -> Void
    let copyToOpposite: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            Divider()

            switch pane.kind {
            case .empty:
                emptyPane
            case .local:
                SFTPWorkspaceLocalPaneView(
                    model: pane.session.local,
                    remoteSource: opposite.kind == .remote ? opposite.session : nil,
                    remoteSourcePaneID: opposite.kind == .remote ? opposite.id : nil,
                    copyToOpposite: copyToOpposite,
                    targetReady: opposite.isReady
                )
            case .remote:
                SFTPWorkspaceRemotePaneView(
                    session: pane.session,
                    paneID: pane.id,
                    remoteSource: opposite.kind == .remote ? opposite.session : nil,
                    remoteSourcePaneID: opposite.kind == .remote ? opposite.id : nil,
                    copyToOpposite: copyToOpposite,
                    targetReady: opposite.isReady
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.018))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Этот Mac", systemImage: "laptopcomputer") {
                    selectLocal()
                }
                Divider()
                if profiles.isEmpty {
                    Text("Нет сохранённых SSH-профилей")
                } else {
                    ForEach(profiles) { profile in
                        Button {
                            selectSavedProfile(profile.id)
                        } label: {
                            Label(
                                profile.friendlyName.isEmpty
                                    ? profile.host
                                    : profile.friendlyName,
                                systemImage: "server.rack"
                            )
                        }
                    }
                }
                Divider()
                Button("Другой сервер…", systemImage: "plus.circle") {
                    selectCustom()
                }
                if pane.kind != .empty {
                    Divider()
                    Button("Отключить панель", systemImage: "xmark.circle") {
                        disconnect()
                    }
                }
            } label: {
                Label(pane.title, systemImage: pane.systemImage)
                    .font(.headline)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)

            Spacer()

            if pane.kind == .remote {
                switch pane.session.connectionState {
                case .connected:
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                case .connecting:
                    ProgressView().controlSize(.small)
                case .error:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .disconnected:
                    Circle()
                        .stroke(Color.secondary, lineWidth: 1)
                        .frame(width: 8, height: 8)
                }
            }

            Button {
                copyToOpposite()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .disabled(!pane.isReady || !opposite.isReady)
            .help("Скопировать выбранное в соседнюю панель")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var emptyPane: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Выберите источник")
                .font(.title3.weight(.semibold))
            Text("Эта панель может показывать файлы этого Mac или отдельного SFTP-сервера.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack {
                Button("Этот Mac", systemImage: "laptopcomputer") {
                    selectLocal()
                }
                Button("Подключить сервер", systemImage: "server.rack") {
                    selectCustom()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct SFTPWorkspaceLocalPaneView: View {
    @ObservedObject var model: SFTPLocalBrowserModel
    let remoteSource: SFTPBrowserSession?
    let remoteSourcePaneID: UUID?
    let copyToOpposite: () -> Void
    let targetReady: Bool

    @State private var pathInput = ""
    @State private var newFolderName = ""
    @State private var newFileName = ""
    @State private var showsNewFolder = false
    @State private var showsNewFile = false
    @State private var deleteEntries: [SFTPLocalEntry] = []
    @State private var renameEntry: SFTPLocalEntry?
    @State private var renameText = ""
    @State private var showsRenamePrompt = false
    @State private var propertiesTarget: SFTPPropertiesTarget?
    @State private var selectionAnchor: String?
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Spacer()
                sftpWorkspaceSortingMenu(
                    field: $model.sortField,
                    direction: $model.sortDirection
                )
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            navigationBar

            sftpWorkspaceBreadcrumbBar(model.breadcrumbs) { crumb in
                model.navigate(to: URL(fileURLWithPath: crumb.path, isDirectory: true))
            }
            .padding(.horizontal, 10)

            sftpWorkspacePathField(
                title: "Локальный путь",
                text: $pathInput,
                disabled: model.isBusy,
                suggestions: pathSuggestions
            ) {
                navigatePath()
            }
            .padding(.horizontal, 10)

            sftpWorkspaceFilterField(
                text: $model.filterText,
                placeholder: "Фильтр локальных файлов"
            )
            .padding(.horizontal, 10)

            sftpWorkspaceFileHeader(
                sortField: model.sortField,
                sortDirection: model.sortDirection
            ) { field in
                model.selectSort(field)
            }
            .padding(.horizontal, 10)

            List {
                ForEach(model.entries) { entry in
                    sftpWorkspaceFileRow(
                        name: entry.name,
                        isDirectory: entry.isDirectory,
                        isSymbolicLink: entry.isSymbolicLink,
                        ownerText: entry.ownerText,
                        permissions: entry.permissions,
                        modifiedText: entry.modifiedText,
                        sizeText: entry.sizeText
                    )
                    .tag(entry.id)
                    .contentShape(Rectangle())
                    .listRowBackground(
                        model.selectedEntryIDs.contains(entry.id)
                            ? Color.accentColor.opacity(0.24)
                            : Color.clear
                    )
                    .onTapGesture(count: 1) {
                        selectRow(entry.id)
                    }
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            model.open(entry)
                        }
                    )
                    .contextMenu {
                        localContextMenu(for: entry)
                    }
                    .onDrag {
                        NSItemProvider(object: entry.url as NSURL)
                    }

                }
            }
            .listStyle(.inset)
            .contextMenu {
                Button("Новый файл…", systemImage: "doc.badge.plus") {
                    newFileName = ""
                    showsNewFile = true
                }
                Button("Новая папка…", systemImage: "folder.badge.plus") {
                    newFolderName = ""
                    showsNewFolder = true
                }
                Divider()
                Button("Обновить", systemImage: "arrow.clockwise") {
                    model.reload()
                }
            }
            .overlay {
                if model.isBusy {
                    sftpWorkspaceBusyOverlay
                } else if model.entries.isEmpty {
                    ContentUnavailableView(
                        model.filterText.isEmpty ? "Локальная папка пуста" : "Ничего не найдено",
                        systemImage: model.filterText.isEmpty ? "folder" : "magnifyingglass",
                        description: model.filterText.isEmpty
                            ? nil
                            : Text("Измените или очистите фильтр")
                    )
                    .allowsHitTesting(false)
                }
            }
            .onDrop(
      of: sftpWorkspaceDropTypeIdentifiers,
      isTargeted: $dropTargeted
  ) { providers in
      acceptDrops(providers, destination: model.currentDirectory)
  }

            .overlay {
                sftpWorkspaceDropOverlay(
                    isTargeted: dropTargeted,
                    text: "Скопировать на этот Mac"
                )
            }

            sftpWorkspaceStatus(model.statusMessage, error: model.errorMessage)
        }
        .onAppear { pathInput = model.currentDirectory.path }
        .onChange(of: model.currentDirectory) { _, value in
            pathInput = value.path
        }
        .alert("Новая локальная папка", isPresented: $showsNewFolder) {
            TextField("Название", text: $newFolderName)
            Button("Создать") {
                model.createDirectory(named: newFolderName)
                newFolderName = ""
            }
            Button("Отмена", role: .cancel) { }
        }
        .alert("Новый локальный файл", isPresented: $showsNewFile) {
            TextField("Название файла", text: $newFileName)
            Button("Создать") {
                model.createFile(named: newFileName)
                newFileName = ""
            }
            Button("Отмена", role: .cancel) { }
        }
        .alert("Переименовать", isPresented: $showsRenamePrompt) {
            TextField("Новое имя", text: $renameText)
            Button("Переименовать") {
                if let renameEntry {
                    model.rename(renameEntry, to: renameText)
                }
                renameEntry = nil
            }
            Button("Отмена", role: .cancel) {
                renameEntry = nil
            }
        } message: {
            Text("Введите новое имя без символа /")
        }
        .alert(
            "Удалить выбранные объекты?",
            isPresented: Binding(
                get: { !deleteEntries.isEmpty },
                set: { if !$0 { deleteEntries = [] } }
            )
        ) {
            Button("В Корзину", role: .destructive) {
                model.moveToTrash(deleteEntries)
                deleteEntries = []
            }
            Button("Отмена", role: .cancel) { deleteEntries = [] }
        } message: {
            Text("Объектов: \(deleteEntries.count). Они будут перемещены в Корзину.")
        }
        .sheet(item: $propertiesTarget) { target in
            SFTPPropertiesView(target: target) { mode, ownerID, groupID in
                guard case let .local(entry) = target else { return }
                model.updateAttributes(
                    entry,
                    mode: mode,
                    ownerID: ownerID,
                    groupID: groupID
                )
            }
        }
    }

    private var navigationBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sftpWorkspaceNavigationButton(
                    systemImage: "chevron.left",
                    help: "Назад",
                    disabled: !model.canGoBack || model.isBusy
                ) { model.goBack() }
                sftpWorkspaceNavigationButton(
                    systemImage: "chevron.right",
                    help: "Вперёд",
                    disabled: !model.canGoForward || model.isBusy
                ) { model.goForward() }
                sftpWorkspaceNavigationButton(
                    systemImage: "house",
                    help: "Домашняя папка",
                    disabled: model.isBusy
                ) { model.goHome() }
                sftpWorkspaceNavigationButton(
                    systemImage: "folder",
                    help: "Выбрать локальную папку",
                    disabled: model.isBusy
                ) { chooseLocalDirectory() }
                sftpWorkspaceNavigationButton(
                    systemImage: "arrow.up",
                    help: "На уровень выше",
                    disabled: model.isBusy
                ) { model.goUp() }
                sftpWorkspaceNavigationButton(
                    systemImage: "arrow.clockwise",
                    help: "Обновить",
                    disabled: model.isBusy
                ) { model.reload() }
                sftpWorkspaceNavigationButton(
                    systemImage: "doc.badge.plus",
                    help: "Новый локальный файл",
                    disabled: model.isBusy
                ) {
                    newFileName = ""
                    showsNewFile = true
                }
                sftpWorkspaceNavigationButton(
                    systemImage: "folder.badge.plus",
                    help: "Новая локальная папка",
                    disabled: model.isBusy
                ) {
                    newFolderName = ""
                    showsNewFolder = true
                }
            }
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func localContextMenu(for entry: SFTPLocalEntry) -> some View {
        if entry.isDirectory {
            Button("Открыть", systemImage: "folder") {
                model.navigate(to: entry.url)
            }
        } else {
            Button("Открыть", systemImage: "arrow.up.forward.app") {
                model.open(entry)
            }
            Button("Открыть с помощью…", systemImage: "square.grid.2x2") {
                sftpWorkspaceChooseApplication { applicationURL in
                    model.openWith(entry, applicationURL: applicationURL)
                }
            }
        }

        Button("Показать в Finder", systemImage: "finder") {
            model.reveal(entry)
        }
        Button("Скопировать путь", systemImage: "doc.on.doc") {
            sftpWorkspaceCopyPath(entry.url.path)
        }
        Button(
            "Скопировать в соседнюю панель",
            systemImage: "arrow.left.arrow.right"
        ) {
            if !model.selectedEntryIDs.contains(entry.id) {
                model.selectedEntryIDs = [entry.id]
                selectionAnchor = entry.id
            }
            copyToOpposite()
        }
        .disabled(!targetReady)

        Divider()

        Button("Переименовать…", systemImage: "pencil") {
            let entries = actionEntries(for: entry)
            guard entries.count == 1 else { return }
            renameEntry = entries[0]
            renameText = entries[0].name
            showsRenamePrompt = true
        }
        .disabled(actionEntries(for: entry).count != 1)

        Button("Свойства…", systemImage: "info.circle") {
            let entries = actionEntries(for: entry)
            guard entries.count == 1 else { return }
            propertiesTarget = .local(entries[0])
        }
        .disabled(actionEntries(for: entry).count != 1)

        Divider()

        Button("Переместить в Корзину", systemImage: "trash", role: .destructive) {
            deleteEntries = actionEntries(for: entry)
        }
    }

    private func actionEntries(for entry: SFTPLocalEntry) -> [SFTPLocalEntry] {
        model.selectedEntryIDs.contains(entry.id) && !model.selectedEntries.isEmpty
            ? model.selectedEntries
            : [entry]
    }

    private func selectRow(_ id: String) {
        let result = sftpWorkspaceRowSelection(
            id: id,
            orderedIDs: model.entries.map(\.id),
            selection: model.selectedEntryIDs,
            anchor: selectionAnchor
        )
        model.selectedEntryIDs = result.selection
        selectionAnchor = result.anchor
    }

    private var pathSuggestions: [String] {
        let typed = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = model.currentDirectory.standardizedFileURL.path
        var candidates = model.entries.filter(\.isDirectory).map { $0.url.path }
        candidates.append(model.currentDirectory.deletingLastPathComponent().path)
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.path)
        return sftpWorkspacePathSuggestions(
            candidates,
            matching: typed,
            current: directory
        )
    }

    private func navigatePath() {
        let path = NSString(
            string: pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        ).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            model.errorMessage = "Локальная папка не найдена: \(path)"
            return
        }
        model.navigate(to: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func chooseLocalDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Выберите локальную папку"
        panel.directoryURL = model.currentDirectory
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        model.navigate(to: directory)
    }

    private func acceptInternalRemoteDrag(
        _ items: [String],
        destination: URL
    ) -> Bool {
        guard let source = remoteSource,
              let sourcePaneID = remoteSourcePaneID,
              let settings = source.settings,
              !source.remote.isBusy,
              !model.isBusy,
              let token = items
                .compactMap(sftpWorkspaceParseInternalDragToken)
                .first(where: { $0.paneID == sourcePaneID })
        else { return false }

        let entries: [SFTPRemoteEntry]
        if source.remote.selectedEntryIDs.contains(token.entryID),
           !source.remote.selectedEntries.isEmpty {
            entries = source.remote.selectedEntries
        } else if let entry = source.remote.entries.first(where: { $0.id == token.entryID }) {
            entries = [entry]
        } else {
            return false
        }

        for entry in entries {
            source.remote.download(
                entry,
                to: destination,
                settings: settings
            )
        }
        return true
    }

    private func acceptDrops(
        _ providers: [NSItemProvider],
        destination: URL
    ) -> Bool {
        let remoteProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(SFTPDragType.remoteEntry.identifier)
        }
        if !remoteProviders.isEmpty,
           let source = remoteSource,
           let settings = source.settings,
           !source.remote.isBusy,
           !model.isBusy {
            for provider in remoteProviders {
                let handler = SFTPMainActorValueHandler<SFTPRemoteDragPayload> { payload in
                    source.remote.download(
                        payload: payload,
                        to: destination,
                        settings: settings
                    )
                }
                SFTPItemProviderBridge.loadRemotePayload(
                    from: provider,
                    handler: handler
                )
            }
            return true
        }

        let stringProviders = providers.filter {
  $0.hasItemConformingToTypeIdentifier(
      NSPasteboard.PasteboardType.string.rawValue
  )
        }
        if !stringProviders.isEmpty {
  for provider in stringProviders {
      let handler = SFTPMainActorValueHandler<String> { value in
          _ = acceptInternalRemoteDrag(
              [value],
              destination: destination
          )
      }
      SFTPItemProviderBridge.loadString(
          from: provider,
          handler: handler
      )
  }
  return true
        }

        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            let handler = SFTPMainActorValueHandler<URL> { url in
                model.copyItems([url], to: destination)
            }
            SFTPItemProviderBridge.loadFileURL(
                from: provider,
                handler: handler
            )
        }
        return true
    }
}

private struct SFTPWorkspaceRemotePaneView: View {
    @ObservedObject var session: SFTPBrowserSession
    let paneID: UUID
    let remoteSource: SFTPBrowserSession?
    let remoteSourcePaneID: UUID?
    let copyToOpposite: () -> Void
    let targetReady: Bool

    @State private var pathInput = "."
    @State private var newFolderName = ""
    @State private var newFileName = ""
    @State private var showsNewFolder = false
    @State private var showsNewFile = false
    @State private var deleteEntries: [SFTPRemoteEntry] = []
    @State private var renameEntry: SFTPRemoteEntry?
    @State private var renameText = ""
    @State private var showsRenamePrompt = false
    @State private var propertiesTarget: SFTPPropertiesTarget?
    @State private var selectionAnchor: String?
    @State private var dropTargeted = false

    private var remote: SFTPBrowserModel { session.remote }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let settings = session.settings {
                HStack {
                    Spacer()
                    sftpWorkspaceSortingMenu(
                        field: Binding(
                            get: { remote.sortField },
                            set: { remote.sortField = $0 }
                        ),
                        direction: Binding(
                            get: { remote.sortDirection },
                            set: { remote.sortDirection = $0 }
                        )
                    )
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)

                navigationBar(settings)

                sftpWorkspaceBreadcrumbBar(remote.breadcrumbs) { crumb in
                    remote.load(settings: settings, directory: crumb.path)
                }
                .padding(.horizontal, 10)

                sftpWorkspacePathField(
                    title: "Путь на сервере",
                    text: $pathInput,
                    disabled: remote.isBusy,
                    suggestions: pathSuggestions
                ) {
                    let path = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    remote.load(settings: settings, directory: path)
                }
                .padding(.horizontal, 10)

                sftpWorkspaceFilterField(
                    text: Binding(
                        get: { remote.filterText },
                        set: { remote.filterText = $0 }
                    ),
                    placeholder: "Фильтр удалённых файлов"
                )
                .padding(.horizontal, 10)

                sftpWorkspaceFileHeader(
                    sortField: remote.sortField,
                    sortDirection: remote.sortDirection
                ) { field in
                    remote.selectSort(field)
                }
                .padding(.horizontal, 10)

                List {
                    ForEach(remote.entries) { entry in
                        sftpWorkspaceFileRow(
                            name: entry.name,
                            isDirectory: entry.isDirectory,
                            isSymbolicLink: entry.isSymbolicLink,
                            ownerText: entry.ownerText,
                            permissions: entry.permissions,
                            modifiedText: entry.modifiedText,
                            sizeText: entry.sizeText
                        )
                        .tag(entry.id)
                        .contentShape(Rectangle())
                        .listRowBackground(
                            remote.selectedEntryIDs.contains(entry.id)
                                ? Color.accentColor.opacity(0.24)
                                : Color.clear
                        )
                        .onTapGesture(count: 1) {
                            selectRow(entry.id)
                        }
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                if entry.isDirectory {
                                    remote.open(entry, settings: settings)
                                } else {
                                    remote.edit(entry, settings: settings)
                                }
                            }
                        )
                        .contextMenu {
                            remoteContextMenu(for: entry, settings: settings)
                        }
                        .background {
                            SFTPWorkspaceAppKitDragMonitor(
                                token: sftpWorkspaceInternalDragToken(
                                    paneID: paneID,
                                    entryID: entry.id
                                ),
                                isDirectory: entry.isDirectory
                            )
                            .allowsHitTesting(false)
                        }

                    }
                }
                .listStyle(.inset)
                .contextMenu {
                    Button("Новый файл…", systemImage: "doc.badge.plus") {
                        newFileName = ""
                        showsNewFile = true
                    }
                    Button("Новая папка…", systemImage: "folder.badge.plus") {
                        newFolderName = ""
                        showsNewFolder = true
                    }
                    Divider()
                    Button("Обновить", systemImage: "arrow.clockwise") {
                        remote.load(
                            settings: settings,
                            directory: remote.currentPath,
                            recordHistory: false
                        )
                    }
                }
                .overlay {
                    if remote.isBusy {
                        sftpWorkspaceBusyOverlay
                    } else if remote.entries.isEmpty {
                        ContentUnavailableView(
                            remote.filterText.isEmpty ? "Удалённая папка пуста" : "Ничего не найдено",
                            systemImage: remote.filterText.isEmpty ? "folder" : "magnifyingglass",
                            description: remote.filterText.isEmpty
                                ? nil
                                : Text("Измените или очистите фильтр")
                        )
                        .allowsHitTesting(false)
                    }
                }
                .onDrop(
          of: sftpWorkspaceDropTypeIdentifiers,
          isTargeted: $dropTargeted
      ) { providers in
          acceptDrops(
              providers,
              to: remote.currentPath,
              destinationSettings: settings
          )
      }

                .overlay {
                    sftpWorkspaceDropOverlay(
                        isTargeted: dropTargeted,
                        text: "Скопировать на этот сервер"
                    )
                }

                sftpWorkspaceStatus(remote.statusMessage, error: remote.errorMessage)
            } else {
                VStack(spacing: 10) {
                    if session.connectionState == .connecting {
                        ProgressView()
                        Text("Подключение SFTP…")
                    } else {
                        Image(systemName: "server.rack")
                            .font(.system(size: 32))
                        Text("SFTP не подключён")
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { pathInput = remote.currentPath }
        .onChange(of: remote.currentPath) { _, value in
            pathInput = value
        }
        .task(id: session.settings?.profileID) {
            while !Task.isCancelled {
                let delayMilliseconds: Int64 = session.transfers.activeCount > 0 ? 1_500 : 5_000
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                guard !Task.isCancelled, let settings = session.settings else { continue }
                remote.refreshSilently(settings: settings)
            }
        }
        .alert("Новая папка на сервере", isPresented: $showsNewFolder) {
            TextField("Название", text: $newFolderName)
            Button("Создать") {
                guard let settings = session.settings else { return }
                remote.createDirectory(named: newFolderName, settings: settings)
                newFolderName = ""
            }
            Button("Отмена", role: .cancel) { }
        }
        .alert("Новый файл на сервере", isPresented: $showsNewFile) {
            TextField("Название файла", text: $newFileName)
            Button("Создать") {
                guard let settings = session.settings else { return }
                remote.createFile(named: newFileName, settings: settings)
                newFileName = ""
            }
            Button("Отмена", role: .cancel) { }
        }
        .alert("Переименовать", isPresented: $showsRenamePrompt) {
            TextField("Новое имя", text: $renameText)
            Button("Переименовать") {
                guard let settings = session.settings, let renameEntry else { return }
                remote.rename(renameEntry, to: renameText, settings: settings)
                self.renameEntry = nil
            }
            Button("Отмена", role: .cancel) {
                renameEntry = nil
            }
        } message: {
            Text("Введите новое имя без символа /")
        }
        .alert(
            "Удалить выбранные объекты?",
            isPresented: Binding(
                get: { !deleteEntries.isEmpty },
                set: { if !$0 { deleteEntries = [] } }
            )
        ) {
            Button("Удалить безвозвратно", role: .destructive) {
                guard let settings = session.settings else { return }
                remote.remove(deleteEntries, settings: settings)
                deleteEntries = []
            }
            Button("Отмена", role: .cancel) { deleteEntries = [] }
        } message: {
            Text("Объектов на сервере: \(deleteEntries.count). Отменить удаление будет нельзя.")
        }
        .sheet(item: $propertiesTarget) { target in
            SFTPPropertiesView(target: target) { mode, ownerID, groupID in
                guard case let .remote(entry, _) = target,
                      let settings = session.settings
                else { return }
                remote.updateAttributes(
                    entry,
                    mode: mode,
                    ownerID: ownerID,
                    groupID: groupID,
                    settings: settings
                )
            }
        }
        .sheet(item: Binding(
            get: { remote.editorDocument },
            set: { if $0 == nil { remote.editorDocument = nil } }
        )) { document in
            SFTPRemoteEditorView(document: document) { text in
                guard let settings = session.settings else { return }
                remote.save(document, text: text, settings: settings)
            }
        }
    }

    private func navigationBar(_ settings: SSHConnectionSettings) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sftpWorkspaceNavigationButton(
                    systemImage: "chevron.left",
                    help: "Назад",
                    disabled: !remote.canGoBack || remote.isBusy
                ) { remote.goBack(settings: settings) }
                sftpWorkspaceNavigationButton(
                    systemImage: "chevron.right",
                    help: "Вперёд",
                    disabled: !remote.canGoForward || remote.isBusy
                ) { remote.goForward(settings: settings) }
                sftpWorkspaceNavigationButton(
                    systemImage: "arrow.up",
                    help: "На уровень выше",
                    disabled: remote.isBusy
                ) { remote.goUp(settings: settings) }
                sftpWorkspaceNavigationButton(
                    systemImage: "house",
                    help: "Домашняя папка",
                    disabled: remote.isBusy
                ) {
                    remote.load(
                        settings: settings,
                        directory: settings.initialDirectory,
                        recordHistory: false
                    )
                }
                sftpWorkspaceNavigationButton(
                    systemImage: "arrow.clockwise",
                    help: "Обновить",
                    disabled: remote.isBusy
                ) {
                    remote.load(
                        settings: settings,
                        directory: remote.currentPath,
                        recordHistory: false
                    )
                }
                sftpWorkspaceNavigationButton(
                    systemImage: "doc.badge.plus",
                    help: "Новый файл на сервере",
                    disabled: remote.isBusy
                ) {
                    newFileName = ""
                    showsNewFile = true
                }
                sftpWorkspaceNavigationButton(
                    systemImage: "folder.badge.plus",
                    help: "Новая папка на сервере",
                    disabled: remote.isBusy
                ) {
                    newFolderName = ""
                    showsNewFolder = true
                }
            }
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func remoteContextMenu(
        for entry: SFTPRemoteEntry,
        settings: SSHConnectionSettings
    ) -> some View {
        if entry.isDirectory {
            Button("Открыть", systemImage: "folder") {
                remote.open(entry, settings: settings)
            }
        } else {
            Button("Редактировать", systemImage: "square.and.pencil") {
                remote.edit(entry, settings: settings)
            }
            Button("Открыть временную копию", systemImage: "arrow.up.forward.app") {
                remote.openDownloaded(entry, applicationURL: nil, settings: settings)
            }
            Button(
                "Открыть временную копию с помощью…",
                systemImage: "square.grid.2x2"
            ) {
                sftpWorkspaceChooseApplication { applicationURL in
                    remote.openDownloaded(
                        entry,
                        applicationURL: applicationURL,
                        settings: settings
                    )
                }
            }
        }

        Button(
            "Скопировать в соседнюю панель",
            systemImage: "arrow.left.arrow.right"
        ) {
            if !remote.selectedEntryIDs.contains(entry.id) {
                remote.selectedEntryIDs = [entry.id]
                selectionAnchor = entry.id
            }
            copyToOpposite()
        }
        .disabled(!targetReady)
        Button("Скопировать путь", systemImage: "doc.on.doc") {
            sftpWorkspaceCopyPath(
                SFTPService.joinedRemotePath(remote.currentPath, entry.name)
            )
        }

        Divider()

        Button("Переименовать…", systemImage: "pencil") {
            let entries = actionEntries(for: entry)
            guard entries.count == 1 else { return }
            renameEntry = entries[0]
            renameText = entries[0].name
            showsRenamePrompt = true
        }
        .disabled(actionEntries(for: entry).count != 1)

        Button("Свойства и доступ…", systemImage: "info.circle") {
            let entries = actionEntries(for: entry)
            guard entries.count == 1 else { return }
            propertiesTarget = .remote(entries[0], directory: remote.currentPath)
        }
        .disabled(actionEntries(for: entry).count != 1)

        Divider()

        Button("Удалить", systemImage: "trash", role: .destructive) {
            deleteEntries = actionEntries(for: entry)
        }
    }

    private func actionEntries(for entry: SFTPRemoteEntry) -> [SFTPRemoteEntry] {
        remote.selectedEntryIDs.contains(entry.id) && !remote.selectedEntries.isEmpty
            ? remote.selectedEntries
            : [entry]
    }

    private func selectRow(_ id: String) {
        let result = sftpWorkspaceRowSelection(
            id: id,
            orderedIDs: remote.entries.map(\.id),
            selection: remote.selectedEntryIDs,
            anchor: selectionAnchor
        )
        remote.selectedEntryIDs = result.selection
        selectionAnchor = result.anchor
    }

    private var pathSuggestions: [String] {
        let typed = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = remote.entries.filter(\.isDirectory).map {
            SFTPService.joinedRemotePath(remote.currentPath, $0.name)
        }
        candidates.append(SFTPService.parentRemotePath(remote.currentPath))
        candidates.append("~")
        candidates.append("/")
        return sftpWorkspacePathSuggestions(
            candidates,
            matching: typed,
            current: remote.currentPath
        )
    }

    private func acceptInternalRemoteDrag(
        _ items: [String],
        to destinationDirectory: String,
        destinationSettings: SSHConnectionSettings
    ) -> Bool {
        guard let source = remoteSource,
              let sourcePaneID = remoteSourcePaneID,
              let sourceSettings = source.settings,
              !source.remote.isBusy,
              !remote.isBusy,
              let token = items
                .compactMap(sftpWorkspaceParseInternalDragToken)
                .first(where: { $0.paneID == sourcePaneID })
        else { return false }

        let entries: [SFTPRemoteEntry]
        if source.remote.selectedEntryIDs.contains(token.entryID),
           !source.remote.selectedEntries.isEmpty {
            entries = source.remote.selectedEntries
        } else if let entry = source.remote.entries.first(where: { $0.id == token.entryID }) {
            entries = [entry]
        } else {
            return false
        }

        remote.copyRemote(
            entries,
            from: source.remote.currentPath,
            sourceSettings: sourceSettings,
            destinationSettings: destinationSettings,
            to: destinationDirectory
        )
        return true
    }

    private func acceptDrops(
        _ providers: [NSItemProvider],
        to destinationDirectory: String,
        destinationSettings: SSHConnectionSettings
    ) -> Bool {
        let fileProviders = providers.filter {
  $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        if !fileProviders.isEmpty {
  for provider in fileProviders {
      let handler = SFTPMainActorValueHandler<URL> { url in
          remote.upload(
              localURLs: [url],
              to: destinationDirectory,
              settings: destinationSettings
          )
      }
      SFTPItemProviderBridge.loadFileURL(
          from: provider,
          handler: handler
      )
  }
  return true
        }

        let stringProviders = providers.filter {
  $0.hasItemConformingToTypeIdentifier(
      NSPasteboard.PasteboardType.string.rawValue
  )
        }
        guard !stringProviders.isEmpty else { return false }
        for provider in stringProviders {
  let handler = SFTPMainActorValueHandler<String> { value in
      _ = acceptInternalRemoteDrag(
          [value],
          to: destinationDirectory,
          destinationSettings: destinationSettings
      )
  }
  SFTPItemProviderBridge.loadString(
      from: provider,
      handler: handler
  )
        }
        return true

    }

}

@MainActor
private struct SFTPWorkspaceAppKitDragMonitor: NSViewRepresentable {
    let token: String
    let isDirectory: Bool

    func makeNSView(context: Context) -> SFTPWorkspaceDragMonitorNSView {
        let view = SFTPWorkspaceDragMonitorNSView()
        view.token = token
        view.isDirectory = isDirectory
        return view
    }

    func updateNSView(
        _ nsView: SFTPWorkspaceDragMonitorNSView,
        context: Context
    ) {
        nsView.token = token
        nsView.isDirectory = isDirectory
    }

    static func dismantleNSView(
        _ nsView: SFTPWorkspaceDragMonitorNSView,
        coordinator: ()
    ) {
        nsView.removeEventMonitor()
    }
}

@MainActor
private final class SFTPWorkspaceDragMonitorNSView: NSView, NSDraggingSource {
    var token = ""
    var isDirectory = false

    private var eventMonitor: Any?
    private var isTrackingMouse = false
    private var initialPoint = NSPoint.zero

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installEventMonitorIfNeeded()
        }
    }

    func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isTrackingMouse = false
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }

            // NSEvent is explicitly non-Sendable in the macOS 26 SDK. Do not
            // capture or return it from MainActor.assumeIsolated. Bridge only
            // its synchronous object address across the isolation boundary and
            // let the actor-isolated code return a Sendable Bool instead.
            let eventAddress = UInt(
                bitPattern: Unmanaged.passUnretained(event).toOpaque()
            )
            let shouldConsume = MainActor.assumeIsolated {
                guard let pointer = UnsafeRawPointer(bitPattern: eventAddress) else {
                    return false
                }
                let mainEvent = Unmanaged<NSEvent>
                    .fromOpaque(pointer)
                    .takeUnretainedValue()
                return self.handleMouseEvent(mainEvent)
            }
            return shouldConsume ? nil : event
        }
    }

    private func handleMouseEvent(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else {
            isTrackingMouse = false
            return false
        }

        let point = convert(event.locationInWindow, from: nil)

        switch event.type {
        case .leftMouseDown:
            guard bounds.contains(point) else {
                isTrackingMouse = false
                return false
            }
            isTrackingMouse = true
            initialPoint = point
            return false

        case .leftMouseDragged:
            guard isTrackingMouse else { return false }
            let deltaX = point.x - initialPoint.x
            let deltaY = point.y - initialPoint.y
            guard hypot(deltaX, deltaY) >= 4 else { return false }

            isTrackingMouse = false
            beginSFTPDraggingSession(event: event, point: point)
            return true

        case .leftMouseUp:
            isTrackingMouse = false
            return false

        default:
            return false
        }
    }

    private func beginSFTPDraggingSession(event: NSEvent, point: NSPoint) {
        guard !token.isEmpty else { return }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(token, forType: .string)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = NSImage(
            systemSymbolName: isDirectory ? "folder.fill" : "doc.fill",
            accessibilityDescription: nil
        ) ?? NSImage(size: NSSize(width: 24, height: 24))
        image.size = NSSize(width: 24, height: 24)

        draggingItem.setDraggingFrame(
            NSRect(
                x: point.x - 12,
                y: point.y - 12,
                width: 24,
                height: 24
            ),
            contents: image
        )

        let session = beginDraggingSession(
            with: [draggingItem],
            event: event,
            source: self
        )
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(
        for session: NSDraggingSession
    ) -> Bool {
        true
    }
}

private let sftpWorkspaceDropTypeIdentifiers = [
    UTType.fileURL.identifier,
    NSPasteboard.PasteboardType.string.rawValue,
    SFTPDragType.remoteEntry.identifier
]

private let sftpWorkspaceInternalDragPrefix = "SelectiveRemoteSFTPRemote|"

private func sftpWorkspaceInternalDragToken(
    paneID: UUID,
    entryID: String
) -> String {
    let encodedEntryID = Data(entryID.utf8).base64EncodedString()
    return sftpWorkspaceInternalDragPrefix
        + paneID.uuidString
        + "|"
        + encodedEntryID
}

private func sftpWorkspaceParseInternalDragToken(
    _ value: String
) -> (paneID: UUID, entryID: String)? {
    guard value.hasPrefix(sftpWorkspaceInternalDragPrefix) else { return nil }
    let body = String(value.dropFirst(sftpWorkspaceInternalDragPrefix.count))
    let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
          let paneID = UUID(uuidString: String(parts[0])),
          let data = Data(base64Encoded: String(parts[1])),
          let entryID = String(data: data, encoding: .utf8)
    else { return nil }
    return (paneID, entryID)
}

@MainActor
private func sftpWorkspaceRowSelection(
    id: String,
    orderedIDs: [String],
    selection: Set<String>,
    anchor: String?
) -> (selection: Set<String>, anchor: String?) {
    let flags = NSApp.currentEvent?.modifierFlags ?? []
    if flags.contains(.shift),
       let anchor,
       let first = orderedIDs.firstIndex(of: anchor),
       let last = orderedIDs.firstIndex(of: id) {
        let lower = min(first, last)
        let upper = max(first, last)
        return (Set(orderedIDs[lower...upper]), anchor)
    }

    if flags.contains(.command) {
        var updated = selection
        if updated.contains(id) {
            updated.remove(id)
        } else {
            updated.insert(id)
        }
        return (updated, id)
    }

    return ([id], id)
}

private func sftpWorkspacePathSuggestions(
    _ candidates: [String],
    matching typed: String,
    current: String
) -> [String] {
    let unique = Array(Set(candidates)).filter { !$0.isEmpty && $0 != current }
    guard !typed.isEmpty else { return unique.sorted().prefix(15).map { $0 } }
    let last = typed
        .split(separator: "/", omittingEmptySubsequences: false)
        .last
        .map(String.init) ?? typed
    return unique.filter { candidate in
        candidate.range(of: typed, options: [.caseInsensitive, .anchored]) != nil
            || URL(fileURLWithPath: candidate).lastPathComponent.range(
                of: last,
                options: [.caseInsensitive, .anchored]
            ) != nil
    }
    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

@MainActor
private func sftpWorkspaceChooseApplication(completion: (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.title = "Выберите приложение"
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.application]
    guard panel.runModal() == .OK, let applicationURL = panel.url else { return }
    completion(applicationURL)
}

@MainActor
private func sftpWorkspaceCopyPath(_ path: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
}

@MainActor
private func sftpWorkspaceFilterField(
    text: Binding<String>,
    placeholder: String,
    disabled: Bool = false
) -> some View {
    HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
            .font(.caption)
            .foregroundStyle(.secondary)
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.caption)
        if !text.wrappedValue.isEmpty {
            Button("Очистить фильтр", systemImage: "xmark.circle.fill") {
                text.wrappedValue = ""
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
    .disabled(disabled)
}

@MainActor
private func sftpWorkspaceBreadcrumbBar(
    _ crumbs: [SFTPPathCrumb],
    onSelect: @escaping (SFTPPathCrumb) -> Void
) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 3) {
            ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button(crumb.title) {
                    onSelect(crumb)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(
                    index == crumbs.count - 1 ? Color.primary : Color.secondary
                )
            }
        }
        .padding(.vertical, 2)
    }
    .frame(height: 22)
}

@MainActor
private func sftpWorkspacePathField(
    title: String,
    text: Binding<String>,
    disabled: Bool,
    suggestions: [String],
    onSubmit: @escaping () -> Void
) -> some View {
    HStack(spacing: 6) {
        Image(systemName: "location")
            .font(.caption)
            .foregroundStyle(.secondary)
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospaced())
            .onSubmit(onSubmit)
        if !suggestions.isEmpty {
            Menu {
                ForEach(suggestions.prefix(15), id: \.self) { suggestion in
                    Button(suggestion) {
                        text.wrappedValue = suggestion
                    }
                }
            } label: {
                Image(systemName: "text.insert")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Подсказки путей из текущей папки")
        }
        Button("Перейти", systemImage: "arrow.right.circle", action: onSubmit)
            .labelStyle(.iconOnly)
            .help("Перейти по указанному пути")
    }
    .disabled(disabled)
}

@MainActor
private func sftpWorkspaceSortingMenu(
    field: Binding<SFTPFileSortField>,
    direction: Binding<SFTPSortDirection>
) -> some View {
    Menu {
        Picker("Сортировать", selection: field) {
            ForEach(SFTPFileSortField.allCases) { field in
                Text(field.title).tag(field)
            }
        }
        Divider()
        Picker("Направление", selection: direction) {
            ForEach(SFTPSortDirection.allCases) { direction in
                Label(direction.title, systemImage: direction.systemImage)
                    .tag(direction)
            }
        }
    } label: {
        Image(systemName: "arrow.up.arrow.down")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Сортировка")
}

@MainActor
private func sftpWorkspaceNavigationButton(
    systemImage: String,
    help: String,
    disabled: Bool,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Image(systemName: systemImage)
    }
    .disabled(disabled)
    .help(help)
}

@MainActor
private func sftpWorkspaceFileHeader(
    sortField: SFTPFileSortField,
    sortDirection: SFTPSortDirection,
    onSelect: @escaping (SFTPFileSortField) -> Void
) -> some View {
    HStack(spacing: 8) {
        sftpWorkspaceColumnHeader(
            "Имя",
            field: .name,
            width: nil,
            sortField: sortField,
            sortDirection: sortDirection,
            onSelect: onSelect
        )
        sftpWorkspaceColumnHeader(
            "Владелец",
            field: .owner,
            width: 86,
            sortField: sortField,
            sortDirection: sortDirection,
            onSelect: onSelect
        )
        sftpWorkspaceColumnHeader(
            "Доступ",
            field: .permissions,
            width: 92,
            sortField: sortField,
            sortDirection: sortDirection,
            onSelect: onSelect
        )
        sftpWorkspaceColumnHeader(
            "Изменён",
            field: .modified,
            width: 112,
            sortField: sortField,
            sortDirection: sortDirection,
            onSelect: onSelect
        )
        sftpWorkspaceColumnHeader(
            "Размер",
            field: .size,
            width: 58,
            sortField: sortField,
            sortDirection: sortDirection,
            onSelect: onSelect
        )
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
}

@MainActor
private func sftpWorkspaceColumnHeader(
    _ title: String,
    field: SFTPFileSortField,
    width: CGFloat?,
    sortField: SFTPFileSortField,
    sortDirection: SFTPSortDirection,
    onSelect: @escaping (SFTPFileSortField) -> Void
) -> some View {
    Button {
        onSelect(field)
    } label: {
        HStack(spacing: 3) {
            Text(title)
            if sortField == field {
                Image(systemName: sortDirection.systemImage)
            }
        }
        .frame(
            minWidth: width,
            maxWidth: width ?? .infinity,
            alignment: .leading
        )
    }
    .buttonStyle(.plain)
}

@MainActor
private func sftpWorkspaceFileRow(
    name: String,
    isDirectory: Bool,
    isSymbolicLink: Bool,
    ownerText: String,
    permissions: String,
    modifiedText: String,
    sizeText: String
) -> some View {
    HStack(spacing: 8) {
        HStack(spacing: 8) {
            Image(
                systemName: isDirectory
                    ? "folder.fill"
                    : isSymbolicLink ? "link" : "doc"
            )
            .foregroundStyle(isDirectory ? Color.blue : Color.secondary)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Text(ownerText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: 86, alignment: .leading)
            .help(ownerText)

        Text(permissions)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 92, alignment: .leading)

        Text(modifiedText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 112, alignment: .leading)
            .help(modifiedText)

        Text(sizeText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 58, alignment: .trailing)
    }
}

@MainActor
private var sftpWorkspaceBusyOverlay: some View {
    ProgressView()
        .controlSize(.large)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
}

@ViewBuilder
@MainActor
private func sftpWorkspaceDropOverlay(isTargeted: Bool, text: String) -> some View {
    if isTargeted {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.accentColor.opacity(0.12))
            .overlay {
                Label(text, systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                    .padding(14)
                    .background(.regularMaterial, in: Capsule())
            }
            .allowsHitTesting(false)
    }
}

@ViewBuilder
@MainActor
private func sftpWorkspaceStatus(_ message: String, error: String?) -> some View {
    HStack(spacing: 7) {
        if let error {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .foregroundStyle(.orange)
        } else {
            Text(message)
                .foregroundStyle(.secondary)
        }
        Spacer()
    }
    .font(.caption)
    .lineLimit(1)
    .padding(.horizontal, 10)
    .padding(.bottom, 8)
}
