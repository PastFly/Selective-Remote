import AppKit
import SwiftUI

enum ConnectionCenterKind: String, CaseIterable, Identifiable, Hashable {
    case rdp
    case terminal
    case sftp
    case forwarding

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rdp: "RDP"
        case .terminal: "Terminal"
        case .sftp: "SFTP"
        case .forwarding: "Forwarding"
        }
    }

    var systemImage: String {
        switch self {
        case .rdp: "desktopcomputer"
        case .terminal: "terminal"
        case .sftp: "folder"
        case .forwarding: "arrow.left.arrow.right"
        }
    }
}

enum ConnectionCenterState: String, Hashable {
    case connected
    case connecting
    case reconnecting
    case disconnected
    case stopping
    case error

    var title: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .disconnected: "Disconnected"
        case .stopping: "Stopping"
        case .error: "Error"
        }
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .disconnected, .stopping: .secondary
        case .error: .red
        }
    }

    var isProblem: Bool {
        self == .error || self == .reconnecting
    }
}

enum ConnectionCenterTerminalScope: Hashable {
    case profile(UUID)
    case global
}

enum ConnectionCenterSFTPScope: Hashable {
    case pane(UUID)
    case profile(UUID)
    case global
}

enum ConnectionCenterSource: Hashable {
    case rdp(profileID: UUID)
    case terminal(scope: ConnectionCenterTerminalScope, tabID: UUID)
    case sftp(scope: ConnectionCenterSFTPScope)
    case profileTunnel(profileID: UUID, ruleID: UUID)
    case independentTunnel(tunnelID: UUID)

    var stableID: String {
        switch self {
        case let .rdp(profileID):
            "rdp:\(profileID.uuidString)"
        case let .terminal(scope, tabID):
            switch scope {
            case let .profile(profileID):
                "terminal:profile:\(profileID.uuidString):\(tabID.uuidString)"
            case .global:
                "terminal:global:\(tabID.uuidString)"
            }
        case let .sftp(scope):
            switch scope {
            case let .pane(paneID):
                "sftp:pane:\(paneID.uuidString)"
            case let .profile(profileID):
                "sftp:profile:\(profileID.uuidString)"
            case .global:
                "sftp:global"
            }
        case let .profileTunnel(profileID, ruleID):
            "forwarding:profile:\(profileID.uuidString):\(ruleID.uuidString)"
        case let .independentTunnel(tunnelID):
            "forwarding:independent:\(tunnelID.uuidString)"
        }
    }
}

struct ConnectionCenterDetailRow: Hashable, Identifiable {
    let label: String
    let value: String

    var id: String { "\(label)\u{0}\(value)" }
}

struct ConnectionCenterDetailSection: Hashable, Identifiable {
    let title: String
    let rows: [ConnectionCenterDetailRow]

    var id: String { title }
}

struct ConnectionCenterItem: Hashable, Identifiable {
    let source: ConnectionCenterSource
    let kind: ConnectionCenterKind
    let profileName: String
    let userHost: String
    let port: Int?
    let route: String?
    let authentication: String
    let state: ConnectionCenterState
    let startedAt: Date?
    let errorMessage: String?
    let detailSections: [ConnectionCenterDetailSection]

    var id: String { source.stableID }

    var sortKind: String { kind.title }
    var sortPort: Int { port ?? Int.max }
    var sortRoute: String { route ?? "" }
    var sortState: Int {
        switch state {
        case .connected: 0
        case .connecting: 1
        case .reconnecting: 2
        case .stopping: 3
        case .disconnected: 4
        case .error: 5
        }
    }
    var sortUptime: TimeInterval {
        guard let startedAt else { return .greatestFiniteMagnitude }
        return -startedAt.timeIntervalSinceReferenceDate
    }

    func uptimeText(now: Date = Date()) -> String {
        guard let startedAt else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    var diagnosticText: String {
        var lines = [
            "Selective Remote · Connection Center",
            "Type: \(kind.title)",
            "Profile: \(profileName)",
            "Target: \(userHost)",
            "Port: \(port.map(String.init) ?? "—")",
            "State: \(state.title)",
            "Auth: \(authentication)"
        ]
        if let route, !route.isEmpty {
            lines.append("Route: \(route)")
        }
        for section in detailSections {
            lines.append("")
            lines.append("[\(section.title)]")
            for row in section.rows {
                lines.append("\(row.label): \(row.value)")
            }
        }
        if let errorMessage, !errorMessage.isEmpty {
            lines.append("")
            lines.append("Error: \(errorMessage)")
        }
        return lines.joined(separator: "\n")
    }
}

struct ConnectionCenterSnapshot: Equatable {
    var items: [ConnectionCenterItem]

