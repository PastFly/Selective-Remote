import AppKit
import CryptoKit
import Foundation

enum UpdateLocalization {
    private static var usesEnglish: Bool {
        switch UserDefaults.standard.string(forKey: "SelectiveRemote.applicationLanguage.v1") {
        case "english": true
        case "russian": false
        default:
            Locale.preferredLanguages.first?.lowercased().hasPrefix("en") == true
        }
    }

    static func text(ru: String, en: String) -> String {
        usesEnglish ? en : ru
    }
}


enum UpdateDownloadStage: Equatable, Sendable {
    case idle
    case downloading
    case verifying
    case ready
    case installing
}

struct UpdateNotificationPolicy {
    static let minimumRepeatInterval: TimeInterval = 24 * 60 * 60

    static func shouldNotify(
        version: String,
        seenVersion: String?,
        lastVersion: String?,
        lastDate: Date?,
        now: Date = Date(),
        minimumInterval: TimeInterval = minimumRepeatInterval
    ) -> Bool {
        guard seenVersion != version else { return false }
        guard lastVersion == version else { return true }
        guard let lastDate else { return true }
        return now.timeIntervalSince(lastDate) >= minimumInterval
    }
}

enum UpdateInstallerError: LocalizedError, Sendable {
    case invalidHTTPResponse
    case invalidDownload
    case checksumUnavailable
    case checksumMismatch
    case commandFailed(String)
    case mountedVolumeMissing
    case applicationMissing
    case invalidApplicationSignature
    case bundleIdentifierMismatch
    case translocatedApplication
    case installationRequiresManualReplacement
    case installerLaunchFailed

    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            UpdateLocalization.text(ru: "Сервер обновлений вернул некорректный HTTP-ответ.", en: "The update server returned an invalid HTTP response.")
        case .invalidDownload:
            UpdateLocalization.text(ru: "Загруженный файл обновления не похож на корректный DMG.", en: "The downloaded update is not a valid DMG.")
        case .checksumUnavailable:
            UpdateLocalization.text(ru: "Не удалось получить SHA-256 для опубликованного DMG.", en: "The published DMG SHA-256 could not be retrieved.")
        case .checksumMismatch:
            UpdateLocalization.text(ru: "SHA-256 загруженного DMG не совпадает с опубликованным значением. Установка остановлена.", en: "The downloaded DMG SHA-256 does not match the published value. Installation was stopped.")
        case let .commandFailed(message):
            UpdateLocalization.text(ru: "Не удалось подготовить обновление: \(message)", en: "Unable to prepare the update: \(message)")
        case .mountedVolumeMissing:
            UpdateLocalization.text(ru: "DMG подключён, но точка монтирования не найдена.", en: "The DMG was mounted, but its mount point could not be found.")
        case .applicationMissing:
            UpdateLocalization.text(ru: "В DMG не найдено приложение Selective Remote.app.", en: "Selective Remote.app was not found in the DMG.")
        case .invalidApplicationSignature:
            UpdateLocalization.text(ru: "Проверка подписи приложения из DMG завершилась ошибкой.", en: "The application signature in the DMG failed verification.")
        case .bundleIdentifierMismatch:
            UpdateLocalization.text(ru: "Bundle identifier приложения в DMG не совпадает с установленным Selective Remote.", en: "The application bundle identifier in the DMG does not match the installed Selective Remote app.")
        case .translocatedApplication:
            UpdateLocalization.text(ru: "Приложение запущено из App Translocation. Откройте установленную копию Selective Remote и повторите обновление.", en: "The app is running from App Translocation. Open the installed copy of Selective Remote and try again.")
        case .installationRequiresManualReplacement:
            UpdateLocalization.text(ru: "Текущая папка приложения недоступна для записи без повышения прав. DMG открыт в Finder — замените приложение вручную.", en: "The current application folder is not writable without elevated privileges. The DMG is open in Finder — replace the app manually.")
        case .installerLaunchFailed:
            UpdateLocalization.text(ru: "Не удалось запустить безопасный установщик обновления.", en: "The safe update installer could not be started.")
        }
    }
}

