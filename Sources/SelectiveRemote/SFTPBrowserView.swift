@preconcurrency import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SFTPRenameTarget {
    case local(SFTPLocalEntry)
    case remote(SFTPRemoteEntry)
}

private enum SFTPDeleteTarget {
    case local([SFTPLocalEntry])
    case remote([SFTPRemoteEntry])
}

struct SFTPBrowserView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject private var session: SFTPBrowserSession
    @ObservedObject private var remote: SFTPBrowserModel
    @ObservedObject private var local: SFTPLocalBrowserModel
    @ObservedObject private var transfers: SFTPTransferQueue
    @State private var showsRemoteFolderPrompt = false
    @State private var showsLocalFolderPrompt = false
    @State private var showsRemoteFilePrompt = false
    @State private var showsLocalFilePrompt = false
    @State private var showsRenamePrompt = false
    @State private var showsDeleteConfirmation = false
    @State private var newRemoteFolderName = ""
    @State private var newLocalFolderName = ""
    @State private var newRemoteFileName = ""
    @State private var newLocalFileName = ""
    @State private var renameText = ""
    @State private var renameTarget: SFTPRenameTarget?
    @State private var deleteTarget: SFTPDeleteTarget?
    @State private var propertiesTarget: SFTPPropertiesTarget?
    @State private var remoteDropTargeted = false
    @State private var localDropTargeted = false
    @State private var localPathInput = ""
    @State private var remotePathInput = "."
    @State private var showsTransferQueue = false

    let profile: ConnectionProfile
    let requestConnection: (() -> Void)?
    let openTerminal: (() -> Void)?
    let activeSSHSession: (() -> Bool)?

    init(
        profile: ConnectionProfile,
        session: SFTPBrowserSession,
        requestConnection: (() -> Void)? = nil,
        openTerminal: (() -> Void)? = nil,
        activeSSHSession: (() -> Bool)? = nil
    ) {
        self.profile = profile
        self.requestConnection = requestConnection
        self.openTerminal = openTerminal
        self.activeSSHSession = activeSSHSession
        _session = ObservedObject(wrappedValue: session)
        _remote = ObservedObject(wrappedValue: session.remote)
        _local = ObservedObject(wrappedValue: session.local)
        _transfers = ObservedObject(wrappedValue: session.transfers)
    }

    private var settings: SSHConnectionSettings? { session.settings }

    var body: some View {
        sheetsContent
    }

    private var browserContent: some View {
        GroupBox("Файлы · двухпанельный SFTP") {
            VStack(alignment: .leading, spacing: 12) {
                connectionBar

                HSplitView {
                    localPanel
                        .frame(minWidth: 470)
                    remotePanel
                        .frame(minWidth: 470)
                }
                .frame(minHeight: 280, maxHeight: .infinity)
                .layoutPriority(1)

                transferBar
                transferQueuePanel
                statusBar
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lifecycleContent: some View {
        browserContent
        .onAppear {
            session.prepare(for: profile.id)
            localPathInput = local.currentDirectory.path
            remotePathInput = remote.currentPath
        }
        .onChange(of: profile.id) { _, _ in
            session.prepare(for: profile.id)
            remotePathInput = "."
        }
        .onChange(of: local.currentDirectory) { _, directory in
            localPathInput = directory.path
        }
        .onChange(of: remote.currentPath) { _, path in
            remotePathInput = path
        }
        .onChange(of: remote.isBusy) { wasBusy, isBusy in
            if wasBusy, !isBusy {
                local.reload()
            }
        }
        .onChange(of: transfers.completedCount) { _, _ in
            local.reload()
        }
        .onChange(of: transfers.activeCount) { _, count in
            if count > 0 { showsTransferQueue = true }
        }
    }

    private var folderAlertsContent: some View {
        lifecycleContent
        .alert("Новая папка на сервере", isPresented: $showsRemoteFolderPrompt) {
            TextField("Название", text: $newRemoteFolderName)
            Button("Создать") {
                guard let settings else { return }
                remote.createDirectory(named: newRemoteFolderName, settings: settings)
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Папка будет создана в \(remote.currentPath)")
        }
        .alert("Новая локальная папка", isPresented: $showsLocalFolderPrompt) {
            TextField("Название", text: $newLocalFolderName)
            Button("Создать") {
                local.createDirectory(named: newLocalFolderName)
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Папка будет создана в \(local.currentDirectory.path)")
        }
    }

    private var fileAlertsContent: some View {
        folderAlertsContent
        .alert("Новый файл на сервере", isPresented: $showsRemoteFilePrompt) {
            TextField("Название файла", text: $newRemoteFileName)
            Button("Создать") {
                guard let settings else { return }
                remote.createFile(named: newRemoteFileName, settings: settings)
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Пустой файл будет создан в \(remote.currentPath)")
        }
        .alert("Новый локальный файл", isPresented: $showsLocalFilePrompt) {
            TextField("Название файла", text: $newLocalFileName)
            Button("Создать") {
                local.createFile(named: newLocalFileName)
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Пустой файл будет создан в \(local.currentDirectory.path)")
        }
    }

    private var actionAlertsContent: some View {
        fileAlertsContent
        .alert("Переименовать", isPresented: $showsRenamePrompt) {
            TextField("Новое имя", text: $renameText)
            Button("Переименовать") {
                performRename()
            }
            Button("Отмена", role: .cancel) {
                renameTarget = nil
            }
        } message: {
            Text("Введите новое имя без символа /")
        }
        .alert("Подтвердите удаление", isPresented: $showsDeleteConfirmation) {
            Button(deleteButtonTitle, role: .destructive) {
                performDelete()
            }
            Button("Отмена", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text(deleteConfirmationText)
        }
    }

    private var sheetsContent: some View {
        actionAlertsContent
        .sheet(item: $propertiesTarget) { target in
            SFTPPropertiesView(target: target) { mode, ownerID, groupID in
                applyProperties(
                    target,
                    mode: mode,
                    ownerID: ownerID,
                    groupID: groupID
                )
            }
        }
        .sheet(item: $remote.editorDocument) { document in
            SFTPRemoteEditorView(document: document) { text in
                guard let settings else { return }
                remote.save(document, text: text, settings: settings)
            }
        }
    }

    private var connectionBar: some View {
        let hasActiveSSHSession = activeSSHSession?()
            ?? appModel.isSSHTerminalRunning(profileID: profile.id)
        return HStack(spacing: 10) {
            Button(
                settings == nil ? "Подключить SFTP" : "Сменить сервер",
                systemImage: settings == nil ? "network" : "arrow.triangle.2.circlepath"
            ) {
                performConnectionRequest()
            }
            .buttonStyle(.borderedProminent)
            .disabled(remote.isBusy)

            if hasActiveSSHSession {
                Label(
                    "Используется активная SSH-сессия",
                    systemImage: "link.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            } else {
                Text(
                    "Пароль или passphrase будут запрошены в отдельном защищённом окне; "
                        + "подключение по ключу работает сразу."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if requestConnection == nil || openTerminal != nil {
                Button("Открыть терминал", systemImage: "terminal") {
                    if let openTerminal {
                        openTerminal()
                    } else {
                        appModel.connect()
                    }
                }
            }
        }
    }

    private var transferBar: some View {
        HStack(spacing: 10) {
            Button("На сервер →", systemImage: "arrow.right") {
                uploadSelectedLocalEntry()
            }
            .disabled(
                settings == nil
                    || remote.isBusy
                    || local.isBusy
                    || local.selectedEntries.isEmpty
            )

            Button("← На этот Mac", systemImage: "arrow.left") {
                downloadSelectedRemoteEntry()
            }
            .disabled(
                settings == nil
                    || remote.isBusy
                    || local.isBusy
                    || remote.selectedEntries.isEmpty
            )

            Spacer()
            if remote.isBusy || local.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(
                remote.isBusy
                    ? remote.statusMessage
                    : local.isBusy
                        ? local.statusMessage
                        : "\(local.statusMessage) · \(remote.statusMessage)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var transferQueuePanel: some View {
        DisclosureGroup(isExpanded: $showsTransferQueue) {
            VStack(spacing: 8) {
                HStack {
                    Picker("При совпадении имён", selection: $transfers.conflictPolicy) {
                        ForEach(SFTPConflictPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .frame(maxWidth: 330)
                    Spacer()
                    if transfers.items.contains(where: { $0.phase == .paused }) {
                        Button("Продолжить все", systemImage: "play.fill") {
                            transfers.resumeAll()
                        }
                    } else if transfers.items.contains(where: { $0.phase == .running }) {
                        Button("Пауза", systemImage: "pause.fill") {
                            transfers.pauseAll()
                        }
                    }
                    Button("Отменить все", systemImage: "xmark") {
                        transfers.cancelAll()
                    }
                    .disabled(transfers.activeCount == 0)
                    Button("Очистить завершённые", systemImage: "trash") {
                        transfers.clearFinished()
                    }
                    .disabled(!transfers.items.contains(where: { $0.phase.isTerminal }))
                }

                if transfers.items.isEmpty {
                    ContentUnavailableView(
                        "Передач пока нет",
                        systemImage: "arrow.left.arrow.right",
                        description: Text("Копирование продолжится, даже если перейти на другую вкладку.")
                    )
                    .frame(height: 54)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(transfers.items.reversed()) { item in
                                transferRow(item)
                            }
                        }
                    }
                    .frame(maxHeight: 130)
                }
            }
            .padding(.top, 8)
        } label: {
            Label(
                "Передачи · активных: \(transfers.activeCount)",
                systemImage: "arrow.up.arrow.down.circle"
            )
            .font(.headline)
        }
    }

    private func transferRow(_ item: SFTPTransferItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.direction.systemImage)
                .foregroundStyle(item.phase == .failed ? Color.red : Color.blue)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.name).fontWeight(.medium).lineLimit(1)
                    Text("· \(item.direction.title)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(item.phase.title)
                        .font(.caption)
                        .foregroundStyle(item.phase == .failed ? Color.red : Color.secondary)
                }
                if let fraction = item.fractionCompleted {
                    ProgressView(value: fraction)
                } else if item.phase == .running {
                    ProgressView().controlSize(.small)
                }
                HStack {
                    Text(item.progressText)
                    if let speed = item.speedText { Text("· \(speed)") }
                    if let error = item.errorMessage {
                        Text("· \(error)").foregroundStyle(.red).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            switch item.phase {
            case .running:
                Button("Пауза", systemImage: "pause.fill") { transfers.pause(item.id) }
                    .labelStyle(.iconOnly)
            case .paused:
                Button("Продолжить", systemImage: "play.fill") { transfers.resume(item.id) }
                    .labelStyle(.iconOnly)
            case .failed, .cancelled:
                Button("Повторить", systemImage: "arrow.clockwise") { transfers.retry(item.id) }
                    .labelStyle(.iconOnly)
            default:
                EmptyView()
            }
            if !item.phase.isTerminal {
                Button("Отменить", systemImage: "xmark") { transfers.cancel(item.id) }
                    .labelStyle(.iconOnly)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private var statusBar: some View {
        if let error = remote.errorMessage ?? local.errorMessage {
            HStack(alignment: .top, spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                Spacer()
                if error.contains("Откройте встроенный SSH-терминал") {
                    Button("Открыть терминал") {
                        appModel.connect()
                    }
                    .controlSize(.small)
                }
            }
        } else {
            Label(
                "Перетаскивайте объекты между панелями или между "
                    + "\(AppBrand.name) и Finder. Правый клик открывает действия и свойства.",
                systemImage: "hand.draw"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var localPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Этот Mac", systemImage: "laptopcomputer")
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                Spacer()
                sortingMenu(
                    field: $local.sortField,
                    direction: $local.sortDirection
                )
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                navigationButton(
                    systemImage: "chevron.left",
                    help: "Назад",
                    disabled: !local.canGoBack || local.isBusy
                ) {
                    local.goBack()
                }
                navigationButton(
                    systemImage: "chevron.right",
                    help: "Вперёд",
                    disabled: !local.canGoForward || local.isBusy
                ) {
                    local.goForward()
                }
                navigationButton(
                    systemImage: "house",
                    help: "Домашняя папка",
                    disabled: local.isBusy
                ) {
                    local.goHome()
                }
                navigationButton(
                    systemImage: "folder",
                    help: "Выбрать локальную папку",
                    disabled: local.isBusy
                ) {
                    chooseLocalDirectory()
                }
                navigationButton(
                    systemImage: "arrow.up",
                    help: "На уровень выше",
                    disabled: local.isBusy
                ) {
                    local.goUp()
                }
                navigationButton(
                    systemImage: "arrow.clockwise",
                    help: "Обновить",
                    disabled: local.isBusy
                ) {
                    local.reload()
                }
                navigationButton(
                    systemImage: "doc.badge.plus",
                    help: "Новый локальный файл",
                    disabled: local.isBusy
                ) {
                    promptForLocalFile()
                }
                navigationButton(
                    systemImage: "folder.badge.plus",
                    help: "Новая локальная папка",
                    disabled: local.isBusy
                ) {
                    promptForLocalFolder()
                }
                }
            }

            breadcrumbBar(local.breadcrumbs) { crumb in
                local.navigate(
                    to: URL(fileURLWithPath: crumb.path, isDirectory: true)
                )
            }

            pathField(
                title: "Локальный путь",
                text: $localPathInput,
                disabled: local.isBusy,
                suggestions: localPathSuggestions
            ) {
                navigateLocalPath()
            }

            filterField(
                text: $local.filterText,
                placeholder: "Фильтр локальных файлов"
            )

            fileHeader(
                sortField: local.sortField,
                sortDirection: local.sortDirection
            ) { field in
                local.selectSort(field)
            }

            List(selection: $local.selectedEntryIDs) {
                ForEach(local.entries) { entry in
                    fileRow(
                        name: entry.name,
                        isDirectory: entry.isDirectory,
                        isSymbolicLink: entry.isSymbolicLink,
                        ownerText: entry.ownerText,
                        permissions: entry.permissions,
                        modifiedText: entry.modifiedText,
                        sizeText: entry.sizeText
                    )
                    .tag(entry.id)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            local.open(entry)
                        }
                    )
                    .contextMenu {
                        localContextMenu(for: entry)
                    }
                    .onDrag {
                        NSItemProvider(object: entry.url as NSURL)
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard entry.isDirectory, !local.isBusy else { return false }
                        local.copyItems(urls, to: entry.url)
                        return !urls.isEmpty
                    }
                    .onDrop(
                        of: [SFTPDragType.remoteEntry.identifier],
                        isTargeted: nil
                    ) { providers in
                        guard entry.isDirectory, !local.isBusy else { return false }
                        return acceptRemoteDrops(providers, destination: entry.url)
                    }
                }
            }
            .contextMenu {
                localBackgroundContextMenu
            }
            .overlay {
                if local.isBusy {
                    busyOverlay
                } else if local.entries.isEmpty {
                    ContentUnavailableView(
                        local.filterText.isEmpty ? "Локальная папка пуста" : "Ничего не найдено",
                        systemImage: local.filterText.isEmpty ? "folder" : "magnifyingglass",
                        description: local.filterText.isEmpty
                            ? nil
                            : Text("Измените или очистите фильтр")
                    )
                    .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !local.isBusy else { return false }
                local.copyItems(urls, to: local.currentDirectory)
                return !urls.isEmpty
            } isTargeted: {
                localDropTargeted = $0
            }
            .onDrop(
                of: [SFTPDragType.remoteEntry.identifier],
                isTargeted: $localDropTargeted
            ) { providers in
                acceptRemoteDrops(providers, destination: local.currentDirectory)
            }
            .overlay {
                dropOverlay(isTargeted: localDropTargeted, text: "Скопировать на этот Mac")
            }
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var remotePanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Удалённый сервер", systemImage: "server.rack")
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                Spacer()
                sortingMenu(
                    field: $remote.sortField,
                    direction: $remote.sortDirection
                )
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                navigationButton(
                    systemImage: "chevron.left",
                    help: "Назад",
                    disabled: settings == nil || !remote.canGoBack || remote.isBusy
                ) {
                    guard let settings else { return }
                    remote.goBack(settings: settings)
                }
                navigationButton(
                    systemImage: "chevron.right",
                    help: "Вперёд",
                    disabled: settings == nil || !remote.canGoForward || remote.isBusy
                ) {
                    guard let settings else { return }
                    remote.goForward(settings: settings)
                }
                navigationButton(
                    systemImage: "arrow.up",
                    help: "На уровень выше",
                    disabled: settings == nil || remote.isBusy
                ) {
                    guard let settings else { return }
                    remote.goUp(settings: settings)
                }
                navigationButton(
                    systemImage: "arrow.clockwise",
                    help: "Обновить",
                    disabled: settings == nil || remote.isBusy
                ) {
                    guard let settings else { return }
                    remote.load(
                        settings: settings,
                        directory: remote.currentPath,
                        recordHistory: false
                    )
                }
                navigationButton(
                    systemImage: "doc.badge.plus",
                    help: "Новый файл на сервере",
                    disabled: settings == nil || remote.isBusy
                ) {
                    promptForRemoteFile()
                }
                navigationButton(
                    systemImage: "folder.badge.plus",
                    help: "Новая папка на сервере",
                    disabled: settings == nil || remote.isBusy
                ) {
                    promptForRemoteFolder()
                }
                }
            }

            breadcrumbBar(remote.breadcrumbs) { crumb in
                guard let settings else { return }
                remote.load(settings: settings, directory: crumb.path)
            }

            pathField(
                title: "Путь на сервере",
                text: $remotePathInput,
                disabled: settings == nil || remote.isBusy,
                suggestions: remotePathSuggestions
            ) {
                navigateRemotePath()
            }

            filterField(
                text: $remote.filterText,
                placeholder: "Фильтр удалённых файлов",
                disabled: settings == nil
            )

            fileHeader(
                sortField: remote.sortField,
                sortDirection: remote.sortDirection
            ) { field in
                remote.selectSort(field)
            }

            List(selection: $remote.selectedEntryIDs) {
                ForEach(remote.entries) { entry in
                    fileRow(
                        name: entry.name,
                        isDirectory: entry.isDirectory,
                        isSymbolicLink: entry.isSymbolicLink,
                        ownerText: entry.ownerText,
                        permissions: entry.permissions,
                        modifiedText: entry.modifiedText,
                        sizeText: entry.sizeText
                    )
                    .tag(entry.id)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            guard let settings else { return }
                            if entry.isDirectory {
                                remote.open(entry, settings: settings)
                            } else {
                                remote.edit(entry, settings: settings)
                            }
                        }
                    )
                    .contextMenu {
                        remoteContextMenu(for: entry)
                    }
                    .onDrag {
                        guard let settings else { return NSItemProvider() }
                        return remote.dragProvider(for: entry, settings: settings)
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard entry.isDirectory,
                              !remote.isBusy,
                              let settings
                        else { return false }
                        remote.upload(
                            localURLs: urls,
                            to: SFTPService.joinedRemotePath(remote.currentPath, entry.name),
                            settings: settings
                        )
                        return !urls.isEmpty
                    }
                }
            }
            .contextMenu {
                remoteBackgroundContextMenu
            }
            .overlay {
                if remote.isBusy {
                    busyOverlay
                } else if remote.entries.isEmpty, settings != nil {
                    ContentUnavailableView(
                        remote.filterText.isEmpty ? "Удалённая папка пуста" : "Ничего не найдено",
                        systemImage: remote.filterText.isEmpty ? "folder" : "magnifyingglass",
                        description: remote.filterText.isEmpty
                            ? nil
                            : Text("Измените или очистите фильтр")
                    )
                    .allowsHitTesting(false)
                } else if settings == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("SFTP не подключён")
                            .font(.title3.weight(.semibold))
                        Text("Выберите сохранённый сервер или укажите hostname/IP вручную.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Выбрать сервер", systemImage: "server.rack") {
                            performConnectionRequest()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !remote.isBusy, let settings else { return false }
                remote.upload(localURLs: urls, settings: settings)
                return !urls.isEmpty
            } isTargeted: {
                remoteDropTargeted = $0
            }
            .overlay {
                dropOverlay(isTargeted: remoteDropTargeted, text: "Загрузить на сервер")
            }
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    @ViewBuilder
    private var localBackgroundContextMenu: some View {
        Button("Новый файл…", systemImage: "doc.badge.plus") {
            promptForLocalFile()
        }
        Button("Новая папка…", systemImage: "folder.badge.plus") {
            promptForLocalFolder()
        }
        Divider()
        Button("Обновить", systemImage: "arrow.clockwise") {
            local.reload()
        }
    }

    @ViewBuilder
    private var remoteBackgroundContextMenu: some View {
        Button("Новый файл…", systemImage: "doc.badge.plus") {
            promptForRemoteFile()
        }
        .disabled(settings == nil)
        Button("Новая папка…", systemImage: "folder.badge.plus") {
            promptForRemoteFolder()
        }
        .disabled(settings == nil)
        Divider()
        Button("Обновить", systemImage: "arrow.clockwise") {
            guard let settings else { return }
            remote.load(
                settings: settings,
                directory: remote.currentPath,
                recordHistory: false
            )
        }
        .disabled(settings == nil)
    }

    @ViewBuilder
    private func localContextMenu(for entry: SFTPLocalEntry) -> some View {
        if entry.isDirectory {
            Button("Открыть", systemImage: "folder") {
                local.navigate(to: entry.url)
            }
        } else {
            Button("Открыть", systemImage: "arrow.up.forward.app") {
                local.open(entry)
            }
            Button("Открыть с помощью…", systemImage: "square.grid.2x2") {
                chooseApplication { applicationURL in
                    local.openWith(entry, applicationURL: applicationURL)
                }
            }
        }

        Button("Показать в Finder", systemImage: "finder") {
            local.reveal(entry)
        }
        Button("Скопировать путь", systemImage: "doc.on.doc") {
            copyPath(entry.url.path)
        }

        if settings != nil {
            Button("Скопировать на сервер", systemImage: "arrow.right") {
                guard let settings else { return }
                remote.upload(
                    localURLs: localActionEntries(for: entry).map(\.url),
                    settings: settings
                )
            }
        }

        Divider()

        Button("Переименовать…", systemImage: "pencil") {
            renameTarget = .local(entry)
            renameText = entry.name
            showsRenamePrompt = true
        }
        .disabled(localActionEntries(for: entry).count != 1)

        Button("Свойства…", systemImage: "info.circle") {
            propertiesTarget = .local(entry)
        }
        .disabled(localActionEntries(for: entry).count != 1)

        Divider()

        Button("Переместить в Корзину", systemImage: "trash", role: .destructive) {
            deleteTarget = .local(localActionEntries(for: entry))
            showsDeleteConfirmation = true
        }
    }

    @ViewBuilder
    private func remoteContextMenu(for entry: SFTPRemoteEntry) -> some View {
        if entry.isDirectory {
            Button("Открыть", systemImage: "folder") {
                guard let settings else { return }
                remote.open(entry, settings: settings)
            }
        } else {
            Button("Редактировать", systemImage: "square.and.pencil") {
                guard let settings else { return }
                remote.edit(entry, settings: settings)
            }
            Button("Открыть временную копию", systemImage: "arrow.up.forward.app") {
                guard let settings else { return }
                remote.openDownloaded(entry, applicationURL: nil, settings: settings)
            }
            Button(
                "Открыть временную копию с помощью…",
                systemImage: "square.grid.2x2"
            ) {
                chooseApplication { applicationURL in
                    guard let settings else { return }
                    remote.openDownloaded(
                        entry,
                        applicationURL: applicationURL,
                        settings: settings
                    )
                }
            }
        }

        Button("Скопировать на этот Mac", systemImage: "arrow.left") {
            guard let settings else { return }
            for selected in remoteActionEntries(for: entry) {
                remote.download(selected, to: local.currentDirectory, settings: settings)
            }
        }
        Button("Скопировать путь", systemImage: "doc.on.doc") {
            copyPath(
                SFTPService.joinedRemotePath(remote.currentPath, entry.name)
            )
        }

        Divider()

        Button("Переименовать…", systemImage: "pencil") {
            renameTarget = .remote(entry)
            renameText = entry.name
            showsRenamePrompt = true
        }
        .disabled(remoteActionEntries(for: entry).count != 1)

        Button("Свойства и доступ…", systemImage: "info.circle") {
            propertiesTarget = .remote(entry, directory: remote.currentPath)
        }
        .disabled(remoteActionEntries(for: entry).count != 1)

        Divider()

        Button("Удалить", systemImage: "trash", role: .destructive) {
            deleteTarget = .remote(remoteActionEntries(for: entry))
            showsDeleteConfirmation = true
        }
    }

    private func fileHeader(
        sortField: SFTPFileSortField,
        sortDirection: SFTPSortDirection,
        onSelect: @escaping (SFTPFileSortField) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            columnHeader(
                "Имя",
                field: .name,
                width: nil,
                sortField: sortField,
                sortDirection: sortDirection,
                onSelect: onSelect
            )
            columnHeader(
                "Владелец",
                field: .owner,
                width: 86,
                sortField: sortField,
                sortDirection: sortDirection,
                onSelect: onSelect
            )
            columnHeader(
                "Доступ",
                field: .permissions,
                width: 92,
                sortField: sortField,
                sortDirection: sortDirection,
                onSelect: onSelect
            )
            columnHeader(
                "Изменён",
                field: .modified,
                width: 112,
                sortField: sortField,
                sortDirection: sortDirection,
                onSelect: onSelect
            )
            columnHeader(
                "Размер",
                field: .size,
                width: 58,
                sortField: sortField,
                sortDirection: sortDirection,
                onSelect: onSelect
            )
        }
        .padding(.horizontal, 8)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func columnHeader(
        _ title: String,
        field: SFTPFileSortField,
        width: CGFloat?,
        sortField: SFTPFileSortField,
        sortDirection: SFTPSortDirection,
        onSelect: @escaping (SFTPFileSortField) -> Void
    ) -> some View {
        Button {
            onSelect(field)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sortField == field {
                    Image(systemName: sortDirection.systemImage)
                }
            }
            .frame(
                minWidth: width,
                maxWidth: width ?? .infinity,
                alignment: .leading
            )
        }
        .buttonStyle(.plain)
    }

    private func fileRow(
        name: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        ownerText: String,
        permissions: String,
        modifiedText: String,
        sizeText: String
    ) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(
                    systemName: isDirectory
                        ? "folder.fill"
                        : isSymbolicLink ? "link" : "doc"
                )
                .foregroundStyle(isDirectory ? Color.blue : Color.secondary)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(ownerText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 86, alignment: .leading)
                .help(ownerText)

            Text(permissions)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)

            Text(modifiedText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
                .help(modifiedText)

            Text(sizeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private func filterField(
        text: Binding<String>,
        placeholder: String,
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            if !text.wrappedValue.isEmpty {
                Button("Очистить фильтр", systemImage: "xmark.circle.fill") {
                    text.wrappedValue = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .disabled(disabled)
    }

    private func breadcrumbBar(
        _ crumbs: [SFTPPathCrumb],
        onSelect: @escaping (SFTPPathCrumb) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(crumb.title) {
                        onSelect(crumb)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(
                        index == crumbs.count - 1 ? Color.primary : Color.secondary
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 22)
    }

    private func pathField(
        title: String,
        text: Binding<String>,
        disabled: Bool,
        suggestions: [String],
        onSubmit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "location")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .onSubmit(onSubmit)
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions.prefix(15), id: \.self) { suggestion in
                        Button(suggestion) {
                            text.wrappedValue = suggestion
                        }
                    }
                } label: {
                    Image(systemName: "text.insert")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Подсказки путей из текущей папки")
            }
            Button("Перейти", systemImage: "arrow.right.circle", action: onSubmit)
                .labelStyle(.iconOnly)
                .help("Перейти по указанному пути")
        }
        .disabled(disabled)
    }

    private func sortingMenu(
        field: Binding<SFTPFileSortField>,
        direction: Binding<SFTPSortDirection>
    ) -> some View {
        Menu {
            Picker("Сортировать", selection: field) {
                ForEach(SFTPFileSortField.allCases) { field in
                    Text(field.title).tag(field)
                }
            }
            Divider()
            Picker("Направление", selection: direction) {
                ForEach(SFTPSortDirection.allCases) { direction in
                    Label(direction.title, systemImage: direction.systemImage)
                        .tag(direction)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Сортировка")
    }

    private func navigationButton(
        systemImage: String,
        help: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .disabled(disabled)
        .help(help)
    }

    private var busyOverlay: some View {
        ProgressView()
            .controlSize(.large)
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func dropOverlay(isTargeted: Bool, text: String) -> some View {
        if isTargeted {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.12))
                .overlay {
                    Label(text, systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                        .padding(14)
                        .background(.regularMaterial, in: Capsule())
                }
                .allowsHitTesting(false)
        }
    }

    private func connect() {
        guard let prepared = appModel.prepareSelectedSSHConnection() else { return }
        session.connect(prepared)
    }

    private func performConnectionRequest() {
        if let requestConnection {
            requestConnection()
        } else {
            connect()
        }
    }

    private func promptForLocalFile() {
        newLocalFileName = ""
        showsLocalFilePrompt = true
    }

    private func promptForLocalFolder() {
        newLocalFolderName = ""
        showsLocalFolderPrompt = true
    }

    private func promptForRemoteFile() {
        guard settings != nil else { return }
        newRemoteFileName = ""
        showsRemoteFilePrompt = true
    }

    private func promptForRemoteFolder() {
        guard settings != nil else { return }
        newRemoteFolderName = ""
        showsRemoteFolderPrompt = true
    }

    private func chooseLocalDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Выберите локальную папку"
        panel.directoryURL = local.currentDirectory
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        local.navigate(to: directory)
    }

    private func chooseApplication(completion: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Выберите приложение"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let applicationURL = panel.url else { return }
        completion(applicationURL)
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private var localPathSuggestions: [String] {
        let typed = localPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = local.currentDirectory.standardizedFileURL.path
        var candidates = local.entries.filter(\.isDirectory).map { $0.url.path }
        candidates.append(local.currentDirectory.deletingLastPathComponent().path)
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.path)
        return pathSuggestions(candidates, matching: typed, current: directory)
    }

    private var remotePathSuggestions: [String] {
        let typed = remotePathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = remote.entries.filter(\.isDirectory).map {
            SFTPService.joinedRemotePath(remote.currentPath, $0.name)
        }
        candidates.append(SFTPService.parentRemotePath(remote.currentPath))
        candidates.append("~")
        candidates.append("/")
        return pathSuggestions(candidates, matching: typed, current: remote.currentPath)
    }

    private func pathSuggestions(
        _ candidates: [String],
        matching typed: String,
        current: String
    ) -> [String] {
        let unique = Array(Set(candidates)).filter { !$0.isEmpty && $0 != current }
        guard !typed.isEmpty else { return unique.sorted().prefix(15).map { $0 } }
        let last = typed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? typed
        return unique.filter { candidate in
            candidate.localizedCaseInsensitiveHasPrefix(typed)
                || URL(fileURLWithPath: candidate).lastPathComponent.localizedCaseInsensitiveHasPrefix(last)
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func localActionEntries(for entry: SFTPLocalEntry) -> [SFTPLocalEntry] {
        local.selectedEntryIDs.contains(entry.id) && !local.selectedEntries.isEmpty
            ? local.selectedEntries
            : [entry]
    }

    private func remoteActionEntries(for entry: SFTPRemoteEntry) -> [SFTPRemoteEntry] {
        remote.selectedEntryIDs.contains(entry.id) && !remote.selectedEntries.isEmpty
            ? remote.selectedEntries
            : [entry]
    }

    private func navigateLocalPath() {
        let path = NSString(
            string: localPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        ).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            local.errorMessage = "Локальная папка не найдена: \(path)"
            return
        }
        local.navigate(to: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func navigateRemotePath() {
        guard let settings else { return }
        let path = remotePathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        remote.load(settings: settings, directory: path)
    }

    private func uploadSelectedLocalEntry() {
        guard let settings, !local.selectedEntries.isEmpty else { return }
        remote.upload(
            localURLs: local.selectedEntries.map(\.url),
            settings: settings
        )
    }

    private func downloadSelectedRemoteEntry() {
        guard let settings, !remote.selectedEntries.isEmpty else { return }
        for entry in remote.selectedEntries {
            remote.download(
                entry,
                to: local.currentDirectory,
                settings: settings
            )
        }
    }

    private func performRename() {
        defer { renameTarget = nil }
        switch renameTarget {
        case let .local(entry):
            local.rename(entry, to: renameText)
        case let .remote(entry):
            guard let settings else { return }
            remote.rename(entry, to: renameText, settings: settings)
        case nil:
            break
        }
    }

    private func performDelete() {
        defer { deleteTarget = nil }
        switch deleteTarget {
        case let .local(entries):
            local.moveToTrash(entries)
        case let .remote(entries):
            guard let settings else { return }
            remote.remove(entries, settings: settings)
        case nil:
            break
        }
    }

    private var deleteButtonTitle: String {
        switch deleteTarget {
        case .local: "В Корзину"
        case .remote: "Удалить безвозвратно"
        case nil: "Удалить"
        }
    }

    private var deleteConfirmationText: String {
        switch deleteTarget {
        case let .local(entries):
            entries.count == 1
                ? "«\(entries[0].name)» будет перемещён в Корзину и сможет быть восстановлен."
                : "Выбранные объекты (\(entries.count)) будут перемещены в Корзину."
        case let .remote(entries):
            if entries.count == 1 {
                let entry = entries[0]
                return entry.isDirectory
                    ? "Удалённая папка «\(entry.name)» и всё её содержимое будут удалены безвозвратно."
                    : "Удалённый файл «\(entry.name)» будет удалён безвозвратно."
            }
            return "Выбранные удалённые объекты (\(entries.count)) и содержимое папок будут удалены безвозвратно."
        case nil:
            "Выбранный объект будет удалён."
        }
    }

    private func applyProperties(
        _ target: SFTPPropertiesTarget,
        mode: String?,
        ownerID: Int?,
        groupID: Int?
    ) {
        switch target {
        case let .local(entry):
            local.updateAttributes(
                entry,
                mode: mode,
                ownerID: ownerID,
                groupID: groupID
            )
        case let .remote(entry, _):
            guard let settings else { return }
            remote.updateAttributes(
                entry,
                mode: mode,
                ownerID: ownerID,
                groupID: groupID,
                settings: settings
            )
        }
    }

    private func acceptRemoteDrops(
        _ providers: [NSItemProvider],
        destination: URL
    ) -> Bool {
        guard let settings, !remote.isBusy, !local.isBusy else { return false }
        let matches = providers.filter {
            $0.hasItemConformingToTypeIdentifier(SFTPDragType.remoteEntry.identifier)
        }
        for provider in matches {
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
                    remote.download(
                        payload: payload,
                        to: destination,
                        settings: settings
                    )
                }
            }
        }
        return !matches.isEmpty
    }
}