    var terminalCount: Int { items.filter { $0.kind == .terminal }.count }
    var rdpCount: Int { items.filter { $0.kind == .rdp }.count }
    var tunnelCount: Int { items.filter { $0.kind == .forwarding }.count }
    var sftpCount: Int { items.filter { $0.kind == .sftp }.count }
    var problemCount: Int { items.filter { $0.state.isProblem }.count }
}

private enum ConnectionCenterTypeFilter: String, CaseIterable, Identifiable, Hashable {
    case all = "Все типы"
    case rdp = "RDP"
    case terminal = "Terminal"
    case sftp = "SFTP"
    case forwarding = "Forwarding"

    var id: String { rawValue }

    func matches(_ item: ConnectionCenterItem) -> Bool {
        switch self {
        case .all: true
        case .rdp: item.kind == .rdp
        case .terminal: item.kind == .terminal
        case .sftp: item.kind == .sftp
        case .forwarding: item.kind == .forwarding
        }
    }
}

private enum ConnectionCenterStateFilter: String, CaseIterable, Identifiable, Hashable {
    case all = "Все состояния"
    case connected = "Подключено"
    case connecting = "Подключается"
    case reconnecting = "Переподключение"
    case problems = "Проблемы"

    var id: String { rawValue }

    func matches(_ item: ConnectionCenterItem) -> Bool {
        switch self {
        case .all: true
        case .connected: item.state == .connected
        case .connecting: item.state == .connecting
        case .reconnecting: item.state == .reconnecting
        case .problems: item.state.isProblem
        }
    }
}

private enum ConnectionCenterSortField: String {
    case kind
    case profile
    case target
    case port
    case route
    case auth
    case state
    case uptime
}

private enum ConnectionCenterPreferences {
    static let typeFilterKey = "SelectiveRemote.connectionCenter.typeFilter.v1"
    static let stateFilterKey = "SelectiveRemote.connectionCenter.stateFilter.v1"
    static let sortFieldKey = "SelectiveRemote.connectionCenter.sortField.v1"
    static let sortOrderKey = "SelectiveRemote.connectionCenter.sortOrder.v1"

    static func restoredTypeFilter(defaults: UserDefaults = .standard) -> ConnectionCenterTypeFilter {
        defaults.string(forKey: typeFilterKey)
            .flatMap(ConnectionCenterTypeFilter.init(rawValue:)) ?? .all
    }

    static func restoredStateFilter(defaults: UserDefaults = .standard) -> ConnectionCenterStateFilter {
        defaults.string(forKey: stateFilterKey)
            .flatMap(ConnectionCenterStateFilter.init(rawValue:)) ?? .all
    }

    static func restoredSortOrder(defaults: UserDefaults = .standard) -> [KeyPathComparator<ConnectionCenterItem>] {
        guard let rawField = defaults.string(forKey: sortFieldKey),
              let field = ConnectionCenterSortField(rawValue: rawField)
        else { return [] }
        let order: SortOrder = defaults.string(forKey: sortOrderKey) == "reverse"
            ? .reverse
            : .forward
        switch field {
        case .kind:
            return [KeyPathComparator(\ConnectionCenterItem.sortKind, order: order)]
        case .profile:
            return [KeyPathComparator(\ConnectionCenterItem.profileName, order: order)]
        case .target:
            return [KeyPathComparator(\ConnectionCenterItem.userHost, order: order)]
        case .port:
            return [KeyPathComparator(\ConnectionCenterItem.sortPort, order: order)]
        case .route:
            return [KeyPathComparator(\ConnectionCenterItem.sortRoute, order: order)]
        case .auth:
            return [KeyPathComparator(\ConnectionCenterItem.authentication, order: order)]
        case .state:
            return [KeyPathComparator(\ConnectionCenterItem.sortState, order: order)]
        case .uptime:
            return [KeyPathComparator(\ConnectionCenterItem.sortUptime, order: order)]
        }
    }

