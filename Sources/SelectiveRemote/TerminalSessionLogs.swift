import AppKit
import Combine
import Foundation
import SwiftUI

enum TerminalSessionLogKind: String, Codable, CaseIterable, Identifiable {
    case ssh = "SSH"
    case mosh = "Mosh"
    case telnet = "Telnet"
    case serial = "Serial"
    case local = "Local"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ssh: "SSH"
        case .mosh: "Mosh"
        case .telnet: "Telnet"
        case .serial: "Serial"
        case .local: UpdateLocalization.text(ru: "Локальный", en: "Local")
        }
    }

    var systemImage: String {
        switch self {
        case .ssh: "network"
        case .mosh: "antenna.radiowaves.left.and.right"
        case .telnet: "network"
        case .serial: "cable.connector"
        case .local: "terminal"
        }
    }
}

enum TerminalSessionLogState: String, Codable {
    case active
    case completed
    case failed
    case interrupted
}

struct TerminalSessionLogRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: TerminalSessionLogKind
    let profileID: UUID?
    let profileName: String
    let target: String
    let startedAt: Date
    var endedAt: Date?
    var exitCode: Int32?
    var state: TerminalSessionLogState
    let filename: String
    var byteCount: Int64
    var wasTruncated: Bool

    var duration: TimeInterval {
        max(0, (endedAt ?? Date()).timeIntervalSince(startedAt))
    }
}

private final class TerminalSessionLogWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let handle: FileHandle
    private let maximumBytes: Int64
    private var bytesWritten: Int64 = 0
    private var isTruncated = false
    private var pendingData = Data()
    private var isClosed = false

    init(url: URL, maximumBytes: Int64) throws {
        let manager = FileManager.default
        manager.createFile(atPath: url.path, contents: nil)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        handle = try FileHandle(forWritingTo: url)
        self.maximumBytes = max(1_024, maximumBytes)
        queue = DispatchQueue(label: "ru.selectiveremote.terminal-session-log.\(UUID().uuidString)")
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async {
            guard !self.isClosed, !self.isTruncated else { return }
            self.pendingData.append(data)
            self.flushCompleteLines()
            if self.pendingData.count > 32_768 {
                self.writeSanitized(String(decoding: self.pendingData, as: UTF8.self))
                self.pendingData.removeAll(keepingCapacity: true)
            }
        }
    }

    func close(completion: @escaping @Sendable (Int64, Bool) -> Void) {
        queue.async {
            if !self.isClosed {
                if !self.pendingData.isEmpty {
                    self.writeSanitized(String(decoding: self.pendingData, as: UTF8.self))
                    self.pendingData.removeAll()
                }
                try? self.handle.synchronize()
                try? self.handle.close()
                self.isClosed = true
            }
            completion(self.bytesWritten, self.isTruncated)
        }
    }

    private func flushCompleteLines() {
        while let newline = pendingData.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            var end = pendingData.index(after: newline)
            if pendingData[newline] == 13 {
                // Keep a trailing CR until the next PTY chunk so a split CRLF
                // boundary is still normalized as one line break.
                guard end != pendingData.endIndex else { return }
                if pendingData[end] == 10 {
                    end = pendingData.index(after: end)
                }
            }
            let length = pendingData.distance(from: pendingData.startIndex, to: end)
            let line = Data(pendingData.prefix(length))
            pendingData.removeFirst(length)
            writeSanitized(String(decoding: line, as: UTF8.self))
        }
    }

    private func writeSanitized(_ text: String) {
        guard !isTruncated else { return }
        let cleaned = TerminalSessionLogSanitizer.sanitize(text)
        guard !cleaned.isEmpty else { return }
        let data = Data(cleaned.utf8)
        let available = maximumBytes - bytesWritten
        guard available > 0 else {
            isTruncated = true
            return
        }
        let chunk = data.count <= available ? data : Data(data.prefix(Int(available)))
        do {
            try handle.write(contentsOf: chunk)
            bytesWritten += Int64(chunk.count)
            if chunk.count < data.count { isTruncated = true }
        } catch {
            isTruncated = true
        }
    }
}

enum TerminalSessionLogSanitizer {
    private static let ansiExpression = try! NSRegularExpression(
        pattern: #"\u001B(?:\[[0-?]*[ -/]*[@-~]|\][^\u0007]*(?:\u0007|\u001B\\)|c|[@-_])"#
    )

    static func sanitize(_ value: String) -> String {
        let finalScalar = value.unicodeScalars.last?.value
        let hasLineBreak = finalScalar == 10 || finalScalar == 13
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let withoutANSI = ansiExpression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: ""
        )
        let redacted = DiagnosticRedactor.sanitize(withoutANSI)
        let filtered = redacted.unicodeScalars.reduce(into: "") { output, scalar in
            if scalar.value == 9 || !CharacterSet.controlCharacters.contains(scalar) {
                output.unicodeScalars.append(scalar)
            }
        }
        return filtered + (hasLineBreak ? "\n" : "")
    }
}

