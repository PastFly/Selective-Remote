import AppKit
import AVFoundation
import Foundation
import LocalAuthentication
import Security
import SwiftUI

enum SystemDiagnosticCheckStatus: String {
    case passed
    case warning
    case failed
    case info

    var systemImage: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        case .info: .secondary
        }
    }
}

enum SystemDiagnosticCheckAction: String {
    case cameraSettings
    case microphoneSettings
}

struct SystemDiagnosticCheckResult: Identifiable {
    let id: String
    let category: String
    let title: String
    let detail: String
    let status: SystemDiagnosticCheckStatus
    let action: SystemDiagnosticCheckAction?
}

@MainActor
enum SystemDiagnosticsCheckService {
    private static let rawHistoryRU = URL(
        string: "https://raw.githubusercontent.com/PastFly/Selective-Remote/main/CHANGELOG.md"
    )!
    private static let rawHistoryEN = URL(
        string: "https://raw.githubusercontent.com/PastFly/Selective-Remote/main/CHANGELOG_EN.md"
    )!

    static func run(
        bundle: Bundle = .main,
        session: URLSession = .shared
    ) async -> [SystemDiagnosticCheckResult] {
        var results = localChecks(bundle: bundle)
        results += await updateChecks(bundle: bundle, session: session)
        return results
    }

    private static func localChecks(bundle: Bundle) -> [SystemDiagnosticCheckResult] {
        var results: [SystemDiagnosticCheckResult] = []
        let fileManager = FileManager.default

        results.append(result(
            "app-version",
            category: "Приложение",
            title: "Selective Remote",
            detail: AppBuildInfo.fullText,
            status: .passed
        ))
        results.append(result(
            "macos",
            category: "Приложение",
            title: "macOS",
            detail: DiagnosticsSystemInfo.macOSVersion,
            status: .passed
        ))
        results.append(result(
            "architecture",
            category: "Приложение",
            title: "Архитектура",
            detail: DiagnosticsSystemInfo.architecture,
            status: DiagnosticsSystemInfo.architecture == "unknown" ? .warning : .passed
        ))

        let bundleURL = bundle.bundleURL.standardizedFileURL
        let isApplicationBundle = bundleURL.pathExtension.lowercased() == "app"
        let isTranslocated = bundleURL.path.contains("/AppTranslocation/")
        let parent = bundleURL.deletingLastPathComponent()
        let parentWritable = fileManager.isWritableFile(atPath: parent.path)

        results.append(result(
            "app-location",
            category: "Приложение",
            title: "Расположение приложения",
            detail: isTranslocated
                ? localized("Приложение запущено через App Translocation", "The app is running through App Translocation")
                : bundleURL.path,
            status: isTranslocated ? .warning : (isApplicationBundle ? .passed : .info)
        ))
        results.append(result(
            "update-write-access",
            category: "Приложение",
            title: "Автоустановка обновлений",
            detail: parentWritable && isApplicationBundle && !isTranslocated
                ? localized("Папка приложения доступна для безопасной замены без sudo", "The application folder is writable for a safe update without sudo")
                : localized("Автоматическая замена может потребовать ручной установки через Finder", "Automatic replacement may require manual installation through Finder"),
            status: parentWritable && isApplicationBundle && !isTranslocated ? .passed : .warning
        ))

        let sshPath = "/usr/bin/ssh"
        results.append(result(
            "ssh-binary",
            category: "SSH",
            title: "/usr/bin/ssh",
            detail: fileManager.isExecutableFile(atPath: sshPath)
                ? localized("Системный OpenSSH доступен", "System OpenSSH is available")
                : localized("Системный OpenSSH не найден или не исполняется", "System OpenSSH is missing or not executable"),
            status: fileManager.isExecutableFile(atPath: sshPath) ? .passed : .failed
        ))

        let sshAgentPath = "/usr/bin/ssh-agent"
        let sshAgentAvailable = fileManager.isExecutableFile(atPath: sshAgentPath)
        let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        results.append(result(
            "ssh-agent",
            category: "SSH",
            title: "ssh-agent",
            detail: sshAgentAvailable
                ? (socket?.isEmpty == false
                    ? localized("Системный ssh-agent доступен, сокет активен", "System ssh-agent is available and its socket is active")
                    : localized("Системный ssh-agent доступен; Selective Remote может запустить managed agent при необходимости", "System ssh-agent is available; Selective Remote can start a managed agent when needed"))
                : localized("Системный ssh-agent недоступен", "System ssh-agent is unavailable"),
            status: sshAgentAvailable ? .passed : .failed
        ))

        let sshDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        var isDirectory: ObjCBool = false
        let sshDirectoryExists = fileManager.fileExists(
            atPath: sshDirectory.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
        results.append(result(
            "ssh-directory",
            category: "SSH",
            title: "~/.ssh",
            detail: sshDirectoryExists
                ? (fileManager.isReadableFile(atPath: sshDirectory.path)
                    ? localized("Каталог доступен для чтения", "Directory is readable")
                    : localized("Каталог существует, но недоступен для чтения", "Directory exists but is not readable"))
                : localized("Каталог пока отсутствует и будет создан при необходимости", "Directory does not exist yet and will be created when needed"),
            status: sshDirectoryExists
                ? (fileManager.isReadableFile(atPath: sshDirectory.path) ? .passed : .failed)
                : .info
        ))

        let knownHostsURL = sshDirectory.appendingPathComponent("known_hosts")
        let knownHostsExists = fileManager.fileExists(atPath: knownHostsURL.path)
        results.append(result(
            "known-hosts",
            category: "SSH",
            title: "Known Hosts",
            detail: knownHostsExists
                ? (fileManager.isReadableFile(atPath: knownHostsURL.path)
                    ? localized("~/.ssh/known_hosts читается", "~/.ssh/known_hosts is readable")
                    : localized("~/.ssh/known_hosts недоступен для чтения", "~/.ssh/known_hosts is not readable"))
                : localized("known_hosts пока не создан", "known_hosts has not been created yet"),
            status: knownHostsExists
                ? (fileManager.isReadableFile(atPath: knownHostsURL.path) ? .passed : .failed)
                : .info
        ))

        let keychainStatus: OSStatus = {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "local.selectiveremote.diagnostics.nonexistent",
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnAttributes as String: true
            ]
            return SecItemCopyMatching(query as CFDictionary, nil)
        }()
        let keychainAccessible = keychainStatus == errSecSuccess || keychainStatus == errSecItemNotFound
        results.append(result(
            "keychain",
            category: "Безопасность",
            title: "Связка ключей",
            detail: keychainAccessible
                ? localized("Keychain API доступен; секреты не считывались", "Keychain API is available; no secrets were read")
                : localized("Keychain API вернул OSStatus \(keychainStatus)", "Keychain API returned OSStatus \(keychainStatus)"),
            status: keychainAccessible ? .passed : .warning
        ))

        let context = LAContext()
        var authError: NSError?
        let biometricsAvailable = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &authError
        )
        results.append(result(
            "touch-id",
            category: "Безопасность",
            title: "Touch ID",
            detail: biometricsAvailable
                ? localized("Биометрическая аутентификация доступна", "Biometric authentication is available")
                : (authError?.localizedDescription ?? localized("Биометрическая аутентификация недоступна", "Biometric authentication is unavailable")),
            status: biometricsAvailable ? .passed : .info
        ))