    static func sortField(
        for comparator: KeyPathComparator<ConnectionCenterItem>
    ) -> ConnectionCenterSortField? {
        if comparator.keyPath == \ConnectionCenterItem.sortKind { return .kind }
        if comparator.keyPath == \ConnectionCenterItem.profileName { return .profile }
        if comparator.keyPath == \ConnectionCenterItem.userHost { return .target }
        if comparator.keyPath == \ConnectionCenterItem.sortPort { return .port }
        if comparator.keyPath == \ConnectionCenterItem.sortRoute { return .route }
        if comparator.keyPath == \ConnectionCenterItem.authentication { return .auth }
        if comparator.keyPath == \ConnectionCenterItem.sortState { return .state }
        if comparator.keyPath == \ConnectionCenterItem.sortUptime { return .uptime }
        return nil
    }

    static func persistSortOrder(
        _ sortOrder: [KeyPathComparator<ConnectionCenterItem>],
        defaults: UserDefaults = .standard
    ) {
        guard let comparator = sortOrder.first,
              let field = sortField(for: comparator)
        else {
            defaults.removeObject(forKey: sortFieldKey)
            defaults.removeObject(forKey: sortOrderKey)
            return
        }
        defaults.set(field.rawValue, forKey: sortFieldKey)
        defaults.set(
            comparator.order == .reverse ? "reverse" : "forward",
            forKey: sortOrderKey
        )
    }
}

struct ConnectionCenterView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onOpen: (ConnectionCenterSource) -> Void
    let onReconnect: (ConnectionCenterSource) -> Void
    let onDisconnect: (ConnectionCenterSource) -> Void
    let onRefresh: () -> Void

    @State private var selectedItemID: String?
    @State private var filter = ConnectionCenterPreferences.restoredTypeFilter()
    @State private var stateFilter = ConnectionCenterPreferences.restoredStateFilter()
    @State private var searchText = ""
    @State private var sortOrder = ConnectionCenterPreferences.restoredSortOrder()
    @SceneStorage("SelectiveRemote.connectionCenter.columns.v1")
    private var columnCustomization: TableColumnCustomization<ConnectionCenterItem>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let snapshot = model.connectionCenterSnapshot(now: timeline.date)
            let items = sortedItems(filteredItems(snapshot.items))

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    header(snapshot: snapshot)
                    summary(snapshot: snapshot)
                    toolbar
                    connectionTable(items: items, now: timeline.date)
                    footer(items: items)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Divider()

