import AppKit
import Foundation
import SwiftUI

enum ConnectionActivityKind: String, Codable, CaseIterable, Identifiable {
    case rdp = "RDP"
    case ssh = "SSH"
    case mosh = "Mosh"
    case telnet = "Telnet"
    case serial = "Serial"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .rdp: "desktopcomputer"
        case .ssh: "terminal"
        case .mosh: "antenna.radiowaves.left.and.right"
        case .telnet: "network"
        case .serial: "cable.connector"
        }
    }
}

enum ConnectionActivityOutcome: String, Codable, CaseIterable, Identifiable {
    case active
    case completed
    case failed
    case interrupted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: UpdateLocalization.text(ru: "Активно", en: "Active")
        case .completed: UpdateLocalization.text(ru: "Завершено", en: "Completed")
        case .failed: UpdateLocalization.text(ru: "Ошибка", en: "Failed")
        case .interrupted: UpdateLocalization.text(ru: "Прервано", en: "Interrupted")
        }
    }

    var systemImage: String {
        switch self {
        case .active: "bolt.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .interrupted: "pause.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .active: .green
        case .completed: .blue
        case .failed: .red
        case .interrupted: .orange
        }
    }
}

struct ConnectionActivityRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let profileID: UUID?
    let profileName: String
    let kind: ConnectionActivityKind
    let target: String
    let route: String?
    let startedAt: Date
    var endedAt: Date?
    var outcome: ConnectionActivityOutcome
    var errorMessage: String?

    var duration: TimeInterval {
        max(0, (endedAt ?? Date()).timeIntervalSince(startedAt))
    }

    var durationText: String {
        let seconds = Int(duration)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

@MainActor
final class ConnectionActivityStore: ObservableObject {
    @Published private(set) var records: [ConnectionActivityRecord]

    private let storageURL: URL
    private let maximumRecordCount: Int

    init(
        storageURL: URL? = nil,
        maximumRecordCount: Int = 500
    ) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.maximumRecordCount = max(25, maximumRecordCount)
        if let data = try? Data(contentsOf: self.storageURL),
           let decoded = try? JSONDecoder().decode(
               [ConnectionActivityRecord].self,
               from: data
           ) {
            records = decoded.map { record in
                guard record.outcome == .active else { return record }
                var recovered = record
                recovered.endedAt = recovered.endedAt ?? Date()
                recovered.outcome = .interrupted
                recovered.errorMessage = "Приложение было завершено до закрытия записи."
                return recovered
            }
        } else {
            records = []
        }
        trimAndSave()
    }

    @discardableResult
    func begin(
        kind: ConnectionActivityKind,
        profileID: UUID?,
        profileName: String,
        target: String,
        route: String? = nil,
        at date: Date = Date()
    ) -> UUID {
        let id = UUID()
        records.insert(
            ConnectionActivityRecord(
                id: id,
                profileID: profileID,
                profileName: DiagnosticRedactor.sanitize(profileName),
                kind: kind,
                target: DiagnosticRedactor.sanitize(target),
                route: DiagnosticRedactor.sanitize(route),
                startedAt: date,
                endedAt: nil,
                outcome: .active,
                errorMessage: nil
            ),
            at: 0
        )
        trimAndSave()
        return id
    }

    func finish(
        _ id: UUID,
        outcome: ConnectionActivityOutcome,
        errorMessage: String? = nil,
        at date: Date = Date()
    ) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].endedAt = date
        records[index].outcome = outcome == .active ? .completed : outcome
        records[index].errorMessage = DiagnosticRedactor.sanitize(errorMessage)
        trimAndSave()
    }

    @discardableResult
    func recordFailure(
        kind: ConnectionActivityKind,
        profileID: UUID?,
        profileName: String,
        target: String,
        route: String? = nil,
        errorMessage: String,
        at date: Date = Date()
    ) -> UUID {
        let id = begin(
            kind: kind,
            profileID: profileID,
            profileName: profileName,
            target: target,
            route: route,
            at: date
        )
        finish(id, outcome: .failed, errorMessage: errorMessage, at: date)
        return id
    }

    func clear() {
        records.removeAll()
        save()
    }

    private func trimAndSave() {
        if records.count > maximumRecordCount {
            records.removeLast(records.count - maximumRecordCount)
        }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: storageURL, options: .atomic)
        } catch {
            // Activity logging must never break or block a connection.
        }
    }

    private static func defaultStorageURL() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("Selective Remote", isDirectory: true)
            .appendingPathComponent("connection-activity.json")
    }
}

