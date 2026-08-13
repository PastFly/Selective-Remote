import AppKit
import SwiftUI

enum ForwardingManagerSource: Hashable {
    case profile(profileID: UUID, ruleID: UUID)
    case independent(tunnelID: UUID)

    var tunnelID: UUID {
        switch self {
        case let .profile(_, ruleID): ruleID
        case let .independent(tunnelID): tunnelID
        }
    }

    var stableID: String {
        switch self {
        case let .profile(profileID, ruleID):
            "profile:\(profileID.uuidString):\(ruleID.uuidString)"
        case let .independent(tunnelID):
            "independent:\(tunnelID.uuidString)"
        }
    }
}

enum ForwardingManagerOwnership: String, Hashable {
    case profile
    case independent

    var title: String {
        switch self {
        case .profile: "Profile"
        case .independent: "Independent"
        }
    }

    var color: Color {
        switch self {
        case .profile: .blue
        case .independent: .indigo
        }
    }
}

enum ForwardingManagerState: String, Hashable {
    case running
    case reconnecting
    case stopping
    case stopped
    case error

    var title: String {
        switch self {
        case .running: "Работает"
        case .reconnecting: "Переподключается"
        case .stopping: "Останавливается"
        case .stopped: "Остановлен"
        case .error: "Ошибка"
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .reconnecting: .orange
        case .stopping: .orange
        case .stopped: .secondary
        case .error: .red
        }
    }

    var canStart: Bool { self == .stopped || self == .error }
    var canStop: Bool { self == .running || self == .reconnecting }
    var canRestart: Bool { self != .stopping }
    var canEdit: Bool { self == .stopped || self == .error }
}

struct ForwardingManagerItem: Identifiable {
    let source: ForwardingManagerSource
    let ownership: ForwardingManagerOwnership
    let profileName: String
    let connection: TerminalTabConnection
    let rule: PortForwardRule
    let host: String
    let username: String
    let port: Int
    let authentication: String
    let identityName: String?
    let jumpHost: String?
    let proxy: String?
    let state: ForwardingManagerState
    let startedAt: Date?
    let lastError: String?
    let hasLog: Bool
    var reconnectProgress: SmartReconnectProgress? = nil

    var id: String { source.stableID }

    var localAddress: String {
        "\(rule.bindAddress):\(rule.sourcePort)"
    }

    var destination: String {
        guard rule.kind != .dynamic else { return "Dynamic / SOCKS" }
        let normalizedHost = rule.destinationHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = normalizedHost.isEmpty ? "…" : normalizedHost
        return "\(host):\(rule.destinationPort)"
    }

    var sshEndpoint: String {
        let normalizedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = normalizedUser.isEmpty ? host : "\(normalizedUser)@\(host)"
        return port == 22 ? destination : "\(destination):\(port)"
    }

    func uptimeText(now: Date = Date()) -> String {
        guard state == .running || state == .stopping, let startedAt else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}

struct ForwardingManagerSnapshot {
    let items: [ForwardingManagerItem]

    var activeCount: Int { items.filter { $0.state == .running }.count }
    var profileCount: Int { items.filter { $0.ownership == .profile }.count }
    var profileActiveCount: Int {
        items.filter { $0.ownership == .profile && $0.state == .running }.count
    }
    var independentCount: Int { items.filter { $0.ownership == .independent }.count }
    var independentActiveCount: Int {
        items.filter { $0.ownership == .independent && $0.state == .running }.count
    }
    var errorCount: Int { items.filter { $0.state == .error }.count }
}

private enum ForwardingManagerFilter: String, CaseIterable, Identifiable {
    case all = "Все"
    case running = "Работают"
    case errors = "С ошибками"

    var id: String { rawValue }

    func matches(_ item: ForwardingManagerItem) -> Bool {
        switch self {
        case .all: true
        case .running:
            item.state == .running || item.state == .reconnecting || item.state == .stopping
        case .errors: item.state == .error
        }
    }
}

private enum ForwardingInspectorTab: String, CaseIterable, Identifiable {
    case overview = "Обзор"
    case scheme = "Схема"
    case log = "Лог"

    var id: String { rawValue }
}

enum ForwardingFailureStage: Equatable {
    case localBind
    case proxy
    case jumpHost
    case authentication
    case sshServer
    case unknown

    static func classify(_ error: String?) -> ForwardingFailureStage {
        guard let error else { return .unknown }
        let text = error.lowercased()
        if text.contains("address already in use")
            || text.contains("cannot listen to port")
            || text.contains("bind:")
            || text.contains("bind [") {
            return .localBind
        }
        if text.contains("permission denied")
            || text.contains("authentication failed")
            || text.contains("no supported authentication") {
            return .authentication
        }
        if text.contains("proxyjump") || text.contains("jump host") || text.contains("jumphost") {
            return .jumpHost
        }
        if text.contains("proxy") || text.contains("socks5") || text.contains("http connect") {
            return .proxy
        }
        if text.contains("could not resolve hostname")
            || text.contains("connection refused")
            || text.contains("connection timed out")
            || text.contains("no route to host")
            || text.contains("network is unreachable") {
            return .sshServer
        }
        return .unknown
    }
}

private enum ForwardingRouteNodeRole: Hashable {
    case localBind
    case mac
    case proxy
    case jumpHost
    case sshServer
    case destination
    case dynamicDestination
    case remoteBind
}

private enum ForwardingRouteNodeState {
    case neutral
    case ok
    case failed
    case unknown
}

private struct ForwardingRouteStep: Identifiable {
    let id: String
    let role: ForwardingRouteNodeRole
    let title: String
    let detail: String
    let icon: String
    let connectorAfter: String?
}

private struct ForwardingConnectionRequest: Identifiable {
    let id = UUID()
    let tunnelID: UUID
    let connection: TerminalTabConnection
}

struct ForwardingManagerView: View {
    @ObservedObject var model: AppModel
    let onOpenTerminal: (TerminalTabConnection) -> Void
    let onOpenProfile: (UUID) -> Void

