import AppKit
import Darwin
import SwiftUI

extension Notification.Name {
    static let selectiveRemoteNewLocalTerminal = Notification.Name(
        "SelectiveRemote.newLocalTerminal"
    )
    static let selectiveRemoteLocalPasswordChanged = Notification.Name(
        "SelectiveRemote.localPasswordChanged"
    )
    static let selectiveRemotePersonalVaultSyncNow = Notification.Name(
        "SelectiveRemote.personalVaultSyncNow"
    )
    static let selectiveRemoteCloudTeamMembershipChanged = Notification.Name(
        "SelectiveRemote.cloudTeamMembershipChanged"
    )
    static let selectiveRemoteCloudSessionChanged = Notification.Name(
        "SelectiveRemote.cloudSessionChanged"
    )
    static let selectiveRemoteCloudSessionLost = Notification.Name(
        "SelectiveRemote.cloudSessionLost"
    )
    static let selectiveRemoteOpenTeamHosts = Notification.Name(
        "SelectiveRemote.openTeamHosts"
    )
    static let selectiveRemoteTeamVaultSyncNow = Notification.Name(
        "SelectiveRemote.teamVaultSyncNow"
    )
}

@MainActor
final class SelectiveRemoteApplicationDelegate: NSObject, NSApplicationDelegate {
    private var helpWindow: NSWindow?
    private var aboutWindow: NSWindow?

    func applicationWillTerminate(_ notification: Notification) {
        SSHKeyService.stopManagedAgent()
    }

    func showHelpWindow() {
        if let helpWindow {
            refreshAuxiliaryTitles()
            helpWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(
            rootView: AppAuxiliaryWindowRoot(store: .shared) { AppHelpView() }
        )
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        configureAuxiliaryWindow(window)
        window.title = UpdateLocalization.text(
            ru: "Справка Selective Remote",
            en: "Selective Remote Help"
        )
        window.setContentSize(NSSize(width: 860, height: 700))
        window.minSize = NSSize(width: 720, height: 560)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        helpWindow = window
    }

    func showAboutWindow() {
        if let aboutWindow {
            refreshAuxiliaryTitles()
            aboutWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(
            rootView: AppAuxiliaryWindowRoot(store: .shared) { AppAboutView() }
        )
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable]
        configureAuxiliaryWindow(window)
        window.title = UpdateLocalization.text(
            ru: "О Selective Remote",
            en: "About Selective Remote"
        )
        window.setContentSize(NSSize(width: 520, height: 500))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow = window
    }

    private func configureAuxiliaryWindow(_ window: NSWindow) {
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.titlebarAppearsTransparent = false
        window.hasShadow = true
    }

    func refreshAuxiliaryTitles() {
        helpWindow?.title = UpdateLocalization.text(
            ru: "Справка Selective Remote", en: "Selective Remote Help"
        )
        aboutWindow?.title = UpdateLocalization.text(
            ru: "О Selective Remote", en: "About Selective Remote"
        )
    }
}

private struct SFTPMenuBarTransferControls: View {
    @ObservedObject var workspace: SFTPWorkspaceModel

    var body: some View {
    if workspace.hasTransferItems {
        Divider()
        Text(UpdateLocalization.text(
            ru: "SFTP-передачи: \(workspace.activeTransferCount) активных",
            en: "SFTP transfers: \(workspace.activeTransferCount) active"
        ))
        if workspace.hasPausedTransfers {
            Button(UpdateLocalization.key("menu.sftp.resume"), systemImage: "play.fill") {
                workspace.resumeAllTransfers()
            }
        } else if workspace.activeTransferCount > 0 {
            Button(UpdateLocalization.key("menu.sftp.pause"), systemImage: "pause.fill") {
                workspace.pauseAllTransfers()
            }
        }
        Button(UpdateLocalization.key("menu.sftp.cancel"), role: .destructive) {
            workspace.cancelAllTransfers()
        }
        .disabled(workspace.activeTransferCount == 0)
    }
    }
}

private struct SelectiveRemoteCloudCommands: Commands {
    @ObservedObject var appLock: AppLockStore
    @Environment(\.openSettings) private var openSettings
    @AppStorage("SelectiveRemote.cloud.endpoint.v1")
    private var endpoint = SelectiveRemoteCloudEndpoint.production

