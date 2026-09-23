@preconcurrency import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum SFTPDragType {
    static let remoteEntry = UTType(
        exportedAs: "local.selectiveremote.sftp.remote-entry"
    )
}

struct SFTPRemoteDragPayload: Codable, Sendable {
    let profileID: UUID
    let remotePath: String
    let name: String
    let isDirectory: Bool
}


// NSItemProvider may invoke its completion handlers on a Foundation-owned
// background queue. Keep those callbacks completely outside MainActor-
// isolated SwiftUI views and pass only Sendable values back to MainActor.
final class SFTPMainActorValueHandler<Value: Sendable>: @unchecked Sendable {
    private let callback: @MainActor @Sendable (Value) -> Void

    @MainActor
    init(_ callback: @escaping @MainActor @Sendable (Value) -> Void) {
        self.callback = callback
    }

    @MainActor
    func call(_ value: Value) {
        callback(value)
    }
}

enum SFTPItemProviderBridge {
    static func loadRemotePayload(
        from provider: NSItemProvider,
        handler: SFTPMainActorValueHandler<SFTPRemoteDragPayload>
    ) {
        provider.loadDataRepresentation(
            forTypeIdentifier: SFTPDragType.remoteEntry.identifier
        ) { data, _ in
            guard let data,
                  let payload = try? JSONDecoder().decode(
                      SFTPRemoteDragPayload.self,
                      from: data
                  )
            else { return }

            Task { @MainActor in
                handler.call(payload)
            }
        }
    }

    static func loadString(
        from provider: NSItemProvider,
        handler: SFTPMainActorValueHandler<String>
    ) {
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let nsString = object as? NSString else { return }
            let value = nsString as String

            Task { @MainActor in
                handler.call(value)
            }
        }
    }

    static func loadFileURL(
        from provider: NSItemProvider,
        handler: SFTPMainActorValueHandler<URL>
    ) {
        provider.loadObject(ofClass: NSURL.self) { object, _ in
            guard let nsURL = object as? NSURL else { return }
            let url = nsURL as URL

            Task { @MainActor in
                handler.call(url)
            }
        }
    }
}

struct SFTPLocalEntry: Identifiable, Equatable, Sendable {
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64?
    let permissions: String
    let mode: Int
    let owner: String
    let group: String
    let ownerID: Int?
    let groupID: Int?
    let modificationDate: Date?

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    var sizeText: String {
        guard !isDirectory, let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var ownerText: String {
        group.isEmpty ? owner : "\(owner):\(group)"
    }

    var modeText: String {
        String(format: "%04o", mode)
    }

    var modifiedText: String {
        guard let modificationDate else { return "—" }
        return UpdateLocalization.dateTimeShort(modificationDate)
    }
}

enum SFTPLocalFileError: LocalizedError, Sendable {
    case unreadableDirectory(String)
    case targetExists(String)
    case copyFailed(String)
    case operationFailed(String)
    case textFileTooLarge
    case unsupportedTextEncoding

    var errorDescription: String? {
        switch self {
        case let .unreadableDirectory(path):
            UpdateLocalization.text(ru: "Не удалось прочитать локальную папку: \(path)", en: "Could not read local folder: \(path)")
        case let .targetExists(name):
            UpdateLocalization.text(ru: "Локальный объект «\(name)» уже существует", en: "Local item “\(name)” already exists")
        case let .copyFailed(message):
            UpdateLocalization.text(ru: "Не удалось скопировать локальный объект: \(message)", en: "Could not copy local item: \(message)")
        case let .operationFailed(message):
            message
        case .textFileTooLarge:
            UpdateLocalization.text(ru: "Встроенный редактор открывает текстовые файлы размером не более 5 МБ", en: "The built-in editor opens text files up to 5 MB")
        case .unsupportedTextEncoding:
            UpdateLocalization.text(ru: "Файл похож на двоичный или использует неподдерживаемую кодировку. Откройте его во внешнем приложении.", en: "The file appears to be binary or uses an unsupported encoding. Open it in another app.")
        }
    }
}

struct SFTPRemoteTextDocument: Identifiable, Equatable, Sendable {
    let remotePath: String
    let name: String
    var text: String

    var id: String { remotePath }
}

final class SFTPFileRepresentationCompletion: @unchecked Sendable {
    private let callback: (URL?, Bool, Error?) -> Void

    init(_ callback: @escaping (URL?, Bool, Error?) -> Void) {
        self.callback = callback
    }

    func finish(url: URL?, isInPlace: Bool, error: Error?) {
        callback(url, isInPlace, error)
    }
}

@MainActor
final class SFTPLocalBrowserModel: ObservableObject {
    @Published private(set) var entries: [SFTPLocalEntry] = []
    @Published private(set) var currentDirectory: URL
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = ""
    @Published var errorMessage: String?
    @Published var selectedEntryIDs: Set<String> = []
    @Published var sortField: SFTPFileSortField = .name {
        didSet { applySort() }
    }
    @Published var sortDirection: SFTPSortDirection = .ascending {
        didSet { applySort() }
    }
    @Published var filterText = "" {
        didSet { applySort() }
    }

    private let homeDirectory: URL
    private var rawEntries: [SFTPLocalEntry] = []
    private var reloadID = UUID()
    private var isReloading = false
    private var isTransferring = false
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        homeDirectory = home
        currentDirectory = home
        reload()
    }

    var selectedEntries: [SFTPLocalEntry] {
        entries.filter { selectedEntryIDs.contains($0.id) }
    }

