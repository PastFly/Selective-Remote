import AppKit
import SwiftUI

extension Notification.Name {
    static let selectiveRemoteNewLocalTerminal = Notification.Name(
        "SelectiveRemote.newLocalTerminal"
    )
}

@MainActor
final class SelectiveRemoteApplicationDelegate: NSObject, NSApplicationDelegate {
    private var helpWindow: NSWindow?

    func applicationWillTerminate(_ notification: Notification) {
        SSHKeyService.stopManagedAgent()
    }

    func showHelpWindow() {
        if let helpWindow {
            helpWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(
            rootView: AppAppearanceRoot(store: .shared) { AppHelpView() }
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Справка Selective Remote"
        window.setContentSize(NSSize(width: 860, height: 700))
        window.minSize = NSSize(width: 720, height: 560)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        helpWindow = window
    }
}

private struct SFTPMenuBarTransferControls: View {
    @ObservedObject var workspace: SFTPWorkspaceModel

    var body: some View {
    if workspace.hasTransferItems {
        Divider()
        Text("SFTP-передачи: \(workspace.activeTransferCount) активных")
        if workspace.hasPausedTransfers {
            Button("Продолжить SFTP-передачи", systemImage: "play.fill") {
                workspace.resumeAllTransfers()
            }
        } else if workspace.activeTransferCount > 0 {
            Button("Приостановить SFTP-передачи", systemImage: "pause.fill") {
                workspace.pauseAllTransfers()
            }
        }
        Button("Отменить SFTP-передачи", role: .destructive) {
            workspace.cancelAllTransfers()
        }
        .disabled(workspace.activeTransferCount == 0)
    }
    }
}

@main
struct SelectiveRemoteApp: App {
    @NSApplicationDelegateAdaptor(SelectiveRemoteApplicationDelegate.self)
    private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var language = AppLanguageStore()
    @StateObject private var appAppearance = AppAppearanceStore.shared
    @StateObject private var appLock = AppLockStore()

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
                    .environmentObject(model)
                    .environmentObject(language)
                    .environmentObject(appAppearance)
                    .environment(\.locale, language.locale)
                    .frame(minWidth: 1050, minHeight: 700)
                    .onAppear {
                        model.presentWhatsNewAfterUpgradeIfNeeded()
                    }
            }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новая вкладка терминала", systemImage: "terminal") {
                    NotificationCenter.default.post(
                        name: .selectiveRemoteNewLocalTerminal,
                        object: nil
                    )
                }
                .keyboardShortcut("t", modifiers: [.command])
                .disabled(appLock.isLocked)
            }
            CommandGroup(replacing: .help) {
                Button("Что нового…", systemImage: "sparkles") {
                    model.openInstalledReleaseNotes()
                }
                Divider()
                Button("Справка Selective Remote") {
                    appDelegate.showHelpWindow()
                }
                    .keyboardShortcut("?", modifiers: [.command])
                Divider()
                Menu("Поддержать проект", systemImage: "heart") {
                    Button("ЮMoney…") {
                        NSWorkspace.shared.open(ProjectSupport.yoomoneyURL)
                    }
                    Button("Boosty…") {
                        NSWorkspace.shared.open(ProjectSupport.boostyURL)
                    }
                    Button("СберБанк…") {
                        NSWorkspace.shared.open(ProjectSupport.sberbankURL)
                    }
                }
            }
            CommandMenu("Сессия") {
                if appLock.isLocked {
                    Button("Разблокировать Selective Remote", systemImage: "touchid") {
                        appLock.unlock()
                    }
                    Button("Отключить App Lock…", systemImage: "lock.open") {
                        appLock.disableWithSystemAuthentication()
                    }
                } else {
                Button("Заблокировать Selective Remote", systemImage: "lock.fill") {
                    appLock.lockNow()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!appLock.enabled || appLock.isLocked)
                Divider()
                Button("Quick Connect…", systemImage: "bolt.fill") {
                    model.quickConnectPresented = true
                }
                .keyboardShortcut("k", modifiers: [.command])
                Divider()
                Button("Показать \(AppBrand.name)") { model.showMainWindow() }
                Divider()
                if model.runningSessions.isEmpty {
                    Text("Активных RDP-сессий нет")
                } else {
                    Button("Панель управления RDP…") {
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
                    Button("Отключить все", role: .destructive) {
                        model.disconnectAll()
                    }
                        .keyboardShortcut("d", modifiers: [.command, .option])
                }
                if model.runningSSHTunnelCount > 0 {
                    Divider()
                    Text("SSH-туннелей: \(model.runningSSHTunnelCount)")
                    Button("Остановить все SSH-туннели", role: .destructive) {
                        model.stopAllSSHTunnels()
                    }
                }
                if model.runningSSHTerminalCount > 0 {
                    Divider()
                    Text("SSH-сессий: \(model.runningSSHTerminalCount)")
                    Button("Отключить все SSH-сессии", role: .destructive) {
                        model.stopAllSSHTerminals()
                    }
                }
                if model.runningLocalTerminalCount > 0 {
                    Divider()
                    Text("Локальных терминалов: \(model.runningLocalTerminalCount)")
                    Button("Завершить все локальные терминалы", role: .destructive) {
                        model.stopAllLocalTerminals()
                    }
                }
                Divider()
                Button("Импортировать профили…") { model.importProfiles() }
                Button("Экспортировать все профили…") { model.exportAllProfiles() }
                Divider()
                Button("Проверить обновления…") { model.checkForUpdates() }
                    .disabled(model.isCheckingForUpdates)
                Divider()
                Text(AppBuildInfo.fullText)
                }
            }
        }

        Settings {
            AppLockGate(store: appLock) {
                AppSettingsView(
                    model: model,
                    appearance: appAppearance,
                    appLock: appLock
                )
            }
                .environmentObject(language)
                .environment(\.locale, language.locale)
        }

        MenuBarExtra {
            if appLock.isLocked {
                Button("Разблокировать Selective Remote", systemImage: "touchid") {
                    appLock.unlock()
                }
                Button("Отключить App Lock…", systemImage: "lock.open") {
                    appLock.disableWithSystemAuthentication()
                }
                Divider()
                Button("Завершить \(AppBrand.name)") { model.quitApplication() }
            } else {
            Button("Показать \(AppBrand.name)") { model.showMainWindow() }
            if !model.favoriteRDPProfiles.isEmpty {
                Divider()
                Text("Избранное")
                ForEach(model.favoriteRDPProfiles) { profile in
                    Button(
                        model.isSessionRunning(profileID: profile.id)
                            ? "\(profile.friendlyName) · подключено"
                            : "Подключить \(profile.friendlyName)",
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
                Text("RDP-сессии не запущены")
            } else {
                Text("Активных сессий: \(model.runningSessionCount)")
                Button("Открыть панель управления…", systemImage: "switch.2") {
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
                Button("Отключить все", role: .destructive) {
                    model.disconnectAll()
                }
            }
            if model.runningSSHTunnelCount > 0 {
                Divider()
                Text("SSH-туннелей: \(model.runningSSHTunnelCount)")
                Button("Остановить все SSH-туннели", role: .destructive) {
                    model.stopAllSSHTunnels()
                }
            }
            if model.runningSSHTerminalCount > 0 {
                Divider()
                Text("SSH-сессий: \(model.runningSSHTerminalCount)")
                Button("Отключить все SSH-сессии", role: .destructive) {
                    model.stopAllSSHTerminals()
                }
            }
            if model.runningLocalTerminalCount > 0 {
                Divider()
                Text("Локальных терминалов: \(model.runningLocalTerminalCount)")
                Button("Завершить все локальные терминалы", role: .destructive) {
                    model.stopAllLocalTerminals()
                }
            }
            SFTPMenuBarTransferControls(workspace: model.sftpWorkspace)
            Divider()
            Text("Правый Shift + Enter — полный экран / окно")
            Text("Правый Shift + D — отключить RDP")
            Divider()
            Button("Проверить обновления…") { model.checkForUpdates() }
                .disabled(model.isCheckingForUpdates)
            Text(AppBuildInfo.fullText)
            Divider()
            Button("Завершить \(AppBrand.name)") { model.quitApplication() }
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
}