    var body: some Commands {
        let loginURL = SelectiveRemoteCloudPortalURL.login(endpoint: endpoint)
        CommandMenu("Cloud") {
            Button(
                UpdateLocalization.key("menu.cloud.settings"),
                systemImage: "cloud"
            ) {
                UserDefaults.standard.set("cloud", forKey: "SelectiveRemote.settings.selected-tab.v1")
                openSettings()
            }
            .disabled(appLock.isLocked)

            Button(
                UpdateLocalization.key("menu.cloud.browser"),
                systemImage: "safari"
            ) {
                if let loginURL {
                    NSWorkspace.shared.open(loginURL)
                }
            }
            .disabled(loginURL == nil)
        }
    }
}

@main
struct SelectiveRemoteApp: App {
    // Acquire before initializing stores that cache whole local collections.
    private static let sharedStorageLease = acquireStorageLease()
    private let storageLease = Self.sharedStorageLease
    @NSApplicationDelegateAdaptor(SelectiveRemoteApplicationDelegate.self)
    private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var language = AppLanguageStore.shared
    @StateObject private var appAppearance = AppAppearanceStore.shared
    @StateObject private var appLock = AppLockStore()
    private let personalVaultAutoSync = SelectiveRemotePersonalVaultAutoSync()
    @State private var personalUploadGeneration = UUID()
    @State private var applyingPersonalVaultDownload = false
    @State private var personalSyncSnippets: [TerminalCommandTemplate] = []
    private let teamVaultAutoSync = SelectiveRemoteTeamVaultAutoSync.shared
    private let syncPresentation = SyncPresentationStore.shared