                inspector(
                    item: selectedItem(from: items),
                    now: timeline.date
                )
                .frame(width: 340)
                .id(selectedItemID)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selectedItemID)
            }
            .onAppear {
                normalizeSelection(items: items)
            }
            .onChange(of: items.map(\.id)) { _, _ in
                normalizeSelection(items: items)
            }
            .onChange(of: filter) { _, value in
                UserDefaults.standard.set(
                    value.rawValue,
                    forKey: ConnectionCenterPreferences.typeFilterKey
                )
            }
            .onChange(of: stateFilter) { _, value in
                UserDefaults.standard.set(
                    value.rawValue,
                    forKey: ConnectionCenterPreferences.stateFilterKey
                )
            }
            .onChange(of: sortOrderSignature) { _, _ in
                ConnectionCenterPreferences.persistSortOrder(sortOrder)
            }
        }
    }

    private func header(snapshot: ConnectionCenterSnapshot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connection Center")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Единое состояние активных RDP, SSH, SFTP и Forwarding-подключений")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Обновить runtime state")
        }
    }

    private func summary(snapshot: ConnectionCenterSnapshot) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            statCard(
                title: "Активные SSH",
                value: snapshot.terminalCount,
                systemImage: "terminal.fill",
                color: .green,
                isActive: filter == .terminal && stateFilter == .all
            ) {
                filter = .terminal
                stateFilter = .all
            }
            statCard(
                title: "Активные RDP",
                value: snapshot.rdpCount,
                systemImage: "desktopcomputer",
                color: .blue,
                isActive: filter == .rdp && stateFilter == .all
            ) {
                filter = .rdp
                stateFilter = .all
            }
            statCard(
                title: "Туннели",
                value: snapshot.tunnelCount,
                systemImage: "arrow.left.arrow.right",
                color: .indigo,
                isActive: filter == .forwarding && stateFilter == .all
            ) {
                filter = .forwarding
                stateFilter = .all
            }
            statCard(
                title: "SFTP",
                value: snapshot.sftpCount,
                systemImage: "folder.fill",
                color: .purple,
                isActive: filter == .sftp && stateFilter == .all
            ) {
                filter = .sftp
                stateFilter = .all
            }
            statCard(
                title: "Проблемы",
                value: snapshot.problemCount,
                systemImage: "exclamationmark.triangle.fill",
                color: snapshot.problemCount == 0 ? .secondary : .red,
                isActive: stateFilter == .problems
            ) {
                filter = .all
                stateFilter = .problems
            }
        }
    }

    private func statCard(
        title: String,
        value: Int,
        systemImage: String,
        color: Color,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(color.opacity(0.13))
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(color)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .layoutPriority(1)
                    Text("\(value)")
                        .font(.title2.bold().monospacedDigit())
                }
                Spacer(minLength: 0)
            }
            .padding(13)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isActive ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.07),
                        lineWidth: isActive ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .help("Нажмите, чтобы отфильтровать подключения")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Поиск подключений", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 220, maxWidth: 360, minHeight: 34)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            }

            Spacer()

            if hasNonDefaultViewState {
                Button(
                    UpdateLocalization.text(ru: "Сбросить", en: "Reset"),
                    systemImage: "arrow.counterclockwise"
                ) {
                    resetView()
                }
                .controlSize(.small)
                .help(UpdateLocalization.text(
                    ru: "Сбросить поиск, фильтры, сортировку и столбцы",
                    en: "Reset search, filters, sorting, and columns"
                ))
            }

            Picker("Состояние", selection: $stateFilter) {
                ForEach(ConnectionCenterStateFilter.allCases) { option in
                    Text(LocalizedStringKey(option.rawValue)).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            Picker("Тип", selection: $filter) {
                ForEach(ConnectionCenterTypeFilter.allCases) { option in
                    Text(LocalizedStringKey(option.rawValue)).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 145)

            Menu("Столбцы", systemImage: "tablecells") {
                Button {
                    toggleColumnVisibility("port")
                } label: {
                    Label(
                        "Port",
                        systemImage: columnIsVisible("port") ? "checkmark" : "circle"
                    )
                }
                Button {
                    toggleColumnVisibility("route")
                } label: {
                    Label(
                        "Jump Host / Gateway",
                        systemImage: columnIsVisible("route") ? "checkmark" : "circle"
                    )
                }
                Button {
                    toggleColumnVisibility("auth")
                } label: {
                    Label(
                        "Auth",
                        systemImage: columnIsVisible("auth") ? "checkmark" : "circle"
                    )
                }
                Button {
                    toggleColumnVisibility("uptime")
                } label: {
                    Label(
                        "Uptime",
                        systemImage: columnIsVisible("uptime") ? "checkmark" : "circle"
                    )
                }
                Divider()
                Button("Сбросить столбцы", systemImage: "arrow.counterclockwise") {
                    columnCustomization = TableColumnCustomization<ConnectionCenterItem>()
                }
            }
        }
    }

    private func connectionTable(items: [ConnectionCenterItem], now: Date) -> some View {
        Table(
            items,
            selection: $selectedItemID,
            sortOrder: $sortOrder,
            columnCustomization: $columnCustomization
        ) {
            TableColumn("Тип", value: \.sortKind) { item in
                connectionCell(item) {
                    HStack(spacing: 7) {
                        Image(systemName: item.kind.systemImage)
                            .foregroundStyle(kindColor(item.kind))
                            .frame(width: 18)
                        Text(LocalizedStringKey(item.kind.title))
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 96, ideal: 112)

            TableColumn("Профиль", value: \.profileName) { item in
                connectionCell(item) {
                    Text(item.profileName)
                        .lineLimit(1)
                        .help(item.profileName)
                }
            }
            .width(min: 110, ideal: 150)

            TableColumn("User@Host", value: \.userHost) { item in
                connectionCell(item) {
                    Text(item.userHost)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .help(item.userHost)
                }
            }
            .width(min: 150, ideal: 210)

            TableColumn("Port", value: \.sortPort) { item in
                connectionCell(item) {
                    Text(item.port.map(String.init) ?? "—")
                        .monospacedDigit()
                }
            }
            .width(min: 48, ideal: 58, max: 70)
            .customizationID("port")

            TableColumn("Jump Host / Gateway", value: \.sortRoute) { item in
                connectionCell(item) {
                    Text(item.route ?? "—")
                        .lineLimit(1)
                        .foregroundStyle(item.route == nil ? Color.secondary : Color.primary)
                        .help(item.route ?? "Маршрут без промежуточного узла")
                }
            }
            .width(min: 140, ideal: 190)
            .customizationID("route")

            TableColumn("Auth", value: \.authentication) { item in
                connectionCell(item) {
                    Text(item.authentication)
                        .lineLimit(1)
                        .help(item.authentication)
                }
            }
            .width(min: 90, ideal: 125)
            .customizationID("auth")

            TableColumn("State", value: \.sortState) { item in
                connectionCell(item) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.state.color)
                            .frame(width: 7, height: 7)
                        Text(LocalizedStringKey(item.state.title))
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 105, ideal: 125)

            TableColumn("Uptime", value: \.sortUptime) { item in
                connectionCell(item) {
                    Text(item.uptimeText(now: now))
                        .monospacedDigit()
                }
            }
            .width(min: 68, ideal: 82, max: 100)
            .customizationID("uptime")
        }
        .frame(minHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
                .allowsHitTesting(false)
        }
    }

    private func connectionCell<Content: View>(
        _ item: ConnectionCenterItem,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                connectionContextMenu(item)
            }
    }

    @ViewBuilder
    private func connectionContextMenu(_ item: ConnectionCenterItem) -> some View {
        if item.kind == .rdp || item.kind == .terminal || item.kind == .forwarding {
            Button("Reconnect", systemImage: "arrow.clockwise") {
                selectedItemID = item.id
                onReconnect(item.source)
            }
        }

        Button(openActionTitle(item.kind), systemImage: openActionIcon(item.kind)) {
            selectedItemID = item.id
            onOpen(item.source)
        }

        Button("Копировать адрес", systemImage: "doc.on.doc") {
            selectedItemID = item.id
            copyText(hostOnly(item.userHost))
        }

        Button("Копировать user@host", systemImage: "person.crop.circle.badge.checkmark") {
            selectedItemID = item.id
            copyText(item.userHost)
        }

        Button("Copy Diagnostic", systemImage: "doc.on.doc") {
            selectedItemID = item.id
            copyDiagnostic(item)
        }

        if model.hasConnectionCenterLog(item.source) {
            Button("Показать журнал", systemImage: "doc.text.magnifyingglass") {
                selectedItemID = item.id
                model.revealConnectionCenterLog(item.source)
            }
        }

        Divider()

        Button(disconnectActionTitle(item.kind), systemImage: "xmark.circle", role: .destructive) {
            selectedItemID = item.id
            onDisconnect(item.source)
        }
    }

    private func footer(items: [ConnectionCenterItem]) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
            Text("Обновлено только что")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(items.count) подключений")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func inspector(item: ConnectionCenterItem?, now: Date) -> some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(kindColor(item.kind).opacity(0.13))
                            Image(systemName: item.kind.systemImage)
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(kindColor(item.kind))
                        }
                        .frame(width: 42, height: 42)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.profileName)
                                .font(.headline)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(item.state.color)
                                    .frame(width: 7, height: 7)
                                Text(LocalizedStringKey(item.state.title))
                                    .font(.caption)
                                if item.startedAt != nil {
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                    Text(item.uptimeText(now: now))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    if let error = item.errorMessage, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }

                    ForEach(item.detailSections) { section in
                        inspectorSection(section)
                    }

                    VStack(spacing: 9) {
                        if item.kind == .rdp || item.kind == .terminal || item.kind == .forwarding {
                            Button {
                                onReconnect(item.source)
                            } label: {
                                Label("Reconnect", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if item.kind == .rdp {
                            Button {
                                onOpen(item.source)
                            } label: {
                                Label(openActionTitle(item.kind), systemImage: openActionIcon(item.kind))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                onOpen(item.source)
                            } label: {
                                Label(openActionTitle(item.kind), systemImage: openActionIcon(item.kind))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Button {
                            copyDiagnostic(item)
                        } label: {
                            Label("Copy Diagnostic", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }

                        Button(role: .destructive) {
                            onDisconnect(item.source)
                        } label: {
                            Label(disconnectActionTitle(item.kind), systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(18)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.and.hand.point.up.left")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Выберите подключение")
                    .font(.headline)
                Text("Справа появятся реальные параметры runtime и доступные действия.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func inspectorSection(_ section: ConnectionCenterDetailSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.subheadline.bold())
            VStack(spacing: 8) {
                ForEach(section.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 102, alignment: .leading)
                        Text(row.value)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(11)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            }
        }
    }

    private func sortedItems(_ items: [ConnectionCenterItem]) -> [ConnectionCenterItem] {
        guard !sortOrder.isEmpty else { return items }
        return items.sorted(using: sortOrder)
    }

    private func filteredItems(_ items: [ConnectionCenterItem]) -> [ConnectionCenterItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            guard filter.matches(item), stateFilter.matches(item) else { return false }
            guard !query.isEmpty else { return true }
            return item.kind.title.localizedCaseInsensitiveContains(query)
                || item.profileName.localizedCaseInsensitiveContains(query)
                || item.userHost.localizedCaseInsensitiveContains(query)
                || item.authentication.localizedCaseInsensitiveContains(query)
                || (item.route?.localizedCaseInsensitiveContains(query) ?? false)
                || item.state.title.localizedCaseInsensitiveContains(query)
        }
    }

    private func selectedItem(from items: [ConnectionCenterItem]) -> ConnectionCenterItem? {
        guard let selectedItemID else { return items.first }
        return items.first(where: { $0.id == selectedItemID }) ?? items.first
    }

    private func normalizeSelection(items: [ConnectionCenterItem]) {
        guard !items.isEmpty else {
            selectedItemID = nil
            return
        }
        if selectedItemID == nil || !items.contains(where: { $0.id == selectedItemID }) {
            selectedItemID = items[0].id
        }
    }

    private func kindColor(_ kind: ConnectionCenterKind) -> Color {
        switch kind {
        case .rdp: .blue
        case .terminal: .green
        case .sftp: .purple
        case .forwarding: .indigo
        }
    }

    private func openActionTitle(_ kind: ConnectionCenterKind) -> String {
        switch kind {
        case .rdp: "Open RDP"
        case .terminal: "Open Terminal"
        case .sftp: "Open SFTP"
        case .forwarding: "Open Forwarding"
        }
    }

    private func disconnectActionTitle(_ kind: ConnectionCenterKind) -> String {
        switch kind {
        case .rdp, .terminal: "Disconnect"
        case .sftp: "Close SFTP"
        case .forwarding: "Stop Tunnel"
        }
    }

    private func openActionIcon(_ kind: ConnectionCenterKind) -> String {
        switch kind {
        case .rdp: "desktopcomputer"
        case .terminal: "terminal"
        case .sftp: "folder"
        case .forwarding: "arrow.left.arrow.right"
        }
    }

    private var hasNonDefaultViewState: Bool {
        let columns = ["port", "route", "auth", "uptime"]
        let columnsCustomized = columns.contains { id in
            columnCustomization[visibility: id] != .automatic
        }
        return !searchText.isEmpty
            || filter != .all
            || stateFilter != .all
            || !sortOrder.isEmpty
            || columnsCustomized
    }

    private func resetView() {
        searchText = ""
        filter = .all
        stateFilter = .all
        sortOrder = []
        columnCustomization = TableColumnCustomization<ConnectionCenterItem>()

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ConnectionCenterPreferences.typeFilterKey)
        defaults.removeObject(forKey: ConnectionCenterPreferences.stateFilterKey)
        ConnectionCenterPreferences.persistSortOrder([], defaults: defaults)
    }

    private func columnIsVisible(_ id: String) -> Bool {
        columnCustomization[visibility: id] != .hidden
    }

    private func toggleColumnVisibility(_ id: String) {
        columnCustomization[visibility: id] =
            columnIsVisible(id) ? .hidden : .visible
    }

    private var sortOrderSignature: String {
        guard let comparator = sortOrder.first,
              let field = ConnectionCenterPreferences.sortField(for: comparator)
        else { return "none" }
        return "\(field.rawValue):\(comparator.order == .reverse ? "reverse" : "forward")"
    }

    private func hostOnly(_ userHost: String) -> String {
        guard let marker = userHost.lastIndex(of: "@") else { return userHost }
        return String(userHost[userHost.index(after: marker)...])
    }

    private func copyText(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func copyDiagnostic(_ item: ConnectionCenterItem) {
        copyText(item.diagnosticText)
    }
}
