import SwiftUI

struct SelectiveRemoteVaultConflictReviewView: View {
    let mergedDocument: SelectiveRemoteVaultDocument
    let conflicts: [SelectiveRemoteVaultConflict]
    let onCancel: () -> Void
    let onResolve: ([SelectiveRemoteVaultConflictResolution]) -> Void

    @State private var choices: [UUID: SelectiveRemoteVaultConflictChoice] = [:]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                summary
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(conflicts.enumerated()), id: \.element.id) { entry in
                            conflictCard(entry.element, number: entry.offset + 1)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(UpdateLocalization.text(
                ru: "Конфликты Team Vault",
                en: "Team Vault Conflicts"
            ))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(UpdateLocalization.text(
                        ru: "Разрешить и синхронизировать",
                        en: "Resolve and Sync"
                    )) {
                        onResolve(resolutions)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasCompleteChoiceSet)
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 620)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                UpdateLocalization.text(
                    ru: "Найдены параллельные изменения: \(conflicts.count)",
                    en: "Concurrent changes found: \(conflicts.count)"
                ),
                systemImage: "arrow.triangle.branch"
            )
            .font(.headline)

            Text(UpdateLocalization.text(
                ru: "Выберите локальную или облачную версию для каждого элемента. Время изменения не выбирает победителя. Отправка доступна только после полного выбора.",
                en: "Choose the local or cloud version for every item. Modification time never chooses the winner. Upload is available only after every choice is complete."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Label(
                    UpdateLocalization.text(
                        ru: "Без конфликтов: \(mergedDocument.records.count) записей",
                        en: "Conflict-free: \(mergedDocument.records.count) records"
                    ),
                    systemImage: "checkmark.circle"
                )
                Label(
                    UpdateLocalization.text(
                        ru: "Удалений: \(mergedDocument.tombstones.count)",
                        en: "Deletions: \(mergedDocument.tombstones.count)"
                    ),
                    systemImage: "trash"
                )
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func conflictCard(
        _ conflict: SelectiveRemoteVaultConflict,
        number: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(UpdateLocalization.text(
                    ru: "Конфликт (number)",
                    en: "Conflict (number)"
                ))
                .font(.headline)
                Spacer()
                Text(String(conflict.id.canonicalCloudString.prefix(8)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .top, spacing: 12) {
                choiceButton(
                    conflict.local,
                    choice: .local,
                    title: UpdateLocalization.text(ru: "На этом Mac", en: "On This Mac"),
                    conflictID: conflict.id
                )
                choiceButton(
                    conflict.remote,
                    choice: .remote,
                    title: UpdateLocalization.text(ru: "В Cloud", en: "In Cloud"),
                    conflictID: conflict.id
                )
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 13))
    }

    private func choiceButton(
        _ entity: SelectiveRemoteVaultEntity,
        choice: SelectiveRemoteVaultConflictChoice,
        title: String,
        conflictID: UUID
    ) -> some View {
        let presentation = SelectiveRemoteVaultConflictPresentation.side(entity)
        let selected = choices[conflictID] == choice
        return Button {
            choices[conflictID] = choice
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                }
                Label(presentation.title, systemImage: presentation.symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(presentation.isDeletion ? Color.red : Color.primary)
                    .lineLimit(2)
                Text(presentation.metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .contentShape(Rectangle())
            .background(
                selected ? Color.accentColor.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(presentation.title), \(presentation.metadata)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var hasCompleteChoiceSet: Bool {
        !conflicts.isEmpty
            && choices.count == conflicts.count
            && conflicts.allSatisfy { choices[$0.id] != nil }
    }

    private var resolutions: [SelectiveRemoteVaultConflictResolution] {
        conflicts.compactMap { conflict in
            choices[conflict.id].map {
                .init(id: conflict.id, choice: $0)
            }
        }
    }
}

enum SelectiveRemoteVaultConflictPresentation {
    struct Side: Equatable, Sendable {
        let title: String
        let metadata: String
        let symbol: String
        let isDeletion: Bool
    }

    static func side(_ entity: SelectiveRemoteVaultEntity) -> Side {
        switch entity {
        case let .record(record):
            return .init(
                title: boundedTitle(record.data),
                metadata: "\(record.type.rawValue) · \(record.modifiedAt)",
                symbol: symbol(record.type),
                isDeletion: false
            )
        case let .tombstone(tombstone):
            return .init(
                title: UpdateLocalization.text(ru: "Удалено", en: "Deleted"),
                metadata: tombstone.deletedAt,
                symbol: "trash.fill",
                isDeletion: true
            )
        }
    }

    private static func boundedTitle(_ data: SelectiveRemoteJSONValue) -> String {
        guard case let .object(values) = data,
              case let .string(rawTitle)? = values["title"]
        else { return UpdateLocalization.text(ru: "Без названия", en: "Untitled") }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return UpdateLocalization.text(ru: "Без названия", en: "Untitled")
        }
        return title.count > 120 ? String(title.prefix(117)) + "…" : title
    }

    private static func symbol(_ type: SelectiveRemoteVaultRecordType) -> String {
        switch type {
        case .host: "desktopcomputer"
        case .credential: "key.fill"
        case .snippet: "text.quote"
        case .forwarding: "arrow.left.arrow.right"
        case .sshKey: "key.horizontal.fill"
        }
    }
}

struct SelectiveRemoteVaultConflictReviewScenario: Sendable {
    let mergedDocument: SelectiveRemoteVaultDocument
    let conflicts: [SelectiveRemoteVaultConflict]
    let resolverDeviceID: UUID
    let resolvedAt: String

    static func synthetic() throws -> Self {
        let deviceA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let deviceB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let resolver = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let credentialID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let snippetID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let localTime = "2026-09-07T09:00:00.000Z"
        let remoteTime = "2026-09-07T09:05:00.000Z"

        let local = try SelectiveRemoteVaultDocument(records: [
            .init(
                id: credentialID,
                type: .credential,
                version: .init([deviceA: 2]),
                modifiedAt: localTime,
                data: .object([
                    "title": .string("Production SSH"),
                    "username": .string("must-not-render"),
                    "secret": .string("must-not-render")
                ])
            ),
            .init(
                id: snippetID,
                type: .snippet,
                version: .init([deviceA: 2]),
                modifiedAt: localTime,
                data: .object([
                    "title": .string("Service status"),
                    "body": .string("must-not-render")
                ])
            )
        ])
        let remote = try SelectiveRemoteVaultDocument(
            records: [
                .init(
                    id: credentialID,
                    type: .credential,
                    version: .init([deviceA: 1, deviceB: 1]),
                    modifiedAt: remoteTime,
                    data: .object([
                        "title": .string("Production SSH — Cloud"),
                        "username": .string("must-not-render"),
                        "secret": .string("must-not-render")
                    ])
                )
            ],
            tombstones: [
                .init(
                    id: snippetID,
                    version: .init([deviceA: 1, deviceB: 1]),
                    deletedAt: remoteTime
                )
            ]
        )
        let merge = try local.merged(with: remote)
        return .init(
            mergedDocument: merge.document,
            conflicts: merge.conflicts,
            resolverDeviceID: resolver,
            resolvedAt: "2026-09-07T09:10:00.000Z"
        )
    }

    func resolve(_ resolutions: [SelectiveRemoteVaultConflictResolution]) throws -> SelectiveRemoteVaultDocument {
        try mergedDocument.resolving(
            conflicts,
            with: resolutions,
            deviceID: resolverDeviceID,
            resolvedAt: resolvedAt
        )
    }
}