    @State private var selectedItemID: String?
    @State private var filter = ForwardingManagerFilter.all
    @State private var searchText = ""
    @State private var inspectorTab = ForwardingInspectorTab.overview
    @State private var connectionRequest: ForwardingConnectionRequest?
    @State private var passwordInputs: [UUID: String] = [:]
    @State private var logText = ""

    private var sshProfiles: [ConnectionProfile] {
        model.profiles
            .filter { $0.connectionType == .ssh }
            .sorted {
                $0.friendlyName.localizedStandardCompare($1.friendlyName) == .orderedAscending
            }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { timeline in
            let snapshot = makeSnapshot()
            let items = filteredItems(snapshot.items)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    summary(snapshot)
                    toolbar(items: items)
                    tunnelTable(items: items, now: timeline.date)
                    footer(items: items)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Divider()

                inspector(item: selectedItem(from: items), now: timeline.date)
                    .frame(minWidth: 380, idealWidth: 430, maxWidth: 500)
            }
            .onAppear {
                normalizeSelection(items: items)
                refreshLog(for: selectedItem(from: items))
            }
            .onChange(of: items.map(\.id)) { _, _ in
                normalizeSelection(items: items)
            }
            .onChange(of: selectedItemID) { _, _ in
                refreshLog(for: selectedItem(from: items))
            }
            .onChange(of: inspectorTab) { _, tab in
                if tab == .log {
                    refreshLog(for: selectedItem(from: items))
                }
            }
        }
        .sheet(item: $connectionRequest) { request in
            TerminalConnectionEditor(
                profiles: sshProfiles,
                initialConnection: request.connection,
                allowsInteractivePassword: false,
                allowsTemporaryPassword: false,
                actionTitle: "Сохранить",
                customAuthenticationMessage: "Для ручного SSH-сервера пароль можно сохранить в Keychain в инспекторе туннеля.",
                onSave: { connection, _, _ in
                    guard var item = model.independentPortForwards.first(where: {
                        $0.id == request.tunnelID
                    }) else { return }
                    item.connection = connection
                    model.updateIndependentPortForward(item)
                }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Forwarding")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Менеджер SSH-туннелей · Local / Remote / Dynamic")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            newTunnelMenu
        }
    }

