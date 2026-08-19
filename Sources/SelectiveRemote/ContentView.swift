import SwiftUI

private enum ProfileTab: String, CaseIterable, Identifiable {
    case general = "Основные"
    case authentication = "Аутентификация"
    case route = "Маршрут"
    case display = "Дисплеи"
    case devices = "Устройства и звук"
    case folders = "Папки"
    case terminal = "Терминал"
    case sftp = "SFTP"
    case forwarding = "Туннели"
    case security = "Безопасность"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .authentication: "key.viewfinder"
        case .route: "point.3.connected.trianglepath.dotted"
        case .display: "display.2"
        case .devices: "headphones"
        case .folders: "folder"
        case .terminal: "terminal"
        case .sftp: "folder.badge.gearshape"
        case .forwarding: "arrow.left.arrow.right"
        case .security: "lock.shield"
        }
    }
}

private enum MainArea: String, CaseIterable, Identifiable {
    case connectionCenter = "Connection Center"
    case connections = "Подключения"
    case terminal = "Терминал"
    case sftp = "SFTP"
    case forwarding = "Forwarding"
    case diagnostics = "Диагностика"
    case keychain = "Keychain"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .connectionCenter: "point.3.connected.trianglepath.dotted"
        case .connections: "rectangle.stack"
        case .terminal: "terminal"
        case .sftp: "folder.badge.gearshape"
        case .diagnostics: "stethoscope"
        case .keychain: "key.viewfinder"
        case .forwarding: "arrow.left.arrow.right"
        }
    }
}

struct ContentView: View {
    private static let globalSFTPScopeID = UUID(
        uuidString: "9C99721B-CFF3-48B7-A0A4-22E627A7D56C"
    )!

    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var terminalAppearance = TerminalAppearanceStore()
    @StateObject private var appAppearance = AppAppearanceStore()
    @State private var selectedTab = ProfileTab.general
    @State private var profileTabs: [UUID: ProfileTab] = [:]
    @State private var mainArea = MainArea.connectionCenter
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var terminalFocusMode = false
    @State private var showsCaptureDiagnostics = false
    @State private var showsSSHKeyGenerator = false
    @State private var showsSSHDiagnostics = false
    @State private var showsAppearanceSettings = false
    @State private var showsUpdatePopover = false
    @State private var showsGlobalSFTPConnectionEditor = false
    @State private var globalSFTPConnection: TerminalTabConnection?

