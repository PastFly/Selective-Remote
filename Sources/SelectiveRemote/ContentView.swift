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

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var terminalAppearance = TerminalAppearanceStore()
    @StateObject private var appAppearance = AppAppearanceStore()
    @State private var selectedTab = ProfileTab.general
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var terminalFocusMode = false
    @State private var showsCaptureDiagnostics = false
    @State private var showsCredentialVault = false
    @State private var showsSSHKeyGenerator = false
    @State private var showsAppearanceSettings = false

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
        .sheet(isPresented: $showsCredentialVault) {
            CredentialVaultView()
                .environmentObject(model)
        }
        .sheet(isPresented: $showsSSHKeyGenerator) {
            SSHKeyGenerationView { request, session in
                model.generateSSHKey(request, session: session)
            }
        }
        .onChange(of: profile.id) { _, _ in
            setTerminalFocusMode(false)
            sftpSession.prepare(for: profile.id)
            selectedTab = .general
        }
        .onChange(of: profile.connectionType) { _, _ in
            if !availableTabs.contains(selectedTab) {
                selectedTab = .general
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab != .terminal {
                setTerminalFocusMode(false)
            }
        }
        .onChange(of: model.requestedSSHConsoleProfileID) { _, profileID in
            guard profileID == profile.id else { return }
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

            List(selection: Binding(
                get: { model.selectedProfileID },
                set: { if let id = $0 { model.selectProfile(id) } }
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
                                .contextMenu {
                                    if model.isSessionRunning(profileID: item.id)
                                        || model.isSSHTerminalRunning(profileID: item.id) {
                                        Button("Отключить", role: .destructive) {
                                            model.disconnect(profileID: item.id)
                                        }
                                        Divider()
                                    }
                                    Button("Создать копию") {
                                        model.selectProfile(item.id)
                                        model.duplicateSelectedProfile()
                                    }
                                    Divider()
                                    Button("Удалить", role: .destructive) {
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
                        .padding(.horizontal, terminalFocusMode ? 10 : 28)
                        .padding(.top, terminalFocusMode ? 10 : 0)
                        .padding(.bottom, terminalFocusMode ? 10 : 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 20) {
                                header
                                profileTabPicker
                            }
                            .frame(maxWidth: 1120, alignment: .leading)

                            selectedSettingsContent
                                .frame(
                                    maxWidth: selectedTab == .sftp ? .infinity : 1120,
                                    alignment: .leading
                                )
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
    }

    private var profileTabPicker: some View {
        Picker("Раздел", selection: $selectedTab) {
            ForEach(availableTabs) { tab in
                Label(tab.rawValue, systemImage: tab.systemImage)
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
        case .forwarding: PortForwardingView(profile: profile)
        case .security: securitySettings
        }
    }

    private var terminalPanel: some View {
        SSHTerminalView(
            workspace: model.terminalWorkspace(profileID: profile.id),
            appearance: terminalAppearance,
            appAppearance: appAppearance,
            profile: profile,
            hasInstallableKey: model.selectedSSHKey?.publicKeyPath != nil,
            isFocusMode: terminalFocusMode,
            connect: { session in
                model.connectSSHTerminal(profileID: profile.id, session: session)
            },
            installKey: model.installSelectedSSHPublicKey,
            toggleFocusMode: {
                setTerminalFocusMode(!terminalFocusMode)
            },
            discoverContext: {
                try await model.discoverTerminalContext(profileID: profile.id)
            }
        )
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

    private var sshGeneralSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Аутентификация") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("SSH-ключ", selection: profileBinding.sshIdentityID) {
                        Text("Автоматически: ~/.ssh/config / ssh-agent")
                            .tag(nil as UUID?)
                        ForEach(model.sshKeys) { key in
                            Text("\(key.name) · \(key.algorithm)")
                                .tag(Optional(key.id))
                        }
                    }
                    HStack {
                        Button("Добавить ключ…", systemImage: "plus") {
                            model.importSSHKey()
                        }
                        Button("Создать ключ…", systemImage: "key.horizontal") {
                            showsSSHKeyGenerator = true
                        }
                        Button("Установить на сервер", systemImage: "arrow.up.to.line") {
                            model.installSelectedSSHPublicKey()
                        }
                        .disabled(
                            model.selectedSSHKey?.publicKeyPath == nil
                                || model.isSelectedSSHTerminalRunning
                        )
                        Button("Keychain и ключи…", systemImage: "key.viewfinder") {
                            showsCredentialVault = true
                        }
                    }
                    Text(
                        "Встроенный терминал запрашивает passphrase напрямую. "
                            + "SFTP и forwarding используют активную SSH-сессию или ssh-agent; "
                            + "пароль SSH-сервера приложение не сохраняет."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(8)
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
                            "Пароль SSH-сервера не сохраняется",
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
                            showsCredentialVault = true
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