    var selectedEntry: SFTPLocalEntry? {
        selectedEntries.count == 1 ? selectedEntries[0] : nil
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    var breadcrumbs: [SFTPPathCrumb] {
        let path = currentDirectory.standardizedFileURL.path
        guard path != "/" else {
            return [SFTPPathCrumb(title: "/", path: "/")]
        }
        var result = [SFTPPathCrumb(title: "/", path: "/")]
        var accumulated = ""
        for component in currentDirectory.standardizedFileURL.pathComponents where component != "/" {
            accumulated += "/\(component)"
            result.append(SFTPPathCrumb(title: component, path: accumulated))
        }
        return result
    }

    func reload() {
        let directory = currentDirectory
        let token = UUID()
        reloadID = token
        isReloading = true
        updateBusy()
        statusMessage = UpdateLocalization.text(ru: "Читаем локальную папку…", en: "Reading local folder…")

        Task {
            do {
                let values = try await Task.detached(priority: .userInitiated) {
                    try Self.readDirectory(directory)
                }.value
                guard reloadID == token, currentDirectory == directory else { return }
                rawEntries = values
                applySort()
                selectedEntryIDs.removeAll()
                isReloading = false
                updateBusy()
                statusMessage = UpdateLocalization.text(ru: "Объектов: \(values.count)", en: "Items: \(values.count)")
                errorMessage = nil
            } catch {
                guard reloadID == token, currentDirectory == directory else { return }
                rawEntries = []
                entries = []
                isReloading = false
                updateBusy()
                statusMessage = UpdateLocalization.text(ru: "Локальная папка недоступна", en: "Local folder is unavailable")
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectSort(_ field: SFTPFileSortField) {
        if sortField == field {
            sortDirection = sortDirection == .ascending ? .descending : .ascending
        } else {
            sortField = field
            sortDirection = .ascending
        }
    }

    func open(_ entry: SFTPLocalEntry) {
        if entry.isDirectory {
            navigate(to: entry.url)
        } else {
            selectedEntryIDs = [entry.id]
            NSWorkspace.shared.open(entry.url)
        }
    }

    func openWith(_ entry: SFTPLocalEntry, applicationURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [entry.url],
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func reveal(_ entry: SFTPLocalEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func navigate(to directory: URL, recordHistory: Bool = true) {
        let target = directory.standardizedFileURL
        guard target != currentDirectory else {
            reload()
            return
        }
        if recordHistory {
            backStack.append(currentDirectory)
            forwardStack.removeAll()
        }
        currentDirectory = target
        reload()
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(currentDirectory)
        navigate(to: target, recordHistory: false)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(currentDirectory)
        navigate(to: target, recordHistory: false)
    }

    func goUp() {
        let parent = currentDirectory.deletingLastPathComponent()
        guard parent.path != currentDirectory.path else { return }
        navigate(to: parent)
    }

    func goHome() {
        navigate(to: homeDirectory)
    }

    func createDirectory(named name: String) {
        do {
            let validated = try SFTPService.validatedName(name)
            let target = currentDirectory.appendingPathComponent(
                validated,
                isDirectory: true
            )
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw SFTPLocalFileError.targetExists(validated)
            }
            try FileManager.default.createDirectory(
                at: target,
                withIntermediateDirectories: false
            )
            statusMessage = UpdateLocalization.text(ru: "Папка \(validated) создана", en: "Folder \(validated) created")
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createFile(named name: String) {
        do {
            let validated = try SFTPService.validatedName(name)
            let target = currentDirectory.appendingPathComponent(validated)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw SFTPLocalFileError.targetExists(validated)
            }
            try Data().write(to: target, options: .atomic)
            statusMessage = UpdateLocalization.text(ru: "Файл \(validated) создан", en: "File \(validated) created")
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ entry: SFTPLocalEntry, to name: String) {
        do {
            let validated = try SFTPService.validatedName(name)
            let target = currentDirectory.appendingPathComponent(
                validated,
                isDirectory: entry.isDirectory
            )
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw SFTPLocalFileError.targetExists(validated)
            }
            try FileManager.default.moveItem(at: entry.url, to: target)
            statusMessage = UpdateLocalization.text(ru: "«\(entry.name)» переименован", en: "“\(entry.name)” renamed")
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveToTrash(_ entry: SFTPLocalEntry) {
        isTransferring = true
        updateBusy()
        statusMessage = UpdateLocalization.text(ru: "Перемещаем «\(entry.name)» в Корзину…", en: "Moving “\(entry.name)” to Trash…")
        NSWorkspace.shared.recycle([entry.url]) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTransferring = false
                self.updateBusy()
                if let error {
                    self.statusMessage = UpdateLocalization.text(ru: "Удаление не выполнено", en: "Could not delete item")
                    self.errorMessage = error.localizedDescription
                } else {
                    self.statusMessage = UpdateLocalization.text(ru: "«\(entry.name)» перемещён в Корзину", en: "“\(entry.name)” moved to Trash")
                    self.errorMessage = nil
                    self.reload()
                }
            }
        }
    }

    func moveToTrash(_ entries: [SFTPLocalEntry]) {
        guard !entries.isEmpty else { return }
        if entries.count == 1 {
            moveToTrash(entries[0])
            return
        }
        isTransferring = true
        updateBusy()
        statusMessage = UpdateLocalization.text(ru: "Перемещаем в Корзину: \(entries.count)…", en: "Moving to Trash: \(entries.count)…")
        NSWorkspace.shared.recycle(entries.map(\.url)) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTransferring = false
                self.updateBusy()
                if let error {
                    self.statusMessage = UpdateLocalization.text(ru: "Удаление не выполнено", en: "Could not delete items")
                    self.errorMessage = error.localizedDescription
                } else {
                    self.statusMessage = UpdateLocalization.text(ru: "Перемещено в Корзину: \(entries.count)", en: "Moved to Trash: \(entries.count)")
                    self.errorMessage = nil
                    self.reload()
                }
            }
        }
    }

    func updateAttributes(
        _ entry: SFTPLocalEntry,
        mode: String?,
        ownerID: Int?,
        groupID: Int?
    ) {
        do {
            var attributes: [FileAttributeKey: Any] = [:]
            if let mode {
                let normalized = try SFTPPermissionFormatter.normalizedMode(mode)
                guard let value = Int(normalized, radix: 8) else {
                    throw SFTPServiceError.invalidPermissions
                }
                attributes[.posixPermissions] = NSNumber(value: value)
            }
            if let ownerID {
                guard ownerID >= 0 else { throw SFTPServiceError.invalidNumericID }
                attributes[.ownerAccountID] = NSNumber(value: ownerID)
            }
            if let groupID {
                guard groupID >= 0 else { throw SFTPServiceError.invalidNumericID }
                attributes[.groupOwnerAccountID] = NSNumber(value: groupID)
            }
            guard !attributes.isEmpty else { return }
            try FileManager.default.setAttributes(attributes, ofItemAtPath: entry.url.path)
            statusMessage = UpdateLocalization.text(ru: "Свойства «\(entry.name)» обновлены", en: "Properties for “\(entry.name)” updated")
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyItems(_ sourceURLs: [URL], to destinationDirectory: URL) {
        let sources = sourceURLs.map(\.standardizedFileURL)
        guard !sources.isEmpty else { return }
        isTransferring = true
        updateBusy()
        errorMessage = nil
        statusMessage = UpdateLocalization.text(ru: "Копируем на этот Mac…", en: "Copying to this Mac…")

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let fileManager = FileManager.default
                    for source in sources {
                        let accessed = source.startAccessingSecurityScopedResource()
                        defer {
                            if accessed {
                                source.stopAccessingSecurityScopedResource()
                            }
                        }
                        let target = destinationDirectory.appendingPathComponent(
                            source.lastPathComponent,
                            isDirectory: source.hasDirectoryPath
                        )
                        if source == target.standardizedFileURL {
                            continue
                        }
                        guard !fileManager.fileExists(atPath: target.path) else {
                            throw SFTPLocalFileError.targetExists(target.lastPathComponent)
                        }
                        do {
                            try fileManager.copyItem(at: source, to: target)
                        } catch {
                            throw SFTPLocalFileError.copyFailed(error.localizedDescription)
                        }
                    }
                }.value
                isTransferring = false
                updateBusy()
                statusMessage = UpdateLocalization.text(ru: "Локальное копирование завершено", en: "Local copy completed")
                if destinationDirectory.standardizedFileURL == currentDirectory {
                    reload()
                }
            } catch {
                isTransferring = false
                updateBusy()
                statusMessage = UpdateLocalization.text(ru: "Локальное копирование не выполнено", en: "Local copy failed")
                errorMessage = error.localizedDescription
            }
        }
    }

    static func availableDestination(
        directory: URL,
        preferredName: String,
        isDirectory: Bool,
        fileManager: FileManager = .default
    ) -> URL {
        let original = directory.appendingPathComponent(
            preferredName,
            isDirectory: isDirectory
        )
        guard fileManager.fileExists(atPath: original.path) else { return original }

        let source = URL(fileURLWithPath: preferredName)
        let extensionText = isDirectory ? "" : source.pathExtension
        let base = extensionText.isEmpty
            ? preferredName
            : source.deletingPathExtension().lastPathComponent
        for index in 1...9_999 {
            let marker = index == 1 ? " копия" : " копия \(index)"
            let name = extensionText.isEmpty
                ? base + marker
                : base + marker + "." + extensionText
            let candidate = directory.appendingPathComponent(
                name,
                isDirectory: isDirectory
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent(
            "\(UUID().uuidString)-\(preferredName)",
            isDirectory: isDirectory
        )
    }

    nonisolated private static func readDirectory(
        _ directory: URL
    ) throws -> [SFTPLocalEntry] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
        } catch {
            throw SFTPLocalFileError.unreadableDirectory(directory.path)
        }

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let isDirectory = values.isDirectory == true
            let isSymbolicLink = values.isSymbolicLink == true
            return SFTPLocalEntry(
                url: url,
                isDirectory: isDirectory,
                isSymbolicLink: isSymbolicLink,
                size: (attributes?[.size] as? NSNumber)?.int64Value
                    ?? values.fileSize.map { Int64($0) },
                permissions: SFTPPermissionFormatter.symbolic(
                    mode: mode,
                    isDirectory: isDirectory,
                    isSymbolicLink: isSymbolicLink
                ),
                mode: mode,
                owner: attributes?[.ownerAccountName] as? String ?? "—",
                group: attributes?[.groupOwnerAccountName] as? String ?? "—",
                ownerID: (attributes?[.ownerAccountID] as? NSNumber)?.intValue,
                groupID: (attributes?[.groupOwnerAccountID] as? NSNumber)?.intValue,
                modificationDate: attributes?[.modificationDate] as? Date
                    ?? values.contentModificationDate
            )
        }
    }

    private func applySort() {
        let visibleEntries = rawEntries.filter {
            SFTPNameFilter.matches($0.name, query: filterText)
        }
        entries = visibleEntries.sorted { left, right in
            if left.isDirectory != right.isDirectory {
                return left.isDirectory
            }
            let comparison: ComparisonResult
            switch sortField {
            case .name:
                comparison = left.name.localizedCaseInsensitiveCompare(right.name)
            case .size:
                comparison = compare(left.size ?? -1, right.size ?? -1)
            case .modified:
                comparison = compare(
                    left.modificationDate ?? .distantPast,
                    right.modificationDate ?? .distantPast
                )
            case .owner:
                comparison = left.ownerText.localizedCaseInsensitiveCompare(right.ownerText)
            case .permissions:
                comparison = left.permissions.compare(right.permissions)
            }
            if comparison == .orderedSame {
                return left.name.localizedCaseInsensitiveCompare(right.name)
                    == .orderedAscending
            }
            return sortDirection == .ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
        selectedEntryIDs.formIntersection(Set(entries.map(\.id)))
    }

    private func compare<T: Comparable>(_ left: T, _ right: T) -> ComparisonResult {
        if left < right { return .orderedAscending }
        if left > right { return .orderedDescending }
        return .orderedSame
    }

    private func updateBusy() {
        isBusy = isReloading || isTransferring
    }
}

private final class SFTPServerBridgeProgressState: @unchecked Sendable {
    enum Stage: Sendable {
        case download
        case upload
    }

    private let lock = NSLock()
    private var stage: Stage = .download
    private var downloadedBytes: Int64 = 0

    func beginUpload(downloadedBytes: Int64) {
        lock.lock()
        self.downloadedBytes = max(0, downloadedBytes)
        stage = .upload
        lock.unlock()
    }

    func snapshot() -> (stage: Stage, downloadedBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (stage, downloadedBytes)
    }
}

@MainActor
final class SFTPBrowserModel: ObservableObject {
    @Published private(set) var entries: [SFTPRemoteEntry] = []
    @Published private(set) var currentPath = "."
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = UpdateLocalization.text(ru: "SFTP ещё не подключён", en: "SFTP is not connected yet")
    @Published var errorMessage: String?
    @Published var selectedEntryIDs: Set<String> = []
    @Published var editorDocument: SFTPRemoteTextDocument?
    @Published var sortField: SFTPFileSortField = .name {
        didSet { applySort() }
    }
    @Published var sortDirection: SFTPSortDirection = .ascending {
        didSet { applySort() }
    }
    @Published var filterText = "" {
        didSet { applySort() }
    }

    private struct UploadRequest: Sendable {
        let localURL: URL
        let remotePath: String
        let isDirectory: Bool
    }

    private var rawEntries: [SFTPRemoteEntry] = []
    private var operationID = UUID()
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var isSilentRefreshRunning = false
    private let transfers: SFTPTransferQueue

    init(transfers: SFTPTransferQueue) {
        self.transfers = transfers
    }

    var selectedEntries: [SFTPRemoteEntry] {
        entries.filter { selectedEntryIDs.contains($0.id) }
    }

    var selectedEntry: SFTPRemoteEntry? {
        selectedEntries.count == 1 ? selectedEntries[0] : nil
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var breadcrumbs: [SFTPPathCrumb] { SFTPService.breadcrumbs(for: currentPath) }

    func reset() {
        operationID = UUID()
        rawEntries = []
        entries = []
        currentPath = "."
        isBusy = false
        statusMessage = UpdateLocalization.text(ru: "SFTP ещё не подключён", en: "SFTP is not connected yet")
        errorMessage = nil
        selectedEntryIDs.removeAll()
        editorDocument = nil
        filterText = ""
        backStack = []
        forwardStack = []
    }

    func selectSort(_ field: SFTPFileSortField) {
        if sortField == field {
            sortDirection = sortDirection == .ascending ? .descending : .ascending
        } else {
            sortField = field
            sortDirection = .ascending
        }
    }

    func load(
        settings: SSHConnectionSettings,
        directory: String? = nil,
        recordHistory: Bool = true,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let target = (directory ?? (
            entries.isEmpty && currentPath == "." ? settings.initialDirectory : currentPath
        )).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            errorMessage = UpdateLocalization.text(ru: "Путь на сервере не должен быть пустым", en: "The server path cannot be empty")
            completion?(false)
            return
        }
        let previous = currentPath
        let token = UUID()
        operationID = token
        isBusy = true
        errorMessage = nil
        statusMessage = UpdateLocalization.text(ru: "Читаем \(target)…", en: "Reading \(target)…")

        Task {
            do {
                let values = try await Task.detached(priority: .userInitiated) {
                    try SFTPService.list(settings: settings, directory: target)
                }.value
                guard operationID == token else { return }
                if recordHistory, target != previous {
                    backStack.append(previous)
                    forwardStack.removeAll()
                }
                rawEntries = values
                applySort()
                currentPath = target
                selectedEntryIDs.removeAll()
                isBusy = false
                statusMessage = UpdateLocalization.text(ru: "Объектов: \(values.count)", en: "Items: \(values.count)")
                completion?(true)
                enrichDirectorySizes(
                    settings: settings,
                    directory: target,
                    token: token,
                    entries: values
                )
            } catch {
                guard operationID == token else { return }
                isBusy = false
                statusMessage = UpdateLocalization.text(ru: "SFTP недоступен", en: "SFTP is unavailable")
                errorMessage = error.localizedDescription
                completion?(false)
            }
        }
    }

    private func enrichDirectorySizes(
        settings: SSHConnectionSettings,
        directory: String,
        token: UUID,
        entries: [SFTPRemoteEntry]
    ) {
        var directories = entries.filter { $0.isDirectory && !$0.isSymbolicLink }.map(\.name)
        // Avoid expensive or endless walks through virtual/mounted filesystems
        // when browsing the server root. Ordinary folders are still enriched.
        if directory == "/" {
            let skipped = Set(["dev", "proc", "sys", "run", "mnt", "media"])
            directories.removeAll { skipped.contains($0) }
        }
        guard !directories.isEmpty, directories.count <= 50 else { return }

        // Take immutable Sendable snapshots before crossing the MainActor boundary.
        // Capturing the actor-isolated local `directories` variable directly in a
        // Task.detached closure is rejected by Swift 6 as a potential data race.
        let sizeSettings = settings
        let sizeDirectory = directory
        let directoryNames = directories

        Task {
            let sizes = await Task.detached(
                priority: .utility,
                operation: { @Sendable [sizeSettings, sizeDirectory, directoryNames] in
                    SFTPService.directorySizes(
                        settings: sizeSettings,
                        directory: sizeDirectory,
                        names: directoryNames
                    )
                }
            ).value
            guard operationID == token, currentPath == directory, !sizes.isEmpty else { return }
            rawEntries = rawEntries.map { entry in
                guard let size = sizes[entry.name], entry.isDirectory else { return entry }
                return SFTPRemoteEntry(
                    name: entry.name,
                    isDirectory: entry.isDirectory,
                    isSymbolicLink: entry.isSymbolicLink,
                    size: size,
                    permissions: entry.permissions,
                    owner: entry.owner,
                    group: entry.group,
                    modifiedText: entry.modifiedText,
                    modificationDate: entry.modificationDate
                )
            }
            applySort()
        }
    }

    func refreshSilently(settings: SSHConnectionSettings) {
        guard !isBusy, !isSilentRefreshRunning else { return }
        let directory = currentPath
        isSilentRefreshRunning = true
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try SFTPService.list(settings: settings, directory: directory) }
            }.value
            defer { isSilentRefreshRunning = false }
            guard currentPath == directory else { return }
            switch result {
            case let .success(values):
                let knownSizes: [String: Int64] = Dictionary(
                    uniqueKeysWithValues: rawEntries.compactMap { entry -> (String, Int64)? in
                        guard entry.isDirectory, let size = entry.size else { return nil }
                        return (entry.name, size)
                    }
                )
                rawEntries = values.map { entry in
                    guard entry.isDirectory, entry.size == nil, let size = knownSizes[entry.name] else {
                        return entry
                    }
                    return SFTPRemoteEntry(
                        name: entry.name,
                        isDirectory: entry.isDirectory,
                        isSymbolicLink: entry.isSymbolicLink,
                        size: size,
                        permissions: entry.permissions,
                        owner: entry.owner,
                        group: entry.group,
                        modifiedText: entry.modifiedText,
                        modificationDate: entry.modificationDate
                    )
                }
                applySort()
                selectedEntryIDs.formIntersection(Set(entries.map(\.id)))
                statusMessage = UpdateLocalization.text(ru: "Объектов: \(values.count)", en: "Items: \(values.count)")
                errorMessage = nil
            case .failure:
                // Background refresh must never turn a healthy visible panel
                // into an error state because of one transient probe failure.
                break
            }
        }
    }

