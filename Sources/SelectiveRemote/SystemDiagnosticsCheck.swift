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

enum RDPCapturePermissionEvidenceState: String, Equatable, Sendable {
    case granted
    case denied
    case restricted
    case timedOut
    case requesting
    case unknown
}

struct RDPCapturePermissionEvidence: Equatable, Sendable {
    var camera: RDPCapturePermissionEvidenceState? = nil
    var microphone: RDPCapturePermissionEvidenceState? = nil

    static func parse(logs: [String]) -> Self {
        RDPCapturePermissionEvidence(
            camera: state(for: "camera", in: logs),
            microphone: state(for: "microphone", in: logs)
        )
    }

    private static func state(
        for permission: String,
        in logs: [String]
    ) -> RDPCapturePermissionEvidenceState? {
        for log in logs {
            if let state = state(for: permission, in: log) {
                return state
            }
        }
        return nil
    }

    private static func state(
        for permission: String,
        in log: String
    ) -> RDPCapturePermissionEvidenceState? {
        let markers: [(String, RDPCapturePermissionEvidenceState)] = [
            ("[SelectiveRemote Privacy] authorized \(permission)", .granted),
            ("[SelectiveRemote Privacy] granted \(permission)", .granted),
            ("[SelectiveRemote Privacy] disabled \(permission)", .denied),
            ("[SelectiveRemote Privacy] denied \(permission)", .denied),
            ("[SelectiveRemote Privacy] restricted \(permission)", .restricted),
            ("[SelectiveRemote Privacy] timeout \(permission)", .timedOut),
            ("[SelectiveRemote Privacy] unknown \(permission)", .unknown),
            ("[SelectiveRemote Privacy] requesting \(permission)", .requesting)
        ]

        var latest: (String.Index, RDPCapturePermissionEvidenceState)?
        for (marker, state) in markers {
            guard let range = log.range(of: marker, options: .backwards) else {
                continue
            }
            if let current = latest {
                if range.lowerBound > current.0 {
                    latest = (range.lowerBound, state)
                }
            } else {
                latest = (range.lowerBound, state)
            }
        }
        return latest?.1
    }
}