@MainActor
final class TerminalSessionLogStore: ObservableObject {
    @Published private(set) var records: [TerminalSessionLogRecord]

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }

    @Published var retentionDays: Int {
        didSet {
            retentionDays = min(max(retentionDays, 1), 365)
            defaults.set(retentionDays, forKey: Key.retentionDays)
            applyRetentionPolicy()
        }
    }

    private enum Key {
        static let enabled = "SelectiveRemote.terminal.sessionLogs.enabled.v1"
        static let retentionDays = "SelectiveRemote.terminal.sessionLogs.retentionDays.v1"
    }

    private let defaults: UserDefaults
    private let rootURL: URL
    private let indexURL: URL
    private let maximumLogBytes: Int64
    private let maximumRecordCount: Int
    private var writers: [UUID: TerminalSessionLogWriter] = [:]

    init(
        rootURL: URL? = nil,
        defaults: UserDefaults = .standard,
        maximumLogBytes: Int64 = 10 * 1_024 * 1_024,
        maximumRecordCount: Int = 500
    ) {
        self.defaults = defaults
        self.rootURL = rootURL ?? Self.defaultRootURL()
        indexURL = self.rootURL.appendingPathComponent("index.json")
        self.maximumLogBytes = max(1_024, maximumLogBytes)
        self.maximumRecordCount = max(25, maximumRecordCount)
        isEnabled = defaults.object(forKey: Key.enabled) == nil
            ? true
            : defaults.bool(forKey: Key.enabled)
        let storedDays = defaults.integer(forKey: Key.retentionDays)
        retentionDays = storedDays > 0 ? min(storedDays, 365) : 30

        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([TerminalSessionLogRecord].self, from: data) {
            records = decoded.map { record in
                guard record.state == .active else { return record }
                var recovered = record
                recovered.state = .interrupted
                recovered.endedAt = recovered.endedAt ?? Date()
                return recovered
            }
        } else {
            records = []
        }
        prepareDirectory()
        applyRetentionPolicy()
    }

    @discardableResult
    func begin(
        kind: TerminalSessionLogKind,
        profileID: UUID?,
        profileName: String,
        target: String,
        at date: Date = Date()
    ) -> UUID? {
        guard isEnabled else { return nil }
        prepareDirectory()
        let id = UUID()
        let filename = "\(Self.filenameDateFormatter.string(from: date))-\(id.uuidString).log"
        let url = rootURL.appendingPathComponent(filename)
        guard let writer = try? TerminalSessionLogWriter(
            url: url,
            maximumBytes: maximumLogBytes
        ) else { return nil }
        writers[id] = writer
        records.insert(
            TerminalSessionLogRecord(
                id: id,
                kind: kind,
                profileID: profileID,
                profileName: DiagnosticRedactor.sanitize(profileName),
                target: DiagnosticRedactor.sanitize(target),
                startedAt: date,
                endedAt: nil,
                exitCode: nil,
                state: .active,
                filename: filename,
                byteCount: 0,
                wasTruncated: false
            ),
            at: 0
        )
        trimRecordCount()
        saveIndex()
        return id
    }

    func append(_ data: Data, to id: UUID) {
        writers[id]?.append(data)
    }

    func finish(
        _ id: UUID,
        exitCode: Int32,
        requested: Bool,
        at date: Date = Date()
    ) {
        guard let writer = writers.removeValue(forKey: id) else { return }
        writer.close { [weak self] byteCount, wasTruncated in
            Task { @MainActor [weak self] in
                guard let self,
                      let index = self.records.firstIndex(where: { $0.id == id })
                else { return }
                self.records[index].endedAt = date
                self.records[index].exitCode = exitCode
                self.records[index].state = requested || exitCode == 0 ? .completed : .failed
                self.records[index].byteCount = byteCount
                self.records[index].wasTruncated = wasTruncated
                self.applyRetentionPolicy()
            }
        }
    }

    func text(for record: TerminalSessionLogRecord, maximumBytes: Int = 2 * 1_024 * 1_024) -> String {
        let url = fileURL(for: record)
        guard let data = try? Data(contentsOf: url) else { return "" }
        let limited = data.count > maximumBytes ? Data(data.suffix(maximumBytes)) : data
        return String(decoding: limited, as: UTF8.self)
    }

    func fileURL(for record: TerminalSessionLogRecord) -> URL {
        rootURL.appendingPathComponent(record.filename)
    }

    func reveal(_ record: TerminalSessionLogRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: record)])
    }

    func delete(_ record: TerminalSessionLogRecord) {
        guard record.state != .active else { return }
        try? FileManager.default.removeItem(at: fileURL(for: record))
        records.removeAll { $0.id == record.id }
        saveIndex()
    }

    func clearCompleted() {
        let removable = records.filter { $0.state != .active }
        removable.forEach { try? FileManager.default.removeItem(at: fileURL(for: $0)) }
        records.removeAll { $0.state != .active }
        saveIndex()
    }

    private func applyRetentionPolicy(now: Date = Date()) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) ?? now
        let expired = records.filter { $0.state != .active && $0.startedAt < cutoff }
        expired.forEach { try? FileManager.default.removeItem(at: fileURL(for: $0)) }
        records.removeAll { record in expired.contains(where: { $0.id == record.id }) }
        trimRecordCount()
        saveIndex()
    }

    private func trimRecordCount() {
        guard records.count > maximumRecordCount else { return }
        let overflow = records.dropFirst(maximumRecordCount).filter { $0.state != .active }
        overflow.forEach { try? FileManager.default.removeItem(at: fileURL(for: $0)) }
        let removedIDs = Set(overflow.map(\.id))
        records.removeAll { removedIDs.contains($0.id) }
    }

    private func prepareDirectory() {
        try? FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func saveIndex() {
        do {
            prepareDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: indexURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: indexURL.path
            )
        } catch {
            // Session logging is deliberately best-effort and must not affect a connection.
        }
    }

    private static func defaultRootURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Selective Remote", isDirectory: true)
            .appendingPathComponent("Session Logs", isDirectory: true)
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