    func goBack(settings: SSHConnectionSettings) {
        guard let target = backStack.last else { return }
        let previous = currentPath
        load(
            settings: settings,
            directory: target,
            recordHistory: false
        ) { success in
            guard success else { return }
            _ = self.backStack.popLast()
            self.forwardStack.append(previous)
        }
    }

    func goForward(settings: SSHConnectionSettings) {
        guard let target = forwardStack.last else { return }
        let previous = currentPath
        load(
            settings: settings,
            directory: target,
            recordHistory: false
        ) { success in
            guard success else { return }
            _ = self.forwardStack.popLast()
            self.backStack.append(previous)
        }
    }

    func open(_ entry: SFTPRemoteEntry, settings: SSHConnectionSettings) {
        guard entry.isDirectory else {
            selectedEntryIDs = [entry.id]
            return
        }
        load(
            settings: settings,
            directory: SFTPService.joinedRemotePath(currentPath, entry.name)
        )
    }

    func goUp(settings: SSHConnectionSettings) {
        load(
            settings: settings,
            directory: SFTPService.parentRemotePath(currentPath)
        )
    }

    func download(
        _ entry: SFTPRemoteEntry,
        to localDirectory: URL,
        settings: SSHConnectionSettings
    ) {
        let remotePath = SFTPService.joinedRemotePath(currentPath, entry.name)
        guard let destination = localDestination(
            directory: localDirectory,
            name: entry.name,
            isDirectory: entry.isDirectory
        ) else { return }
        download(
            remotePath: remotePath,
            name: entry.name,
            isDirectory: entry.isDirectory,
            totalBytes: entry.size,
            destination: destination,
            settings: settings
        )
    }