struct ConnectionActivityView: View {
    @ObservedObject var store: ConnectionActivityStore
    @State private var searchText = ""
    @State private var kindFilter: ConnectionActivityKind?
    @State private var outcomeFilter: ConnectionActivityOutcome?
    @State private var confirmsClear = false

    private var filteredRecords: [ConnectionActivityRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.records.filter { record in
            (kindFilter == nil || record.kind == kindFilter)
                && (outcomeFilter == nil || record.outcome == outcomeFilter)
                && (
                    query.isEmpty
                    || record.profileName.localizedCaseInsensitiveContains(query)
                    || record.target.localizedCaseInsensitiveContains(query)
                    || (record.route?.localizedCaseInsensitiveContains(query) ?? false)
                    || (record.errorMessage?.localizedCaseInsensitiveContains(query) ?? false)
                )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            toolbar
            if filteredRecords.isEmpty {
                ContentUnavailableView {
                    Label("Журнал пуст", systemImage: "clock.badge.questionmark")
                } description: {
                    Text(
                        store.records.isEmpty
                            ? "Здесь появятся безопасные метаданные RDP-, SSH-, Mosh-, Telnet- и Serial-подключений."
                            : "Измените поиск или фильтры."
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredRecords) { record in
                    activityRow(record)
                }
                .listStyle(.inset)
            }
        }
        .padding(24)
        .confirmationDialog(
            "Очистить весь журнал подключений?",
            isPresented: $confirmsClear
        ) {
            Button("Очистить журнал", role: .destructive) { store.clear() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это удалит только локальные метаданные. Профили и системные логи не изменятся.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Журнал подключений")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Локальная история без паролей, ключей и содержимого терминала")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Очистить", systemImage: "trash", role: .destructive) {
                confirmsClear = true
            }
            .disabled(store.records.isEmpty)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Поиск по профилю или адресу", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
            Picker("Протокол", selection: $kindFilter) {
                Text("Все протоколы").tag(nil as ConnectionActivityKind?)
                ForEach(ConnectionActivityKind.allCases) { kind in
                    Text(kind.rawValue).tag(Optional(kind))
                }
            }
            .frame(width: 150)
            Picker("Результат", selection: $outcomeFilter) {
                Text("Все результаты").tag(nil as ConnectionActivityOutcome?)
                ForEach(ConnectionActivityOutcome.allCases) { outcome in
                    Text(outcome.title).tag(Optional(outcome))
                }
            }
            .frame(width: 160)
        }
    }

    private func activityRow(_ record: ConnectionActivityRecord) -> some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(record.outcome.color.opacity(0.12))
                Image(systemName: record.kind.systemImage)
                    .foregroundStyle(record.outcome.color)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(record.profileName.isEmpty
                        ? UpdateLocalization.text(ru: "Без названия", en: "Untitled")
                        : record.profileName)
                        .font(.headline)
                    Text(record.kind.rawValue)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                    Spacer()
                    Text(record.startedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(record.target)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Label(record.outcome.title, systemImage: record.outcome.systemImage)
                        .foregroundStyle(record.outcome.color)
                    Text(record.durationText)
                    if let route = record.route, !route.isEmpty {
                        Label(route, systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                .font(.caption)
                if let error = record.errorMessage, !error.isEmpty {
                    Text(localizedErrorMessage(error))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func localizedErrorMessage(_ message: String) -> String {
        guard message == "Приложение было завершено до закрытия записи." else {
            return message
        }
        return UpdateLocalization.text(
            ru: message,
            en: "The application quit before the activity record was closed."
        )
    }
}
