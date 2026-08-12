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
        return modificationDate.formatted(
            .dateTime
                .day()
                .month(.abbreviated)
                .year()
                .hour()
                .minute()
        )
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
            "Не удалось прочитать локальную папку: \(path)"
        case let .targetExists(name):
            "Локальный объект «\(name)» уже существует"
        case let .copyFailed(message):
            "Не удалось скопировать локальный объект: \(message)"
        case let .operationFailed(message):
            message
        case .textFileTooLarge:
            "Встроенный редактор открывает текстовые файлы размером не более 5 МБ"
        case .unsupportedTextEncoding:
            "Файл похож на двоичный или использует неподдерживаемую кодировку. Откройте его во внешнем приложении."
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
        statusMessage = "Читаем локальную папку…"

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
                statusMessage = "Объектов: \(values.count)"
                errorMessage = nil
            } catch {
                guard reloadID == token, currentDirectory == directory else { return }
                rawEntries = []
                entries = []
                isReloading = false
                updateBusy()
                statusMessage = "Локальная папка недоступна"
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
            statusMessage = "Папка \(validated) создана"
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
            statusMessage = "Файл \(validated) создан"
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
            statusMessage = "«\(entry.name)» переименован"
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveToTrash(_ entry: SFTPLocalEntry) {
        isTransferring = true
        updateBusy()
        statusMessage = "Перемещаем «\(entry.name)» в Корзину…"
        NSWorkspace.shared.recycle([entry.url]) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTransferring = false
                self.updateBusy()
                if let error {
                    self.statusMessage = "Удаление не выполнено"
                    self.errorMessage = error.localizedDescription
                } else {
                    self.statusMessage = "«\(entry.name)» перемещён в Корзину"
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
        statusMessage = "Перемещаем в Корзину: \(entries.count)…"
        NSWorkspace.shared.recycle(entries.map(\.url)) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTransferring = false
                self.updateBusy()
                if let error {
                    self.statusMessage = "Удаление не выполнено"
                    self.errorMessage = error.localizedDescription
                } else {
                    self.statusMessage = "Перемещено в Корзину: \(entries.count)"
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
            statusMessage = "Свойства «\(entry.name)» обновлены"
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
        statusMessage = "Копируем на этот Mac…"

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
                statusMessage = "Локальное копирование завершено"
                if destinationDirectory.standardizedFileURL == currentDirectory {
                    reload()
                }
            } catch {
                isTransferring = false
                updateBusy()
                statusMessage = "Локальное копирование не выполнено"
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

@MainActor
final class SFTPBrowserModel: ObservableObject {
    @Published private(set) var entries: [SFTPRemoteEntry] = []
    @Published private(set) var currentPath = "."
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = "SFTP ещё не подключён"
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
        statusMessage = "SFTP ещё не подключён"
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
            errorMessage = "Путь на сервере не должен быть пустым"
            completion?(false)
            return
        }
        let previous = currentPath
        let token = UUID()
        operationID = token
        isBusy = true
        errorMessage = nil
        statusMessage = "Читаем \(target)…"

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
                statusMessage = "Объектов: \(values.count)"
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
                statusMessage = "SFTP недоступен"
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

        // Snapshot the filtered names before crossing the MainActor boundary.
        // `directories` is mutable actor-isolated state within this method;
        // capturing it directly in Task.detached is rejected by newer Swift 6
        // concurrency checking even though [String] itself is Sendable.
        let directoryNames = directories
        Task {
            let sizes = await Task.detached(
                priority: .utility,
                operation: { [settings, directory, directoryNames] in
                    SFTPService.directorySizes(
                        settings: settings,
                        directory: directory,
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
                statusMessage = "Объектов: \(values.count)"
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
            errorMessage = "Этот удалённый объект относится к другому SSH-профилю"
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
                    self.statusMessage = "\(request.localURL.lastPathComponent) загружен"
                    if targetDirectory == self.currentPath {
                        self.load(settings: settings, directory: self.currentPath, recordHistory: false)
                    }
                }
            ))
        }
        statusMessage = "Добавлено в очередь: \(requests.count)"
    }

    func createDirectory(
        named name: String,
        settings: SSHConnectionSettings
    ) {
        do {
            let validated = try SFTPService.validatedName(name)
            let remotePath = SFTPService.joinedRemotePath(currentPath, validated)
            runTransfer(status: "Создаём \(validated)…") {
                try SFTPService.createDirectory(
                    settings: settings,
                    remotePath: remotePath
                )
            } completion: {
                self.statusMessage = "Папка \(validated) создана"
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
            runTransfer(status: "Создаём \(validated)…") {
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
                self.statusMessage = "Файл \(validated) создан"
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
            runTransfer(status: "Переименовываем «\(entry.name)»…") {
                try SFTPService.rename(
                    settings: settings,
                    from: source,
                    to: destination
                )
            } completion: {
                self.statusMessage = "«\(entry.name)» переименован"
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
        runTransfer(status: "Удаляем «\(entry.name)»…") {
            try SFTPService.remove(
                settings: settings,
                remotePath: path,
                isDirectory: entry.isDirectory
            )
        } completion: {
            self.statusMessage = "«\(entry.name)» удалён"
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
        runTransfer(status: "Удаляем объектов: \(entries.count)…") {
            try SFTPService.removeMany(settings: settings, items: items)
        } completion: {
            self.statusMessage = "Удалено объектов: \(entries.count)"
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
        runTransfer(status: "Обновляем свойства «\(entry.name)»…") {
            try SFTPService.updateAttributes(
                settings: settings,
                remotePath: path,
                mode: mode,
                ownerID: ownerID,
                groupID: groupID
            )
        } completion: {
            self.statusMessage = "Свойства «\(entry.name)» обновлены"
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
        statusMessage = "Открываем «\(entry.name)»…"

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
                statusMessage = "«\(entry.name)» открыт в редакторе"
                editorDocument = document
            } catch {
                guard operationID == token else { return }
                isBusy = false
                statusMessage = "Файл не открыт"
                errorMessage = error.localizedDescription
            }
        }
    }

    func save(
        _ document: SFTPRemoteTextDocument,
        text: String,
        settings: SSHConnectionSettings
    ) {
        runTransfer(status: "Сохраняем «\(document.name)»…") {
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
            self.statusMessage = "«\(document.name)» сохранён"
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
        runTransfer(status: "Скачиваем «\(entry.name)» для открытия…") {
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
            self.statusMessage = "«\(entry.name)» открыт из временной копии"
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
                self?.statusMessage = "\(name) скачан в \(destination.deletingLastPathComponent().path)"
            }
        ))
        statusMessage = "«\(name)» добавлен в очередь"
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
            statusMessage = "«\(name)» пропущен: объект уже существует"
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
                statusMessage = "Операция SFTP не выполнена"
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

@MainActor
final class SFTPBrowserSession: ObservableObject {
    let transfers: SFTPTransferQueue
    let remote: SFTPBrowserModel
    let local = SFTPLocalBrowserModel()
    @Published var settings: SSHConnectionSettings?

    private(set) var profileID: UUID?

    init() {
        let transfers = SFTPTransferQueue()
        self.transfers = transfers
        remote = SFTPBrowserModel(transfers: transfers)
    }

    func prepare(for profileID: UUID) {
        guard self.profileID != profileID else { return }
        self.profileID = profileID
        settings = nil
        remote.reset()
    }

    func connect(
        _ settings: SSHConnectionSettings,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        self.settings = settings
        remote.load(
            settings: settings,
            directory: settings.initialDirectory,
            completion: completion
        )
    }
}