        results.append(capturePermissionResult(
            mediaType: .video,
            id: "camera-permission",
            title: "Камера",
            action: .cameraSettings
        ))
        results.append(capturePermissionResult(
            mediaType: .audio,
            id: "microphone-permission",
            title: "Микрофон",
            action: .microphoneSettings
        ))

        if isApplicationBundle {
            let helpers = bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
            let sessionApp = helpers.appendingPathComponent(
                "Selective Remote Session.app",
                isDirectory: true
            )
            let sessionBinary = sessionApp
                .appendingPathComponent("Contents/MacOS/SelectiveRemoteSession")
            let frameworks = sessionApp
                .appendingPathComponent("Contents/Frameworks", isDirectory: true)
            let interposer = frameworks
                .appendingPathComponent("SelectiveRemoteMonitorInterposer.dylib")
            let fnShortcut = frameworks
                .appendingPathComponent("SelectiveRemoteFnShortcut.dylib")
            let privacyPreflight = frameworks
                .appendingPathComponent("SelectiveRemotePrivacyPreflight.dylib")

            results.append(fileCheck(
                id: "freerdp-helper",
                category: "RDP",
                title: "FreeRDP helper",
                url: sessionBinary,
                executable: true
            ))
            results.append(fileCheck(
                id: "monitor-interposer",
                category: "RDP",
                title: "Monitor topology helper",
                url: interposer
            ))
            results.append(fileCheck(
                id: "fn-shortcut",
                category: "RDP",
                title: "Fn keyboard helper",
                url: fnShortcut
            ))
            results.append(fileCheck(
                id: "privacy-preflight",
                category: "RDP",
                title: "Privacy preflight helper",
                url: privacyPreflight
            ))

            let cameraAddin = firstCameraAddin(in: frameworks, fileManager: fileManager)
            results.append(result(
                "camera-addin",
                category: "RDP",
                title: "Camera helper",
                detail: cameraAddin?.lastPathComponent ?? localized("librdpecam-client не найден", "librdpecam-client was not found"),
                status: cameraAddin == nil ? .failed : .passed
            ))
        } else {
            for item in [
                ("freerdp-helper", "FreeRDP helper"),
                ("monitor-interposer", "Monitor topology helper"),
                ("fn-shortcut", "Fn keyboard helper"),
                ("privacy-preflight", "Privacy preflight helper"),
                ("camera-addin", "Camera helper")
            ] {
                results.append(result(
                    item.0,
                    category: "RDP",
                    title: item.1,
                    detail: localized("Проверка доступна в собранном .app", "This check is available in the built .app"),
                    status: .info
                ))
            }
        }