    private static func acquireStorageLease() -> NativeStorageLease {
        do {
            let lease = try NativeStorageLease()
            try NativeStorageMigration.prepare(UserDefaults.standard)
            try NativeStorageMigration.prepareWorkspaces(UserDefaults.standard)
            try NativeStorageValidation.validate(UserDefaults.standard)
            try NativeStorageValidation.finishLegacyProfileMigration(UserDefaults.standard)
            return lease
        }
        catch {
            let alert = NSAlert()
            alert.messageText = UpdateLocalization.text(ru: "Не удалось открыть хранилище", en: "Unable to open storage")
            alert.informativeText = UpdateLocalization.text(
                ru: "Другая копия приложения уже работает либо не удалось безопасно подготовить хранилище. Закройте другие копии и повторите попытку.",
                en: "Another app copy is running or storage could not be prepared safely. Close other copies and try again."
            )
            alert.runModal()
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private var menuBarSystemImage: String {
        if appLock.isLocked { return "lock.fill" }
        if model.isSessionRunning
            || model.runningSSHTunnelCount > 0
            || model.runningSSHTerminalCount > 0
            || model.runningLocalTerminalCount > 0 {
            return "bolt.horizontal.circle.fill"
        }
        return "display"
    }

    var body: some Scene {
        WindowGroup {
            AppLockGate(store: appLock) {
                ContentView()
                    .background(AppRuntimeLanguageObserver())
                    .environmentObject(model)
                    .environmentObject(language)
                    .environmentObject(appAppearance)
                    .environment(\.locale, language.locale)
                    .toggleStyle(SelectiveRemoteCheckboxToggleStyle())
                    .modifier(SelectiveRemoteCloudTeamInvitationPrompt())
                    .frame(minWidth: 1050, minHeight: 700)
                    .onAppear {
                        model.presentWhatsNewAfterUpgradeIfNeeded()
                        personalSyncSnippets = TerminalCommandHistoryStore.shared.templates()
                        configureSyncPresentation()
                    }
                    .task {
                        await runPersonalVaultInboundSyncLoop()
                    }
                    .onChange(of: model.profiles) { old, new in
                        schedulePersonalVaultEdits(from: old, to: new) { before, after in
                            var previous = before
                            previous.lastConnectedAt = after.lastConnectedAt
                            return previous == after
                        }
                    }
                    .onChange(of: model.independentPortForwards) { old, new in
                        schedulePersonalVaultEdits(from: old, to: new)
                    }
                    .onChange(of: model.sshKeys) { old, new in
                        schedulePersonalVaultEdits(from: old, to: new)
                    }
                    .onReceive(TerminalCommandHistoryStore.shared.$snippetRevision.dropFirst()) { _ in
                        let previous = personalSyncSnippets
                        personalSyncSnippets = TerminalCommandHistoryStore.shared.templates()
                        schedulePersonalVaultEdits(from: previous, to: personalSyncSnippets)
                    }
                    .onReceive(NotificationCenter.default.publisher(
                        for: .selectiveRemoteLocalPasswordChanged
                    ).receive(on: RunLoop.main)) { notification in
                        guard let id = notification.object as? UUID else { return }
                        schedulePersonalVaultAutoSync(editDates: [id: Date()])
                    }
                    .onReceive(NotificationCenter.default.publisher(
                        for: .selectiveRemotePersonalVaultSyncNow
                    )) { _ in
                        schedulePersonalVaultAutoSync()
                    }
                    .onReceive(NotificationCenter.default.publisher(
                        for: .selectiveRemoteCloudSessionChanged
                    )) { _ in
                        schedulePersonalVaultAutoSync()
                    }
                    .onReceive(NotificationCenter.default.publisher(
                        for: .selectiveRemoteTeamVaultSyncNow
                    )) { _ in
                        Task {
                            do { _ = try await teamVaultAutoSync.synchronizeConfiguredAccountNow() }
                            catch {
                                if error as? SelectiveRemoteCloudError == .invalidRequest {
                                    syncPresentation.setPrerequisite(.team, lifecycle: .signedOut)
                                } else {
                                    syncPresentation.recordTeamFailure()
                                }
                            }
                        }
                    }
            }
            .onChange(of: appLock.isLocked) { _, _ in
                updateTeamVaultAutoSync()
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                syncPresentation.setAccount(
                    endpoint: cloudEndpointPreference,
                    deviceID: UserDefaults.standard.string(forKey: "SelectiveRemote.cloud.device-id.v1")
                )
            }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(UpdateLocalization.key("menu.app.about")) {
                    appDelegate.showAboutWindow()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button(UpdateLocalization.key("menu.terminal.new_tab"), systemImage: "terminal") {
                    NotificationCenter.default.post(
                        name: .selectiveRemoteNewLocalTerminal,
                        object: nil
                    )
                }
                .keyboardShortcut("t", modifiers: [.command])
                .disabled(appLock.isLocked)
            }
            CommandGroup(replacing: .help) {
                Button(UpdateLocalization.key("menu.whats_new"), systemImage: "sparkles") {
                    model.openInstalledReleaseNotes()
                }
                Divider()
                Button(UpdateLocalization.key("menu.help.title")) {
                    appDelegate.showHelpWindow()
                }
                    .keyboardShortcut("?", modifiers: [.command])
                Divider()
                Menu(UpdateLocalization.key("help.support.title"), systemImage: "heart") {
                    Button(UpdateLocalization.key("menu.help.yoomoney")) {
                        NSWorkspace.shared.open(ProjectSupport.yoomoneyURL)
                    }
                    Button("Boosty…") {
                        NSWorkspace.shared.open(ProjectSupport.boostyURL)
                    }
                    Button(UpdateLocalization.key("menu.help.sberbank")) {
                        NSWorkspace.shared.open(ProjectSupport.sberbankURL)
                    }
                }
            }
            CommandMenu(UpdateLocalization.key("menu.session.title")) {
                if appLock.isLocked {
                    Button(UpdateLocalization.key("menu.session.unlock"), systemImage: "touchid") {
                        appLock.unlock()
                    }
                    Button(UpdateLocalization.key("menu.session.disable_lock"), systemImage: "lock.open") {
                        appLock.disableWithSystemAuthentication()
                    }
                } else {
                Button(UpdateLocalization.key("menu.session.lock"), systemImage: "lock.fill") {
                    appLock.lockNow()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!appLock.enabled || appLock.isLocked)
                Divider()
                Button(UpdateLocalization.key("menu.session.quick_connect"), systemImage: "bolt.fill") {
                    model.quickConnectPresented = true
                }
                .keyboardShortcut("k", modifiers: [.command])
                Divider()
                Button(UpdateLocalization.key("menu.session.show_main")) { model.showMainWindow() }
                Divider()
                if model.runningSessions.isEmpty {
                    Text(UpdateLocalization.key("menu.session.no_rdp"))
                } else {
                    Button(UpdateLocalization.key("menu.session.rdp_panel")) {
                        model.showRDPControlPanel()
                    }
                    ForEach(model.runningSessions) { session in
                        Menu(session.profileName) {
                            ForEach(RDPSessionCommand.allCases) { command in
                                Button(command.title, systemImage: command.systemImage) {
                                    model.sendRDPCommand(command, profileID: session.id)
                                }
                            }
                        }
                    }
                    Divider()
                    Button(UpdateLocalization.key("menu.session.disconnect_all"), role: .destructive) {
                        model.disconnectAll()
                    }
                        .keyboardShortcut("d", modifiers: [.command, .option])
                }
                if model.runningSSHTunnelCount > 0 {
                    Divider()
                    Text("\(UpdateLocalization.key("menu.session.ssh_tunnels_count")): \(model.runningSSHTunnelCount)")
                    Button(UpdateLocalization.key("menu.session.stop_ssh_tunnels"), role: .destructive) {
                        model.stopAllSSHTunnels()
                    }
                }
                if model.runningSSHTerminalCount > 0 {
                    Divider()
                    Text("\(UpdateLocalization.key("menu.session.ssh_sessions_count")): \(model.runningSSHTerminalCount)")
                    Button(UpdateLocalization.key("menu.session.disconnect_ssh"), role: .destructive) {
                        model.stopAllSSHTerminals()
                    }
                }
                if model.runningLocalTerminalCount > 0 {
                    Divider()
                    Text("\(UpdateLocalization.key("menu.session.local_terminals_count")): \(model.runningLocalTerminalCount)")
                    Button(UpdateLocalization.key("menu.session.stop_local_terminals"), role: .destructive) {
                        model.stopAllLocalTerminals()
                    }
                }
                Divider()
                Button(UpdateLocalization.key("menu.session.import_profiles")) { model.importProfiles() }
                Button(UpdateLocalization.key("menu.session.export_profiles")) { model.exportAllProfiles() }
                Divider()
                Button(UpdateLocalization.key("menu.session.check_updates")) { model.checkForUpdates() }
                    .disabled(model.isCheckingForUpdates)
                Divider()
                Text(AppBuildInfo.fullText)
                }
            }
            SelectiveRemoteCloudCommands(appLock: appLock)
        }

        Settings {
            AppLockGate(store: appLock) {
                AppSettingsView(
                    model: model,
                    appearance: appAppearance,
                    appLock: appLock
                )
                .toggleStyle(SelectiveRemoteCheckboxToggleStyle())
                .background(
                    SettingsWindowCloseGuard(
                        preventsClosing: model.isUpdateOperationInProgress
                    )
                )
            }
                .environmentObject(language)
                .environment(\.locale, language.locale)
        }

        MenuBarExtra {
            if appLock.isLocked {
                Button(UpdateLocalization.key("menu.session.unlock"), systemImage: "touchid") {
                    appLock.unlock()
                }
                Button(UpdateLocalization.key("menu.session.disable_lock"), systemImage: "lock.open") {
                    appLock.disableWithSystemAuthentication()
                }
                Divider()
                Button(UpdateLocalization.key("menu.session.quit")) { model.quitApplication() }
            } else {
            Button(UpdateLocalization.key("menu.session.show_main")) { model.showMainWindow() }
            if !model.favoriteRDPProfiles.isEmpty {
                Divider()
                Text(UpdateLocalization.key("menu.favorites"))
                ForEach(model.favoriteRDPProfiles) { profile in
                    Button(
                        model.isSessionRunning(profileID: profile.id)
                            ? "\(profile.friendlyName) · \(UpdateLocalization.key("menu.connected"))"
                            : "\(UpdateLocalization.key("menu.connect")) \(profile.friendlyName)",
                        systemImage: profile.isFavorite ? "star.fill" : "star"
                    ) {
                        if model.isSessionRunning(profileID: profile.id) {
                            model.showRDPControlPanel()
                        } else {
                            model.connectFavorite(profileID: profile.id)
                        }
                    }
                }
            }
            Divider()
            if model.runningSessions.isEmpty {
                Text(UpdateLocalization.key("menu.no_rdp_running"))
            } else {
                Text("\(UpdateLocalization.key("menu.active_sessions")): \(model.runningSessionCount)")
                Button(UpdateLocalization.key("menu.open_control_panel"), systemImage: "switch.2") {
                    model.showRDPControlPanel()
                }
                ForEach(model.runningSessions) { session in
                    Menu(session.profileName) {
                        ForEach(RDPSessionCommand.allCases) { command in
                            Button(command.title, systemImage: command.systemImage) {
                                model.sendRDPCommand(command, profileID: session.id)
                            }
                        }
                    }
                }
                Divider()
                Button(UpdateLocalization.key("menu.session.disconnect_all"), role: .destructive) {
                    model.disconnectAll()
                }
            }
            if model.runningSSHTunnelCount > 0 {
                Divider()
                Text("\(UpdateLocalization.key("menu.session.ssh_tunnels_count")): \(model.runningSSHTunnelCount)")
                Button(UpdateLocalization.key("menu.session.stop_ssh_tunnels"), role: .destructive) {
                    model.stopAllSSHTunnels()
                }
            }
            if model.runningSSHTerminalCount > 0 {
                Divider()
                Text("\(UpdateLocalization.key("menu.session.ssh_sessions_count")): \(model.runningSSHTerminalCount)")
                Button(UpdateLocalization.key("menu.session.disconnect_ssh"), role: .destructive) {
                    model.stopAllSSHTerminals()
                }
            }
            if model.runningLocalTerminalCount > 0 {
                Divider()
                Text("\(UpdateLocalization.key("menu.session.local_terminals_count")): \(model.runningLocalTerminalCount)")
                Button(UpdateLocalization.key("menu.session.stop_local_terminals"), role: .destructive) {
                    model.stopAllLocalTerminals()
                }
            }
            SFTPMenuBarTransferControls(workspace: model.sftpWorkspace)
            Divider()
            Text(UpdateLocalization.key("menu.shortcut.full_screen"))
            Text(UpdateLocalization.key("menu.shortcut.disconnect"))
            Divider()
            Button(UpdateLocalization.key("menu.session.check_updates")) { model.checkForUpdates() }
                .disabled(model.isCheckingForUpdates)
            Text(AppBuildInfo.fullText)
            Divider()
            Button(UpdateLocalization.key("menu.session.quit")) { model.quitApplication() }
            }
        } label: {
            Label(
                AppBrand.name,
                systemImage: menuBarSystemImage
            )
        }
        .menuBarExtraStyle(.menu)
        .environment(\.locale, language.locale)
    }

    private func updateTeamVaultAutoSync() {
        let shouldRun = !appLock.isLocked
        if !shouldRun {
            syncPresentation.setPrerequisite(.team, lifecycle: .locked)
            syncPresentation.setPrerequisite(.personal, lifecycle: .locked)
        }
        Task {
            if shouldRun {
                await teamVaultAutoSync.start()
                _ = try? await teamVaultAutoSync.synchronizeConfiguredAccountNow()
            } else {
                await teamVaultAutoSync.stop()
            }
        }
    }

    private func configureSyncPresentation() {
        syncPresentation.setAccount(
            endpoint: cloudEndpointPreference,
            deviceID: UserDefaults.standard.string(forKey: "SelectiveRemote.cloud.device-id.v1")
        )
        Task {
            await teamVaultAutoSync.observePresentation { event in
                await MainActor.run {
                    switch event {
                    case let .started(token, endpoint, deviceID):
                        if syncPresentation.matchesAccount(
                            endpoint: endpoint.absoluteString, deviceID: deviceID.uuidString
                        ) { syncPresentation.beginTeamCycle(token: token) }
                    case let .completed(report, token, endpoint, deviceID):
                        if syncPresentation.matchesAccount(
                            endpoint: endpoint.absoluteString, deviceID: deviceID.uuidString
                        ) { syncPresentation.completeTeamCycle(report, token: token) }
                    case let .failed(token, endpoint, deviceID):
                        if syncPresentation.matchesAccount(
                            endpoint: endpoint.absoluteString, deviceID: deviceID.uuidString
                        ) { syncPresentation.failTeamCycle(token: token) }
                    }
                }
            }
            updateTeamVaultAutoSync()
        }
    }

    private var cloudEndpointPreference: String {
        UserDefaults.standard.string(forKey: "SelectiveRemote.cloud.endpoint.v1")
            ?? SelectiveRemoteCloudEndpoint.production
    }

    @MainActor
    private func schedulePersonalVaultEdits<T: Identifiable & Equatable>(
        from old: [T], to new: [T], matching: (T, T) -> Bool = (==)
    ) where T.ID == UUID {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        var changed: [UUID: Date] = [:]
        for id in Set(before.keys).union(after.keys) {
            if let previous = before[id], let value = after[id], matching(previous, value) { continue }
            changed[id] = now
        }
        if !changed.isEmpty { schedulePersonalVaultAutoSync(editDates: changed) }
    }

    @discardableResult
    @MainActor
    private func schedulePersonalVaultAutoSync(editDates: [UUID: Date] = [:]) -> Task<Void, Never>? {
        guard !applyingPersonalVaultDownload else { return nil }
        guard !appLock.isLocked else {
            syncPresentation.setPrerequisite(.personal, lifecycle: .locked)
            return nil
        }
        guard UserDefaults.standard.object(
            forKey: "SelectiveRemote.cloud.personal-vault-sync-enabled.v1"
        ) as? Bool ?? true else {
            syncPresentation.setPrerequisite(.personal, lifecycle: .disabled)
            return nil
        }
        guard let endpoint = try? SelectiveRemoteCloudEndpoint.normalized(cloudEndpointPreference),
              let deviceText = UserDefaults.standard.string(forKey: "SelectiveRemote.cloud.device-id.v1"),
              let deviceID = UUID(uuidString: deviceText), deviceID.isSelectiveRemoteCloudUUID
        else {
            syncPresentation.setPrerequisite(.personal, lifecycle: .signedOut)
            return nil
        }
        let sessionEpoch = SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint)
        let profiles = model.profiles
        let snippets = TerminalCommandHistoryStore.shared.templates()
        let forwarding = model.independentPortForwards
        let sshKeys = model.sshKeys
        let syncGeneration = syncPresentation.generation
        let syncEndpoint = endpoint.absoluteString
        let syncDeviceID = deviceID.uuidString
        let uploadGeneration = UUID()
        personalUploadGeneration = uploadGeneration
        if !editDates.isEmpty, ![.setupRequired, .signedOut].contains(syncPresentation.personal.lifecycle) {
            syncPresentation.recordPersonalPending()
        }
        let legacyAppliedRevision = UserDefaults.standard.integer(
            forKey: SelectiveRemotePersonalVaultSyncStatus.revisionKey
        )
        return Task {
            guard personalUploadGeneration == uploadGeneration,
                  syncPresentation.generation == syncGeneration else { return }
            let upload = await personalVaultAutoSync.schedule(
                endpoint: endpoint,
                deviceID: deviceID,
                expectedSessionEpoch: sessionEpoch,
                profiles: profiles,
                snippets: snippets,
                forwarding: forwarding,
                sshKeys: sshKeys,
                editDates: editDates,
                legacyAppliedRevision: legacyAppliedRevision,
                onFailure: { issue in
                    await MainActor.run {
                        guard personalUploadGeneration == uploadGeneration,
                              syncPresentation.generation == syncGeneration,
                              syncPresentation.matchesAccount(
                                endpoint: syncEndpoint, deviceID: syncDeviceID
                              ) else { return }
                        syncPresentation.recordPersonalFailure(issue)
                    }
                }
            )
            await upload.value
            guard personalUploadGeneration == uploadGeneration, syncPresentation.generation == syncGeneration
            else { return }
            await downloadPersonalVaultChanges(afterReconciliation: true)
        }
    }

    @MainActor
    private func runPersonalVaultInboundSyncLoop() async {
        await schedulePersonalVaultAutoSync()?.value
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            await downloadPersonalVaultChanges()
        }
    }