    func download(
        payload: SFTPRemoteDragPayload,
        to localDirectory: URL,
        settings: SSHConnectionSettings
    ) {
        guard payload.profileID == settings.profileID else {
            errorMessage = UpdateLocalization.text(ru: "Этот удалённый объект относится к другому SSH-профилю", en: "This remote item belongs to another SSH profile")
            return
        }
        guard let destination = localDestination(
            directory: localDirectory,
            name: payload.name,
            isDirectory: payload.isDirectory
        ) else { return }
        download(
            remotePath: payload.remotePath,
            name: payload.name,
            isDirectory: payload.isDirectory,
            totalBytes: nil,
            destination: destination,
            settings: settings
        )
    }

    func upload(
        localURLs: [URL],
        to remoteDirectory: String? = nil,
        settings: SSHConnectionSettings,
        sizeHints: [String: Int64] = [:]
    ) {
        let targetDirectory = remoteDirectory ?? currentPath
        var reservedNames = transfers.conflictPolicy == .rename && targetDirectory == currentPath
            ? Set(entries.map(\.name))
            : []
        let requests = localURLs.compactMap { url -> UploadRequest? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = values?.isDirectory ?? url.hasDirectoryPath
            let exists = targetDirectory == currentPath
                && entries.contains(where: { $0.name == url.lastPathComponent })
            if exists && transfers.conflictPolicy == .skip { return nil }
            let name = transfers.conflictPolicy == .rename
                ? Self.availableRemoteName(
                    preferredName: url.lastPathComponent,
                    isDirectory: isDirectory,
                    reservedNames: &reservedNames
                )
                : url.lastPathComponent
            return UploadRequest(
                localURL: url,
                remotePath: SFTPService.joinedRemotePath(targetDirectory, name),
                isDirectory: isDirectory
            )
        }
        guard !requests.isEmpty else { return }

        for request in requests {
            let id = UUID()
            let accessedForSize = request.localURL.startAccessingSecurityScopedResource()
            let totalBytes = sizeHints[request.localURL.path] ?? Self.localItemSize(request.localURL)
            if accessedForSize { request.localURL.stopAccessingSecurityScopedResource() }
            let item = SFTPTransferItem(
                id: id,
                direction: .upload,
                name: request.localURL.lastPathComponent,
                source: request.localURL.path,
                destination: request.remotePath,
                totalBytes: totalBytes,
                createdAt: Date(),
                phase: .queued,
                transferredBytes: 0,
                bytesPerSecond: 0,
                errorMessage: nil
            )
            transfers.enqueue(SFTPTransferRequest(
                item: item,
                operation: { resume, control in
                let accessed = request.localURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        request.localURL.stopAccessingSecurityScopedResource()
                    }
                }
                try SFTPService.upload(
                    settings: settings,
                    localURL: request.localURL,
                    remotePath: request.remotePath,
                    isDirectory: request.isDirectory,
                    resume: resume,
                    control: control
                )
                },
                progressProbe: {
                    SFTPService.transferItemSize(
                        settings: settings,
                        remotePath: request.remotePath,
                        isDirectory: request.isDirectory
                    )
                },
                completion: { [weak self] in
                    guard let self else { return }
                    self.statusMessage = UpdateLocalization.text(ru: "\(request.localURL.lastPathComponent) загружен", en: "\(request.localURL.lastPathComponent) uploaded")
                    if targetDirectory == self.currentPath {
                        self.load(settings: settings, directory: self.currentPath, recordHistory: false)
                    }
                }
            ))
        }
        statusMessage = UpdateLocalization.text(ru: "Добавлено в очередь: \(requests.count)", en: "Added to queue: \(requests.count)")
    }

    func copyRemote(
        _ sourceEntries: [SFTPRemoteEntry],
        from sourceDirectory: String,
        sourceSettings: SSHConnectionSettings,
        destinationSettings: SSHConnectionSettings,
        to destinationDirectory: String? = nil
    ) {
        guard !sourceEntries.isEmpty else { return }
        let targetDirectory = destinationDirectory ?? currentPath
        var reservedNames = transfers.conflictPolicy == .rename && targetDirectory == currentPath
            ? Set(entries.map(\.name))
            : []

        var added = 0
        for entry in sourceEntries {
            let destinationExists = targetDirectory == currentPath
                && entries.contains { $0.name == entry.name }
            if destinationExists && transfers.conflictPolicy == .skip {
                continue
            }

            let destinationName = transfers.conflictPolicy == .rename
                ? Self.availableRemoteName(
                    preferredName: entry.name,
                    isDirectory: entry.isDirectory,
                    reservedNames: &reservedNames
                )
                : entry.name
            enqueueRemoteBridge(
                name: entry.name,
                destinationName: destinationName,
                isDirectory: entry.isDirectory,
                sourcePath: SFTPService.joinedRemotePath(sourceDirectory, entry.name),
                sourceTotalBytes: entry.size,
                targetDirectory: targetDirectory,
                sourceSettings: sourceSettings,
                destinationSettings: destinationSettings
            )
            added += 1
        }

        if added == 0 {
            statusMessage = UpdateLocalization.text(ru: "Выбранные объекты пропущены по политике конфликтов", en: "Selected items were skipped by the conflict policy")
        } else {
            statusMessage = UpdateLocalization.text(ru: "Server → Server: добавлено в очередь \(added)", en: "Server → Server: \(added) added to queue")
        }
    }

    func copyRemote(
        payload: SFTPRemoteDragPayload,
        sourceSettings: SSHConnectionSettings,
        destinationSettings: SSHConnectionSettings,
        to destinationDirectory: String? = nil
    ) {
        guard payload.profileID == sourceSettings.profileID else {
            errorMessage = UpdateLocalization.text(ru: "Перетаскиваемый объект относится к другой SSH-сессии", en: "The dragged item belongs to another SSH session")
            return
        }
        let targetDirectory = destinationDirectory ?? currentPath
        if targetDirectory == currentPath,
           entries.contains(where: { $0.name == payload.name }),
           transfers.conflictPolicy == .skip {
            statusMessage = UpdateLocalization.text(ru: "«\(payload.name)» пропущен: объект уже существует", en: "“\(payload.name)” skipped: item already exists")
            return
        }

        var reservedNames = transfers.conflictPolicy == .rename && targetDirectory == currentPath
            ? Set(entries.map(\.name))
            : []
        let destinationName = transfers.conflictPolicy == .rename
            ? Self.availableRemoteName(
                preferredName: payload.name,
                isDirectory: payload.isDirectory,
                reservedNames: &reservedNames
            )
            : payload.name
        enqueueRemoteBridge(
            name: payload.name,
            destinationName: destinationName,
            isDirectory: payload.isDirectory,
            sourcePath: payload.remotePath,
            sourceTotalBytes: nil,
            targetDirectory: targetDirectory,
            sourceSettings: sourceSettings,
            destinationSettings: destinationSettings
        )
        statusMessage = UpdateLocalization.text(ru: "Server → Server: «\(payload.name)» добавлен в очередь", en: "Server → Server: “\(payload.name)” added to queue")
    }

    private func enqueueRemoteBridge(
        name: String,
        destinationName: String,
        isDirectory: Bool,
        sourcePath: String,
        sourceTotalBytes: Int64?,
        targetDirectory: String,
        sourceSettings: SSHConnectionSettings,
        destinationSettings: SSHConnectionSettings
    ) {
        let destinationPath = SFTPService.joinedRemotePath(
            targetDirectory,
            destinationName
        )
        let transferID = UUID()
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SelectiveRemote-SFTP-Bridge-\(transferID.uuidString)",
                isDirectory: true
            )
        let staged = stagingDirectory.appendingPathComponent(
            name,
            isDirectory: isDirectory
        )
        let bridgeProgress = SFTPServerBridgeProgressState()
        let combinedTotal = sourceTotalBytes.flatMap { size -> Int64? in
            guard size > 0, size <= Int64.max / 2 else { return nil }
            return size * 2
        }
        let item = SFTPTransferItem(
            id: transferID,
            direction: .serverToServer,
            name: name,
            source: "\(sourceSettings.host):\(sourcePath)",
            destination: "\(destinationSettings.host):\(destinationPath)",
            totalBytes: combinedTotal,
            createdAt: Date(),
            phase: .queued,
            transferredBytes: 0,
            bytesPerSecond: 0,
            errorMessage: nil
        )

        transfers.enqueue(
            SFTPTransferRequest(
                item: item,
                operation: { _, control in
                    defer {
                        try? FileManager.default.removeItem(at: stagingDirectory)
                    }

                    try FileManager.default.createDirectory(
                        at: stagingDirectory,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                    try SFTPService.download(
                        settings: sourceSettings,
                        remotePath: sourcePath,
                        localURL: staged,
                        isDirectory: isDirectory,
                        resume: false,
                        control: control
                    )
                    bridgeProgress.beginUpload(
                        downloadedBytes: Self.localItemSize(staged)
                            ?? sourceTotalBytes
                            ?? 0
                    )
                    try SFTPService.upload(
                        settings: destinationSettings,
                        localURL: staged,
                        remotePath: destinationPath,
                        isDirectory: isDirectory,
                        resume: false,
                        control: control
                    )
                },
                progressProbe: {
                    let snapshot = bridgeProgress.snapshot()
                    switch snapshot.stage {
                    case .download:
                        return Self.localItemSize(staged)
                    case .upload:
                        let uploaded = SFTPService.transferItemSize(
                            settings: destinationSettings,
                            remotePath: destinationPath,
                            isDirectory: isDirectory
                        ) ?? 0
                        return snapshot.downloadedBytes + uploaded
                    }
                },
                completion: { [weak self] in
                    guard let self else { return }
                    self.statusMessage = UpdateLocalization.text(ru: "«\(name)» скопирован между серверами", en: "“\(name)” copied between servers")
                    if self.currentPath == targetDirectory {
                        self.load(
                            settings: destinationSettings,
                            directory: self.currentPath,
                            recordHistory: false
                        )
                    }
                }
            )
        )
    }

    func createDirectory(
        named name: String,
        settings: SSHConnectionSettings
    ) {
        do {
            let validated = try SFTPService.validatedName(name)
            let remotePath = SFTPService.joinedRemotePath(currentPath, validated)
            runTransfer(status: UpdateLocalization.text(ru: "Создаём \(validated)…", en: "Creating \(validated)…")) {
                try SFTPService.createDirectory(
                    settings: settings,
                    remotePath: remotePath
                )
            } completion: {
                self.statusMessage = UpdateLocalization.text(ru: "Папка \(validated) создана", en: "Folder \(validated) created")
                self.load(
                    settings: settings,
                    directory: self.currentPath,
                    recordHistory: false
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createFile(
        named name: String,
        settings: SSHConnectionSettings
    ) {
        do {
            let validated = try SFTPService.validatedName(name)
            guard !rawEntries.contains(where: { $0.name == validated }) else {
                throw SFTPLocalFileError.targetExists(validated)
            }
            let remotePath = SFTPService.joinedRemotePath(currentPath, validated)
            runTransfer(status: UpdateLocalization.text(ru: "Создаём \(validated)…", en: "Creating \(validated)…")) {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "SelectiveRemote-SFTP-Create-\(UUID().uuidString)",
                        isDirectory: true
                    )
                let source = directory.appendingPathComponent(validated)
                defer { try? FileManager.default.removeItem(at: directory) }
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false
                )
                try Data().write(to: source, options: .atomic)
                try SFTPService.uploadFileContents(
                    settings: settings,
                    localURL: source,
                    remotePath: remotePath
                )
            } completion: {
                self.statusMessage = UpdateLocalization.text(ru: "Файл \(validated) создан", en: "File \(validated) created")
                self.load(
                    settings: settings,
                    directory: self.currentPath,
                    recordHistory: false
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(
        _ entry: SFTPRemoteEntry,
        to name: String,
        settings: SSHConnectionSettings
    ) {
        do {
            let validated = try SFTPService.validatedName(name)
            guard !rawEntries.contains(where: { $0.name == validated }) else {
                throw SFTPLocalFileError.targetExists(validated)
            }
            let source = SFTPService.joinedRemotePath(currentPath, entry.name)
            let destination = SFTPService.joinedRemotePath(currentPath, validated)
            runTransfer(status: UpdateLocalization.text(ru: "Переименовываем «\(entry.name)»…", en: "Renaming “\(entry.name)”…")) {
                try SFTPService.rename(
                    settings: settings,
                    from: source,
                    to: destination
                )
            } completion: {
                self.statusMessage = UpdateLocalization.text(ru: "«\(entry.name)» переименован", en: "“\(entry.name)” renamed")
                self.load(
                    settings: settings,
                    directory: self.currentPath,
                    recordHistory: false
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(
        _ entry: SFTPRemoteEntry,
        settings: SSHConnectionSettings
    ) {
        let path = SFTPService.joinedRemotePath(currentPath, entry.name)
        runTransfer(status: UpdateLocalization.text(ru: "Удаляем «\(entry.name)»…", en: "Deleting “\(entry.name)”…")) {
            try SFTPService.remove(
                settings: settings,
                remotePath: path,
                isDirectory: entry.isDirectory
            )
        } completion: {
            self.statusMessage = UpdateLocalization.text(ru: "«\(entry.name)» удалён", en: "“\(entry.name)” deleted")
            self.load(
                settings: settings,
                directory: self.currentPath,
                recordHistory: false
            )
        }
    }

    func remove(
        _ entries: [SFTPRemoteEntry],
        settings: SSHConnectionSettings
    ) {
        guard !entries.isEmpty else { return }
        if entries.count == 1 {
            remove(entries[0], settings: settings)
            return
        }
        let items = entries.map { entry in
            (
                path: SFTPService.joinedRemotePath(currentPath, entry.name),
                isDirectory: entry.isDirectory
            )
        }
        runTransfer(status: UpdateLocalization.text(ru: "Удаляем объектов: \(entries.count)…", en: "Deleting items: \(entries.count)…")) {
            try SFTPService.removeMany(settings: settings, items: items)
        } completion: {
            self.statusMessage = UpdateLocalization.text(ru: "Удалено объектов: \(entries.count)", en: "Deleted items: \(entries.count)")
            self.load(
                settings: settings,
                directory: self.currentPath,
                recordHistory: false
            )
        }
    }

    func updateAttributes(
        _ entry: SFTPRemoteEntry,
        mode: String?,
        ownerID: Int?,
        groupID: Int?,
        settings: SSHConnectionSettings
    ) {
        let path = SFTPService.joinedRemotePath(currentPath, entry.name)
        runTransfer(status: UpdateLocalization.text(ru: "Обновляем свойства «\(entry.name)»…", en: "Updating properties for “\(entry.name)”…")) {
            try SFTPService.updateAttributes(
                settings: settings,
                remotePath: path,
                mode: mode,
                ownerID: ownerID,
                groupID: groupID
            )
        } completion: {
            self.statusMessage = UpdateLocalization.text(ru: "Свойства «\(entry.name)» обновлены", en: "Properties for “\(entry.name)” updated")
            self.load(
                settings: settings,
                directory: self.currentPath,
                recordHistory: false
            )
        }
    }

    func edit(
        _ entry: SFTPRemoteEntry,
        settings: SSHConnectionSettings
    ) {
        guard !entry.isDirectory else { return }
        if let size = entry.size, size > 5 * 1_024 * 1_024 {
            errorMessage = SFTPLocalFileError.textFileTooLarge.localizedDescription
            return
        }
        let remotePath = SFTPService.joinedRemotePath(currentPath, entry.name)
        let token = UUID()
        operationID = token
        isBusy = true
        errorMessage = nil
        statusMessage = UpdateLocalization.text(ru: "Открываем «\(entry.name)»…", en: "Opening “\(entry.name)”…")

        Task {
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent(
                            "SelectiveRemote-SFTP-Edit-\(UUID().uuidString)",
                            isDirectory: true
                        )
                    let destination = directory.appendingPathComponent(entry.name)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: false
                    )
                    try SFTPService.download(
                        settings: settings,
                        remotePath: remotePath,
                        localURL: destination
                    )
                    let data = try Data(contentsOf: destination)
                    guard data.count <= 5 * 1_024 * 1_024 else {
                        throw SFTPLocalFileError.textFileTooLarge
                    }
                    guard !data.contains(UInt8(0)),
                          let text = String(data: data, encoding: .utf8)
                    else {
                        throw SFTPLocalFileError.unsupportedTextEncoding
                    }
                    return SFTPRemoteTextDocument(
                        remotePath: remotePath,
                        name: entry.name,
                        text: text
                    )
                }.value
                guard operationID == token else { return }
                isBusy = false
                statusMessage = UpdateLocalization.text(ru: "«\(entry.name)» открыт в редакторе", en: "“\(entry.name)” opened in editor")
                editorDocument = document
            } catch {
                guard operationID == token else { return }
                isBusy = false
                statusMessage = UpdateLocalization.text(ru: "Файл не открыт", en: "Could not open file")
                errorMessage = error.localizedDescription
            }
        }
    }

    func save(
        _ document: SFTPRemoteTextDocument,
        text: String,
        settings: SSHConnectionSettings
    ) {
        runTransfer(status: UpdateLocalization.text(ru: "Сохраняем «\(document.name)»…", en: "Saving “\(document.name)”…")) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "SelectiveRemote-SFTP-Save-\(UUID().uuidString)",
                    isDirectory: true
                )
            let source = directory.appendingPathComponent(document.name)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            try Data(text.utf8).write(to: source, options: .atomic)
            // Do not use `put -p` here: preserving the temporary local file's
            // attributes would silently replace the remote POSIX mode.
            try SFTPService.uploadFileContents(
                settings: settings,
                localURL: source,
                remotePath: document.remotePath
            )
        } completion: {
            self.editorDocument = nil
            self.statusMessage = UpdateLocalization.text(ru: "«\(document.name)» сохранён", en: "“\(document.name)” saved")
            self.load(
                settings: settings,
                directory: self.currentPath,
                recordHistory: false
            )
        }
    }

    func openDownloaded(
        _ entry: SFTPRemoteEntry,
        applicationURL: URL?,
        settings: SSHConnectionSettings
    ) {
        guard !entry.isDirectory else { return }
        let remotePath = SFTPService.joinedRemotePath(currentPath, entry.name)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SelectiveRemote-SFTP-Open-\(UUID().uuidString)",
                isDirectory: true
            )
        let destination = directory.appendingPathComponent(entry.name)
        runTransfer(status: UpdateLocalization.text(ru: "Скачиваем «\(entry.name)» для открытия…", en: "Downloading “\(entry.name)” to open…")) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            do {
                try SFTPService.download(
                    settings: settings,
                    remotePath: remotePath,
                    localURL: destination
                )
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        } completion: {
            if let applicationURL {
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open(
                    [destination],
                    withApplicationAt: applicationURL,
                    configuration: configuration
                ) { [weak self] _, error in
                    guard let error else { return }
                    Task { @MainActor [weak self] in
                        self?.errorMessage = error.localizedDescription
                    }
                }
            } else {
                NSWorkspace.shared.open(destination)
            }
            self.statusMessage = UpdateLocalization.text(ru: "«\(entry.name)» открыт из временной копии", en: "“\(entry.name)” opened from a temporary copy")
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .seconds(86_400)
            ) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    func dragProvider(
        for entry: SFTPRemoteEntry,
        settings: SSHConnectionSettings
    ) -> NSItemProvider {
        let remotePath = SFTPService.joinedRemotePath(currentPath, entry.name)
        let fileType = entry.isDirectory
            ? UTType.folder.identifier
            : UTType(filenameExtension: URL(fileURLWithPath: entry.name).pathExtension)?
                .identifier ?? UTType.data.identifier
        let provider = NSItemProvider()
        provider.suggestedName = entry.name
        provider.registerFileRepresentation(
            forTypeIdentifier: fileType,
            fileOptions: [],
            visibility: NSItemProviderRepresentationVisibility.all
        ) { completionHandler in
            let completion = SFTPFileRepresentationCompletion(completionHandler)
            DispatchQueue.global(qos: .userInitiated).async {
                let exportDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "SelectiveRemote-SFTP-Drag-\(UUID().uuidString)",
                        isDirectory: true
                    )
                let destination = exportDirectory.appendingPathComponent(
                    entry.name,
                    isDirectory: entry.isDirectory
                )
                do {
                    try FileManager.default.createDirectory(
                        at: exportDirectory,
                        withIntermediateDirectories: false
                    )
                    try SFTPService.download(
                        settings: settings,
                        remotePath: remotePath,
                        localURL: destination,
                        isDirectory: entry.isDirectory
                    )
                    completion.finish(url: destination, isInPlace: false, error: nil)
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + .seconds(86_400)
                    ) {
                        try? FileManager.default.removeItem(at: exportDirectory)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: exportDirectory)
                    completion.finish(url: nil, isInPlace: false, error: error)
                }
            }
            return nil
        }

        let payload = SFTPRemoteDragPayload(
            profileID: settings.profileID,
            remotePath: remotePath,
            name: entry.name,
            isDirectory: entry.isDirectory
        )
        if let data = try? JSONEncoder().encode(payload) {
            provider.registerDataRepresentation(
                forTypeIdentifier: SFTPDragType.remoteEntry.identifier,
                visibility: NSItemProviderRepresentationVisibility.all
            ) { completion in
                Task { @MainActor in
                    completion(data, nil)
                }
                return nil
            }
        }
        return provider
    }

    private func download(
        remotePath: String,
        name: String,
        isDirectory: Bool,
        totalBytes: Int64?,
        destination: URL,
        settings: SSHConnectionSettings
    ) {
        let id = UUID()
        let item = SFTPTransferItem(
            id: id,
            direction: .download,
            name: name,
            source: remotePath,
            destination: destination.path,
            totalBytes: isDirectory ? nil : totalBytes,
            createdAt: Date(),
            phase: .queued,
            transferredBytes: 0,
            bytesPerSecond: 0,
            errorMessage: nil
        )
        let replace = transfers.conflictPolicy == .replace
        transfers.enqueue(SFTPTransferRequest(
            item: item,
            operation: { resume, control in
                if replace && !resume && FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try SFTPService.download(
                    settings: settings,
                    remotePath: remotePath,
                    localURL: destination,
                    isDirectory: isDirectory,
                    resume: resume,
                    control: control
                )
            },
            progressProbe: { Self.localItemSize(destination) },
            completion: { [weak self] in
                self?.statusMessage = UpdateLocalization.text(ru: "\(name) скачан в \(destination.deletingLastPathComponent().path)", en: "\(name) downloaded to \(destination.deletingLastPathComponent().path)")
            }
        ))
        statusMessage = UpdateLocalization.text(ru: "«\(name)» добавлен в очередь", en: "“\(name)” added to queue")
    }

    private func localDestination(
        directory: URL,
        name: String,
        isDirectory: Bool
    ) -> URL? {
        let exact = directory.appendingPathComponent(name, isDirectory: isDirectory)
        guard FileManager.default.fileExists(atPath: exact.path) else { return exact }
        switch transfers.conflictPolicy {
        case .rename:
            return SFTPLocalBrowserModel.availableDestination(
                directory: directory,
                preferredName: name,
                isDirectory: isDirectory
            )
        case .replace:
            return exact
        case .skip:
            statusMessage = UpdateLocalization.text(ru: "«\(name)» пропущен: объект уже существует", en: "“\(name)” skipped: item already exists")
            return nil
        }
    }

    nonisolated private static func localItemSize(_ url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let number = attributes[.size] as? NSNumber {
                return number.int64Value
            }
            return nil
        }
        if values.isDirectory != true {
            if let fileSize = values.fileSize { return Int64(fileSize) }
            if let allocated = values.totalFileAllocatedSize { return Int64(allocated) }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let number = attributes[.size] as? NSNumber {
                return number.int64Value
            }
            return nil
        }
        // SFTP `put -r` transfers dotfiles and hidden subdirectories too.
        // The progress total must therefore count exactly the same tree; skipping
        // hidden files made the denominator smaller than the bytes actually sent.
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return nil }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            if let childValues = try? child.resourceValues(forKeys: keys),
               childValues.isDirectory != true {
                total += Int64(childValues.fileSize ?? 0)
            }
        }
        return total
    }

    private func runTransfer(
        status: String,
        operation: @escaping @Sendable () throws -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        let token = UUID()
        operationID = token
        isBusy = true
        errorMessage = nil
        statusMessage = status

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try operation()
                }.value
                guard operationID == token else { return }
                isBusy = false
                completion()
            } catch {
                guard operationID == token else { return }
                isBusy = false
                statusMessage = UpdateLocalization.text(ru: "Операция SFTP не выполнена", en: "SFTP operation failed")
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applySort() {
        let visibleEntries = rawEntries.filter {
            SFTPNameFilter.matches($0.name, query: filterText)
        }
        entries = SFTPRemoteEntrySorter.sorted(
            visibleEntries,
            by: sortField,
            direction: sortDirection
        )
        selectedEntryIDs.formIntersection(Set(entries.map(\.id)))
    }

    private static func availableRemoteName(
        preferredName: String,
        isDirectory: Bool,
        reservedNames: inout Set<String>
    ) -> String {
        guard reservedNames.contains(preferredName) else {
            reservedNames.insert(preferredName)
            return preferredName
        }

        let source = URL(fileURLWithPath: preferredName)
        let extensionText = isDirectory ? "" : source.pathExtension
        let base = extensionText.isEmpty
            ? preferredName
            : source.deletingPathExtension().lastPathComponent
        for index in 1...9_999 {
            let marker = index == 1 ? " копия" : " копия \(index)"
            let candidate = extensionText.isEmpty
                ? base + marker
                : base + marker + "." + extensionText
            if !reservedNames.contains(candidate) {
                reservedNames.insert(candidate)
                return candidate
            }
        }
        let fallback = "\(UUID().uuidString)-\(preferredName)"
        reservedNames.insert(fallback)
        return fallback
    }
}