enum SystemDiagnosticCheckAction: String {
    case cameraSettings
    case microphoneSettings
    case retryCheck
    case showApplication
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
        session: URLSession = .shared,
        captureEvidence: RDPCapturePermissionEvidence = .init()
    ) async -> [SystemDiagnosticCheckResult] {
        var results = localChecks(
            bundle: bundle,
            captureEvidence: captureEvidence
        )
        results += await updateChecks(bundle: bundle, session: session)
        return results
    }

    static func runPostUpgradeCriticalChecks(
        bundle: Bundle = .main,
        session: URLSession = .shared
    ) async -> [SystemDiagnosticCheckResult] {
        var results: [SystemDiagnosticCheckResult] = []
        let fileManager = FileManager.default
        let bundleURL = bundle.bundleURL.standardizedFileURL
        let isApplicationBundle = bundleURL.pathExtension.lowercased() == "app"
        let isTranslocated = bundleURL.path.contains("/AppTranslocation/")

        results.append(result(
            "app-location",
            category: "Приложение",
            title: "Расположение приложения",
            detail: isTranslocated
                ? localized(
                    "Приложение запущено через App Translocation",
                    "The app is running through App Translocation"
                )
                : bundleURL.path,
            status: isTranslocated ? .warning : (isApplicationBundle ? .passed : .info),
            action: isTranslocated ? .showApplication : nil
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

            results.append(fileCheck(
                id: "freerdp-helper",
                category: "RDP",
                title: "RDP Session",
                url: sessionBinary,
                executable: true,
                action: .showApplication
            ))
            results.append(fileCheck(
                id: "monitor-interposer",
                category: "RDP",
                title: localized("Раскладка мониторов", "Monitor layout"),
                url: frameworks.appendingPathComponent("SelectiveRemoteMonitorInterposer.dylib"),
                action: .showApplication
            ))
            results.append(fileCheck(
                id: "privacy-preflight",
                category: "RDP",
                title: localized("Проверка разрешений RDP", "RDP permission preflight"),
                url: frameworks.appendingPathComponent("SelectiveRemotePrivacyPreflight.dylib"),
                action: .showApplication
            ))

            let cameraAddin = firstCameraAddin(in: frameworks, fileManager: fileManager)
            results.append(result(
                "camera-addin",
                category: "RDP",
                title: localized("Передача камеры RDP", "RDP camera redirection"),
                detail: cameraAddin?.lastPathComponent
                    ?? localized("Компонент камеры не найден", "Camera component was not found"),
                status: cameraAddin == nil ? .failed : .passed,
                action: cameraAddin == nil ? .showApplication : nil
            ))
        }

        guard let feedURL = try? UpdateService.configuredFeedURL(bundle: bundle) else {
            results.append(result(
                "update-feed",
                category: "Обновления",
                title: localized("Канал обновлений", "Update Feed"),
                detail: localized(
                    "URL канала обновлений не настроен в текущей сборке",
                    "The update-feed URL is not configured in this build"
                ),
                status: .warning,
                action: .retryCheck
            ))
            return results
        }

        do {
            let data = try await fetchData(feedURL, session: session)
            let manifest = try JSONDecoder().decode(
                SelectiveRemoteUpdateManifest.self,
                from: data
            )
            results.append(result(
                "update-feed",
                category: "Обновления",
                title: localized("Канал обновлений", "Update Feed"),
                detail: "\(manifest.version) · build \(manifest.build)",
                status: .passed
            ))
        } catch {
            results.append(result(
                "update-feed",
                category: "Обновления",
                title: localized("Канал обновлений", "Update Feed"),
                detail: error.localizedDescription,
                status: .warning,
                action: .retryCheck
            ))
        }
        return results
    }

    private static func localChecks(
        bundle: Bundle,
        captureEvidence: RDPCapturePermissionEvidence
    ) -> [SystemDiagnosticCheckResult] {
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
            action: .cameraSettings,
            evidenceState: captureEvidence.camera
        ))
        results.append(capturePermissionResult(
            mediaType: .audio,
            id: "microphone-permission",
            title: "Микрофон",
            action: .microphoneSettings,
            evidenceState: captureEvidence.microphone
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
                title: "RDP Session",
                url: sessionBinary,
                executable: true,
                action: .showApplication
            ))
            results.append(fileCheck(
                id: "monitor-interposer",
                category: "RDP",
                title: localized("Раскладка мониторов", "Monitor layout"),
                url: interposer,
                action: .showApplication
            ))
            results.append(fileCheck(
                id: "fn-shortcut",
                category: "RDP",
                title: localized("Fn-переключатель языка", "Fn language shortcut"),
                url: fnShortcut,
                action: .showApplication
            ))
            results.append(fileCheck(
                id: "privacy-preflight",
                category: "RDP",
                title: localized("Проверка разрешений RDP", "RDP permission preflight"),
                url: privacyPreflight,
                action: .showApplication
            ))

            let cameraAddin = firstCameraAddin(in: frameworks, fileManager: fileManager)
            results.append(result(
                "camera-addin",
                category: "RDP",
                title: localized("Передача камеры RDP", "RDP camera redirection"),
                detail: cameraAddin?.lastPathComponent
                    ?? localized("Компонент камеры не найден", "Camera component was not found"),
                status: cameraAddin == nil ? .failed : .passed,
                action: cameraAddin == nil ? .showApplication : nil
            ))
        } else {
            for item in [
                ("freerdp-helper", "RDP Session"),
                ("monitor-interposer", localized("Раскладка мониторов", "Monitor layout")),
                ("fn-shortcut", localized("Fn-переключатель языка", "Fn language shortcut")),
                ("privacy-preflight", localized("Проверка разрешений RDP", "RDP permission preflight")),
                ("camera-addin", localized("Передача камеры RDP", "RDP camera redirection"))
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
                title: localized("Канал обновлений", "Update Feed"),
                detail: localized("URL канала обновлений не настроен в текущей сборке", "The update-feed URL is not configured in this build"),
                status: .warning,
                action: .retryCheck
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
                title: localized("Канал обновлений", "Update Feed"),
                detail: "\(manifest.version) · build \(manifest.build)",
                status: .passed
            )]

            let ruURL = manifest.releaseNotesHistoryURL ?? rawHistoryRU
            let enURL = manifest.releaseNotesHistoryENURL ?? rawHistoryEN
            results.append(await remoteDocumentCheck(
                id: "changelog-ru",
                title: localized("История изменений — RU", "Release History — RU"),
                url: ruURL,
                session: session
            ))
            results.append(await remoteDocumentCheck(
                id: "changelog-en",
                title: localized("История изменений — EN", "Release History — EN"),
                url: enURL,
                session: session
            ))
            return results
        } catch {
            return [result(
                "update-feed",
                category: "Обновления",
                title: localized("Канал обновлений", "Update Feed"),
                detail: error.localizedDescription,
                status: .failed,
                action: .retryCheck
            )]
        }
    }

    private static func capturePermissionResult(
        mediaType: AVMediaType,
        id: String,
        title: String,
        action: SystemDiagnosticCheckAction,
        evidenceState: RDPCapturePermissionEvidenceState?
    ) -> SystemDiagnosticCheckResult {
        if let evidenceState {
            switch evidenceState {
            case .granted:
                return result(
                    id,
                    category: "Безопасность",
                    title: title,
                    detail: localized(
                        "Последний известный запуск RDP Session подтвердил доступ",
                        "The last known RDP Session run confirmed access"
                    ),
                    status: .passed
                )
            case .denied:
                return result(
                    id,
                    category: "Безопасность",
                    title: title,
                    detail: localized(
                        "Последний известный запуск RDP Session: доступ был запрещён macOS",
                        "Last known RDP Session run: access was denied by macOS"
                    ),
                    status: .warning,
                    action: action
                )
            case .restricted:
                return result(
                    id,
                    category: "Безопасность",
                    title: title,
                    detail: localized(
                        "Последний известный запуск RDP Session: доступ был ограничен политикой macOS",
                        "Last known RDP Session run: access was restricted by macOS policy"
                    ),
                    status: .warning,
                    action: action
                )
            case .timedOut:
                return result(
                    id,
                    category: "Безопасность",
                    title: title,
                    detail: localized(
                        "RDP Session: ожидание ответа macOS завершилось по тайм-ауту",
                        "RDP Session: the macOS permission request timed out"
                    ),
                    status: .warning,
                    action: action
                )
            case .requesting:
                return result(
                    id,
                    category: "Безопасность",
                    title: title,
                    detail: localized(
                        "RDP Session: ожидается ответ на запрос разрешения",
                        "RDP Session: waiting for the permission request to finish"
                    ),
                    status: .info
                )
            case .unknown:
                return result(
                    id,
                    category: "Безопасность",
                    title: title,
                    detail: localized(
                        "RDP Session вернул неизвестное состояние разрешения",
                        "RDP Session returned an unknown permission state"
                    ),
                    status: .warning,
                    action: action
                )
            }
        }

        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        switch status {
        case .authorized:
            return result(
                id,
                category: "Безопасность",
                title: title,
                detail: localized(
                    "Основное приложение: разрешено. RDP Session проверяет доступ отдельно при запуске.",
                    "Main app: allowed. RDP Session checks access separately when it starts."
                ),
                status: .passed
            )
        case .notDetermined:
            return result(
                id,
                category: "Безопасность",
                title: title,
                detail: localized(
                    "Основное приложение не сообщает итоговый статус; RDP Session использует отдельный контекст разрешений и проверит доступ при запуске RDP.",
                    "The main app does not report a final status; RDP Session uses a separate permission context and checks access when RDP starts."
                ),
                status: .info,
                action: action
            )
        case .denied:
            return result(
                id,
                category: "Безопасность",
                title: title,
                detail: localized(
                    "Основное приложение: доступ запрещён. RDP Session имеет отдельный контекст разрешений.",
                    "Main app: access denied. RDP Session has a separate permission context."
                ),
                status: .warning,
                action: action
            )
        case .restricted:
            return result(
                id,
                category: "Безопасность",
                title: title,
                detail: localized(
                    "Основное приложение: доступ ограничен политикой macOS. RDP Session проверяется отдельно.",
                    "Main app: access is restricted by macOS policy. RDP Session is checked separately."
                ),
                status: .warning,
                action: action
            )
        @unknown default:
            return result(
                id,
                category: "Безопасность",
                title: title,
                detail: localized(
                    "Основное приложение вернуло неизвестное состояние; RDP Session проверяется отдельно.",
                    "The main app returned an unknown state; RDP Session is checked separately."
                ),
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
        executable: Bool = false,
        action: SystemDiagnosticCheckAction? = nil
    ) -> SystemDiagnosticCheckResult {
        let exists = executable
            ? FileManager.default.isExecutableFile(atPath: url.path)
            : FileManager.default.fileExists(atPath: url.path)
        return result(
            id,
            category: category,
            title: title,
            detail: exists ? url.lastPathComponent : localized("Компонент не найден", "Component not found"),
            status: exists ? .passed : .failed,
            action: exists ? nil : action
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
                status: .warning,
                action: .retryCheck
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
    @ObservedObject var model: AppModel

    @State private var results: [SystemDiagnosticCheckResult] = []
    @State private var isRunning = false
    @State private var lastRunAt: Date?
    @State private var showProblemsOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Проверка системы")
                        .font(.title3.bold())
                    Text(UpdateLocalization.text(
                        ru: "Безопасные preflight-проверки без запуска RDP/SSH, запросов разрешений и чтения секретов",
                        en: "Safe preflight checks without starting RDP/SSH, requesting permissions, or reading secrets"
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
                if !results.isEmpty {
                    Toggle(isOn: $showProblemsOnly) {
                        Text(UpdateLocalization.text(
                            ru: "Только проблемы",
                            en: "Problems Only"
                        ))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
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
                    readinessBanner
                    healthOverview
                    summary

                    if showProblemsOnly && visibleResults.isEmpty {
                        ContentUnavailableView(
                            UpdateLocalization.text(
                                ru: "Проблем не обнаружено",
                                en: "No problems detected"
                            ),
                            systemImage: "checkmark.circle",
                            description: Text(UpdateLocalization.text(
                                ru: "Предупреждений и ошибок в текущей проверке нет.",
                                en: "The current check has no warnings or errors."
                            ))
                        )
                        .frame(minHeight: 180)
                    } else {
                        ForEach(categories, id: \.self) { category in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(LocalizedStringKey(category))
                                    .font(.headline)
                                ForEach(visibleResults.filter { $0.category == category }) { item in
                                    resultRow(item)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var problemResults: [SystemDiagnosticCheckResult] {
        results.filter { item in
            item.status == .warning || item.status == .failed
        }
    }

    private var visibleResults: [SystemDiagnosticCheckResult] {
        showProblemsOnly ? problemResults : results
    }

    private var categories: [String] {
        let preferred = ["Приложение", "RDP", "SSH", "Безопасность", "Обновления"]
        return preferred.filter { category in
            visibleResults.contains(where: { $0.category == category })
        }
    }

    private var readinessBanner: some View {
        let failed = results.filter { $0.status == .failed }.count
        let warnings = results.filter { $0.status == .warning }.count
        let attention = failed + warnings
        let color: Color = failed > 0 ? .red : (warnings > 0 ? .orange : .green)
        let icon = attention == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        let title = attention == 0
            ? UpdateLocalization.text(
                ru: "Selective Remote готов к работе",
                en: "Selective Remote is ready"
            )
            : UpdateLocalization.text(
                ru: "Требуется внимание: \(attention)",
                en: "Attention required: \(attention)"
            )
        let detail = attention == 0
            ? UpdateLocalization.text(
                ru: "Критических проблем не обнаружено. Серые статусы уточняются только при использовании соответствующей функции.",
                en: "No critical problems were detected. Gray statuses are resolved only when the related feature is used."
            )
            : UpdateLocalization.text(
                ru: "Откройте проблемные пункты ниже; автоматические исправления не выполняются.",
                en: "Review the problem items below; no automatic fixes are performed."
            )

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(color.opacity(0.18))
        }
    }

    private var healthOverview: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 126), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            healthChip("SSH", ids: ["ssh-binary", "ssh-agent", "ssh-directory", "known-hosts"])
            healthChip("RDP", ids: [
                "freerdp-helper",
                "monitor-interposer",
                "privacy-preflight",
                "camera-addin"
            ])
            healthChip(
                UpdateLocalization.text(ru: "Камера", en: "Camera"),
                ids: ["camera-permission"]
            )
            healthChip(
                UpdateLocalization.text(ru: "Микрофон", en: "Microphone"),
                ids: ["microphone-permission"]
            )
            healthChip(
                UpdateLocalization.text(ru: "Обновления", en: "Updates"),
                ids: ["update-feed", "changelog-ru", "changelog-en"]
            )
        }
    }

    private func healthChip(_ title: String, ids: Set<String>) -> some View {
        let status = aggregateStatus(ids: ids)
        return HStack(spacing: 7) {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.color)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(status.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func aggregateStatus(ids: Set<String>) -> SystemDiagnosticCheckStatus {
        let matching = results.filter { ids.contains($0.id) }
        if matching.contains(where: { $0.status == .failed }) { return .failed }
        if matching.contains(where: { $0.status == .warning }) { return .warning }
        if matching.contains(where: { $0.status == .info }) { return .info }
        return matching.isEmpty ? .info : .passed
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
                Button(actionTitle(action)) {
                    perform(action)
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
        let evidence = model.rdpCapturePermissionEvidence()
        let newResults = await SystemDiagnosticsCheckService.run(
            captureEvidence: evidence
        )
        guard !Task.isCancelled else {
            isRunning = false
            return
        }
        results = newResults
        lastRunAt = Date()
        isRunning = false
    }

    private func isProblem(_ item: SystemDiagnosticCheckResult) -> Bool {
        item.status == .warning || item.status == .failed
    }

    private func actionTitle(_ action: SystemDiagnosticCheckAction) -> String {
        switch action {
        case .cameraSettings, .microphoneSettings:
            UpdateLocalization.text(ru: "Открыть настройки", en: "Open Settings")
        case .retryCheck:
            UpdateLocalization.text(ru: "Повторить проверку", en: "Retry Check")
        case .showApplication:
            UpdateLocalization.text(ru: "Показать приложение", en: "Show Application")
        }
    }

    private func perform(_ action: SystemDiagnosticCheckAction) {
        switch action {
        case .cameraSettings:
            openPrivacySettings(anchor: "Privacy_Camera")
        case .microphoneSettings:
            openPrivacySettings(anchor: "Privacy_Microphone")
        case .retryCheck:
            Task { await runChecks() }
        case .showApplication:
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