        return results
    }

    private static func updateChecks(
        bundle: Bundle,
        session: URLSession
    ) async -> [SystemDiagnosticCheckResult] {
        guard let feedURL = try? UpdateService.configuredFeedURL(bundle: bundle) else {
            return [result(
                "update-feed",
                category: "Обновления",
                title: "Update feed",
                detail: localized("URL канала обновлений не настроен в текущей сборке", "The update-feed URL is not configured in this build"),
                status: .warning
            )]
        }

        do {
            let data = try await fetchData(feedURL, session: session)
            let manifest = try JSONDecoder().decode(
                SelectiveRemoteUpdateManifest.self,
                from: data
            )
            var results = [result(
                "update-feed",
                category: "Обновления",
                title: "Update feed",
                detail: "\(manifest.version) · build \(manifest.build)",
                status: .passed
            )]

            let ruURL = manifest.releaseNotesHistoryURL ?? rawHistoryRU
            let enURL = manifest.releaseNotesHistoryENURL ?? rawHistoryEN
            results.append(await remoteDocumentCheck(
                id: "changelog-ru",
                title: "CHANGELOG RU",
                url: ruURL,
                session: session
            ))
            results.append(await remoteDocumentCheck(
                id: "changelog-en",
                title: "CHANGELOG EN",
                url: enURL,
                session: session
            ))
            return results
        } catch {
            return [result(
                "update-feed",
                category: "Обновления",
                title: "Update feed",
                detail: error.localizedDescription,
                status: .failed
            )]
        }
    }

    private static func capturePermissionResult(
        mediaType: AVMediaType,
        id: String,
        title: String,
        action: SystemDiagnosticCheckAction
    ) -> SystemDiagnosticCheckResult {
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        switch status {
        case .authorized:
            return result(
                id,
                category: "Безопасность",
                title: title,
                detail: localized("Разрешение предоставлено", "Permission granted"),
                status: .passed
            )
        case .notDetermined:
            return result(
                id,
                category: "Безопасность",
                title: title,
                detail: localized("Разрешение ещё не запрашивалось", "Permission has not been requested yet"),
                status: .info,
                action: action
            )
        case .denied:
            return result(
                id,
                category: "Безопасность",
                title: title,
                detail: localized("Доступ запрещён в настройках macOS", "Access is denied in macOS Settings"),
                status: .warning,
                action: action
            )
        case .restricted:
            return result(
                id,
                category: "Безопасность",
                title: title,
                detail: localized("Доступ ограничен политикой macOS", "Access is restricted by macOS policy"),
                status: .warning,
                action: action
            )
        @unknown default:
            return result(
                id,
                category: "Безопасность",
                title: title,
                detail: localized("Неизвестное состояние разрешения", "Unknown permission state"),
                status: .warning,
                action: action
            )
        }
    }

    private static func fileCheck(
        id: String,
        category: String,
        title: String,
        url: URL,
        executable: Bool = false
    ) -> SystemDiagnosticCheckResult {
        let exists = executable
            ? FileManager.default.isExecutableFile(atPath: url.path)
            : FileManager.default.fileExists(atPath: url.path)
        return result(
            id,
            category: category,
            title: title,
            detail: exists ? url.lastPathComponent : localized("Компонент не найден", "Component not found"),
            status: exists ? .passed : .failed
        )
    }

    private static func firstCameraAddin(
        in frameworks: URL,
        fileManager: FileManager
    ) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: frameworks,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            if url.lastPathComponent.hasPrefix("librdpecam-client.") {
                return url
            }
        }
        return nil
    }

    private static func remoteDocumentCheck(
        id: String,
        title: String,
        url: URL,
        session: URLSession
    ) async -> SystemDiagnosticCheckResult {
        do {
            let data = try await fetchData(url, session: session)
            guard !data.isEmpty else {
                throw UpdateReleaseNotesError.invalidText
            }
            return result(
                id,
                category: "Обновления",
                title: title,
                detail: localized("Доступен", "Available") + " · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))",
                status: .passed
            )
        } catch {
            return result(
                id,
                category: "Обновления",
                title: title,
                detail: error.localizedDescription,
                status: .warning
            )
        }
    }

    private static func fetchData(
        _ url: URL,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { throw UpdateServiceError.invalidResponse }
        return data
    }

    private static func localized(_ ru: String, _ en: String) -> String {
        UpdateLocalization.text(ru: ru, en: en)
    }

    private static func result(
        _ id: String,
        category: String,
        title: String,
        detail: String,
        status: SystemDiagnosticCheckStatus,
        action: SystemDiagnosticCheckAction? = nil
    ) -> SystemDiagnosticCheckResult {
        SystemDiagnosticCheckResult(
            id: id,
            category: category,
            title: title,
            detail: detail,
            status: status,
            action: action
        )
    }
}