    private var newTunnelMenu: some View {
        Menu {
            Menu("Profile tunnel") {
                if sshProfiles.isEmpty {
                    Text("Нет SSH-профилей")
                } else {
                    ForEach(sshProfiles) { profile in
                        Menu(profile.friendlyName) {
                            ForEach(PortForwardKind.allCases) { kind in
                                Button {
                                    if let id = model.addPortForward(kind, profileID: profile.id) {
                                        selectedItemID = ForwardingManagerSource.profile(
                                            profileID: profile.id,
                                            ruleID: id
                                        ).stableID
                                        inspectorTab = .overview
                                    }
                                } label: {
                                    Label(kind.title, systemImage: kind.systemImage)
                                }
                            }
                        }
                    }
                }
            }

            Menu("Independent tunnel") {
                ForEach(PortForwardKind.allCases) { kind in
                    Button {
                        model.addIndependentPortForward(kind)
                        if let id = model.independentPortForwards.last?.id {
                            selectedItemID = ForwardingManagerSource.independent(
                                tunnelID: id
                            ).stableID
                            inspectorTab = .overview
                        }
                    } label: {
                        Label(kind.title, systemImage: kind.systemImage)
                    }
                }
            }
        } label: {
            Label("Новый туннель", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
    }

    private func summary(_ snapshot: ForwardingManagerSnapshot) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 155), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            statCard(
                title: "Активные туннели",
                value: snapshot.activeCount,
                detail: "из \(snapshot.items.count) всего",
                systemImage: "arrow.left.arrow.right",
                color: .green
            )
            statCard(
                title: "Profile tunnel",
                value: snapshot.profileActiveCount,
                detail: "из \(snapshot.profileCount) всего",
                systemImage: "person.crop.square",
                color: .blue
            )
            statCard(
                title: "Independent tunnel",
                value: snapshot.independentActiveCount,
                detail: "из \(snapshot.independentCount) всего",
                systemImage: "shippingbox",
                color: .indigo
            )
            statCard(
                title: "Ошибки",
                value: snapshot.errorCount,
                detail: snapshot.errorCount == 0 ? "нет проблем" : "требует внимания",
                systemImage: "exclamationmark.triangle.fill",
                color: snapshot.errorCount == 0 ? .secondary : .red
            )
        }
    }

    private func statCard(
        title: String,
        value: Int,
        detail: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(color.opacity(0.13))
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(value)")
                    .font(.title2.bold().monospacedDigit())
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private func toolbar(items: [ForwardingManagerItem]) -> some View {
        let selected = selectedItem(from: items)
        return HStack(spacing: 8) {
            Button {
                if let selected { start(selected) }
            } label: {
                Label("Запустить", systemImage: "play.fill")
            }
            .disabled(selected?.state.canStart != true)

            Button {
                if let selected { model.stopSSHTunnel(selected.source.tunnelID) }
            } label: {
                Label("Остановить", systemImage: "stop.fill")
            }
            .disabled(selected?.state.canStop != true)

            Button {
                if let selected { restart(selected) }
            } label: {
                Label("Перезапустить", systemImage: "arrow.clockwise")
            }
            .disabled(selected?.state.canRestart != true || selected?.state == .stopping)

            Menu("Ещё") {
                if let selected {
                    Button("Open Terminal", systemImage: "terminal") {
                        onOpenTerminal(selected.connection)
                    }
                    if case let .profile(profileID, _) = selected.source {
                        Button("Открыть профиль", systemImage: "rectangle.stack") {
                            onOpenProfile(profileID)
                        }
                    }
                    Button("Показать журнал", systemImage: "doc.text.magnifyingglass") {
                        model.revealSSHTunnelLog(selected.source.tunnelID)
                    }
                    .disabled(!selected.hasLog)
                    Button("Копировать команду", systemImage: "doc.on.doc") {
                        copyCommand(selected)
                    }
                    Divider()
                    if selected.ownership == .independent {
                        Button("Создать копию", systemImage: "plus.square.on.square") {
                            if let id = model.duplicateIndependentPortForward(selected.source.tunnelID) {
                                selectedItemID = ForwardingManagerSource.independent(tunnelID: id).stableID
                            }
                        }
                    }
                    Button("Удалить", systemImage: "trash", role: .destructive) {
                        delete(selected)
                    }
                    .disabled(!selected.state.canEdit)
                }
            }
            .disabled(selected == nil)

            Spacer(minLength: 12)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Поиск туннелей", text: $searchText)
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
            .padding(.horizontal, 9)
            .frame(minWidth: 160, idealWidth: 220, maxWidth: 280, minHeight: 32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            }

            Picker("Фильтр", selection: $filter) {
                ForEach(ForwardingManagerFilter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 230)
        }
        .controlSize(.small)
    }

    private func tunnelTable(items: [ForwardingManagerItem], now: Date) -> some View {
        Table(items, selection: $selectedItemID) {
            TableColumn("Состояние") { item in
                HStack(spacing: 7) {
                    Circle()
                        .fill(item.state.color)
                        .frame(width: 7, height: 7)
                    Text(item.state.title)
                        .lineLimit(1)
                }
            }
            .width(min: 100, ideal: 118)

            TableColumn("Имя") { item in
                HStack(spacing: 6) {
                    Image(systemName: item.rule.kind.systemImage)
                        .foregroundStyle(item.ownership.color)
                    Text(item.rule.name)
                        .lineLimit(1)
                        .help(item.rule.name)
                }
            }
            .width(min: 130, ideal: 180)

            TableColumn("Тип") { item in
                Text(item.ownership.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(item.ownership.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(item.ownership.color.opacity(0.10), in: Capsule())
            }
            .width(min: 92, ideal: 105)

            TableColumn("Локальный адрес") { item in
                Text(item.localAddress)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
            }
            .width(min: 125, ideal: 150)

            TableColumn("Назначение") { item in
                Text(item.destination)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(item.rule.kind == .dynamic ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .help(item.destination)
            }
            .width(min: 125, ideal: 160)

            TableColumn("SSH-host") { item in
                Text(item.sshEndpoint)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .help(item.sshEndpoint)
            }
            .width(min: 135, ideal: 180)

            TableColumn("Uptime") { item in
                Text(item.uptimeText(now: now))
                    .monospacedDigit()
            }
            .width(min: 62, ideal: 75, max: 90)
        }
        .frame(minHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
                .allowsHitTesting(false)
        }

    }

    private func footer(items: [ForwardingManagerItem]) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
            Text("Runtime state из существующих SSH tunnel processes")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(items.count) туннелей")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func inspector(item: ForwardingManagerItem?, now: Date) -> some View {
        if let item {
            VStack(spacing: 0) {
                inspectorHeader(item: item, now: now)
                    .padding(18)
                Divider()

                Picker("Инспектор", selection: $inspectorTab) {
                    ForEach(ForwardingInspectorTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

                Divider()

                switch inspectorTab {
                case .overview:
                    overviewInspector(item: item, now: now)
                case .scheme:
                    schemeInspector(item: item)
                case .log:
                    logInspector(item: item)
                }
            }
        } else {
            ContentUnavailableView(
                "Выберите туннель",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Справа появятся схема маршрута, runtime state и действия.")
            )
            .padding(24)
        }
    }

    private func inspectorHeader(item: ForwardingManagerItem, now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(item.ownership.color.opacity(0.13))
                Image(systemName: item.rule.kind.systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(item.ownership.color)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.rule.name)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Circle().fill(item.state.color).frame(width: 7, height: 7)
                    Text(item.state.title)
                    if item.startedAt != nil {
                        Text("·").foregroundStyle(.tertiary)
                        Text(item.uptimeText(now: now)).monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(item.ownership.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.ownership.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(item.ownership.color.opacity(0.10), in: Capsule())
        }
    }

    private func overviewInspector(item: ForwardingManagerItem, now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let progress = item.reconnectProgress {
                    reconnectBanner(progress)
                } else if let error = item.lastError, item.state == .error {
                    errorBanner(error)
                }

                routeDiagram(item)
                ruleEditor(item)
                sshServerCard(item)
                routeCard(item)
                authenticationCard(item)
                diagnosticsCard(item, now: now)
                actionCard(item)
            }
            .padding(18)
        }
    }

    private func ruleEditor(_ item: ForwardingManagerItem) -> some View {
        let binding = ruleBinding(item)
        return inspectorCard("Основное", systemImage: "slider.horizontal.3") {
            VStack(spacing: 10) {
                HStack {
                    Text("Имя")
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    TextField("Название туннеля", text: binding.name)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!item.state.canEdit)
                }

                Picker("Режим", selection: binding.kind) {
                    Text("Local").tag(PortForwardKind.local)
                    Text("Remote").tag(PortForwardKind.remote)
                    Text("Dynamic").tag(PortForwardKind.dynamic)
                }
                .pickerStyle(.segmented)
                .disabled(!item.state.canEdit)

                HStack {
                    Text(item.rule.kind == .remote ? "Remote bind" : "Local bind")
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    TextField("127.0.0.1", text: binding.bindAddress)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!item.state.canEdit)
                    TextField("Port", value: binding.sourcePort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 78)
                        .disabled(!item.state.canEdit)
                }

                if item.rule.kind != .dynamic {
                    HStack {
                        Text("Назначение")
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        TextField("host", text: binding.destinationHost)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!item.state.canEdit)
                        TextField("Port", value: binding.destinationPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 78)
                            .disabled(!item.state.canEdit)
                    }
                }
            }
            .font(.caption)
        }
    }

    private func sshServerCard(_ item: ForwardingManagerItem) -> some View {
        inspectorCard("SSH-сервер", systemImage: "server.rack") {
            VStack(alignment: .leading, spacing: 9) {
                detailRow("Профиль", item.profileName)
                detailRow("SSH", item.sshEndpoint)
                if item.ownership == .independent {
                    Button("Выбрать SSH-сервер…") {
                        connectionRequest = ForwardingConnectionRequest(
                            tunnelID: item.source.tunnelID,
                            connection: item.connection
                        )
                    }
                    .disabled(!item.state.canEdit)
                } else if case let .profile(profileID, _) = item.source {
                    Button("Открыть профиль") { onOpenProfile(profileID) }
                }
            }
        }
    }

    private func routeCard(_ item: ForwardingManagerItem) -> some View {
        inspectorCard("Маршрут", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
            VStack(alignment: .leading, spacing: 8) {
                detailRow("Jump Host", item.jumpHost ?? "—")
                detailRow("Proxy", item.proxy ?? "—")
                detailRow("Hops", hopCountText(item))
                Text(routeExplanation(item.rule.kind))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func authenticationCard(_ item: ForwardingManagerItem) -> some View {
        if item.ownership == .independent, item.connection.kind == .custom {
            inspectorCard("Аутентификация", systemImage: "key.fill") {
                VStack(alignment: .leading, spacing: 9) {
                    detailRow("Метод", item.authentication)
                    SecureField(
                        model.hasSavedForwardingPassword(item.source.tunnelID)
                            ? "Сохранён в Keychain — новый заменит его"
                            : "Пароль SSH-сервера",
                        text: passwordBinding(for: item.source.tunnelID)
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(!item.state.canEdit)

                    HStack {
                        Button("Сохранить в Keychain") {
                            let id = item.source.tunnelID
                            let value = passwordInputs[id] ?? ""
                            guard !value.isEmpty else { return }
                            model.saveForwardingPassword(value, tunnelID: id)
                            passwordInputs[id] = ""
                        }
                        .disabled(!item.state.canEdit || (passwordInputs[item.source.tunnelID] ?? "").isEmpty)

                        if model.hasSavedForwardingPassword(item.source.tunnelID) {
                            Spacer()
                            Button("Удалить пароль", role: .destructive) {
                                model.deleteSavedForwardingPassword(item.source.tunnelID)
                                passwordInputs[item.source.tunnelID] = ""
                            }
                            .disabled(!item.state.canEdit)
                        }
                    }

                    Toggle(
                        "Требовать Touch ID перед использованием пароля",
                        isOn: Binding(
                            get: { model.forwardingPasswordRequiresUserPresence(item.source.tunnelID) },
                            set: { model.setForwardingPasswordUserPresence($0, tunnelID: item.source.tunnelID) }
                        )
                    )
                    .toggleStyle(.switch)
                    .disabled(!item.state.canEdit)
                }
            }
        } else {
            inspectorCard("Аутентификация", systemImage: "key.fill") {
                VStack(alignment: .leading, spacing: 8) {
                    detailRow("Метод", item.authentication)
                    if let identityName = item.identityName {
                        detailRow("SSH key", identityName)
                    }
                    if item.ownership == .profile {
                        Text("Используются credentials выбранного SSH-профиля и существующая Keychain/Touch ID policy.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func diagnosticsCard(_ item: ForwardingManagerItem, now: Date) -> some View {
        inspectorCard("Диагностика", systemImage: "stethoscope") {
            VStack(alignment: .leading, spacing: 8) {
                detailRow("Статус", item.state.title)
                detailRow("Uptime", item.uptimeText(now: now))
                detailRow("Keepalive", keepAliveText(item))
                if let lastError = item.lastError, !lastError.isEmpty {
                    Divider()
                    Text(lastError)
                        .font(.caption2.monospaced())
                        .foregroundStyle(item.state == .error ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                        .lineLimit(8)
                }
            }
        }
    }

    private func actionCard(_ item: ForwardingManagerItem) -> some View {
        inspectorCard("Действия", systemImage: "bolt.fill") {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Open Terminal", systemImage: "terminal") {
                        onOpenTerminal(item.connection)
                    }
                    Button("Показать лог", systemImage: "doc.text") {
                        model.revealSSHTunnelLog(item.source.tunnelID)
                    }
                    .disabled(!item.hasLog)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Button("Копировать команду", systemImage: "doc.on.doc") {
                        copyCommand(item)
                    }
                    Button(
                        item.state == .running
                            ? "Reconnect SSH"
                            : (item.state == .reconnecting ? "Отменить reconnect" : "Запустить")
                    ) {
                        if item.state == .running {
                            restart(item)
                        } else if item.state == .reconnecting {
                            model.stopSSHTunnel(item.source.tunnelID)
                        } else {
                            start(item)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(item.state == .stopping)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func schemeInspector(item: ForwardingManagerItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let progress = item.reconnectProgress {
                    reconnectBanner(progress)
                } else if let error = item.lastError, item.state == .error {
                    errorBanner(error)
                }
                Text("Схема туннеля")
                    .font(.headline)
                routeDiagram(item)
                Text("Состояние Destination отмечается как неизвестное, пока runtime не выполняет отдельную проверку конечного узла.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
    }

    private func routeDiagram(_ item: ForwardingManagerItem) -> some View {
        let steps = routeSteps(item)
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    routeNode(step, state: nodeState(step.role, item: item))
                    if index < steps.count - 1 {
                        routeConnector(
                            step.connectorAfter ?? "",
                            active: item.state == .running
                        )
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private func routeNode(
        _ step: ForwardingRouteStep,
        state: ForwardingRouteNodeState
    ) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(nodeColor(state).opacity(0.12))
                Image(systemName: step.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(nodeColor(state))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                nodeStateIcon(state)
                    .padding(5)
            }
            .frame(width: 72, height: 58)

            Text(step.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(step.detail)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(width: 108)
    }

    @ViewBuilder
    private func nodeStateIcon(_ state: ForwardingRouteNodeState) -> some View {
        switch state {
        case .neutral:
            EmptyView()
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .unknown:
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func routeConnector(_ label: String, active: Bool) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 2) {
                Rectangle().frame(height: 1.5)
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
            }
            .foregroundStyle(active ? Color.green : Color.secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 52)
        .padding(.top, 19)
    }

    private func logInspector(item: ForwardingManagerItem) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("SSH tunnel log")
                    .font(.headline)
                Spacer()
                Button("Обновить", systemImage: "arrow.clockwise") {
                    refreshLog(for: item)
                }
                .controlSize(.small)
                Button("Показать в Finder", systemImage: "folder") {
                    model.revealSSHTunnelLog(item.source.tunnelID)
                }
                .controlSize(.small)
                .disabled(!item.hasLog)
            }
            .padding(18)

            Divider()

            if logText.isEmpty {
                ContentUnavailableView(
                    "Журнал пока пуст",
                    systemImage: "doc.text",
                    description: Text("После запуска здесь появится реальный вывод системного /usr/bin/ssh.")
                )
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(logText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                }
            }
        }
    }

    private func reconnectBanner(_ progress: SmartReconnectProgress) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Smart Reconnect · \(progress.attemptLabel)")
                        .font(.subheadline.bold())
                    Text(progress.reason)
                        .font(.caption)
                    if let countdown = progress.countdownText(now: context.date) {
                        Text(countdown)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
            }
        }
    }

    private func errorBanner(_ error: String) -> some View {
        Label {
            Text(error)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func inspectorCard<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.bold())
            content()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func makeSnapshot() -> ForwardingManagerSnapshot {
        var items: [ForwardingManagerItem] = []

        for profile in sshProfiles {
            for rule in profile.portForwards {
                let runtime = model.sshTunnels[rule.id]
                let isRunning = model.isProfileSSHTunnelRunning(
                    ruleID: rule.id,
                    profileID: profile.id
                )
                let state = runtimeState(
                    tunnelID: rule.id,
                    isRunning: isRunning
                )
                let jumpHost = runtime?.jumpHostDestination ?? profileJumpHost(profile)
                let proxy = effectiveProxy(
                    jumpHost: jumpHost,
                    mode: runtime?.proxyMode ?? profile.sshProxyMode,
                    host: runtime?.proxyHost ?? profile.sshProxyHost,
                    port: runtime?.proxyPort ?? profile.sshProxyPort
                )
                let identityName = runtime?.identityName ?? profile.sshIdentityID.flatMap { keyID in
                    model.sshKeys.first(where: { $0.id == keyID })?.name
                }
                items.append(
                    ForwardingManagerItem(
                        source: .profile(profileID: profile.id, ruleID: rule.id),
                        ownership: .profile,
                        profileName: profile.friendlyName,
                        connection: .savedProfile(profile.id),
                        rule: runtime?.rule ?? rule,
                        host: runtime?.host ?? profile.host,
                        username: runtime?.username ?? profile.username,
                        port: runtime?.port ?? profile.sshPort,
                        authentication: (runtime?.authenticationMode ?? profile.sshAuthenticationMode).title,
                        identityName: identityName,
                        jumpHost: jumpHost,
                        proxy: proxy,
                        state: state,
                        startedAt: runtime?.startedAt,
                        lastError: model.sshTunnelLastErrors[rule.id],
                        hasLog: model.sshTunnelLogURL(for: rule.id) != nil,
                        reconnectProgress: model.sshTunnelReconnectProgress[rule.id]
                    )
                )
            }
        }

        for tunnel in model.independentPortForwards {
            let runtime = model.sshTunnels[tunnel.id]
            let isRunning = model.isIndependentSSHTunnelRunning(tunnelID: tunnel.id)
            let resolved = independentConnectionDetails(tunnel)
            let jumpHost = runtime?.jumpHostDestination ?? resolved.jumpHost
            let proxy = effectiveProxy(
                jumpHost: jumpHost,
                mode: runtime?.proxyMode ?? resolved.proxyMode,
                host: runtime?.proxyHost ?? resolved.proxyHost,
                port: runtime?.proxyPort ?? resolved.proxyPort
            )
            let authentication: String
            if let runtime {
                authentication = runtime.authenticationMode.title
            } else if tunnel.connection.kind == .custom,
                      model.hasSavedForwardingPassword(tunnel.id) {
                authentication = "Автоматически + Keychain"
            } else {
                authentication = resolved.authentication.title
            }
            items.append(
                ForwardingManagerItem(
                    source: .independent(tunnelID: tunnel.id),
                    ownership: .independent,
                    profileName: resolved.profileName,
                    connection: tunnel.connection,
                    rule: runtime?.rule ?? tunnel.rule,
                    host: runtime?.host ?? resolved.host,
                    username: runtime?.username ?? resolved.username,
                    port: runtime?.port ?? resolved.port,
                    authentication: authentication,
                    identityName: runtime?.identityName ?? resolved.identityName,
                    jumpHost: jumpHost,
                    proxy: proxy,
                    state: runtimeState(tunnelID: tunnel.id, isRunning: isRunning),
                    startedAt: runtime?.startedAt,
                    lastError: model.sshTunnelLastErrors[tunnel.id],
                    hasLog: model.sshTunnelLogURL(for: tunnel.id) != nil,
                    reconnectProgress: model.sshTunnelReconnectProgress[tunnel.id]
                )
            )
        }

        return ForwardingManagerSnapshot(
            items: items.sorted {
                let lhsActive = $0.state == .running || $0.state == .reconnecting
                let rhsActive = $1.state == .running || $1.state == .reconnecting
                if lhsActive != rhsActive { return lhsActive }
                return $0.rule.name.localizedStandardCompare($1.rule.name) == .orderedAscending
            }
        )
    }

    private func runtimeState(tunnelID: UUID, isRunning: Bool) -> ForwardingManagerState {
        if model.isSSHTunnelStopping(tunnelID) { return .stopping }
        if model.sshTunnelReconnectProgress[tunnelID] != nil { return .reconnecting }
        if isRunning { return .running }
        if model.sshTunnelLastErrors[tunnelID]?.isEmpty == false { return .error }
        return .stopped
    }

    private func profileJumpHost(_ profile: ConnectionProfile) -> String? {
        guard let jumpID = profile.sshJumpHostProfileID,
              let jump = model.profiles.first(where: {
                  $0.id == jumpID && $0.connectionType == .ssh
              })
        else { return nil }
        let user = jump.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = user.isEmpty ? jump.host : "\(user)@\(jump.host)"
        return jump.sshPort == 22 ? destination : "\(destination):\(jump.sshPort)"
    }

    private func effectiveProxy(
        jumpHost: String?,
        mode: SSHProxyMode,
        host: String,
        port: Int
    ) -> String? {
        guard jumpHost == nil, mode != .none else { return nil }
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return "\(mode.title) · \(normalized):\(port)"
    }

    private func independentConnectionDetails(
        _ tunnel: IndependentPortForward
    ) -> (
        profileName: String,
        host: String,
        username: String,
        port: Int,
        authentication: SSHAuthenticationMode,
        identityName: String?,
        jumpHost: String?,
        proxyMode: SSHProxyMode,
        proxyHost: String,
        proxyPort: Int
    ) {
        switch tunnel.connection.kind {
        case .savedProfile:
            guard let profileID = tunnel.connection.profileID,
                  let profile = model.profiles.first(where: {
                      $0.id == profileID && $0.connectionType == .ssh
                  })
            else {
                return (
                    "Профиль недоступен", "—", "", 22, .automatic,
                    nil, nil, .none, "", 0
                )
            }
            return (
                profile.friendlyName,
                profile.host,
                profile.username,
                profile.sshPort,
                profile.sshAuthenticationMode,
                profile.sshIdentityID.flatMap { keyID in
                    model.sshKeys.first(where: { $0.id == keyID })?.name
                },
                profileJumpHost(profile),
                profile.sshProxyMode,
                profile.sshProxyHost,
                profile.sshProxyPort
            )
        case .custom:
            let name = tunnel.connection.displayLabel(profiles: sshProfiles)
            return (
                name,
                tunnel.connection.normalizedHost,
                tunnel.connection.normalizedUsername,
                tunnel.connection.port,
                .automatic,
                nil,
                nil,
                .none,
                "",
                0
            )
        }
    }

    private func filteredItems(_ items: [ForwardingManagerItem]) -> [ForwardingManagerItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            guard filter.matches(item) else { return false }
            guard !query.isEmpty else { return true }
            return item.rule.name.localizedCaseInsensitiveContains(query)
                || item.profileName.localizedCaseInsensitiveContains(query)
                || item.sshEndpoint.localizedCaseInsensitiveContains(query)
                || item.localAddress.localizedCaseInsensitiveContains(query)
                || item.destination.localizedCaseInsensitiveContains(query)
                || item.ownership.title.localizedCaseInsensitiveContains(query)
                || item.state.title.localizedCaseInsensitiveContains(query)
        }
    }

    private func selectedItem(from items: [ForwardingManagerItem]) -> ForwardingManagerItem? {
        guard let selectedItemID else { return items.first }
        return items.first(where: { $0.id == selectedItemID }) ?? items.first
    }

    private func normalizeSelection(items: [ForwardingManagerItem]) {
        if let selectedItemID,
           items.contains(where: { $0.id == selectedItemID }) {
            return
        }
        selectedItemID = items.first?.id
    }

    private func start(_ item: ForwardingManagerItem) {
        switch item.source {
        case let .profile(profileID, ruleID):
            model.startProfileSSHTunnel(ruleID: ruleID, profileID: profileID)
        case let .independent(tunnelID):
            model.startIndependentPortForward(tunnelID)
        }
    }

    private func restart(_ item: ForwardingManagerItem) {
        switch item.source {
        case let .profile(profileID, ruleID):
            model.restartProfileSSHTunnel(ruleID: ruleID, profileID: profileID)
        case let .independent(tunnelID):
            model.restartIndependentPortForward(tunnelID)
        }
    }

    private func delete(_ item: ForwardingManagerItem) {
        switch item.source {
        case let .profile(profileID, ruleID):
            model.removePortForward(ruleID, profileID: profileID)
        case let .independent(tunnelID):
            model.removeIndependentPortForward(tunnelID)
        }
    }

    private func copyCommand(_ item: ForwardingManagerItem) {
        let settings: SSHConnectionSettings?
        switch item.source {
        case let .profile(profileID, _):
            settings = model.sshConnectionSettings(profileID: profileID)
        case let .independent(tunnelID):
            guard let tunnel = model.independentPortForwards.first(where: { $0.id == tunnelID }) else {
                return
            }
            settings = model.sshConnectionSettings(
                connection: tunnel.connection,
                tabID: tunnelID
            )
        }
        guard let settings else { return }
        do {
            let command = try SSHService.tunnelCommandPreview(
                settings: settings,
                rule: item.rule
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            model.statusMessage = "Команда SSH-туннеля скопирована без секретов"
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func ruleBinding(_ item: ForwardingManagerItem) -> Binding<PortForwardRule> {
        switch item.source {
        case let .profile(profileID, ruleID):
            return Binding(
                get: {
                    model.profiles
                        .first(where: { $0.id == profileID })?
                        .portForwards.first(where: { $0.id == ruleID })
                        ?? item.rule
                },
                set: { model.updatePortForward($0, profileID: profileID) }
            )
        case let .independent(tunnelID):
            return Binding(
                get: {
                    model.independentPortForwards
                        .first(where: { $0.id == tunnelID })?.rule
                        ?? item.rule
                },
                set: { rule in
                    guard var tunnel = model.independentPortForwards.first(where: {
                        $0.id == tunnelID
                    }) else { return }
                    tunnel.rule = rule
                    tunnel.rule.id = tunnelID
                    model.updateIndependentPortForward(tunnel)
                }
            )
        }
    }

    private func passwordBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { passwordInputs[id] ?? "" },
            set: { passwordInputs[id] = $0 }
        )
    }

    private func refreshLog(for item: ForwardingManagerItem?) {
        guard let item else {
            logText = ""
            return
        }
        logText = model.sshTunnelLogExcerpt(item.source.tunnelID)
    }

    private func keepAliveText(_ item: ForwardingManagerItem) -> String {
        let seconds: Int
        switch item.connection.kind {
        case .savedProfile:
            seconds = item.connection.profileID.flatMap { profileID in
                model.profiles.first(where: { $0.id == profileID })?.sshKeepAliveSeconds
            } ?? 0
        case .custom:
            seconds = 30
        }
        return seconds > 0 ? "Каждые \(seconds) sec" : "Отключён"
    }

    private func hopCountText(_ item: ForwardingManagerItem) -> String {
        var count = 1
        if item.proxy != nil { count += 1 }
        if item.jumpHost != nil { count += 1 }
        return count == 1 ? "Direct" : "\(count) узла"
    }

    private func routeExplanation(_ kind: PortForwardKind) -> String {
        switch kind {
        case .local:
            "Local открывает порт на Mac и передаёт TCP через SSH к фиксированному назначению."
        case .remote:
            "Remote открывает порт на SSH-сервере и ведёт входящий поток обратно через SSH к назначению."
        case .dynamic:
            "Dynamic открывает локальный SOCKS-порт; фиксированного Destination у него нет."
        }
    }

    private func routeSteps(_ item: ForwardingManagerItem) -> [ForwardingRouteStep] {
        switch item.rule.kind {
        case .local:
            var steps = [
                ForwardingRouteStep(
                    id: "mac",
                    role: .localBind,
                    title: "Ваш Mac",
                    detail: item.localAddress,
                    icon: "laptopcomputer",
                    connectorAfter: item.proxy != nil ? "Proxy" : (item.jumpHost != nil ? "SSH" : "SSH")
                )
            ]
            appendTransportSteps(to: &steps, item: item)
            steps.append(
                ForwardingRouteStep(
                    id: "destination",
                    role: .destination,
                    title: "Destination",
                    detail: item.destination,
                    icon: "network",
                    connectorAfter: nil
                )
            )
            return steps

        case .remote:
            var steps = [
                ForwardingRouteStep(
                    id: "remote-bind",
                    role: .remoteBind,
                    title: "Remote port",
                    detail: item.localAddress,
                    icon: "dot.radiowaves.left.and.right",
                    connectorAfter: "listen"
                ),
                ForwardingRouteStep(
                    id: "ssh-server",
                    role: .sshServer,
                    title: "SSH Server",
                    detail: item.sshEndpoint,
                    icon: "server.rack",
                    connectorAfter: item.jumpHost != nil ? "ProxyJump" : (item.proxy != nil ? "Proxy" : "SSH")
                )
            ]
            if let jumpHost = item.jumpHost {
                steps.append(
                    ForwardingRouteStep(
                        id: "jump",
                        role: .jumpHost,
                        title: "Jump Host",
                        detail: jumpHost,
                        icon: "point.3.connected.trianglepath.dotted",
                        connectorAfter: "SSH"
                    )
                )
            } else if let proxy = item.proxy {
                steps.append(
                    ForwardingRouteStep(
                        id: "proxy",
                        role: .proxy,
                        title: "Proxy",
                        detail: proxy,
                        icon: "arrow.triangle.branch",
                        connectorAfter: "SSH"
                    )
                )
            }
            steps.append(
                ForwardingRouteStep(
                    id: "mac",
                    role: .mac,
                    title: "Ваш Mac",
                    detail: "обратный SSH-канал",
                    icon: "laptopcomputer",
                    connectorAfter: "TCP"
                )
            )
            steps.append(
                ForwardingRouteStep(
                    id: "destination",
                    role: .destination,
                    title: "Destination",
                    detail: item.destination,
                    icon: "network",
                    connectorAfter: nil
                )
            )
            return steps

        case .dynamic:
            var steps = [
                ForwardingRouteStep(
                    id: "socks",
                    role: .localBind,
                    title: "Ваш Mac / SOCKS",
                    detail: item.localAddress,
                    icon: "laptopcomputer",
                    connectorAfter: item.proxy != nil ? "Proxy" : "SSH"
                )
            ]
            appendTransportSteps(to: &steps, item: item)
            steps.append(
                ForwardingRouteStep(
                    id: "dynamic",
                    role: .dynamicDestination,
                    title: "Dynamic destination",
                    detail: "задаётся SOCKS-клиентом",
                    icon: "globe",
                    connectorAfter: nil
                )
            )
            return steps
        }
    }

    private func appendTransportSteps(
        to steps: inout [ForwardingRouteStep],
        item: ForwardingManagerItem
    ) {
        if let proxy = item.proxy {
            steps.append(
                ForwardingRouteStep(
                    id: "proxy",
                    role: .proxy,
                    title: "Proxy",
                    detail: proxy,
                    icon: "arrow.triangle.branch",
                    connectorAfter: "SSH"
                )
            )
        }
        if let jumpHost = item.jumpHost {
            steps.append(
                ForwardingRouteStep(
                    id: "jump",
                    role: .jumpHost,
                    title: "Jump Host",
                    detail: jumpHost,
                    icon: "point.3.connected.trianglepath.dotted",
                    connectorAfter: "ProxyJump"
                )
            )
        }
        steps.append(
            ForwardingRouteStep(
                id: "ssh-server",
                role: .sshServer,
                title: "SSH Server",
                detail: item.sshEndpoint,
                icon: "server.rack",
                connectorAfter: item.rule.kind == .dynamic ? "SOCKS" : "TCP"
            )
        )
    }

    private func nodeState(
        _ role: ForwardingRouteNodeRole,
        item: ForwardingManagerItem
    ) -> ForwardingRouteNodeState {
        if item.state == .running {
            switch role {
            case .destination, .dynamicDestination:
                return .unknown
            default:
                return .ok
            }
        }
        guard item.state == .error else { return .neutral }
        switch ForwardingFailureStage.classify(item.lastError) {
        case .localBind:
            return role == .localBind || role == .remoteBind ? .failed : .neutral
        case .proxy:
            return role == .proxy ? .failed : .neutral
        case .jumpHost:
            return role == .jumpHost ? .failed : .neutral
        case .authentication, .sshServer:
            return role == .sshServer ? .failed : .neutral
        case .unknown:
            return .neutral
        }
    }

    private func nodeColor(_ state: ForwardingRouteNodeState) -> Color {
        switch state {
        case .neutral, .unknown: .accentColor
        case .ok: .green
        case .failed: .red
        }
    }
}
