import AppKit
import Foundation
import LocalAuthentication
import SwiftUI

private final class NotificationObserverBag: @unchecked Sendable {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    func append(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for token in tokens {
            center.removeObserver(token)
        }
    }
}

@MainActor
final class AppLockStore: ObservableObject {
    private enum Keys {
        static let enabled = "SelectiveRemote.appLock.enabled.v1"
        static let lockOnLaunch = "SelectiveRemote.appLock.onLaunch.v1"
        static let lockOnWake = "SelectiveRemote.appLock.onWake.v1"
        static let lockOnMinimize = "SelectiveRemote.appLock.onMinimize.v1"
        static let inactivityTimeout = "SelectiveRemote.appLock.inactivityTimeout.v1"
    }

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Keys.enabled)
            if !enabled {
                isLocked = false
                lastError = nil
            }
        }
    }
    @Published var lockOnLaunch: Bool {
        didSet { defaults.set(lockOnLaunch, forKey: Keys.lockOnLaunch) }
    }
    @Published var lockOnWake: Bool {
        didSet { defaults.set(lockOnWake, forKey: Keys.lockOnWake) }
    }
    @Published var lockOnMinimize: Bool {
        didSet { defaults.set(lockOnMinimize, forKey: Keys.lockOnMinimize) }
    }
    @Published var inactivityTimeout: TimeInterval {
        didSet { defaults.set(inactivityTimeout, forKey: Keys.inactivityTimeout) }
    }
    @Published private(set) var isLocked: Bool
    @Published private(set) var isAuthenticating = false
    @Published private(set) var lastError: String?

    private let defaults: UserDefaults
    private var inactiveSince: Date?
    private let notificationObservers = NotificationObserverBag(center: .default)
    private let workspaceNotificationObservers = NotificationObserverBag(
        center: NSWorkspace.shared.notificationCenter
    )

    var touchIDAvailable: Bool { KeychainService.touchIDAvailable }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedEnabled = defaults.bool(forKey: Keys.enabled)
        let savedLockOnLaunch = (defaults.object(forKey: Keys.lockOnLaunch) as? Bool) ?? true
        enabled = savedEnabled
        lockOnLaunch = savedLockOnLaunch
        lockOnWake = (defaults.object(forKey: Keys.lockOnWake) as? Bool) ?? true
        lockOnMinimize = defaults.bool(forKey: Keys.lockOnMinimize)
        let savedTimeout = defaults.object(forKey: Keys.inactivityTimeout) as? Double
        inactivityTimeout = savedTimeout ?? 300
        isLocked = savedEnabled && savedLockOnLaunch
        installLifecycleObservers()
    }

    func setEnabled(_ value: Bool) {
        guard !value || touchIDAvailable else {
            lastError = "Touch ID недоступен на этом Mac или для текущего пользователя."
            enabled = false
            return
        }
        enabled = value
        lastError = nil
    }

    func lockNow() {
        guard enabled else { return }
        isLocked = true
        isAuthenticating = false
        lastError = nil
    }

    func unlock() {
        guard enabled, isLocked, !isAuthenticating else { return }
        let context = LAContext()
        context.localizedCancelTitle = "Отмена"
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &evaluationError
        ), context.biometryType == .touchID else {
            lastError = evaluationError?.localizedDescription
                ?? "Touch ID недоступен. Проверьте настройки macOS."
            return
        }

        isAuthenticating = true
        lastError = nil
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Разблокировать Selective Remote"
        ) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.isLocked = false
                    self.inactiveSince = nil
                    self.lastError = nil
                } else {
                    self.lastError = Self.authenticationMessage(error)
                }
            }
        }
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.applicationDidResignActive() }
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.applicationDidBecomeActive() }
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: NSWindow.didMiniaturizeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.enabled, self.lockOnMinimize else { return }
                    self.lockNow()
                }
            }
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceNotificationObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.enabled, self.lockOnWake else { return }
                    self.lockNow()
                }
            }
        )
    }

    private func applicationDidResignActive() {
        guard enabled else { return }
        inactiveSince = Date()
        if inactivityTimeout <= 0 {
            lockNow()
        }
    }

    private func applicationDidBecomeActive() {
        guard enabled, !isLocked, let inactiveSince else { return }
        if Date().timeIntervalSince(inactiveSince) >= inactivityTimeout {
            lockNow()
        }
        self.inactiveSince = nil
    }

    private static func authenticationMessage(_ error: Error?) -> String {
        guard let laError = error as? LAError else {
            return error?.localizedDescription ?? "Не удалось подтвердить Touch ID."
        }
        switch laError.code {
        case .userCancel, .appCancel, .systemCancel:
            return "Разблокировка отменена."
        case .biometryLockout:
            return "Touch ID временно заблокирован. Разблокируйте его в macOS."
        case .biometryNotAvailable, .biometryNotEnrolled:
            return "Touch ID недоступен или отпечатки не настроены."
        default:
            return laError.localizedDescription
        }
    }
}

struct AppLockGate<Content: View>: View {
    @ObservedObject var store: AppLockStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let content: Content

    init(
        store: AppLockStore,
        @ViewBuilder content: () -> Content
    ) {
        self.store = store
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .opacity(store.isLocked ? 0 : 1)
                .allowsHitTesting(!store.isLocked)
                .accessibilityHidden(store.isLocked)

            if store.isLocked {
                AppLockScreen(store: store)
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: store.isLocked
        )
    }
}

private struct AppLockScreen: View {
    @ObservedObject var store: AppLockStore

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 86, height: 86)

            VStack(spacing: 7) {
                Text("Selective Remote заблокирован")
                    .font(.title.bold())
                Text("Подтвердите Touch ID, чтобы снова открыть подключения.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                store.unlock()
            } label: {
                Label(
                    store.isAuthenticating ? "Ожидаем Touch ID…" : "Разблокировать",
                    systemImage: "touchid"
                )
                .frame(minWidth: 190)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.isAuthenticating)

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct AppLockSettingsView: View {
    @ObservedObject var store: AppLockStore

    private let timeoutOptions: [(TimeInterval, String)] = [
        (0, "Сразу после перехода в фон"),
        (60, "Через 1 минуту"),
        (300, "Через 5 минут"),
        (900, "Через 15 минут"),
        (1800, "Через 30 минут")
    ]

    var body: some View {
        Form {
            Section("Блокировка приложения") {
                Toggle(
                    "Защищать Selective Remote с помощью Touch ID",
                    isOn: Binding(
                        get: { store.enabled },
                        set: { store.setEnabled($0) }
                    )
                )
                .disabled(!store.touchIDAvailable && !store.enabled)

                if !store.touchIDAvailable {
                    Label(
                        "Touch ID недоступен на этом Mac или не настроен.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }

                Text(
                    "App Lock закрывает интерфейс приложения. Пароли и passphrase независимо от него продолжают храниться в macOS Keychain."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Когда блокировать") {
                Toggle("При следующем запуске", isOn: $store.lockOnLaunch)
                Toggle("После выхода Mac из сна", isOn: $store.lockOnWake)
                Toggle("При сворачивании окна", isOn: $store.lockOnMinimize)
                Picker("После бездействия", selection: $store.inactivityTimeout) {
                    ForEach(timeoutOptions, id: \.0) { option in
                        Text(option.1).tag(option.0)
                    }
                }
            }
            .disabled(!store.enabled)

            Section("Проверка") {
                Button("Заблокировать сейчас", systemImage: "lock.fill") {
                    store.lockNow()
                }
                .disabled(!store.enabled)
                Text("Также доступно сочетание клавиш ⌘⇧L.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
