import SwiftUI

private enum ProfileTab: String, CaseIterable, Identifiable {
    case general = "Основные"
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
    case keychain = "Keychain"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .connectionCenter: "point.3.connected.trianglepath.dotted"
        case .connections: "rectangle.stack"
        case .terminal: "terminal"
        case .sftp: "folder.badge.gearshape"
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
    @State private var showsGlobalSFTPConnectionEditor = false
    @State private var globalSFTPConnection: TerminalTabConnection?

    private var profile: ConnectionProfile { model.selectedProfile }
    private var sftpSession: SFTPBrowserSession { model.sftpSession }
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
            [.general, .terminal, .sftp, .forwarding, .security]
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
        .tint(Color(red: 0.10, green: 0.52, blue: 0.72))
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
            if model.availableReleaseNotesURL != nil {
                Button("Что нового") { model.openAvailableReleaseNotes() }
            }
            Button("OK", role: .cancel) { model.updateMessage = nil }
        } message: {
            Text(model.updateMessage ?? "")
        }
        .sheet(isPresented: $model.quickConnectPresented) {
            QuickConnectView { profileID, action in
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
            }
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
            sftpSession.prepare(for: newProfileID)
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
                    Text("\(AppBrand.tagline) · \(AppBuildInfo.displayText)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
                if model.runningSessionCount > 0 {
                    Label("\(model.runningSessionCount)", systemImage: "bolt.fill")
                        .font(.caption.bold())
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.12), in: Capsule())
                        .help("Активных RDP-сессий: \(model.runningSessionCount)")
                }
                if model.runningSSHTunnelCount > 0 {
                    Label("\(model.runningSSHTunnelCount)", systemImage: "arrow.left.arrow.right")
                        .font(.caption.bold())
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .help("Активных SSH-туннелей: \(model.runningSSHTunnelCount)")
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
                            Text(mode.title).tag(mode)
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
            onOpen: openConnectionCenterSource,
            onReconnect: model.reconnectConnectionCenterSource,
            onDisconnect: model.disconnectConnectionCenterSource,
            onRefresh: model.refreshConnectionCenterRuntimeState
        )
    }

    private var profileDetail: some View {
        VStack(spacing: 0) {
                if selectedTab == .terminal {
                    if !terminalFocusMode {
                        VStack(alignment: .leading, spacing: 20) {
                            header
                            profileTabPicker
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 28)
                        .padding(.bottom, 16)
                        .frame(maxWidth: 1120, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }

                    terminalPanel
                        .id(profile.id)
                        .padding(.horizontal, terminalFocusMode ? 10 : 28)
                        .padding(.top, terminalFocusMode ? 10 : 0)
                        .padding(.bottom, terminalFocusMode ? 10 : 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if selectedTab == .sftp {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 20) {
                            header
                            profileTabPicker
                        }
                        .frame(maxWidth: 1120, alignment: .leading)

                        SFTPBrowserView(profile: profile, session: sftpSession)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if selectedTab == .forwarding {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 20) {
                            header
                            profileTabPicker
                        }
                        .frame(maxWidth: 1120, alignment: .leading)

                        PortForwardingView(profile: profile)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 20) {
                                header
                                profileTabPicker
                            }
                            .frame(maxWidth: 1120, alignment: .leading)

                            selectedSettingsContent
                                .frame(maxWidth: 1120, alignment: .leading)
                        }
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !terminalFocusMode {
                    connectionBar
                }
            }
            .groupBoxStyle(ModernGroupBoxStyle())
            .controlSize(.large)
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
                    Text("Независимый файловый менеджер для сохранённых и временных серверов")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 16)

            SFTPBrowserView(
                profile: globalSFTPProfile,
                session: model.globalSFTPSession,
                requestConnection: {
                    showsGlobalSFTPConnectionEditor = true
                },
                activeSSHSession: {
                    if let profileID = globalSFTPConnection?.profileID {
                        return model.isSSHTerminalRunning(profileID: profileID)
                    }
                    guard let connection = globalSFTPConnection else { return false }
                    return model.globalTerminalWorkspace().tabs.contains {
                        $0.session.isRunning && $0.connection == connection
                    }
                }
            )
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

    private var profileTabPicker: some View {
        Picker("Раздел", selection: $selectedTab) {
            ForEach(availableTabs) { tab in
                Label {
                    Text(LocalizedStringKey(tab.rawValue))
                } icon: {
                    Image(systemName: tab.systemImage)
                }
                .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(6)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch selectedTab {
        case .general: generalSettings
        case .display: displaySettings
        case .devices: deviceSettings
        case .folders: folderSettings
        case .terminal: EmptyView()
        case .sftp: SFTPBrowserView(profile: profile, session: sftpSession)
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
                guard let settings = model.prepareSSHConnection(
                    connection: tab.connection,
                    clientID: tab.id
                ) else { return }
                sftpSession.prepare(for: profile.id)
                sftpSession.connect(settings)
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
                globalSFTPConnection = tab.connection
                connectGlobalSFTP(tab.connection, clientID: tab.id)
                mainArea = .sftp
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

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.10, green: 0.62, blue: 0.78),
                                Color.indigo
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(
                    systemName: model.isSelectedSessionRunning
                        ? "display.2"
                        : profile.connectionType.systemImage
                )
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)
            .shadow(color: Color.blue.opacity(0.22), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Text(profile.friendlyName.isEmpty ? "Без названия" : profile.friendlyName)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    if let session = model.sessions[profile.id] {
                        Label(session.phase.rawValue, systemImage: "circle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(Color.green)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    }
                    if profile.connectionType == .ssh,
                       model.selectedProfileHasActiveTunnels {
                        Label("Туннель активен", systemImage: "arrow.left.arrow.right")
                            .font(.caption.bold())
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
                Label(
                    profile.host.isEmpty
                        ? "Настройте новое \(profile.connectionType.title)-подключение"
                        : "\(profile.connectionType.title) · \(profile.host)",
                    systemImage: "network"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.checkForUpdates() } label: {
                if model.isCheckingForUpdates {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isCheckingForUpdates)
            .help(model.isCheckingForUpdates ? "Проверяем обновления…" : "Проверить обновления")
            Button { model.toggleFavorite() } label: {
                Label(
                    profile.isFavorite ? "В избранном" : "В избранное",
                    systemImage: profile.isFavorite ? "star.fill" : "star"
                )
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: Color.black.opacity(0.05), radius: 18, y: 7)
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
            } else {
                sshGeneralSettings
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

    private var sshGeneralSettings: some View {
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
                            Label(mode.title, systemImage: mode.systemImage).tag(mode)
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
                    ForEach(SSHProxyMode.allCases) { mode in Text(mode.title).tag(mode) }
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

            if model.unavailableSelectedDisplayCount > 0 {
                HStack {
                    Label(
                        "Недоступные мониторы временно пропущены: \(model.unavailableSelectedDisplayCount)",
                        systemImage: "display.trianglebadge.exclamationmark"
                    )
                    .foregroundStyle(.orange)
                    Spacer()
                    Button("Забыть недоступные") {
                        model.forgetUnavailableDisplays()
                    }
                    .help("Используйте, если мониторы заменены, а не временно отключены")
                }
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
                                Text(mode.title).tag(mode)
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
                            Text(mode.title).tag(mode)
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
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .padding(8)
            }

            GroupBox("Буфер обмена") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Направление", selection: profileBinding.clipboardMode) {
                        ForEach(ClipboardMode.allCases) { mode in
                            Text(mode.title).tag(mode)
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
