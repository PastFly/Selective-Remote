import SwiftUI

enum RegisteredResourceDirectory {
    static func available(in state: CloudAccessFormatState) -> Bool { state == .preparing }
}

// The registry is the only source for resource identities. This picker deliberately
// does not associate a selected registry row with any legacy V1 record or path.
struct SelectiveRemoteRegisteredResourcePicker: View {
    let vault: SelectiveRemoteCloudAccessReference
    let client: SelectiveRemoteCloudAccessClient
    let session: CloudAccessSession
    let onCommitted: (CloudAccessCommit) -> Void

    @State private var rows: [CloudAccessResource] = []
    @State private var cursor: UUID?
    @State private var selected: SelectiveRemoteCloudAccessReference?
    @State private var kind: CloudAccessKind = .host
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var loaded = false
    @State private var pageNumber = 1
    @State private var requestGeneration = UUID()

    var body: some View {
        DisclosureGroup(CloudAccessLocalization.text("Зарегистрированные ресурсы", "Registered resources")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(CloudAccessLocalization.text(
                    "Выберите подтверждённый сервером ресурс. Записи V1 и пути папок не связываются с ним автоматически.",
                    "Select a server registered resource. V1 records and folder paths are not linked automatically."
                )).font(.caption).foregroundStyle(.secondary)
                Picker(CloudAccessLocalization.text("Тип ресурса", "Resource type"), selection: $kind) {
                    ForEach(CloudAccessKind.allCases.filter { $0 != .vault }, id: \.self) { value in
                        Text(CloudAccessLocalization.kind(value.rawValue)).tag(value)
                    }
                }.onChange(of: kind) { _, _ in Task { await load(reset: true) } }
                TextField(CloudAccessLocalization.text("Найти ID на этой странице", "Find ID on this page"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(CloudAccessLocalization.text("Поиск ID на текущей странице", "Search IDs on the current page"))
                if let error { Text(error).foregroundStyle(.orange).font(.caption) }
                ForEach(rows.filter { search.isEmpty || $0.id.canonicalCloudString.localizedCaseInsensitiveContains(search) }, id: \.id) { row in
                    Button("\(CloudAccessLocalization.kind(row.policyKind.rawValue)) · \(row.id.canonicalCloudString)") {
                        Task { await open(row) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(CloudAccessLocalization.kind(row.policyKind.rawValue)) \(row.id.canonicalCloudString)")
                    .accessibilityIdentifier("access-resource-\(row.id.canonicalCloudString)")
                }
                if rows.isEmpty && loaded && error == nil {
                    Text(CloudAccessLocalization.text("В реестре нет ресурсов этого типа.", "No registered resources of this type."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if loading { ProgressView().controlSize(.small) }
                    if pageNumber > 1 {
                        Button(CloudAccessLocalization.text("Первая страница", "First page")) { Task { await load(reset: true) } }
                            .disabled(loading)
                    }
                    if cursor != nil {
                        Button(CloudAccessLocalization.text("Следующие 50", "Next 50")) { Task { await load(reset: false) } }
                            .disabled(loading)
                    }
                }
            }
            .task { if !loaded { await load(reset: true) } }
        }
        .sheet(item: $selected) { reference in
            SelectiveRemoteCloudResourceAccessView(
                reference: reference, client: client, session: session,
                initialSection: .who, onCommitted: onCommitted
            )
        }
    }

    private func load(reset: Bool) async {
        guard reset || !loading else { return }
        let generation = UUID()
        requestGeneration = generation
        loading = true
        defer { if requestGeneration == generation { loading = false } }
        if reset { rows = []; cursor = nil; error = nil; loaded = false; pageNumber = 1 }
        let requestedKind = kind
        let requestedCursor = reset ? nil : cursor
        do {
            let page = try await client.resources(vault, session: session,
                                                  cursor: requestedCursor, kind: requestedKind)
            guard requestGeneration == generation, kind == requestedKind else { return }
            rows = page.rows
            cursor = page.nextCursor
            if !reset { pageNumber += 1 }
            loaded = true
        } catch {
            guard requestGeneration == generation, kind == requestedKind else { return }
            self.error = error.localizedDescription
        }
    }

    private func open(_ row: CloudAccessResource) async {
        let generation = requestGeneration
        do {
            let exact = try await client.getResource(vault, resourceID: row.id, session: session)
            guard requestGeneration == generation, kind == row.policyKind else { return }
            guard exact.policyKind == row.policyKind else { throw CloudAccessError.scopeMismatch }
            let reference = try SelectiveRemoteCloudAccessReference(
                teamID: vault.teamID, vaultID: vault.vaultID,
                resourceID: exact.id, kind: exact.policyKind
            )
            AccessResourceEntry.dispatch(reference: reference, kind: exact.policyKind,
                                         open: { selected = $0 },
                                         prerequisite: AccessRegistrationPrerequisite.show)
        } catch {
            guard requestGeneration == generation, kind == row.policyKind else { return }
            self.error = error.localizedDescription
        }
    }
}