struct TerminalSessionLogsView: View {
    @ObservedObject var store: TerminalSessionLogStore
    @State private var selectedID: UUID?
    @State private var searchText = ""
    @State private var kindFilter: TerminalSessionLogKind?
    @State private var confirmsClear = false
    @State private var wrapsLines = true
    @State private var previewRefresh = Date()

    private let previewTimer = Timer.publish(
        every: 1,
        on: .main,
        in: .common
    ).autoconnect()

    private var filteredRecords: [TerminalSessionLogRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.records.filter { record in
            (kindFilter == nil || record.kind == kindFilter)
                && (query.isEmpty
                    || record.profileName.localizedCaseInsensitiveContains(query)
                    || record.target.localizedCaseInsensitiveContains(query))
        }
    }

    private var selectedRecord: TerminalSessionLogRecord? {
        guard let selectedID else { return filteredRecords.first }
        return store.records.first(where: { $0.id == selectedID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            settings
            HSplitView {
                Group {
                    if filteredRecords.isEmpty {
                        ContentUnavailableView {
                            Label(
                                store.records.isEmpty ? "Логов пока нет" : "Ничего не найдено",
                                systemImage: "doc.text.magnifyingglass"
                            )
                        } description: {
                            Text(
                                store.records.isEmpty
                                    ? "Запустите SSH или Local Terminal — новая сессия появится здесь."
                                    : "Измените поиск или фильтр типа сессии."
                            )
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(filteredRecords, selection: $selectedID) { record in
                            row(record)
                                .tag(record.id)
                                .contextMenu {
                                    Button("Показать в Finder", systemImage: "folder") {
                                        store.reveal(record)
                                    }
                                    Button("Удалить", systemImage: "trash", role: .destructive) {
                                        store.delete(record)
                                    }
                                    .disabled(record.state == .active)
                                }
                        }
                    }
                }
                .frame(minWidth: 330, idealWidth: 400, maxHeight: .infinity)

                Group {
                    if filteredRecords.isEmpty {
                        ContentUnavailableView {
                            Label("Вывод сессии", systemImage: "terminal")
                        } description: {
                            Text("После появления логов выберите сессию слева.")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let record = selectedRecord {
                        preview(record)
                    } else {
                        ContentUnavailableView(
                            "Выберите сессию",
                            systemImage: "doc.text.magnifyingglass"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(24)
        .confirmationDialog("Удалить завершённые логи?", isPresented: $confirmsClear) {
            Button("Удалить", role: .destructive) { store.clearCompleted() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Активные логи останутся на месте.")
        }
        .onReceive(previewTimer) { date in
            if selectedRecord?.state == .active {
                previewRefresh = date
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(UpdateLocalization.text(
                    ru: "Журналы сессий",
                    en: "Session Logs"
                ))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Локальная запись вывода SSH и Local Terminal")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Очистить", systemImage: "trash", role: .destructive) { confirmsClear = true }
                .disabled(!store.records.contains { $0.state != .active })
        }
    }

    private var settings: some View {
        HStack(spacing: 12) {
            Toggle("Записывать новые сессии", isOn: Binding(
                get: { store.isEnabled },
                set: { store.isEnabled = $0 }
            ))
            TextField("Поиск", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Picker("Тип", selection: $kindFilter) {
                Text("Все").tag(nil as TerminalSessionLogKind?)
                ForEach(TerminalSessionLogKind.allCases) { kind in
                    Text(kind.title).tag(Optional(kind))
                }
            }
            .frame(width: 130)
            Picker("Хранить", selection: Binding(
                get: { store.retentionDays },
                set: { store.retentionDays = $0 }
            )) {
                Text("7 дней").tag(7)
                Text("30 дней").tag(30)
                Text("90 дней").tag(90)
                Text("1 год").tag(365)
            }
            .frame(width: 130)
            Spacer()
        }
    }

    private func row(_ record: TerminalSessionLogRecord) -> some View {
        HStack(spacing: 11) {
            Image(systemName: record.kind.systemImage)
                .foregroundStyle(record.state == .active ? .green : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(record.profileName).font(.headline).lineLimit(1)
                    if record.state == .active {
                        Text("REC")
                            .font(.caption2.bold())
                            .foregroundStyle(.red)
                    }
                }
                Text(record.target)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(UpdateLocalization.dateTime(record.startedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if record.wasTruncated {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help("Лог ограничен 10 МБ")
            }
        }
        .padding(.vertical, 4)
    }

    private func preview(_ record: TerminalSessionLogRecord) -> some View {
        // Reading this state makes an active log refresh once per second without
        // publishing every PTY output chunk through SwiftUI.
        let _ = previewRefresh
        let text = store.text(for: record)
        let axes: Axis.Set = wrapsLines ? .vertical : [.horizontal, .vertical]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.profileName)
                        .font(.title3.bold())
                    Text(record.target)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Label(stateTitle(record.state), systemImage: stateImage(record.state))
                    .font(.caption.bold())
                    .foregroundStyle(stateColor(record.state))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(stateColor(record.state).opacity(0.1), in: Capsule())
            }

            HStack(spacing: 14) {
                Label(
                    UpdateLocalization.dateTime(record.startedAt),
                    systemImage: "calendar"
                )
                Label(durationText(record.duration), systemImage: "timer")
                Label(byteCountText(record), systemImage: "doc.text")
                if let exitCode = record.exitCode {
                    Label("Exit \(exitCode)", systemImage: "return")
                }
                Spacer()
                Button {
                    wrapsLines.toggle()
                } label: {
                    Label(
                        wrapsLines ? "Не переносить строки" : "Переносить строки",
                        systemImage: "text.word.spacing"
                    )
                }
                .help(wrapsLines ? "Показать исходную ширину строк" : "Переносить длинные строки по ширине окна")
                Button("Копировать", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(text.isEmpty)
                Button("Finder", systemImage: "folder") { store.reveal(record) }
            }
            .font(.caption)

            ScrollView(axes) {
                Text(text.isEmpty ? "Вывод сессии пока пуст." : text)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: !wrapsLines, vertical: true)
                    .frame(
                        maxWidth: wrapsLines ? .infinity : nil,
                        alignment: .topLeading
                    )
                    .padding(14)
            }
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
        }
        .padding(12)
    }

    private func stateTitle(_ state: TerminalSessionLogState) -> String {
        switch state {
        case .active: UpdateLocalization.text(ru: "Запись", en: "Recording")
        case .completed: UpdateLocalization.text(ru: "Завершено", en: "Completed")
        case .failed: UpdateLocalization.text(ru: "Ошибка", en: "Failed")
        case .interrupted: UpdateLocalization.text(ru: "Прервано", en: "Interrupted")
        }
    }

    private func stateImage(_ state: TerminalSessionLogState) -> String {
        switch state {
        case .active: "record.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .interrupted: "pause.circle"
        }
    }

    private func stateColor(_ state: TerminalSessionLogState) -> Color {
        switch state {
        case .active: .red
        case .completed: .green
        case .failed: .orange
        case .interrupted: .secondary
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        if seconds < 60 {
            return UpdateLocalization.text(ru: "\(seconds) сек.", en: "\(seconds) sec")
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return UpdateLocalization.text(
                ru: "\(minutes) мин. \(seconds % 60) сек.",
                en: "\(minutes) min \(seconds % 60) sec"
            )
        }
        return UpdateLocalization.text(
            ru: "\(minutes / 60) ч. \(minutes % 60) мин.",
            en: "\(minutes / 60) hr \(minutes % 60) min"
        )
    }

    private func byteCountText(_ record: TerminalSessionLogRecord) -> String {
        let currentBytes: Int64
        if record.state == .active,
           let attributes = try? FileManager.default.attributesOfItem(
               atPath: store.fileURL(for: record).path
           ),
           let size = attributes[.size] as? NSNumber {
            currentBytes = size.int64Value
        } else {
            currentBytes = record.byteCount
        }
        return ByteCountFormatter.string(fromByteCount: currentBytes, countStyle: .file)
    }
}
