import AppKit
import SwiftUI

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
        let controller = NSHostingController(rootView: AppHelpView())
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

@main
struct SelectiveRemoteApp: App {
    @NSApplicationDelegateAdaptor(SelectiveRemoteApplicationDelegate.self)
    private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var language = AppLanguageStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(language)
                .environment(\.locale, language.locale)
                .frame(minWidth: 1050, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .help) {
                Button("Справка Selective Remote") {
                    appDelegate.showHelpWindow()
                }
                    .keyboardShortcut("?", modifiers: [.command])
            }
            CommandMenu("Сессия") {
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

        MenuBarExtra {
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
            if !model.sftpSession.transfers.items.isEmpty {
                Divider()
                Text("SFTP-передачи: \(model.sftpSession.transfers.activeCount) активных")
                if model.sftpSession.transfers.items.contains(where: { $0.phase == .paused }) {
                    Button("Продолжить SFTP-передачи", systemImage: "play.fill") {
                        model.sftpSession.transfers.resumeAll()
                    }
                } else if model.sftpSession.transfers.activeCount > 0 {
                    Button("Приостановить SFTP-передачи", systemImage: "pause.fill") {
                        model.sftpSession.transfers.pauseAll()
                    }
                }
                Button("Отменить SFTP-передачи", role: .destructive) {
                    model.sftpSession.transfers.cancelAll()
                }
                .disabled(model.sftpSession.transfers.activeCount == 0)
            }
            Divider()
            Text("Правый Shift + Enter — полный экран / окно")
            Text("Правый Shift + D — отключить RDP")
            Divider()
            Button("Проверить обновления…") { model.checkForUpdates() }
                .disabled(model.isCheckingForUpdates)
            Text(AppBuildInfo.fullText)
            Divider()
            Button("Завершить \(AppBrand.name)") { model.quitApplication() }
        } label: {
            Label(
                AppBrand.name,
                systemImage: model.isSessionRunning
                    || model.runningSSHTunnelCount > 0
                    || model.runningSSHTerminalCount > 0
                    ? "bolt.horizontal.circle.fill"
                    : "display"
            )
        }
        .menuBarExtraStyle(.menu)
        .environment(\.locale, language.locale)
    }
}