    private var profile: ConnectionProfile { model.selectedProfile }
    private var profileBinding: Binding<ConnectionProfile> {
        Binding(
            get: { model.selectedProfile },
            set: { model.updateSelectedProfile($0) }
        )
    }
    private var availableTabs: [ProfileTab] {
        switch profile.connectionType {
        case .rdp:
            [.general, .display, .devices, .folders, .security]
        case .ssh:
            [.general, .authentication, .route, .terminal, .sftp, .forwarding, .security]
        }
    }
    private var cameraSelectionBinding: Binding<String> {
        Binding(
            get: { model.cameraSelectionToken },
            set: { model.setCameraSelectionToken($0) }
        )
    }
    private var rdpWindowModeBinding: Binding<RDPWindowMode> {
        Binding(
            get: { profile.rdpWindowMode },
            set: { mode in
                model.mutateSelectedProfile {
                    $0.rdpWindowMode = mode
                    $0.startFullScreen = mode == .fullScreen
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 265, ideal: 300, max: 350)
        } detail: {
            detail
        }
        .background {
            AppWindowBackdrop(appearance: appAppearance.snapshot)
                .ignoresSafeArea()
        }
        .preferredColorScheme(appAppearance.theme.colorScheme)
        .appTextSize(appAppearance.textSize)
        .controlSize(appAppearance.density.controlSize)
        .tint(.accentColor)
        .alert("Ошибка", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
            if model.sessionLogURL != nil {
                Button("Показать журнал") { model.revealSessionLog() }
            }
        } message: {
            Text(model.errorMessage ?? "Неизвестная ошибка")
        }
        .alert("Обновления \(AppBrand.name)", isPresented: Binding(
            get: { model.updateMessage != nil },
            set: { if !$0 { model.updateMessage = nil } }
        )) {
            if model.availableUpdateURL != nil {
                Button("Скачать DMG") { model.openAvailableUpdate() }
            }
            if model.availableUpdateManifest != nil {
                Button("Что нового") { model.openAvailableReleaseNotes() }
            }
            Button("OK", role: .cancel) { model.updateMessage = nil }
        } message: {
            Text(model.updateMessage ?? "")
        }
        .alert(
            UpdateLocalization.text(
                ru: "Проверка после обновления",
                en: "Post-Update Check"
            ),
            isPresented: Binding(
                get: { model.postUpgradeHealthWarning != nil },
                set: {
                    if !$0 {
                        model.postUpgradeHealthWarning = nil
                    }
                }
            )
        ) {
            Button(UpdateLocalization.text(
                ru: "Открыть диагностику",
                en: "Open Diagnostics"
            )) {
                model.postUpgradeHealthWarning = nil
                setMainArea(.diagnostics)
            }
            Button("OK", role: .cancel) {
                model.postUpgradeHealthWarning = nil
            }
        } message: {
            Text(model.postUpgradeHealthWarning ?? "")
        }
        .sheet(isPresented: $model.quickConnectPresented) {
            QuickConnectView(
                onOpenProfile: { profileID, action in
                    model.selectProfile(profileID)
                    switch action {
                    case .terminal:
                        setMainArea(.connections)
                        selectedTab = .terminal
                    case .sftp:
                        setMainArea(.connections)
                        selectedTab = .sftp
                    case .connect:
                        setMainArea(.connections)
                        model.connect()
                    }
                },
                onOpenSSH: openQuickConnectSSH
            )
            .environmentObject(model)
        }
        .sheet(isPresented: $showsCaptureDiagnostics) {
            CaptureDiagnosticsView(
                cameraSelectionMode: profile.cameraSelectionMode,
                selectedCameraID: profile.cameraDeviceID,
                cameraSelectionDescription: model.cameraSelectionDescription,
                cameraQuality: profile.cameraQuality,
                cameraCount: model.cameras.count,
                redirectsCamera: profile.redirectCamera,
                redirectsMicrophone: profile.redirectMicrophone
            )
        }
        .sheet(isPresented: $showsSSHDiagnostics) {
            SSHDiagnosticsView(
                profile: profile,
                identity: model.selectedSSHKey,
                jumpHost: profile.sshJumpHostProfileID.flatMap { jumpID in
                    model.profiles.first(where: { $0.id == jumpID })
                }
            )
        }
        .sheet(isPresented: $showsSSHKeyGenerator) {
            SSHKeyGenerationView(
                touchIDPreset: profileBinding.wrappedValue.sshAuthenticationMode == .touchIDKey
            ) { request, session in
                model.generateSSHKey(request, session: session)
            }
        }
        .sheet(isPresented: $showsGlobalSFTPConnectionEditor) {
            TerminalConnectionEditor(
                profiles: sortedSSHProfiles,
                initialConnection: globalSFTPConnection
                    ?? sortedSSHProfiles.first.map {
                        .savedProfile($0.id)
                    }
                    ?? .custom(host: "", username: ""),
                allowsInteractivePassword: true,
                actionTitle: "Подключить SFTP",
                heading: "Подключение SFTP",
                message: "Выберите сохранённый сервер или укажите временный SFTP-адрес. "
                    + "При необходимости пароль будет запрошен отдельным системным окном.",
                customAuthenticationMessage: "SFTP использует системный ssh-agent и ~/.ssh/config. "
                    + "Если ключа или активной SSH-сессии нет, пароль будет запрошен "
                    + "в отдельном защищённом окне и не будет сохранён.",
                onSave: { connection, _, temporaryPassword in
                    globalSFTPConnection = connection
                    connectGlobalSFTP(connection, temporaryPassword: temporaryPassword)
                }
            )
        }
        .onAppear {
            selectedTab = restoredProfileTab(for: profile.id)
            profileTabs[profile.id] = selectedTab
        }
        .onChange(of: profile.id) { oldProfileID, newProfileID in
            setTerminalFocusMode(false)
            profileTabs[oldProfileID] = selectedTab
            selectedTab = restoredProfileTab(for: newProfileID)
        }
        .onChange(of: profile.connectionType) { _, _ in
            if !availableTabs.contains(selectedTab) {
                selectedTab = .general
            }
        }
        .onChange(of: selectedTab) { _, tab in
            profileTabs[profile.id] = tab
            UserDefaults.standard.set(
                tab.rawValue,
                forKey: profileTabStorageKey(profileID: profile.id)
            )
            if tab != .terminal {
                setTerminalFocusMode(false)
            }
        }
        .onChange(of: model.requestedSSHConsoleProfileID) { _, profileID in
            guard profileID == profile.id else { return }
            mainArea = .connections
            selectedTab = .terminal
            model.consumeSSHConsoleNavigationRequest()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.12, green: 0.62, blue: 0.78),
                                        Color(red: 0.25, green: 0.35, blue: 0.88)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "network")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 42, height: 42)
                    .shadow(color: Color.blue.opacity(0.22), radius: 8, y: 4)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppBrand.name)
                            .font(.title3.bold())
                            .lineLimit(1)
                        Text("\(AppBrand.tagline) · \(AppBuildInfo.displayText)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 6)
                    Button {
                        showsAppearanceSettings.toggle()
                    } label: {
                        Image(systemName: "paintpalette")
                    }
                    .buttonStyle(.borderless)
                    // This is an auxiliary mouse action, not the primary action of
                    // the window. Excluding it from the key-view loop prevents
                    // macOS from painting it as selected immediately after launch.
                    .focusable(false)
                    .help("Оформление приложения и терминала")
                    .popover(isPresented: $showsAppearanceSettings, arrowEdge: .top) {
                        TerminalAppearanceView(
                            store: terminalAppearance,
                            appAppearance: appAppearance
                        )
                    }
                }

                if model.availableUpdateManifest != nil ||
                    model.runningSessionCount > 0 ||
                    model.runningSSHTunnelCount > 0 {
                    HStack(spacing: 8) {
                        if let manifest = model.availableUpdateManifest {
                            Button {
                                showsUpdatePopover.toggle()
                            } label: {
                                Label {
                                    Text("Обновление \(manifest.version)")
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                } icon: {
                                    Image(systemName: "arrow.down.circle.fill")
                                }
                                .font(.caption.bold())
                                .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.borderless)
                            .focusable(false)
                            .layoutPriority(1)
                            .help("Доступно обновление \(manifest.version)")
                            .popover(isPresented: $showsUpdatePopover, arrowEdge: .top) {
                                UpdateExperiencePopover(model: model)
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            .animation(
                                reduceMotion ? nil : .easeInOut(duration: 0.2),
                                value: manifest.version
                            )
                        }
                        Spacer(minLength: 4)
                        if model.runningSessionCount > 0 {
                            Label("\(model.runningSessionCount)", systemImage: "bolt.fill")
                                .font(.caption.bold())
                                .foregroundStyle(Color.green)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.green.opacity(0.12), in: Capsule())
                                .fixedSize(horizontal: true, vertical: false)
                                .help("Активных RDP-сессий: \(model.runningSessionCount)")
                        }
                        if model.runningSSHTunnelCount > 0 {
                            Label(
                                "\(model.runningSSHTunnelCount)",
                                systemImage: "arrow.left.arrow.right"
                            )
                            .font(.caption.bold())
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                            .fixedSize(horizontal: true, vertical: false)
                            .help("Активных SSH-туннелей: \(model.runningSSHTunnelCount)")
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 16)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Поиск", text: $model.searchText)
                    .textFieldStyle(.plain)
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            VStack(spacing: 5) {
                ForEach(MainArea.allCases) { area in
                    Button {
                        setMainArea(area)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: area.systemImage)
                                .frame(width: 22)
                            Text(LocalizedStringKey(area.rawValue))
                            Spacer()
                            if area == .terminal,
                               model.globalTerminalWorkspace().runningSessionCount > 0 {
                                Text("\(model.globalTerminalWorkspace().runningSessionCount)")
                                    .font(.caption.bold())
                                    .foregroundStyle(.green)
                            }
                            if area == .sftp,
                               model.globalSFTPSession.settings != nil {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.green)
                            }
                            if area == .forwarding,
                               model.runningIndependentSSHTunnelCount > 0 {
                                Text("\(model.runningIndependentSSHTunnelCount)")
                                    .font(.caption.bold())
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        mainArea == area
                            ? Color.accentColor.opacity(0.18)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            List(selection: Binding(
                get: { model.selectedProfileID },
                set: {
                    if let id = $0 {
                        model.selectProfile(id)
                        setMainArea(.connections)
                    }
                }
            )) {
                ForEach(model.profileGroups) { group in
                    Section(group.name) {
                        ForEach(group.profiles) { item in
                            ProfileRow(
                                profile: item,
                                session: model.sessions[item.id],
                                hasActiveSSH: model.isSSHTerminalRunning(profileID: item.id),
                                activeTunnelCount: model.sshTunnels.values.filter {
                                    $0.profileID == item.id
                                }.count
                            )
                                .tag(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selectProfile(item.id)
                                    setMainArea(.connections)
                                }
                                .contextMenu {
                                    if model.isSessionRunning(profileID: item.id)
                                        || model.isSSHTerminalRunning(profileID: item.id) {
                                        Button("Отключить", systemImage: "stop.fill", role: .destructive) {
                                            model.disconnect(profileID: item.id)
                                        }
                                    } else {
                                        Button(
                                            item.connectionType == .ssh ? "Подключить SSH" : "Подключить RDP",
                                            systemImage: item.connectionType == .ssh ? "terminal" : "play.fill"
                                        ) {
                                            model.selectProfile(item.id)
                                            setMainArea(.connections)
                                            if item.connectionType == .ssh {
                                                selectedTab = .terminal
                                            }
                                            model.connect()
                                        }
                                    }

                                    if item.connectionType == .ssh {
                                        Button("Открыть терминал", systemImage: "terminal") {
                                            model.selectProfile(item.id)
                                            setMainArea(.connections)
                                            selectedTab = .terminal
                                        }
                                        Button("Открыть SFTP", systemImage: "folder.badge.gearshape") {
                                            model.selectProfile(item.id)
                                            setMainArea(.connections)
                                            selectedTab = .sftp
                                        }
                                        Button("Открыть туннели", systemImage: "arrow.left.arrow.right") {
                                            model.selectProfile(item.id)
                                            setMainArea(.connections)
                                            selectedTab = .forwarding
                                        }
                                    }

                                    Divider()
                                    Button(
                                        item.isFavorite ? "Убрать из избранного" : "В избранное",
                                        systemImage: item.isFavorite ? "star.slash" : "star"
                                    ) {
                                        model.toggleFavorite(profileID: item.id)
                                    }
                                    Menu("Переместить в группу", systemImage: "folder") {
                                        Button("Без группы") {
                                            model.setProfileGroup(profileID: item.id, group: "")
                                        }
                                        if !model.profileGroupNames.isEmpty { Divider() }
                                        ForEach(model.profileGroupNames, id: \.self) { groupName in
                                            Button(groupName) {
                                                model.setProfileGroup(profileID: item.id, group: groupName)
                                            }
                                        }
                                    }
                                    Button("Создать копию", systemImage: "doc.on.doc") {
                                        model.selectProfile(item.id)
                                        model.duplicateSelectedProfile()
                                    }
                                    Divider()
                                    Button("Удалить", systemImage: "trash", role: .destructive) {
                                        model.selectProfile(item.id)
                                        model.deleteSelectedProfile()
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            HStack(spacing: 9) {
                Menu {
                    Button("Новое RDP", systemImage: "desktopcomputer") {
                        model.addProfile(connectionType: .rdp)
                    }
                    Button("Новое SSH", systemImage: "terminal") {
                        model.addProfile(connectionType: .ssh)
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .help("Новое подключение")
                Button { model.duplicateSelectedProfile() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Создать копию")
                Button { model.deleteSelectedProfile() } label: { Image(systemName: "trash") }
                    .help("Удалить")

                Spacer()

                Menu {
                    Button("Импортировать…", systemImage: "square.and.arrow.down") {
                        model.importProfiles()
                    }
                    Divider()
                    Button("Все профили \(AppBrand.name)…", systemImage: "archivebox") {
                        model.exportAllProfiles()
                    }
                    Button("Выбранный профиль как .rdp…", systemImage: "doc") {
                        model.exportSelectedRDP()
                    }
                    .disabled(profile.connectionType != .rdp)
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .help("Импорт и экспорт без паролей и SSH-ключей")

                Menu {
                    Picker("Сортировка", selection: $model.profileSortMode) {
                        ForEach(ProfileSortMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.title)).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .help("Сортировка подключений")
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(width: 1)
        }
    }

    private var detail: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.52, blue: 0.72).opacity(0.08),
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            switch mainArea {
            case .connectionCenter:
                connectionCenterDetail
            case .connections:
                profileDetail
            case .terminal:
                globalTerminalDetail
            case .sftp:
                globalSFTPDetail
            case .diagnostics:
                DiagnosticsCenterView(model: model)
            case .keychain:
                credentialVaultDetail
            case .forwarding:
                ForwardingManagerView(
                    model: model,
                    onOpenTerminal: openForwardingTerminal,
                    onOpenProfile: openForwardingProfile
                )
            }
        }
    }

    private var connectionCenterDetail: some View {
        ConnectionCenterView(
            model: model,
            sftpWorkspace: model.sftpWorkspace,
            onOpen: openConnectionCenterSource,
            onReconnect: model.reconnectConnectionCenterSource,
            onDisconnect: model.disconnectConnectionCenterSource,
            onRefresh: model.refreshConnectionCenterRuntimeState
        )
    }

    private var profileDetail: some View {
        Group {
            if profile.connectionType == .rdp {
                rdpProfileWorkspace
            } else {
                sshProfileWorkspace
            }
        }
    }

    private var sshProfileWorkspace: some View {
        VStack(spacing: 0) {
            if sshWorkspaceTabs.contains(selectedTab) {
                sshRuntimeWorkspace
            } else {
                GeometryReader { proxy in
                    VStack(alignment: .leading, spacing: 18) {
                        sshWorkspaceHeader

                        HStack(alignment: .top, spacing: 16) {
                            sshSectionRail
                                .frame(width: 205)

                            ScrollView {
                                VStack(alignment: .leading, spacing: 18) {
                                    sshSectionHeading
                                    sshQuickFacts
                                    selectedSettingsContent
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, 20)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if proxy.size.width >= 1120 {
                                sshProfileInspector
                                    .frame(width: 270)
                            }
                        }
                        .frame(maxWidth: 1380, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }

                connectionBar
            }
        }
        .groupBoxStyle(ModernGroupBoxStyle())
        .controlSize(.large)
    }

    private var sshWorkspaceTabs: [ProfileTab] {
        [.terminal, .sftp, .forwarding]
    }

    private var sshRuntimeWorkspace: some View {
        VStack(spacing: 0) {
            if !terminalFocusMode {
                sshCompactWorkspaceHeader
            } else if selectedTab != .terminal {
                focusExitBar
            }

            sshRuntimeContent
                .padding(.horizontal, terminalFocusMode ? 10 : 18)
                .padding(.top, terminalFocusMode ? 4 : 0)
                .padding(.bottom, terminalFocusMode ? 10 : 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var focusExitBar: some View {
        HStack {
            Spacer()
            Button {
                setTerminalFocusMode(false)
            } label: {
                Label(
                    UpdateLocalization.text(ru: "Выйти из фокуса", en: "Exit Focus"),
                    systemImage: "arrow.down.right.and.arrow.up.left"
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var sshRuntimeContent: some View {
        switch selectedTab {
        case .terminal:
            terminalPanel
                .id(profile.id)
        case .sftp:
            SFTPWorkspaceView(workspace: model.sftpWorkspace)
                .task(id: profile.id) {
                    // Manual requests from Terminal Smart Links or "Open SFTP"
                    // must win over the default profile request.
                    if model.sftpWorkspace.pendingOpenRequest == nil {
                        model.sftpWorkspace.requestOpen(
                            connection: .savedProfile(profile.id),
                            path: nil
                        )
                    }
                }
                .layoutPriority(1)
        case .forwarding:
            PortForwardingView(profile: profile)
                .layoutPriority(1)
        default:
            EmptyView()
        }
    }

    private var sshCompactWorkspaceHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.indigo, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "terminal.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(profile.friendlyName.isEmpty ? "SSH" : profile.friendlyName)
                        .font(.headline)
                        .lineLimit(1)
                    Text("SSH")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.indigo)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.10), in: Capsule())
                }
                Text(sshEndpointLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)
            sshWorkspaceSwitcher

            Button {
                selectedTab = .general
            } label: {
                Label(
                    UpdateLocalization.text(ru: "Настройки", en: "Settings"),
                    systemImage: "slider.horizontal.3"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help(UpdateLocalization.text(ru: "Настройки профиля", en: "Profile Settings"))

            Button {
                setTerminalFocusMode(true)
            } label: {
                Label(
                    UpdateLocalization.text(ru: "Фокус", en: "Focus"),
                    systemImage: "arrow.up.left.and.arrow.down.right"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help(
                UpdateLocalization.text(
                    ru: "Скрыть навигацию и отдать рабочей области максимум места",
                    en: "Hide navigation and maximize the workspace"
                )
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }

    private var sshWorkspaceSwitcher: some View {
        Picker(
            UpdateLocalization.text(ru: "Рабочая область", en: "Workspace"),
            selection: $selectedTab
        ) {
            ForEach(sshWorkspaceTabs) { tab in
                Label(rdpTabTitle(tab), systemImage: tab.systemImage)
                    .tag(tab)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 300)
    }

    private var sshWorkspaceHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.indigo, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "terminal.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)
            .shadow(color: Color.indigo.opacity(0.20), radius: 9, y: 4)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(
                        profile.friendlyName.isEmpty
                            ? UpdateLocalization.text(
                                ru: "Новое SSH-подключение",
                                en: "New SSH connection"
                            )
                            : profile.friendlyName
                    )
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .lineLimit(1)

                    Text("SSH")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.indigo)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.indigo.opacity(0.10), in: Capsule())
                }

                HStack(spacing: 9) {
                    Label(sshEndpointLabel, systemImage: "network")

                    Label(
                        profile.sshAuthenticationMode.title,
                        systemImage: profile.sshAuthenticationMode.systemImage
                    )

                    if sshJumpHostProfile != nil {
                        Label("Jump Host", systemImage: "server.rack")
                    }

                    if model.selectedProfileHasActiveTunnels {
                        Label(
                            UpdateLocalization.text(ru: "Туннель активен", en: "Tunnel active"),
                            systemImage: "arrow.left.arrow.right"
                        )
                        .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button { model.toggleFavorite() } label: {
                Image(systemName: profile.isFavorite ? "star.fill" : "star")
            }
            .buttonStyle(.bordered)
            .help(UpdateLocalization.text(ru: "Избранное", en: "Favorite"))
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075))
        }
    }

    private var sshSectionRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UpdateLocalization.text(ru: "НАСТРОЙКА И РАБОТА", en: "SETTINGS & WORK"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)

            ForEach(availableTabs) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.systemImage)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(rdpTabTitle(tab))
                                .font(.subheadline.weight(.semibold))
                            Text(rdpTabSubtitle(tab))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        if selectedTab == tab {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                        }
                    }
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    selectedTab == tab ? Color.accentColor.opacity(0.11) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 7) {
                Label(
                    UpdateLocalization.text(ru: "Автосохранение", en: "Auto Save"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)

                Text(
                    UpdateLocalization.text(
                        ru: "Настройки применяются при следующем подключении.",
                        en: "Settings apply to the next connection."
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.065))
        }
    }

    private var sshSectionHeading: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                Image(systemName: selectedTab.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(rdpTabTitle(selectedTab))
                    .font(.title2.bold())
                Text(rdpTabDescription(selectedTab))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var sshQuickFacts: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 155), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            rdpFactCard(
                UpdateLocalization.text(ru: "SSH-сервер", en: "SSH server"),
                value: profile.host.isEmpty ? "—" : profile.host,
                systemImage: "server.rack"
            )
            rdpFactCard(
                UpdateLocalization.text(ru: "Пользователь", en: "User"),
                value: profile.username.isEmpty ? "—" : profile.username,
                systemImage: "person"
            )
            rdpFactCard(
                UpdateLocalization.text(ru: "Порт", en: "Port"),
                value: "\(profile.sshPort)",
                systemImage: "number"
            )
            rdpFactCard(
                UpdateLocalization.text(ru: "Маршрут", en: "Route"),
                value: sshJumpHostProfile.map {
                    $0.friendlyName.isEmpty
                        ? ($0.host.isEmpty ? "Jump Host" : $0.host)
                        : $0.friendlyName
                } ?? UpdateLocalization.text(ru: "Прямое", en: "Direct"),
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        }
    }

    private var sshProfileInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(UpdateLocalization.text(ru: "Сводка", en: "Summary"))
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(model.canConnect ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
            }

            VStack(spacing: 8) {
                rdpRouteNode(
                    title: UpdateLocalization.text(ru: "Ваш Mac", en: "Your Mac"),
                    subtitle: "Selective Remote",
                    systemImage: "macbook"
                )
                Image(systemName: "arrow.down")
                    .foregroundStyle(.secondary)

                if let jump = sshJumpHostProfile {
                    rdpRouteNode(
                        title: jump.friendlyName.isEmpty ? "Jump Host" : jump.friendlyName,
                        subtitle: sshEndpointLabel(for: jump),
                        systemImage: "server.rack"
                    )
                    Image(systemName: "arrow.down")
                        .foregroundStyle(.secondary)
                }

                rdpRouteNode(
                    title: profile.friendlyName.isEmpty ? "SSH" : profile.friendlyName,
                    subtitle: sshEndpointLabel,
                    systemImage: "terminal"
                )
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 13))

            Divider()

            rdpSummaryLine(
                UpdateLocalization.text(ru: "Аутентификация", en: "Authentication"),
                value: profile.sshAuthenticationMode.title
            )
            rdpSummaryLine(
                UpdateLocalization.text(ru: "Host key", en: "Host key"),
                value: profile.sshHostKeyPolicy.title
            )
            rdpSummaryLine(
                UpdateLocalization.text(ru: "Keepalive", en: "Keepalive"),
                value: "\(profile.sshKeepAliveSeconds) s"
            )
            rdpSummaryLine(
                UpdateLocalization.text(ru: "Сжатие", en: "Compression"),
                value: profile.sshCompression
                    ? UpdateLocalization.text(ru: "Вкл.", en: "On")
                    : UpdateLocalization.text(ru: "Выкл.", en: "Off")
            )

            Divider()

            Text(UpdateLocalization.text(ru: "Рабочие области", en: "Workspaces"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            sshWorkspaceSummaryRow(
                .terminal,
                status: model.isSelectedSSHTerminalRunning
                    ? UpdateLocalization.text(ru: "Активен", en: "Active")
                    : UpdateLocalization.text(ru: "Готов", en: "Ready")
            )
            sshWorkspaceSummaryRow(
                .sftp,
                status: selectedProfileSFTPWorkspaceConnected
                    ? UpdateLocalization.text(ru: "Подключён", en: "Connected")
                    : UpdateLocalization.text(ru: "Готов", en: "Ready")
            )
            sshWorkspaceSummaryRow(
                .forwarding,
                status: model.selectedProfileHasActiveTunnels
                    ? UpdateLocalization.text(ru: "Активны", en: "Active")
                    : UpdateLocalization.text(ru: "Готов", en: "Ready")
            )

            Spacer(minLength: 0)
        }
        .padding(15)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.065))
        }
    }

    private func sshWorkspaceSummaryRow(_ tab: ProfileTab, status: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage)
                    .frame(width: 18)
                Text(rdpTabTitle(tab))
                    .font(.caption)
                Spacer()
                Text(status)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sshJumpHostProfile: ConnectionProfile? {
        guard let jumpID = profile.sshJumpHostProfileID else { return nil }
        return model.profiles.first(where: { $0.id == jumpID })
    }

    private var sshEndpointLabel: String {
        sshEndpointLabel(for: profile)
    }

    private var selectedProfileSFTPWorkspaceConnected: Bool {
        model.sftpWorkspace.tabs.contains { tab in
            [tab.left, tab.right].contains { pane in
                pane.kind == .remote
                    && pane.connection?.profileID == profile.id
                    && pane.isReady
            }
        }
    }

    private func sshEndpointLabel(for profile: ConnectionProfile) -> String {
        let host = profile.host.isEmpty
            ? UpdateLocalization.text(ru: "сервер не указан", en: "server not set")
            : profile.host
        let endpoint = "\(host):\(profile.sshPort)"
        return profile.username.isEmpty ? endpoint : "\(profile.username)@\(endpoint)"
    }


    private var rdpProfileWorkspace: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 18) {
                    rdpWorkspaceHeader

                    HStack(alignment: .top, spacing: 16) {
                        rdpSectionRail
                            .frame(width: 205)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                rdpSectionHeading
                                rdpQuickFacts
                                selectedSettingsContent
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 20)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if proxy.size.width >= 1120 {
                            rdpProfileInspector
                                .frame(width: 270)
                        }
                    }
                    .frame(maxWidth: 1380, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            connectionBar
        }
        .groupBoxStyle(ModernGroupBoxStyle())
        .controlSize(.large)
    }

    private var rdpWorkspaceHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)
            .shadow(color: Color.blue.opacity(0.20), radius: 9, y: 4)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(
                        profile.friendlyName.isEmpty
                            ? UpdateLocalization.text(
                                ru: "Новое RDP-подключение",
                                en: "New RDP connection"
                            )
                            : profile.friendlyName
                    )
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .lineLimit(1)

                    Text("RDP")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.10), in: Capsule())
                }

                HStack(spacing: 9) {
                    Label(
                        profile.host.isEmpty
                            ? UpdateLocalization.text(
                                ru: "Компьютер не указан",
                                en: "Computer not set"
                            )
                            : profile.host,
                        systemImage: "network"
                    )

                    if model.selectedProfileHasSavedPassword {
                        Label(
                            UpdateLocalization.text(
                                ru: "Пароль в Keychain",
                                en: "Password in Keychain"
                            ),
                            systemImage: "key.fill"
                        )
                        .foregroundStyle(.green)
                    }

                    if !profile.gatewayHost.isEmpty {
                        Label("RD Gateway", systemImage: "building.2")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button { model.toggleFavorite() } label: {
                Image(systemName: profile.isFavorite ? "star.fill" : "star")
            }
            .buttonStyle(.bordered)
            .help(UpdateLocalization.text(ru: "Избранное", en: "Favorite"))
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075))
        }
    }

    private var rdpSectionRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UpdateLocalization.text(ru: "НАСТРОЙКА", en: "SETTINGS"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)

            ForEach(availableTabs) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.systemImage)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(rdpTabTitle(tab))
                                .font(.subheadline.weight(.semibold))
                            Text(rdpTabSubtitle(tab))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        if selectedTab == tab {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                        }
                    }
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    selectedTab == tab ? Color.accentColor.opacity(0.11) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 7) {
                Label(
                    UpdateLocalization.text(ru: "Автосохранение", en: "Auto Save"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)

                Text(
                    UpdateLocalization.text(
                        ru: "Изменения профиля сохраняются сразу.",
                        en: "Profile changes are saved immediately."
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.065))
        }
    }

    private var rdpSectionHeading: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                Image(systemName: selectedTab.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(rdpTabTitle(selectedTab))
                    .font(.title2.bold())
                Text(rdpTabDescription(selectedTab))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var rdpQuickFacts: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 155), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            rdpFactCard(
                UpdateLocalization.text(ru: "Компьютер", en: "Computer"),
                value: profile.host.isEmpty ? "—" : profile.host,
                systemImage: "desktopcomputer"
            )
            rdpFactCard(
                UpdateLocalization.text(ru: "Пользователь", en: "User"),
                value: profile.username.isEmpty ? "—" : profile.username,
                systemImage: "person"
            )
            rdpFactCard(
                UpdateLocalization.text(ru: "Мониторы", en: "Displays"),
                value: "\(model.effectiveSelectedDisplayIDs.count)",
                systemImage: "display.2"
            )
            rdpFactCard(
                "Gateway",
                value: profile.gatewayHost.isEmpty
                    ? UpdateLocalization.text(ru: "Прямое", en: "Direct")
                    : profile.gatewayHost,
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        }
    }

    private func rdpFactCard(
        _ title: String,
        value: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.055))
        }
    }

    private var rdpProfileInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(UpdateLocalization.text(ru: "Сводка", en: "Summary"))
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(
                        model.canConnect || model.isSelectedSessionRunning
                            ? Color.green
                            : Color.orange
                    )
                    .frame(width: 8, height: 8)
            }

            VStack(spacing: 8) {
                rdpRouteNode(
                    title: UpdateLocalization.text(ru: "Ваш Mac", en: "Your Mac"),
                    subtitle: "Selective Remote",
                    systemImage: "macbook"
                )
                Image(systemName: "arrow.down")
                    .foregroundStyle(.secondary)

                if !profile.gatewayHost.isEmpty {
                    rdpRouteNode(
                        title: "RD Gateway",
                        subtitle: profile.gatewayHost,
                        systemImage: "building.2"
                    )
                    Image(systemName: "arrow.down")
                        .foregroundStyle(.secondary)
                }

                rdpRouteNode(
                    title: "Windows",
                    subtitle: profile.host.isEmpty ? "—" : profile.host,
                    systemImage: "desktopcomputer"
                )
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 13)
            )

            Divider()

            rdpSummaryLine(
                UpdateLocalization.text(ru: "Режим окна", en: "Window mode"),
                value: profile.rdpWindowMode.title
            )
            rdpSummaryLine(
                UpdateLocalization.text(ru: "Масштаб", en: "Scale"),
                value: profile.windowsScale.title
            )
            rdpSummaryLine(
                UpdateLocalization.text(ru: "Качество", en: "Quality"),
                value: profile.rdpQuality.title
            )
            rdpSummaryLine(
                UpdateLocalization.text(ru: "Мониторы", en: "Displays"),
                value: "\(model.effectiveSelectedDisplayIDs.count)"
            )

            Divider()

            Text(UpdateLocalization.text(ru: "Перенаправления", en: "Redirection"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            rdpFeatureRow(
                UpdateLocalization.text(ru: "Микрофон", en: "Microphone"),
                enabled: profile.redirectMicrophone,
                systemImage: "mic"
            )
            rdpFeatureRow(
                UpdateLocalization.text(ru: "Камера", en: "Camera"),
                enabled: profile.redirectCamera,
                systemImage: "video"
            )
            rdpFeatureRow(
                UpdateLocalization.text(ru: "Принтеры", en: "Printers"),
                enabled: profile.redirectPrinters,
                systemImage: "printer"
            )

            Spacer(minLength: 0)
        }
        .padding(15)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.065))
        }
    }

    private func rdpRouteNode(
        title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.accentColor.opacity(0.10))
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private func rdpSummaryLine(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private func rdpFeatureRow(
        _ title: String,
        enabled: Bool,
        systemImage: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(enabled ? Color.green : Color.secondary)
            Text(title)
                .font(.caption)
            Spacer()
            Text(
                enabled
                    ? UpdateLocalization.text(ru: "Вкл.", en: "On")
                    : UpdateLocalization.text(ru: "Выкл.", en: "Off")
            )
            .font(.caption2.weight(.semibold))
            .foregroundStyle(enabled ? Color.green : Color.secondary)
        }
    }

    private func rdpTabTitle(_ tab: ProfileTab) -> String {
        switch tab {
        case .general:
            UpdateLocalization.text(ru: "Основное", en: "General")
        case .authentication:
            UpdateLocalization.text(ru: "Аутентификация", en: "Authentication")
        case .route:
            UpdateLocalization.text(ru: "Маршрут", en: "Route")
        case .display:
            UpdateLocalization.text(ru: "Экран", en: "Display")
        case .devices:
            UpdateLocalization.text(ru: "Устройства", en: "Devices")
        case .folders:
            UpdateLocalization.text(ru: "Папки", en: "Folders")
        case .security:
            UpdateLocalization.text(ru: "Безопасность", en: "Security")
        case .terminal:
            UpdateLocalization.text(ru: "Терминал", en: "Terminal")
        case .sftp:
            "SFTP"
        case .forwarding:
            UpdateLocalization.text(ru: "Туннели", en: "Forwarding")
        }
    }

    private func rdpTabSubtitle(_ tab: ProfileTab) -> String {
        switch tab {
        case .general:
            UpdateLocalization.text(
                ru: "Адрес и учётная запись",
                en: "Address and account"
            )
        case .authentication:
            UpdateLocalization.text(
                ru: "Пароль, ключ или Touch ID",
                en: "Password, key, or Touch ID"
            )
        case .route:
            UpdateLocalization.text(
                ru: "Jump Host, proxy, OpenSSH",
                en: "Jump Host, proxy, OpenSSH"
            )
        case .display:
            UpdateLocalization.text(
                ru: "Мониторы и качество",
                en: "Displays and quality"
            )
        case .devices:
            UpdateLocalization.text(
                ru: "Звук, камера, клавиатура",
                en: "Audio, camera, keyboard"
            )
        case .folders:
            UpdateLocalization.text(
                ru: "Локальные ресурсы",
                en: "Local resources"
            )
        case .security:
            UpdateLocalization.text(
                ru: "Доверие и хранение",
                en: "Trust and storage"
            )
        case .terminal:
            UpdateLocalization.text(ru: "Командная строка", en: "Command line")
        case .sftp:
            UpdateLocalization.text(ru: "Файлы и серверы", en: "Files & servers")
        case .forwarding:
            UpdateLocalization.text(ru: "Проброс портов", en: "Port forwarding")
        }
    }

    private func rdpTabDescription(_ tab: ProfileTab) -> String {
        switch tab {
        case .general:
            profile.connectionType == .ssh
                ? UpdateLocalization.text(
                    ru: "Название, адрес SSH-сервера, пользователь и порт.",
                    en: "Name, SSH server address, user, and port."
                )
                : UpdateLocalization.text(
                    ru: "Компьютер, пользователь, Keychain и RD Gateway.",
                    en: "Computer, user, Keychain, and RD Gateway."
                )
        case .authentication:
            UpdateLocalization.text(
                ru: "Выберите способ входа, пароль, SSH ID или ключ с Touch ID.",
                en: "Choose a sign-in method, password, SSH ID, or Touch ID key."
            )
        case .route:
            UpdateLocalization.text(
                ru: "Настройте Jump Host, HTTP/SOCKS proxy и параметры OpenSSH.",
                en: "Configure Jump Host, HTTP/SOCKS proxy, and OpenSSH options."
            )
        case .display:
            UpdateLocalization.text(
                ru: "Мониторы Mac, виртуальная схема Windows, масштаб и качество изображения.",
                en: "Mac displays, Windows virtual layout, scale, and image quality."
            )
        case .devices:
            UpdateLocalization.text(
                ru: "Звук, буфер обмена, клавиатура, микрофон, камера и принтеры.",
                en: "Audio, clipboard, keyboard, microphone, camera, and printers."
            )
        case .folders:
            UpdateLocalization.text(
                ru: "Папки Mac, которые будут доступны внутри Windows.",
                en: "Mac folders that will be available inside Windows."
            )
        case .security:
            UpdateLocalization.text(
                ru: "Доверие, Keychain, импорт и экспорт профиля.",
                en: "Trust, Keychain, profile import, and export."
            )
        case .terminal:
            UpdateLocalization.text(
                ru: "Полноразмерный Terminal Workspace этого SSH-профиля.",
                en: "Full-size Terminal Workspace for this SSH profile."
            )
        case .sftp:
            UpdateLocalization.text(
                ru: "SFTP Workspace этого SSH-профиля: соседняя панель может быть этим Mac или другим сервером.",
                en: "SFTP Workspace for this SSH profile; the opposite pane can be this Mac or another server."
            )
        case .forwarding:
            UpdateLocalization.text(
                ru: "Локальные, удалённые и динамические SSH-туннели.",
                en: "Local, remote, and dynamic SSH tunnels."
            )
        }
    }


    private var globalTerminalDetail: some View {
        VStack(spacing: 0) {
            if !terminalFocusMode {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Терминал")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Независимые SSH-сессии, вкладки и разделённые панели")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 16)
            }

            globalTerminalPanel
                .padding(.horizontal, terminalFocusMode ? 10 : 28)
                .padding(.bottom, terminalFocusMode ? 10 : 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .groupBoxStyle(ModernGroupBoxStyle())
        .controlSize(.large)
    }

    private var globalSFTPDetail: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SFTP")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Несколько SFTP-вкладок · Local ↔ Server · Server ↔ Server")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 16)

            SFTPWorkspaceView(workspace: model.sftpWorkspace)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .groupBoxStyle(ModernGroupBoxStyle())
        .controlSize(.large)
    }

    private var credentialVaultDetail: some View {
        CredentialVaultView(presentation: .embedded) { profileID in
            model.selectProfile(profileID)
            setMainArea(.connections)
            selectedTab = .general
        }
        .environmentObject(model)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sortedSSHProfiles: [ConnectionProfile] {
        model.profiles
            .filter { $0.connectionType == .ssh }
            .sorted {
                $0.friendlyName.localizedStandardCompare($1.friendlyName)
                    == .orderedAscending
            }
    }

    private var globalSFTPProfile: ConnectionProfile {
        var profile = ConnectionProfile(connectionType: .ssh)
        profile.id = Self.globalSFTPScopeID
        profile.friendlyName = "SFTP"
        return profile
    }

    private func connectGlobalSFTP(
        _ connection: TerminalTabConnection,
        clientID: UUID = Self.globalSFTPScopeID,
        temporaryPassword: String? = nil
    ) {
        guard let settings = model.prepareSSHConnection(
            connection: connection,
            clientID: clientID
        ) else { return }

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
                model.errorMessage = error.localizedDescription
                return
            }
        }

        model.globalSFTPSession.prepare(for: Self.globalSFTPScopeID)
        model.globalSFTPSession.connect(settings) { _ in
            if hasTemporaryPassword {
                try? KeychainService.deletePassword(profileID: clientID, kind: .ssh)
            }
        }
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch selectedTab {
        case .general: generalSettings
        case .authentication: sshAuthenticationSettings
        case .route: sshRouteSettings
        case .display: displaySettings
        case .devices: deviceSettings
        case .folders: folderSettings
        case .terminal: EmptyView()
        case .sftp: EmptyView()
        case .forwarding: EmptyView()
        case .security: securitySettings
        }
    }

    private var terminalPanel: some View {
        SSHTerminalView(
            workspace: model.terminalWorkspace(profileID: profile.id),
            appearance: terminalAppearance,
            appAppearance: appAppearance,
            workspaceTitle: profile.friendlyName,
            defaultProfileID: profile.id,
            locksPrimaryConnection: true,
            sshProfiles: model.profiles
                .filter { $0.connectionType == .ssh }
                .sorted {
                    $0.friendlyName.localizedStandardCompare($1.friendlyName)
                        == .orderedAscending
                },
            hasInstallableKey: model.selectedSSHKey?.publicKeyPath != nil,
            isFocusMode: terminalFocusMode,
            connect: { tab, temporaryPassword in
                model.connectSSHTerminal(
                    connection: tab.connection,
                    tabID: tab.id,
                    session: tab.session,
                    temporaryPassword: temporaryPassword
                )
            },
            installKey: model.installSelectedSSHPublicKey,
            toggleFocusMode: {
                setTerminalFocusMode(!terminalFocusMode)
            },
            openSFTP: { tab in
                model.sftpWorkspace.requestOpen(
                    connection: tab.connection,
                    path: nil
                )
                selectedTab = .sftp
            },
            openSFTPPath: { tab, path in
                model.sftpWorkspace.requestOpen(
                    connection: tab.connection,
                    path: path
                )
                selectedTab = .sftp
            },
            discoverContext: { tab in
                try await model.discoverTerminalContext(
                    connection: tab.connection,
                    tabID: tab.id
                )
            }
        )
    }

    private var globalTerminalPanel: some View {
        let profiles = model.profiles
            .filter { $0.connectionType == .ssh }
            .sorted {
                $0.friendlyName.localizedStandardCompare($1.friendlyName)
                    == .orderedAscending
            }
        return SSHTerminalView(
            workspace: model.globalTerminalWorkspace(),
            appearance: terminalAppearance,
            appAppearance: appAppearance,
            workspaceTitle: "Терминал",
            defaultProfileID: profiles.first?.id,
            locksPrimaryConnection: false,
            sshProfiles: profiles,
            hasInstallableKey: false,
            isFocusMode: terminalFocusMode,
            connect: { tab, temporaryPassword in
                model.connectSSHTerminal(
                    connection: tab.connection,
                    tabID: tab.id,
                    session: tab.session,
                    temporaryPassword: temporaryPassword
                )
            },
            installKey: {},
            toggleFocusMode: {
                setTerminalFocusMode(!terminalFocusMode)
            },
            openSFTP: { tab in
                model.sftpWorkspace.requestOpen(
                    connection: tab.connection,
                    path: nil
                )
                setMainArea(.sftp)
            },
            openSFTPPath: { tab, path in
                model.sftpWorkspace.requestOpen(
                    connection: tab.connection,
                    path: path
                )
                setMainArea(.sftp)
            },
            discoverContext: { tab in
                try await model.discoverTerminalContext(
                    connection: tab.connection,
                    tabID: tab.id
                )
            }
        )
    }


    private func profileTabStorageKey(profileID: UUID) -> String {
        "SelectiveRemote.profile.lastTab.v1.\(profileID.uuidString)"
    }

    private func restoredProfileTab(for profileID: UUID) -> ProfileTab {
        if let cached = profileTabs[profileID] {
            return cached
        }
        guard let rawValue = UserDefaults.standard.string(
            forKey: profileTabStorageKey(profileID: profileID)
        ), let stored = ProfileTab(rawValue: rawValue) else {
            return .general
        }
        return stored
    }

    private func openQuickConnectSSH(_ request: QuickConnectSSHRequest) {
        let connection: TerminalTabConnection
        let temporaryPassword: String?

        if request.saveAsProfile {
            guard let profileID = model.saveQuickConnectSSHProfile(request) else { return }
            connection = .savedProfile(profileID)
            temporaryPassword = nil
        } else {
            connection = .custom(
                host: request.target.host,
                username: request.target.username,
                port: request.target.port,
                authenticationMode: request.authenticationMode,
                identityID: request.identityID,
                jumpHostProfileID: request.jumpHostProfileID
            )
            temporaryPassword = request.password.isEmpty ? nil : request.password
        }

        let workspace = model.globalTerminalWorkspace()
        guard let tab = workspace.addTab(
            connection: connection,
            title: connection.displayLabel(profiles: sortedSSHProfiles)
        ) else {
            model.errorMessage = "Достигнут лимит вкладок Terminal Workspace"
            return
        }
        model.connectSSHTerminal(
            connection: connection,
            tabID: tab.id,
            session: tab.session,
            temporaryPassword: temporaryPassword
        )
        setMainArea(.terminal)
    }

    private func openForwardingTerminal(_ connection: TerminalTabConnection) {
        let workspace = model.globalTerminalWorkspace()
        if let existing = workspace.tabs.first(where: { $0.connection == connection }) {
            workspace.selectedTabID = existing.id
        } else {
            _ = workspace.addTab(
                connection: connection,
                title: connection.displayLabel(profiles: sortedSSHProfiles)
            )
        }
        setMainArea(.terminal)
    }

    private func openForwardingProfile(_ profileID: UUID) {
        model.selectProfile(profileID)
        selectedTab = .forwarding
        setMainArea(.connections)
    }

    private func openConnectionCenterSource(_ source: ConnectionCenterSource) {
        switch source {
        case let .rdp(profileID):
            model.activateRDP(profileID: profileID)
        case let .terminal(scope, tabID):
            _ = model.selectConnectionCenterTerminal(scope: scope, tabID: tabID)
            switch scope {
            case let .profile(profileID):
                model.selectProfile(profileID)
                selectedTab = .terminal
                setMainArea(.connections)
            case .global:
                setMainArea(.terminal)
            }
        case let .sftp(scope):
            switch scope {
  case let .pane(paneID):
    if let tab = model.sftpWorkspace.tab(containing: paneID) {
        model.sftpWorkspace.selectedTabID = tab.id
    }
    setMainArea(.sftp)
            case let .profile(profileID):
                model.selectProfile(profileID)
                selectedTab = .sftp
                setMainArea(.connections)
            case .global:
                setMainArea(.sftp)
            }
        case let .profileTunnel(profileID, _):
            model.selectProfile(profileID)
            selectedTab = .forwarding
            setMainArea(.connections)
        case .independentTunnel:
            setMainArea(.forwarding)
        }
    }

    private func setMainArea(_ area: MainArea) {
        if area != .terminal {
            setTerminalFocusMode(false)
        }
        mainArea = area
    }

    private func setTerminalFocusMode(_ enabled: Bool) {
        terminalFocusMode = enabled
        columnVisibility = enabled ? .detailOnly : .all
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Тип подключения") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Протокол", selection: profileBinding.connectionType) {
                        ForEach(ConnectionType.allCases) { type in
                            Label(type.title, systemImage: type.systemImage).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(
                        model.isSelectedSessionRunning || model.selectedProfileHasActiveTunnels
                    )
                    Text(
                        profile.connectionType == .rdp
                            ? "Удалённый рабочий стол через встроенный FreeRDP."
                            : "Terminal, SFTP и туннели используют системный OpenSSH macOS."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox(profile.connectionType == .rdp ? "Компьютер" : "SSH-сервер") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        Text("Название")
                        TextField(
                            profile.connectionType == .rdp
                                ? "Рабочий компьютер"
                                : "SSH-сервер",
                            text: profileBinding.friendlyName
                        )
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Группа")
                        TextField("Например: Работа", text: profileBinding.group)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Описание")
                        TextField(
                            "Например: назначение или заметка",
                            text: profileBinding.profileDescription
                        )
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Hostname")
                        TextField(
                            profile.connectionType == .rdp
                                ? "server.example.local"
                                : "server.example.com или Host из ~/.ssh/config",
                            text: profileBinding.host
                        )
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Пользователь")
                        TextField(
                            profile.connectionType == .rdp ? "DOMAIN\\username" : "username",
                            text: profileBinding.username
                        )
                            .textFieldStyle(.roundedBorder)
                    }

                    if profile.connectionType == .rdp {
                        GridRow {
                            Text("Пароль")
                            credentialEditor(
                                value: $model.password,
                                hasSavedValue: model.selectedProfileHasSavedPassword,
                                placeholder: "Введите пароль RDP",
                                savedText: "RDP-пароль сохранён в Keychain",
                                onSave: model.savePassword,
                                onDelete: model.deleteSavedPassword
                            )
                        }
                    } else {
                        GridRow {
                            Text("Порт")
                            TextField("22", value: profileBinding.sshPort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 130, alignment: .leading)
                        }
                    }
                }
                .padding(8)
            }

            if profile.connectionType == .rdp {
                GroupBox("RD Gateway — необязательно") {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                        GridRow {
                            Text("Gateway")
                            TextField("gateway.example.local", text: profileBinding.gatewayHost)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("Пользователь")
                            TextField("DOMAIN\\username", text: profileBinding.gatewayUsername)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("Пароль")
                            credentialEditor(
                                value: $model.gatewayPassword,
                                hasSavedValue: model.selectedProfileHasSavedGatewayPassword,
                                placeholder: "Отдельный пароль RD Gateway",
                                savedText: "Пароль RD Gateway сохранён отдельно в Keychain",
                                onSave: model.saveGatewayPassword,
                                onDelete: model.deleteSavedGatewayPassword
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    private var availableSSHIdentityKeys: [SSHKeyRecord] {
        if profileBinding.wrappedValue.sshAuthenticationMode == .touchIDKey {
            return model.sshKeys.filter(SSHKeyService.isTouchIDCompatible)
        }
        return model.sshKeys
    }

    private func normalizeTouchIDIdentitySelection() {
        guard profileBinding.wrappedValue.sshAuthenticationMode == .touchIDKey else { return }
        let selectedID = profileBinding.wrappedValue.sshIdentityID
        let selectedIsCompatible = selectedID.flatMap { id in
            model.sshKeys.first(where: { $0.id == id })
        }.map(SSHKeyService.isTouchIDCompatible) ?? false
        guard !selectedIsCompatible else { return }
        profileBinding.wrappedValue.sshIdentityID = availableSSHIdentityKeys.first?.id
    }

    private var authModeHint: String {
        switch profileBinding.wrappedValue.sshAuthenticationMode {
        case .automatic:
            "OpenSSH попробует выбранный ключ, ssh-agent и затем пароль. Удобно для совместимости."
        case .password:
            "Используется только SSH-пароль. Public key authentication отключена."
        case .key:
            "Используется только выбранный SSH-ключ. Пароль не будет fallback-вариантом."
        case .touchIDKey:
            "Touch ID Key — отдельный тип входа: используется только ECDSA-ключ и перед каждым использованием требуется Touch ID. На сервер устанавливается обычный публичный ECDSA-ключ."
        case .agent:
            "Используются только системный ssh-agent и ~/.ssh/config."
        }
    }

    private var sshAuthenticationSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                        Image(systemName: "key.viewfinder")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SSH-аутентификация")
                            .font(.title3.bold())
                        Text("Один способ входа используется Terminal, SFTP и Forwarding")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Диагностика", systemImage: "stethoscope") {
                        showsSSHDiagnostics = true
                    }
                    Button("Keychain", systemImage: "lock.shield") {
                        setMainArea(.keychain)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Способ входа")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Способ входа", selection: profileBinding.sshAuthenticationMode) {
                        ForEach(SSHAuthenticationMode.allCases) { mode in
                            Label(LocalizedStringKey(mode.title), systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(authModeHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if profileBinding.wrappedValue.sshAuthenticationMode == .automatic
                    || profileBinding.wrappedValue.sshAuthenticationMode == .password {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Пароль", systemImage: "ellipsis.rectangle.fill")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if model.selectedProfileHasSavedSSHPassword {
                                Label("Сохранён в Keychain", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                        HStack(spacing: 8) {
                            SecureField(
                                model.selectedProfileHasSavedSSHPassword
                                    ? "Сохранён — введите новый для замены"
                                    : "Пароль SSH-сервера",
                                text: $model.sshPassword
                            )
                            .textFieldStyle(.roundedBorder)
                            Button("Сохранить") { model.saveSSHPassword() }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.sshPassword.isEmpty)
                            Button(role: .destructive) { model.deleteSavedSSHPassword() } label: {
                                Image(systemName: "trash")
                            }
                            .disabled(!model.selectedProfileHasSavedSSHPassword)
                        }
                        if model.selectedProfileHasSavedSSHPassword {
                            Toggle(
                                isOn: Binding(
                                    get: { model.selectedSSHPasswordRequiresUserPresence },
                                    set: { model.setSelectedSSHPasswordUserPresence($0) }
                                )
                            ) {
                                Label("Touch ID перед использованием пароля", systemImage: "touchid")
                            }
                            .toggleStyle(.switch)
                        }
                    }
                    .padding(14)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if profileBinding.wrappedValue.sshAuthenticationMode == .automatic
                    || profileBinding.wrappedValue.sshAuthenticationMode == .key
                    || profileBinding.wrappedValue.sshAuthenticationMode == .touchIDKey {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(
                                profileBinding.wrappedValue.sshAuthenticationMode == .touchIDKey ? "Touch ID Key" : "SSH ID",
                                systemImage: profileBinding.wrappedValue.sshAuthenticationMode == .touchIDKey ? "touchid" : "key.horizontal.fill"
                            )
                            .font(.subheadline.weight(.semibold))
                            Spacer()
                            if profileBinding.wrappedValue.sshAuthenticationMode == .touchIDKey {
                                Label("Touch ID обязателен", systemImage: "checkmark.shield.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }

                        Picker("Ключ", selection: profileBinding.sshIdentityID) {
                            Text("Выберите ключ…").tag(nil as UUID?)
                            ForEach(availableSSHIdentityKeys) { key in
                                Text("\(key.name) · \(key.algorithm)").tag(Optional(key.id))
                            }
                        }
                        .labelsHidden()
                        .onChange(of: profileBinding.wrappedValue.sshAuthenticationMode) { _, _ in
                            normalizeTouchIDIdentitySelection()
                        }

                        if profileBinding.wrappedValue.sshAuthenticationMode == .touchIDKey {
                            if availableSSHIdentityKeys.isEmpty {
                                Label(
                                    "Нет ECDSA Touch ID Key. Создайте новый ключ — обычные Ed25519/RSA здесь намеренно не предлагаются.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            } else {
                                Text("Для Touch ID Key доступны только ECDSA-ключи. Ed25519, RSA и FIDO2/SK остаются отдельными SSH ID.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 8) {
                            Button(
                                profileBinding.wrappedValue.sshAuthenticationMode == .touchIDKey
                                    ? "Создать Touch ID Key"
                                    : "Создать SSH ID",
                                systemImage: profileBinding.wrappedValue.sshAuthenticationMode == .touchIDKey ? "touchid" : "plus.circle.fill"
                            ) { showsSSHKeyGenerator = true }
                            .buttonStyle(.borderedProminent)
                            Button("Импортировать", systemImage: "square.and.arrow.down") { model.importSSHKey() }
                            Button("Установить на сервер", systemImage: "arrow.up.to.line") {
                                model.installSelectedSSHPublicKey()
                            }
                            .disabled(model.selectedSSHKey?.publicKeyPath == nil || model.isSelectedSSHTerminalRunning)
                        }

                        if profileBinding.wrappedValue.sshAuthenticationMode == .key {
                            Toggle(
                                isOn: Binding(
                                    get: { model.selectedSSHKeyRequiresUserPresence },
                                    set: { model.setSelectedSSHKeyUserPresence($0) }
                                )
                            ) {
                                Label("Дополнительно подтверждать использование ключа через Touch ID", systemImage: "touchid")
                            }
                            .toggleStyle(.switch)
                            .disabled(model.selectedSSHKey == nil)
                        }

                        if let key = model.selectedSSHKey {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(key.name).font(.caption.weight(.semibold))
                                    Text(key.fingerprint)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if profileBinding.wrappedValue.sshAuthenticationMode == .agent {
                    Label(
                        "Selective Remote использует системный ssh-agent и ~/.ssh/config. Пароль и выбранный SSH ID профиля не передаются OpenSSH.",
                        systemImage: "terminal.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }

        }
    }

    private var sshRouteSettings: some View {
        VStack(alignment: .leading, spacing: 18) {

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Маршрут SSH", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    Spacer()
                    Text(profileBinding.wrappedValue.sshJumpHostProfileID == nil ? "Прямое подключение" : "Jump Host")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Jump Host", selection: profileBinding.sshJumpHostProfileID) {
                    Text("Прямое подключение").tag(UUID?.none)
                    ForEach(sortedSSHProfiles.filter {
                        $0.id != profile.id && $0.sshAuthenticationMode != .password
                    }) { jump in
                        Text(jump.friendlyName.isEmpty ? jump.host : jump.friendlyName)
                            .tag(Optional(jump.id))
                    }
                }
                .pickerStyle(.menu)

                if let jumpID = profileBinding.wrappedValue.sshJumpHostProfileID,
                   let jump = model.profiles.first(where: { $0.id == jumpID }) {
                    HStack(spacing: 12) {
                        routeNode(title: "Mac", subtitle: "Этот Mac", systemImage: "laptopcomputer")
                        Image(systemName: "arrow.right").foregroundStyle(Color.accentColor)
                        routeNode(
                            title: jump.friendlyName.isEmpty ? "Jump Host" : jump.friendlyName,
                            subtitle: jump.username.isEmpty ? "\(jump.host):\(jump.sshPort)" : "\(jump.username)@\(jump.host):\(jump.sshPort)",
                            systemImage: "server.rack"
                        )
                        Image(systemName: "arrow.right").foregroundStyle(Color.accentColor)
                        routeNode(
                            title: profile.friendlyName.isEmpty ? "Target" : profile.friendlyName,
                            subtitle: profile.username.isEmpty ? "\(profile.host):\(profile.sshPort)" : "\(profile.username)@\(profile.host):\(profile.sshPort)",
                            systemImage: "terminal"
                        )
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Label(
                        "Подключение выполняется системным OpenSSH через -J. Настройки HTTP/SOCKS proxy целевого профиля при этом не применяются.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Для bastion-сценария выберите другой сохранённый SSH-профиль. Его адрес и пользователь используются как ProxyJump.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Proxy", systemImage: "arrow.triangle.branch")
                        .font(.headline)
                    Spacer()
                    Text(profileBinding.wrappedValue.sshProxyMode.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Proxy", selection: profileBinding.sshProxyMode) {
                    ForEach(SSHProxyMode.allCases) { mode in Text(LocalizedStringKey(mode.title)).tag(mode) }
                }
                .pickerStyle(.segmented)
                .disabled(profileBinding.wrappedValue.sshJumpHostProfileID != nil)

                if profileBinding.wrappedValue.sshProxyMode != .none
                    && profileBinding.wrappedValue.sshJumpHostProfileID == nil {
                    HStack(spacing: 10) {
                        TextField("proxy.example.com", text: profileBinding.sshProxyHost)
                            .textFieldStyle(.roundedBorder)
                        TextField(
                            "Порт",
                            value: profileBinding.sshProxyPort,
                            format: .number.grouping(.never)
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    }
                    TextField("Имя пользователя прокси (необязательно)", text: profileBinding.sshProxyUsername)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 10) {
                        SecureField(
                            model.selectedProfileHasSavedProxyPassword
                                ? "Сохранён в Keychain — введите новый для замены"
                                : "Пароль прокси (необязательно)",
                            text: $model.proxyPassword
                        )
                        .textFieldStyle(.roundedBorder)
                        Button("Сохранить") { model.saveProxyPassword() }
                            .disabled(model.proxyPassword.isEmpty)
                        if model.selectedProfileHasSavedProxyPassword {
                            Button(role: .destructive) { model.deleteSavedProxyPassword() } label: {
                                Image(systemName: "trash")
                            }
                            .help("Удалить пароль прокси из Keychain")
                        }
                    }
                    Label(
                        profileBinding.wrappedValue.sshProxyMode == .http
                            ? "HTTP CONNECT: Basic-аутентификация выполняется защищённым helper-процессом; пароль не попадает в аргументы OpenSSH."
                            : "SOCKS5: поддерживаются анонимный режим и username/password; пароль хранится в Keychain и передаётся helper-процессу через временный файл 0600.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }

            GroupBox("Параметры OpenSSH") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        Text("Начальная папка SFTP")
                        TextField(".", text: profileBinding.sshInitialDirectory)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Проверка host key")
                        Picker("", selection: profileBinding.sshHostKeyPolicy) {
                            ForEach(SSHHostKeyPolicy.allCases) { policy in
                                Text(policy.title).tag(policy)
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Keepalive, секунд")
                        TextField(
                            "30",
                            value: profileBinding.sshKeepAliveSeconds,
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130, alignment: .leading)
                    }
                    GridRow {
                        Text("Сжатие")
                        Toggle("Включить SSH compression", isOn: profileBinding.sshCompression)
                    }
                }
                .padding(8)
            }

            GroupBox("SSH Agent Forwarding") {
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
    }

    private func credentialEditor(
        value: Binding<String>,
        hasSavedValue: Bool,
        placeholder: String,
        savedText: String,
        onSave: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                SecureField(
                    hasSavedValue ? "Пустое поле использует сохранённый пароль" : placeholder,
                    text: value
                )
                .textFieldStyle(.roundedBorder)
                Button("Сохранить", action: onSave)
                    .disabled(value.wrappedValue.isEmpty)
                Button("Удалить", role: .destructive, action: onDelete)
                    .disabled(!hasSavedValue)
            }
            Label(
                hasSavedValue ? savedText : "Сохранённый пароль отсутствует",
                systemImage: hasSavedValue ? "checkmark.circle.fill" : "circle"
            )
            .font(.caption)
            .foregroundStyle(hasSavedValue ? Color.green : Color.gray)
        }
    }

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Дисплеи macOS") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Физические мониторы")
                                .font(.headline)
                            Text("Поддерживаются любые дисплеи, которые обнаруживает macOS и SDL-FreeRDP.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Показать номера", systemImage: "number.square") {
                            model.showNumbers()
                        }
                        Button("Обновить", systemImage: "arrow.clockwise") {
                            model.refreshDisplays()
                        }
                    }

                    MonitorMapView(
                        displays: model.displays,
                        selectedIDs: model.effectiveSelectedDisplayIDs,
                        primaryID: model.effectivePrimaryDisplayID,
                        onToggle: model.toggleSelection,
                        onPrimary: model.setPrimary
                    )
                    .frame(height: 245)
                }
                .padding(8)
            }

            GroupBox("Виртуальная схема для Windows") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker(
                            "Расстановка",
                            selection: Binding(
                                get: { profile.displayLayoutMode },
                                set: { model.setDisplayLayoutMode($0) }
                            )
                        ) {
                            ForEach(DisplayLayoutMode.allCases) { mode in
                                Text(LocalizedStringKey(mode.title)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 340)
                        Spacer()
                        if profile.displayLayoutMode == .custom {
                            Button("Горизонтально") { model.arrangeVirtualDisplays(.horizontal) }
                            Button("Вертикально") { model.arrangeVirtualDisplays(.vertical) }
                            Button("Сбросить") { model.resetVirtualLayout() }
                        }
                    }

                    if model.placements.isEmpty {
                        Text("Выберите хотя бы один доступный дисплей")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        VirtualMonitorLayoutEditor(
                            displays: model.displays,
                            placements: model.placements,
                            editable: profile.displayLayoutMode == .custom,
                            onMove: model.moveVirtualDisplay
                        )
                        .frame(height: 285)
                        Text(
                            profile.displayLayoutMode == .custom
                                ? "Перетаскивайте мониторы. Координаты привязываются к сетке 20 px; основной экран всегда нормализуется к x:0, y:0."
                                : "Автоматический режим удаляет промежутки между выбранными физическими дисплеями."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if model.hasOverlappingPlacements {
                        Label(
                            "Мониторы перекрываются — подключение заблокировано",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.red)
                    }

                    ForEach(model.placements, id: \.id) { placement in
                        let display = model.displays.first(where: { $0.id == placement.id })
                        HStack {
                            Text(display?.name ?? "Дисплей")
                            if placement.isPrimary {
                                Label("Основной", systemImage: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                            }
                            Spacer()
                            Text(
                                "x: \(Int(placement.virtualFrame.minX)), y: \(Int(placement.virtualFrame.minY)), "
                                    + "\(Int(placement.virtualFrame.width)) × \(Int(placement.virtualFrame.height))"
                            )
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("Масштаб и окно") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Масштаб Windows", selection: profileBinding.windowsScale) {
                        ForEach(WindowsScale.allCases) { scale in
                            Text(scale.title).tag(scale)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 380)
                    Picker("Режим окна", selection: rdpWindowModeBinding) {
                        ForEach(RDPWindowMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.title)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 700)
                    if profile.rdpWindowMode != .fullScreen {
                        HStack {
                            TextField("Ширина", value: profileBinding.windowWidth, format: .number)
                                .frame(width: 110)
                            Text("×")
                            TextField("Высота", value: profileBinding.windowHeight, format: .number)
                                .frame(width: 110)
                            Text("px")
                                .foregroundStyle(.secondary)
                        }
                        Text(
                            profile.rdpWindowMode == .dynamicWindow
                                ? "При изменении размера окна Windows получает новое разрешение, а не растягивается."
                                : "Разрешение остаётся фиксированным; изображение масштабируется внутри окна."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }

            GroupBox("Качество RDP-сессии") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Профиль сети", selection: profileBinding.rdpQuality) {
                        ForEach(RDPQualityPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 640)

                    Text(profile.rdpQuality.details)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Label(
                        "Новый профиль применяется при следующем подключении.",
                        systemImage: "arrow.trianglehead.clockwise"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox("Управление полноэкранной RDP-сессией") {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Правый Shift + Enter — переключить полный экран / окно", systemImage: "rectangle.inset.filled")
                    Label("Правый Shift + D — отключить RDP", systemImage: "xmark.circle")
                    if model.isSelectedSessionRunning {
                        Button("Открыть панель управления", systemImage: "switch.2") {
                            model.showRDPControlPanel()
                        }
                        Button("Отключить эту сессию", role: .destructive) { model.disconnect() }
                    }
                }
                .padding(8)
            }
        }
    }

    private var deviceSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Проверка перед подключением") {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Проверьте выбранную камеру и разрешения macOS")
                            .font(.headline)
                        Text("Предпросмотр работает локально и не запускает RDP-сессию.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Проверить устройства…", systemImage: "waveform.and.magnifyingglass") {
                        showsCaptureDiagnostics = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSessionRunning)
                    .help(
                        model.isSessionRunning
                            ? "Сначала завершите активные RDP-сессии, чтобы не делить камеру с FreeRDP"
                            : "Проверить разрешения, микрофон и выбранную камеру"
                    )
                }
                .padding(8)
            }

            GroupBox("Звук") {
                Picker("Воспроизводить звук", selection: profileBinding.audioMode) {
                    ForEach(AudioMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.title)).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .padding(8)
            }

            GroupBox("Буфер обмена") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Направление", selection: profileBinding.clipboardMode) {
                        ForEach(ClipboardMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.title)).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                }
                .padding(8)
            }

            GroupBox("Клавиатура") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "Левый Command работает как Ctrl (⌘C/⌘V)",
                        isOn: profileBinding.mapCommandToControl
                    )
                    Toggle(
                        "Правый Command остаётся клавишей Windows",
                        isOn: profileBinding.mapRightCommandToWindows
                    )
                    .disabled(!profile.mapCommandToControl)
                    Toggle(
                        "Левый Option работает как клавиша Windows",
                        isOn: profileBinding.mapOptionToWindows
                    )
                    Toggle(
                        "Fn переключает язык Windows",
                        isOn: profileBinding.fnSwitchesWindowsLanguage
                    )
                    Text(
                        "Одиночное нажатие Fn отправляет Win+Space. "
                            + "Fn в сочетании с другими клавишами не переключает язык."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Divider()
                    HStack {
                        Text("Собственные переназначения").font(.headline)
                        Spacer()
                        Button("Добавить", systemImage: "plus") {
                            model.mutateSelectedProfile {
                                $0.customKeyMappings.append(
                                    RDPKeyMapping(source: .capsLock, target: .escape)
                                )
                            }
                        }
                    }
                    if profile.customKeyMappings.isEmpty {
                        Text("Можно переназначить отдельные служебные клавиши без установки драйверов.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(profileBinding.customKeyMappings) { $mapping in
                            HStack {
                                Toggle("", isOn: $mapping.isEnabled)
                                    .labelsHidden()
                                Picker("Из", selection: $mapping.source) {
                                    ForEach(RDPRemappableKey.allCases) { key in
                                        Text(key.title).tag(key)
                                    }
                                }
                                Text("→")
                                Picker("В", selection: $mapping.target) {
                                    ForEach(RDPRemappableKey.allCases) { key in
                                        Text(key.title).tag(key)
                                    }
                                }
                                Button("Удалить", systemImage: "trash", role: .destructive) {
                                    let id = mapping.id
                                    model.mutateSelectedProfile {
                                        $0.customKeyMappings.removeAll { $0.id == id }
                                    }
                                }
                                .labelStyle(.iconOnly)
                            }
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("Перенаправление устройств") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Микрофон", isOn: profileBinding.redirectMicrophone)
                    Toggle("Принтеры", isOn: profileBinding.redirectPrinters)
                    if profile.redirectMicrophone {
                        Text("При первом использовании macOS покажет в запросе «Selective Remote» или «Selective Remote Session». Если отказать, RDP всё равно подключится — не будет передаваться только микрофон.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }

            GroupBox("Камера") {
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Toggle("Передавать камеру в Windows", isOn: profileBinding.redirectCamera)
                            .disabled(!FreeRDPService.cameraRedirectionAvailable)
                        Spacer()
                        Button("Обновить", systemImage: "arrow.clockwise") {
                            model.refreshCameras()
                        }
                        .help("Повторно найти встроенные, USB- и Continuity-камеры")
                    }

                    Picker("Источник", selection: cameraSelectionBinding) {
                        Text("Встроенная камера Mac (рекомендуется)")
                            .tag(CameraSelectionToken.builtIn)
                        Text("Автоматически (выбор macOS)")
                            .tag(CameraSelectionToken.automatic)
                        ForEach(model.cameras) { camera in
                            Label(camera.displayName, systemImage: camera.kind.systemImage)
                                .tag(CameraSelectionToken.device(camera.id))
                        }
                        if model.selectedCameraUnavailable,
                           let id = profile.cameraDeviceID {
                            Text("\(profile.cameraDeviceName ?? "Сохранённая камера") · недоступна")
                                .tag(CameraSelectionToken.device(id))
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!profile.redirectCamera || !FreeRDPService.cameraRedirectionAvailable)

                    Label(
                        model.cameraSelectionDescription,
                        systemImage: model.selectedCameraUnavailable
                            ? "video.slash.fill"
                            : "video.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(model.selectedCameraUnavailable ? Color.orange : Color.secondary)

                    Picker("Качество", selection: profileBinding.cameraQuality) {
                        ForEach(CameraQualityPreset.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!profile.redirectCamera || !FreeRDPService.cameraRedirectionAvailable)

                    Text(profile.cameraQuality.details)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if profile.cameraQuality != .automatic {
                        Text("Битрейт является целью кодировщика FreeRDP; фактический трафик может отличаться в зависимости от изображения и сервера.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if profile.redirectCamera && FreeRDPService.cameraRedirectionAvailable {
                        Text("Выбранное устройство и качество сохраняются в этом профиле. Если конкретная камера недоступна при запуске, RDPECAM безопасно перейдёт на встроенную камеру Mac, а затем — на системную.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("При первом подключении macOS запросит доступ для «Selective Remote Session». После изменения разрешения полностью переподключите RDP-сессию.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Отказ в доступе к камере не блокирует RDP: подключение продолжится без видео.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !FreeRDPService.cameraRedirectionAvailable {
                        Text("В этой копии приложения не найден изолированный RDPECAM addin. Соберите полный пакет через scripts/build_app.sh — обычный запуск через swift run камеру не включает.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(8)
            }

            GroupBox("Поведение подключения") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Автоматически переподключаться при сетевом сбое", isOn: profileBinding.autoReconnect)
                    Toggle("Восстанавливать после сна Mac", isOn: profileBinding.reconnectAfterWake)
                    Text("Автовосстановление после сна возможно только с сохранённым RDP-паролем и подключёнными выбранными мониторами.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Подключаться к административной сессии", isOn: profileBinding.adminSession)
                }
                .padding(8)
            }
        }
    }

    private var folderSettings: some View {
        GroupBox("Папки, доступные в удалённой Windows") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Добавляйте только те папки, которые действительно нужны в удалённой сессии.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Недоступная macOS папка будет пропущена; сама RDP-сессия продолжит запуск.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(profile.redirectedFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { model.removeFolder(path) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button("Добавить папку…", systemImage: "plus") { model.chooseFolder() }
            }
            .padding(8)
        }
    }

    private var securitySettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            if profile.connectionType == .rdp {
                GroupBox("Сертификат сервера") {
                    Picker("Проверка сертификата", selection: profileBinding.certificatePolicy) {
                        ForEach(CertificatePolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .padding(8)
                }

                if profile.certificatePolicy == .ignore {
                    Label(
                        "Проверка сертификата отключена. Используйте этот режим только для диагностики.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            } else {
                GroupBox("Проверка SSH-сервера") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Host key", selection: profileBinding.sshHostKeyPolicy) {
                            ForEach(SSHHostKeyPolicy.allCases) { policy in
                                Text(policy.title).tag(policy)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        Label(
                            "Новые и известные ключи хранятся системным OpenSSH в ~/.ssh/known_hosts",
                            systemImage: "checkmark.shield"
                        )
                        .font(.caption)
                        Text(
                            "Режим «принимать новые» добавляет только ранее неизвестный ключ, "
                                + "но всегда отклоняет изменившийся ключ сервера."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
            }

            GroupBox("Хранение и перенос данных") {
                VStack(alignment: .leading, spacing: 10) {
                    if profile.connectionType == .rdp {
                        Label(
                            "RDP и RD Gateway используют отдельные записи Keychain",
                            systemImage: "key.fill"
                        )
                    } else {
                        Label(
                            "Passphrase SSH-ключей хранится только в системном Keychain",
                            systemImage: "key.fill"
                        )
                        Label(
                            "SSH-пароли профилей хранятся только в системном Keychain",
                            systemImage: "eye.slash"
                        )
                    }
                    Label(
                        "Пароли и passphrase не попадают в профиль или экспорт",
                        systemImage: "lock.doc"
                    )
                    HStack {
                        Button("Импортировать…") { model.importProfiles() }
                        Button("Экспортировать все профили…") { model.exportAllProfiles() }
                        if profile.connectionType == .rdp {
                            Button("Экспортировать .rdp…") { model.exportSelectedRDP() }
                        }
                        Button("Keychain и ключи…", systemImage: "key.viewfinder") {
                            setMainArea(.keychain)
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private var connectionBar: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(
                        model.isSelectedSessionRunning || model.isSelectedSSHTerminalRunning
                            ? Color.green.opacity(0.14)
                            : model.selectedProfileHasActiveTunnels
                                ? Color.orange.opacity(0.14)
                                : Color.blue.opacity(0.12)
                    )
                Image(
                    systemName: model.isSelectedSessionRunning
                        ? "bolt.fill"
                        : model.isSelectedSSHTerminalRunning
                            ? "terminal.fill"
                        : model.selectedProfileHasActiveTunnels
                            ? "arrow.left.arrow.right"
                            : "info.circle.fill"
                )
                .foregroundStyle(
                    model.isSelectedSessionRunning || model.isSelectedSSHTerminalRunning
                        ? Color.green
                        : model.selectedProfileHasActiveTunnels ? Color.orange : Color.blue
                )
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    model.isSelectedSessionRunning
                        ? "Сессия активна"
                        : model.isSelectedSSHTerminalRunning
                            ? "SSH-терминал активен"
                        : profile.connectionType == .ssh
                            ? model.selectedProfileHasActiveTunnels
                                ? "SSH-туннель активен"
                                : "Готово к SSH"
                            : "Готово к подключению"
                )
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(model.statusMessage)
                    .lineLimit(1)
            }
            if model.sessionLogURL != nil {
                Button("Журнал", systemImage: "doc.text.magnifyingglass") {
                    model.revealSessionLog()
                }
                    .buttonStyle(.link)
            }
            if model.runningSessionCount > 1 {
                Text("\(model.runningSessionCount) активных")
                    .font(.caption.bold())
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.12), in: Capsule())
            }
            Spacer()
            if model.isSelectedSessionRunning || model.isSelectedSSHTerminalRunning {
                Button("Отключиться", systemImage: "stop.fill", role: .destructive) {
                    model.disconnect()
                }
                .buttonStyle(.bordered)
            } else if model.canReconnectSelectedProfile {
                Button("Восстановить", systemImage: "arrow.clockwise") {
                    model.reconnectSelectedProfile()
                }
                    .buttonStyle(.borderedProminent)
            } else {
                Button {
                    if profile.connectionType == .ssh {
                        selectedTab = .terminal
                    }
                    model.connect()
                } label: {
                    Label(
                        profile.connectionType == .ssh ? "Открыть SSH" : "Подключиться",
                        systemImage: profile.connectionType == .ssh
                            ? "terminal"
                            : "arrow.right.circle.fill"
                    )
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.canConnect)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }
}

private struct ProfileRow: View {
    let profile: ConnectionProfile
    let session: RDPSessionSummary?
    let hasActiveSSH: Bool
    let activeTunnelCount: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: session == nil && !hasActiveSSH
                                ? profile.connectionType == .ssh
                                    ? [Color.purple.opacity(0.82), Color.indigo.opacity(0.80)]
                                    : [Color.blue.opacity(0.82), Color.indigo.opacity(0.80)]
                                : [Color.green.opacity(0.88), Color.teal.opacity(0.82)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                Image(systemName: profile.connectionType.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                if session != nil || hasActiveSSH || activeTunnelCount > 0 {
                    Circle()
                        .fill(session != nil || hasActiveSSH ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(profile.friendlyName.isEmpty ? "Без названия" : profile.friendlyName)
                        .lineLimit(1)
                    if profile.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                    }
                }
                Text(
                    session?.phase.rawValue
                        ?? (hasActiveSSH
                            ? "SSH-сессия активна"
                            : activeTunnelCount > 0
                            ? "Туннелей: \(activeTunnelCount)"
                            : profile.host.isEmpty ? "Hostname не указан" : profile.host)
                )
                    .font(.caption)
                .foregroundStyle(
                    session != nil || hasActiveSSH
                        ? Color.green
                        : activeTunnelCount > 0 ? Color.orange : Color.secondary
                )
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

private func routeNode(title: String, subtitle: String, systemImage: String) -> some View {
    VStack(spacing: 6) {
        Image(systemName: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.accentColor)
        Text(title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
        Text(subtitle)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
    .frame(maxWidth: .infinity)
}

private struct ModernGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            configuration.label
                .font(.headline)
                .foregroundStyle(.primary)
            configuration.content
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075))
        }
        .shadow(color: Color.black.opacity(0.035), radius: 12, y: 5)
    }
}