struct DiagnosticsSystemCheckView: View {
    @State private var results: [SystemDiagnosticCheckResult] = []
    @State private var isRunning = false
    @State private var lastRunAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Проверка системы")
                        .font(.title3.bold())
                    Text(UpdateLocalization.text(
                        ru: "Локальные preflight-проверки без запуска RDP/SSH и без чтения секретов",
                        en: "Local preflight checks without starting RDP/SSH or reading secrets"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let lastRunAt {
                    Text(UpdateLocalization.text(
                        ru: "Последняя проверка: \(lastRunAt.formatted(date: .omitted, time: .shortened))",
                        en: "Last checked: \(lastRunAt.formatted(date: .omitted, time: .shortened))"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await runChecks() }
                } label: {
                    Label(
                        isRunning
                            ? UpdateLocalization.text(ru: "Проверяем…", en: "Checking…")
                            : UpdateLocalization.text(ru: "Проверить всё", en: "Run All Checks"),
                        systemImage: "checkmark.shield"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
            }

            if isRunning && results.isEmpty {
                ProgressView(UpdateLocalization.text(
                    ru: "Проверяем компоненты Selective Remote…",
                    en: "Checking Selective Remote components…"
                ))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else if results.isEmpty {
                ContentUnavailableView(
                    UpdateLocalization.text(
                        ru: "Проверка ещё не запускалась",
                        en: "The system check has not run yet"
                    ),
                    systemImage: "checkmark.shield",
                    description: Text(UpdateLocalization.text(
                        ru: "Нажмите «Проверить всё», чтобы проверить локальные компоненты, разрешения и канал обновлений.",
                        en: "Run all checks to verify local components, permissions, and the update feed."
                    ))
                )
                .frame(minHeight: 260)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    summary
                    ForEach(categories, id: \.self) { category in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(LocalizedStringKey(category))
                                .font(.headline)
                            ForEach(results.filter { $0.category == category }) { item in
                                resultRow(item)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var categories: [String] {
        let preferred = ["Приложение", "RDP", "SSH", "Безопасность", "Обновления"]
        return preferred.filter { category in
            results.contains(where: { $0.category == category })
        }
    }

    private var summary: some View {
        let passed = results.filter { $0.status == .passed }.count
        let warnings = results.filter { $0.status == .warning }.count
        let failed = results.filter { $0.status == .failed }.count
        return HStack(spacing: 10) {
            summaryBadge("OK", count: passed, color: .green)
            summaryBadge("Предупреждения", count: warnings, color: .orange)
            summaryBadge("Ошибки", count: failed, color: .red)
            Spacer()
        }
    }

    private func summaryBadge(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(LocalizedStringKey(title))
            Text("\(count)").monospacedDigit().fontWeight(.semibold)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.10), in: Capsule())
    }

    private func resultRow(_ item: SystemDiagnosticCheckResult) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: item.status.systemImage)
                .foregroundStyle(item.status.color)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(item.title))
                    .font(.subheadline.weight(.semibold))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if let action = item.action {
                Button(UpdateLocalization.text(ru: "Открыть настройки", en: "Open Settings")) {
                    openSettings(action)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }

    @MainActor
    private func runChecks() async {
        guard !isRunning else { return }
        isRunning = true
        let newResults = await SystemDiagnosticsCheckService.run()
        guard !Task.isCancelled else { return }
        results = newResults
        lastRunAt = Date()
        isRunning = false
    }

    private func openSettings(_ action: SystemDiagnosticCheckAction) {
        let anchor: String
        switch action {
        case .cameraSettings:
            anchor = "Privacy_Camera"
        case .microphoneSettings:
            anchor = "Privacy_Microphone"
        }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