struct MountedSelectiveRemoteUpdate: Sendable {
    let dmgURL: URL
    let mountURL: URL
    let appURL: URL
}

private final class UpdateDownloadOperation: @unchecked Sendable {
    private let sourceURL: URL
    private let destinationURL: URL
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var finished = false

    init(sourceURL: URL, destinationURL: URL) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
    }

    var fractionCompleted: Double {
        lock.lock()
        defer { lock.unlock() }
        if finished { return 1 }
        return task?.progress.fractionCompleted ?? 0
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: sourceURL) { [self] temporaryURL, response, error in
                defer { markFinished() }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let temporaryURL else {
                    continuation.resume(throwing: UpdateInstallerError.invalidHTTPResponse)
                    return
                }
                do {
                    let fileManager = FileManager.default
                    try fileManager.createDirectory(
                        at: destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                    let values = try destinationURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true,
                          (values.fileSize ?? 0) > 1_048_576,
                          destinationURL.pathExtension.lowercased() == "dmg" else {
                        throw UpdateInstallerError.invalidDownload
                    }
                    continuation.resume(returning: destinationURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            lock.lock()
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    private func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}

@MainActor
enum UpdateInstaller {
    static func downloadAndValidateDMG(
        from sourceURL: URL,
        progress: @escaping @MainActor (Double) -> Void,
        stage: @escaping @MainActor (UpdateDownloadStage) -> Void
    ) async throws -> URL {
        guard sourceURL.scheme?.lowercased() == "https",
              sourceURL.pathExtension.lowercased() == "dmg" else {
            throw UpdateInstallerError.invalidDownload
        }

        let cacheRoot = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Selective Remote", isDirectory: true)
        .appendingPathComponent("Updates", isDirectory: true)
        let destinationURL = cacheRoot.appendingPathComponent(sourceURL.lastPathComponent)
        let operation = UpdateDownloadOperation(sourceURL: sourceURL, destinationURL: destinationURL)
        stage(.downloading)

        let progressTask = Task { @MainActor in
            while !Task.isCancelled && !operation.isFinished {
                progress(min(max(operation.fractionCompleted, 0), 0.98))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { progressTask.cancel() }

        let downloadedURL = try await operation.start()
        progress(0.985)
        stage(.verifying)
        try await validatePublishedChecksum(for: downloadedURL, sourceURL: sourceURL)
        progress(1)
        return downloadedURL
    }

    static func mountValidatedDMG(_ dmgURL: URL) throws -> MountedSelectiveRemoteUpdate {
        let output = try runAndCapture(
            "/usr/bin/hdiutil",
            arguments: ["attach", "-plist", "-nobrowse", "-readonly", dmgURL.path]
        )
        guard let plist = try PropertyListSerialization.propertyList(
            from: output,
            options: [],
            format: nil
        ) as? [String: Any],
        let entities = plist["system-entities"] as? [[String: Any]],
        let mountPath = entities.compactMap({ $0["mount-point"] as? String }).last else {
            throw UpdateInstallerError.mountedVolumeMissing
        }

        let mountURL = URL(fileURLWithPath: mountPath, isDirectory: true)
        let preferred = mountURL.appendingPathComponent("Selective Remote.app", isDirectory: true)
        let appURL: URL
        if FileManager.default.fileExists(atPath: preferred.path) {
            appURL = preferred
        } else {
            let candidates = (try? FileManager.default.contentsOfDirectory(
                at: mountURL,
                includingPropertiesForKeys: nil
            )) ?? []
            guard let candidate = candidates.first(where: {
                $0.pathExtension.lowercased() == "app" && $0.lastPathComponent == "Selective Remote.app"
            }) else {
                try? detach(mountURL)
                throw UpdateInstallerError.applicationMissing
            }
            appURL = candidate
        }

        do {
            _ = try runAndCapture(
                "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", appURL.path]
            )
        } catch {
            try? detach(mountURL)
            throw UpdateInstallerError.invalidApplicationSignature
        }
        let currentIdentifier = Bundle.main.bundleIdentifier
        let candidateIdentifier = Bundle(url: appURL)?.bundleIdentifier
        guard currentIdentifier != nil, candidateIdentifier == currentIdentifier else {
            try? detach(mountURL)
            throw UpdateInstallerError.bundleIdentifierMismatch
        }

        return MountedSelectiveRemoteUpdate(dmgURL: dmgURL, mountURL: mountURL, appURL: appURL)
    }

    static func installAndRestart(_ mounted: MountedSelectiveRemoteUpdate) throws {
        let destination = Bundle.main.bundleURL.standardizedFileURL
        guard destination.pathExtension.lowercased() == "app" else {
            try? detach(mounted.mountURL)
            throw UpdateInstallerError.applicationMissing
        }
        if destination.path.contains("/AppTranslocation/") {
            NSWorkspace.shared.activateFileViewerSelecting([mounted.appURL])
            throw UpdateInstallerError.translocatedApplication
        }
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([mounted.appURL])
            throw UpdateInstallerError.installationRequiresManualReplacement
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("selective-remote-update-\(UUID().uuidString).sh")
        let script = #"""
#!/bin/sh
set -eu
PID="$1"
SRC="$2"
DST="$3"
MOUNT="$4"
DMG="$5"
while /bin/kill -0 "$PID" 2>/dev/null; do
    /bin/sleep 0.2
done
BACKUP="${DST}.selective-remote-backup.$$"
/bin/rm -rf "$BACKUP"
if ! /bin/mv "$DST" "$BACKUP"; then
    /usr/bin/open "$DST" >/dev/null 2>&1 || true
    /usr/bin/hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    exit 1
fi
if /usr/bin/ditto "$SRC" "$DST" && /usr/bin/codesign --verify --deep --strict "$DST"; then
    /bin/rm -rf "$BACKUP"
    /usr/bin/open "$DST"
else
    /bin/rm -rf "$DST"
    /bin/mv "$BACKUP" "$DST"
    /usr/bin/open "$DST"
    exit 1
fi
/usr/bin/hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
/bin/rm -f "$DMG" "$0"
"""#
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                scriptURL.path,
                String(ProcessInfo.processInfo.processIdentifier),
                mounted.appURL.path,
                destination.path,
                mounted.mountURL.path,
                mounted.dmgURL.path
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            try? detach(mounted.mountURL)
            throw UpdateInstallerError.installerLaunchFailed
        }
        NSApp.terminate(nil)
    }

    static func revealDMG(_ dmgURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([dmgURL])
    }

    private static func validatePublishedChecksum(
        for dmgURL: URL,
        sourceURL: URL
    ) async throws {
        guard let checksumURL = URL(string: sourceURL.absoluteString + ".sha256") else {
            throw UpdateInstallerError.checksumUnavailable
        }
        let (data, response) = try await URLSession.shared.data(from: checksumURL)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8),
              let expected = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
              expected.count == 64 else {
            throw UpdateInstallerError.checksumUnavailable
        }
        let actual = try await sha256Hex(of: dmgURL)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            try? FileManager.default.removeItem(at: dmgURL)
            throw UpdateInstallerError.checksumMismatch
        }
    }

    private static func sha256Hex(of url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var hasher = SHA256()
                    while true {
                        let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
                        if chunk.isEmpty { break }
                        hasher.update(data: chunk)
                    }
                    let digest = hasher.finalize()
                    let value = digest.map { String(format: "%02x", $0) }.joined()
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runAndCapture(_ executable: String, arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? "\(executable) exited with \(process.terminationStatus)"
            throw UpdateInstallerError.commandFailed(message)
        }
        return data
    }

    private static func detach(_ mountURL: URL) throws {
        _ = try runAndCapture("/usr/bin/hdiutil", arguments: ["detach", mountURL.path])
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