    @MainActor
    private func downloadPersonalVaultChanges(afterReconciliation: Bool = false) async {
        guard !appLock.isLocked else {
            syncPresentation.setPrerequisite(.personal, lifecycle: .locked)
            return
        }
        guard UserDefaults.standard.object(
            forKey: "SelectiveRemote.cloud.personal-vault-sync-enabled.v1"
        ) as? Bool ?? true else {
            syncPresentation.setPrerequisite(.personal, lifecycle: .disabled)
            return
        }
        guard let endpoint = try? SelectiveRemoteCloudEndpoint.normalized(cloudEndpointPreference),
              let deviceText = UserDefaults.standard.string(
                  forKey: "SelectiveRemote.cloud.device-id.v1"
              ),
              let deviceID = UUID(uuidString: deviceText), deviceID.isSelectiveRemoteCloudUUID
        else {
            syncPresentation.setPrerequisite(.personal, lifecycle: .signedOut)
            return
        }
        UserDefaults.standard.set(
            true,
            forKey: SelectiveRemotePersonalVaultSyncStatus.isSyncingKey
        )
        let syncGeneration = syncPresentation.generation
        let uploadGeneration = personalUploadGeneration
        if syncPresentation.personal.pendingLocalChanges != true,
           ![.setupRequired, .signedOut].contains(syncPresentation.personal.lifecycle) {
            syncPresentation.begin(.personal)
        }
        defer {
            UserDefaults.standard.set(
                false,
                forKey: SelectiveRemotePersonalVaultSyncStatus.isSyncingKey
            )
        }
        do {
            let result = try await personalVaultAutoSync.checkForChanges(
                endpoint: endpoint,
                deviceID: deviceID
            )
            guard syncPresentation.matchesAccount(
                endpoint: endpoint.absoluteString, deviceID: deviceID.uuidString
            ), syncPresentation.generation == syncGeneration,
               personalUploadGeneration == uploadGeneration else { return }
            let download: SelectiveRemotePersonalVaultAutoSync.Download
            switch result {
            case .unavailable:
                syncPresentation.recordPersonalUnknown()
                return
            case .signedOut:
                syncPresentation.setPrerequisite(.personal, lifecycle: .signedOut)
                return
            case .setupRequired:
                syncPresentation.setPrerequisite(.personal, lifecycle: .setupRequired)
                return
            case let .unconfirmedUpload(issue):
                if let issue {
                    syncPresentation.recordPersonalFailure(issue)
                    if !afterReconciliation { schedulePersonalVaultAutoSync() }
                } else { syncPresentation.recordPersonalPending() }
                return
            case let .current(revision):
                SelectiveRemotePersonalVaultSyncStatus.recordSuccess(revision: revision)
                syncPresentation.recordPersonalSuccess(revision: revision, generation: syncGeneration)
                return
            case let .download(newer):
                guard afterReconciliation else {
                    schedulePersonalVaultAutoSync()
                    return
                }
                download = newer
            }
            let snapshot = try SelectiveRemotePersonalVaultImporter.decode(download.document)
            applyingPersonalVaultDownload = true
            defer { applyingPersonalVaultDownload = false }
            let accepted = try personalVaultAutoSync.acceptDownload(
                download,
                endpoint: endpoint,
                deviceID: deviceID,
                apply: {
                    guard syncPresentation.matchesAccount(
                        endpoint: endpoint.absoluteString, deviceID: deviceID.uuidString
                    ), syncPresentation.generation == syncGeneration,
                       personalUploadGeneration == uploadGeneration else { return false }
                    let restoredKeys = try SelectiveRemotePersonalVaultSSHKeyStore.install(snapshot.sshKeys)
                    let sources = model.profiles.map(\.id) + model.independentPortForwards.map(\.id)
                    try KeychainService.applySyncedPasswords(
                        snapshot.credentials, tombstones: snapshot.tombstoneIDs, sourceIDs: sources
                    )
                    if model.profiles != snapshot.profiles { model.profiles = snapshot.profiles }
                    if model.independentPortForwards != snapshot.forwarding {
                        model.independentPortForwards = snapshot.forwarding
                    }
                    if model.sshKeys != restoredKeys { model.sshKeys = restoredKeys }
                    TerminalCommandHistoryStore.shared.replaceSyncedTemplates(snapshot.snippets)
                    return true
                }
            )
            guard syncPresentation.matchesAccount(
                endpoint: endpoint.absoluteString, deviceID: deviceID.uuidString
            ), syncPresentation.generation == syncGeneration,
               personalUploadGeneration == uploadGeneration else { return }
            guard accepted else { syncPresentation.recordPersonalUnknown(); return }
            SelectiveRemotePersonalVaultSyncStatus.recordSuccess(revision: download.revision)
            syncPresentation.recordPersonalSuccess(
                revision: download.revision, generation: syncGeneration
            )
        } catch {
            guard personalUploadGeneration == uploadGeneration,
                  syncPresentation.matchesAccount(
                endpoint: endpoint.absoluteString, deviceID: deviceID.uuidString
            ), syncPresentation.generation == syncGeneration else { return }
            if (error as? SelectiveRemoteCloudError)?.isAuthenticationLoss == true {
                syncPresentation.setPrerequisite(.personal, lifecycle: .signedOut)
                return
            }
            SelectiveRemotePersonalVaultSyncStatus.recordError(error)
            syncPresentation.recordPersonalFailure(SyncIssue.classifyPersonal(error))
        }
    }
}