enum SFTPConnectionState: String, Equatable {
    case disconnected
    case connecting
    case connected
    case error

    var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .error: "Error"
        }
    }
}

@MainActor
final class SFTPBrowserSession: ObservableObject {
    let transfers: SFTPTransferQueue
    let remote: SFTPBrowserModel
    let local = SFTPLocalBrowserModel()
    @Published var settings: SSHConnectionSettings?
    @Published private(set) var connectionState = SFTPConnectionState.disconnected
    @Published private(set) var connectedAt: Date?
    @Published private(set) var lastErrorMessage: String?

    private(set) var profileID: UUID?
    private var retainedMasterSettings: SSHConnectionSettings?

    init() {
        let transfers = SFTPTransferQueue()
        self.transfers = transfers
        remote = SFTPBrowserModel(transfers: transfers)
    }

    func prepare(for profileID: UUID) {
        guard self.profileID != profileID else { return }
        self.profileID = profileID
        disconnect()
    }

    func connect(
        _ settings: SSHConnectionSettings,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        if let retainedMasterSettings {
            SFTPService.releaseMasterConnection(settings: retainedMasterSettings)
        }
        retainedMasterSettings = settings
        SFTPService.retainMasterConnection(settings: settings)
        self.settings = settings
        connectionState = .connecting
        connectedAt = nil
        lastErrorMessage = nil
        remote.load(
            settings: settings,
            directory: settings.initialDirectory
        ) { [weak self] success in
            guard let self else {
                completion?(success)
                return
            }
            if success {
                connectionState = .connected
                connectedAt = Date()
                lastErrorMessage = nil
            } else {
                connectionState = .error
                connectedAt = nil
                lastErrorMessage = remote.errorMessage
            }
            completion?(success)
        }
    }

    func disconnect() {
        transfers.cancelAll()
        if let retainedMasterSettings {
            SFTPService.releaseMasterConnection(settings: retainedMasterSettings)
            self.retainedMasterSettings = nil
        }
        settings = nil
        connectionState = .disconnected
        connectedAt = nil
        lastErrorMessage = nil
        remote.reset()
    }
}
