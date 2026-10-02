import CryptoKit
import Foundation
import SwiftUI

enum SelectiveRemoteWholePublicationSection: Int, CaseIterable { case access, share, edit, move }

@MainActor
final class SelectiveRemoteWholePublicationModel: ObservableObject {
    let reference: SelectiveRemotePublishedModelReference
    let client: SelectiveRemoteCloudAPIClient
    @Published var section: SelectiveRemoteWholePublicationSection
    @Published var title: String
    @Published var body = ""
    @Published var parent = ""
    @Published var principal = ""
    @Published var mask = 1
    @Published private(set) var principals: [SelectiveRemoteWholePublicationEditing.Principal] = []
    @Published private(set) var folders: [(id: String, name: String)] = []
    @Published private(set) var preview: SelectiveRemoteWholePublicationPreview?
    @Published private(set) var available = false
    @Published private(set) var busy = false
    @Published private(set) var blocked = false
    @Published private(set) var canDiscard = false
    @Published private(set) var committed = false
    @Published private(set) var message: String?
    @Published private(set) var status = ""
    private var cache: SelectiveRemotePublicationCache?
    private var context: SelectiveRemoteJSONValue?
    private var session: SelectiveRemotePublicationSession?
    private var identity: SelectiveRemoteTeamDeviceIdentity?
    private var root: P256.Signing.PrivateKey?
    private var store: SelectiveRemoteWholePublicationCheckpointStore?
    private var coordinator: SelectiveRemoteWholePublicationCoordinator?
    private var savedRequest: SelectiveRemoteJSONValue?
    private var changedParts: [String: Data] = [:]
    init(reference: SelectiveRemotePublishedModelReference, title: String, section: SelectiveRemoteWholePublicationSection, client: SelectiveRemoteCloudAPIClient = .init()) {
        self.reference = reference; self.title = title; self.section = section; self.client = client
    }
    private func check(requireCurrent: Bool = true) throws {
        try session?.check()
        guard !requireCurrent || SelectiveRemotePublicationPresentation.shared.valid(reference) else { throw SelectiveRemoteWholePublicationError.scope }
    }
    private func makeCoordinator(_ operationID: UUID) throws -> SelectiveRemoteWholePublicationCoordinator {
        guard let session, let identity, let root, let store else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
        try check()
        return .init(scope: .init(session: session, teamID: reference.scope.teamID, operationID: operationID), session: session, remote: client, identity: identity, root: root, store: store)
    }
    func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        principals = []; folders = []; available = false
        do {
            try check()
            guard let cache = SelectiveRemotePublicationPresentation.shared.caches.first(where: { $0.scope == reference.scope && $0.headerHash == reference.headerHash }),
                  let session = try await client.publicationSession(endpoint: reference.scope.endpoint, deviceID: reference.scope.deviceID) else { throw SelectiveRemoteWholePublicationError.scope }
            self.session = session; try check()
            guard session.accountID == reference.scope.accountID,
                  let key = try SelectiveRemoteTeamDeviceKeychainStore().privateKeyRepresentation(for: session.endpoint, deviceID: session.deviceID),
                  let root = try SelectiveRemoteDeviceTrustLocalStore().root(endpoint: session.endpoint, accountID: session.accountID) else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
            self.identity = try .init(deviceID: session.deviceID, privateKeyRepresentation: key); self.root = root
            self.store = try .init(); self.cache = cache
            let probe = SelectiveRemoteWholePublicationScope(session: session, teamID: reference.scope.teamID, operationID: UUID())
            if let pending = try store!.pendingOperation(scope: probe, session: session) {
                coordinator = try makeCoordinator(pending); blocked = true
                savedRequest = try await coordinator!.savedRequest(); try check()
                canDiscard = try await coordinator!.canDiscardUncommitted(); try check()
                message = SelectiveRemoteWholePublicationError.readbackRequired.localizedDescription
                return
            }
            coordinator = try makeCoordinator(UUID())
            let context = try await coordinator!.context(); try check(); self.context = context
            let current = try currentVault()
            guard current["generationID"] == .string(reference.generationID), current["headerHash"] == .string(reference.headerHash) else { throw SelectiveRemoteWholePublicationError.scope }
            var members: [SelectiveRemoteCloudTeamMember] = [], cursor: UUID?, cursors = Set<UUID>(), total: Int?
            repeat {
                try check(); let page = try await client.teamMembersPage(endpoint: session.endpoint, teamID: reference.scope.teamID, limit: 100, cursor: cursor); try check()
                if total == nil { total = page.total }
                guard total == page.total, page.total <= 1000, members.count + page.members.count <= 1000 else { throw SelectiveRemoteWholePublicationError.limit }
                members += page.members; cursor = page.nextCursor
                if let cursor { guard cursors.insert(cursor).inserted else { throw SelectiveRemoteWholePublicationError.incompletePreview } }
            } while cursor != nil
            guard members.count == total, Set(members.map(\.id)).count == members.count else { throw SelectiveRemoteWholePublicationError.incompletePreview }
            let c = try context.publicationObject()
            for raw in try c["memberships"]!.publicationArray() {
                let membership = try raw.publicationObject(), id = try SelectiveRemoteWholePublicationWire.id(membership["id"]!), user = try SelectiveRemoteWholePublicationWire.id(membership["userID"]!), epoch = try membership["epoch"]!.publicationInteger()
                guard let member = members.first(where: { $0.id == id && $0.userID == user && $0.epoch == epoch }) else { throw SelectiveRemoteWholePublicationError.scope }
                principals.append(.init(id: user, kind: "USER", name: member.displayName.isEmpty ? member.username : member.displayName + " (@" + member.username + ")", membershipID: id, epoch: epoch))
            }
            for raw in try c["groups"]!.publicationArray() {
                let group = try raw.publicationObject(); principals.append(.init(id: try SelectiveRemoteWholePublicationWire.id(group["id"]!), kind: "GROUP", name: CloudAccessLocalization.text("Группа: ", "Group: ") + (try group["name"]!.publicationString()), membershipID: nil, epoch: nil))
            }
            principals.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }; principal = principals.first?.key ?? ""
            if let source = cache.parts.first(where: { $0.resourceID == reference.resourceID }) {
                parent = source.parentFolderID?.canonicalCloudString ?? ""
                let p = try cache.payload(source)
                if reference.kind == .snippet, let r = p["record"] { body = try r.publicationObject()["data"]!.publicationObject()["body"]!.publicationString() }
                let type = reference.kind == .folder ? try p["folder"]!.publicationObject()["type"]!.publicationString() : reference.kind == .host ? "host" : "snippet"
                for f in cache.parts where f.kind == .folder && f.resourceID != reference.resourceID {
                    let fields = try cache.payload(f)["folder"]!.publicationObject()
                    if fields["type"] == .string(type) { folders.append((f.resourceID.canonicalCloudString, try fields["path"]!.publicationString())) }
                }
                folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            available = true; message = nil; try check()
        } catch { available = false; message = error.localizedDescription }
    }
    private func currentVault() throws -> [String: SelectiveRemoteJSONValue] {
        guard let context, let rows = try context.publicationObject()["current"]?.publicationArray(), let value = try rows.first(where: { try $0.publicationObject()["vaultID"] == .string(reference.scope.vaultID.canonicalCloudString) }) else { throw SelectiveRemoteWholePublicationError.scope }
        return try value.publicationObject()
    }
    private func desiredVault() throws -> SelectiveRemoteJSONValue {
        let c = try currentVault()
        return .object(["vaultID": c["vaultID"]!, "resources": c["resources"]!, "policy": c["policy"]!, "contentChanges": .array([]), "custodianDeviceIDs": c["custodianDeviceIDs"]!])
    }
    func discardPreview() { guard !busy, !blocked, !committed else { return }; preview = nil; changedParts = [:]; savedRequest = nil; status = "" }
    func preparePreview() async {
        guard available, !busy, !blocked, !committed, section != .access else { return }
        busy = true; defer { busy = false }
        do {
            try check(); guard let context, let cache else { throw SelectiveRemoteWholePublicationError.scope }
            let coordinator = try makeCoordinator(UUID()); self.coordinator = coordinator
            // Each intent gets its own operation ID and fresh sealed plan. A prepared operation is immutable.
            let freshContext = try await coordinator.context(); try check()
            let fresh = try freshContext.publicationObject(), prior = try context.publicationObject()
            guard ["current", "groups", "memberships", "edges"].allSatisfy({ fresh[$0] == prior[$0] }) else { throw SelectiveRemoteWholePublicationError.scope }
            var vault = try desiredVault(); changedParts = [:]
            switch section {
            case .share:
                guard let selected = principals.first(where: { $0.key == principal }) else { throw SelectiveRemoteWholePublicationError.invalid }
                vault = try SelectiveRemoteWholePublicationEditing.grant(vault: vault, reference: reference, principal: selected, mask: mask)
            case .edit, .move:
                let intent: SelectiveRemoteWholePublicationEditing.Intent = section == .edit ? .content(title: title, body: reference.kind == .snippet ? body : nil) : .move(parent: parent.isEmpty ? nil : UUID(uuidString: parent))
                let draft = try SelectiveRemoteWholePublicationEditing.draft(vault: vault, reference: reference, parts: cache.parts, intent: intent)
                vault = draft.vault; changedParts = draft.changedParts
            case .access: throw SelectiveRemoteWholePublicationError.invalid
            }
            let request = try await coordinator.desiredRequest(context: context, vaultOverrides: [reference.scope.vaultID: vault]); try check()
            let preview = try await coordinator.preview(request: request); try check()
            self.preview = preview; savedRequest = request; message = nil
            status = CloudAccessLocalization.text("Полный список изменений получен и проверен. Подтвердите публикацию всей команды.", "The complete change list was received and verified. Confirm publication for the whole Team.")
        } catch { preview = nil; message = error.localizedDescription }
    }
    func publish() async {
        guard let coordinator, let preview, !busy, !blocked, !committed else { return }; busy = true; defer { busy = false }
        do {
            try check(); status = CloudAccessLocalization.text("Подготовка новой публикации…", "Preparing the new publication…")
            try await coordinator.prepare(preview: preview, changedParts: changedParts); try check()
            status = CloudAccessLocalization.text("Сохранение и проверка результата…", "Saving and verifying the result…")
            _ = try await coordinator.commit(preview: preview); try check(requireCurrent: false)
            committed = true; self.preview = nil; status = CloudAccessLocalization.text("Публикация сохранена и проверена. Обновление ресурсов…", "Publication saved and verified. Refreshing resources…")
            let result = try await SelectiveRemoteTeamVaultAutoSync.shared.synchronizeConfiguredAccountNow(); try check(requireCurrent: false)
            if result.failures > 0 { message = result.lastFailure }
        } catch {
            blocked = (try? await coordinator.writesDisabled()) ?? true; message = error.localizedDescription
            canDiscard = (try? await coordinator.canDiscardUncommitted()) ?? false
            if !blocked { self.preview = nil; available = false; savedRequest = nil; changedParts = [:] }
            if committed { status = CloudAccessLocalization.text("Публикация подтверждена; обновите список ресурсов.", "Publication confirmed; refresh the resource list.") }
        }
    }
    func resolve() async {
        guard let coordinator, let savedRequest, !busy else { return }; busy = true; defer { busy = false }
        do {
            try check(requireCurrent: false); _ = try await coordinator.resolveReceipt(request: savedRequest); try check(requireCurrent: false)
            blocked = false; committed = true; preview = nil; message = nil
            status = CloudAccessLocalization.text("Сохранённая публикация подтверждена. Обновление ресурсов…", "Saved publication confirmed. Refreshing resources…")
            let result = try await SelectiveRemoteTeamVaultAutoSync.shared.synchronizeConfiguredAccountNow(); try check(requireCurrent: false)
            if result.failures > 0 { message = result.lastFailure }
        } catch { blocked = true; canDiscard = (try? await coordinator.canDiscardUncommitted()) ?? false; message = error.localizedDescription }
    }
    func discard() async {
        guard let coordinator, !busy, blocked, canDiscard else { return }; busy = true; defer { busy = false }
        do {
            try check(requireCurrent: false); try await coordinator.discardAfterFailedCommit(); try check(requireCurrent: false)
            blocked = false; canDiscard = false; available = false; preview = nil; savedRequest = nil; changedParts = [:]; message = nil
            status = CloudAccessLocalization.text("Незавершённая подготовка отменена. Обновите данные перед новой операцией.", "Uncommitted preparation discarded. Refresh data before a new operation.")
        } catch { message = error.localizedDescription }
    }
    func refresh() async {
        guard !busy else { return }; busy = true
        do {
            try check(requireCurrent: false); let result = try await SelectiveRemoteTeamVaultAutoSync.shared.synchronizeConfiguredAccountNow(); try check(requireCurrent: false)
            if result.failures > 0 { message = result.lastFailure }
        } catch { message = error.localizedDescription }
        busy = false
        if SelectiveRemotePublicationPresentation.shared.valid(reference) { await load() }
    }
    func accountName(_ value: SelectiveRemoteJSONValue?) -> String {
        guard let value, let id = try? SelectiveRemoteWholePublicationWire.id(value), let p = principals.first(where: { $0.kind == "USER" && $0.id == id }) else { return CloudAccessLocalization.text("Участник не найден — обновите данные", "Member unavailable — refresh data") }
        return p.name
    }
    func resourceName(_ value: SelectiveRemoteJSONValue?, vault: SelectiveRemoteJSONValue?) -> String {
        guard let value, let id = try? SelectiveRemoteWholePublicationWire.id(value) else { return CloudAccessLocalization.text("Служебные данные", "Administrative data") }
        for cache in SelectiveRemotePublicationPresentation.shared.caches where cache.scope.endpoint == reference.scope.endpoint && cache.scope.accountID == reference.scope.accountID && cache.scope.deviceID == reference.scope.deviceID && cache.scope.teamID == reference.scope.teamID && vault == .string(cache.scope.vaultID.canonicalCloudString) {
            if let part = cache.parts.first(where: { $0.resourceID == id }), let p = try? cache.payload(part) {
                if let title = try? p["record"]?.publicationObject()["data"]?.publicationObject()["title"]?.publicationString() { return title }
                if let title = try? p["metadata"]?.publicationObject()["title"]?.publicationString() { return title }
                if let title = try? p["folder"]?.publicationObject()["path"]?.publicationString() { return title }
            }
        }
        return CloudAccessLocalization.text("Ресурс ", "Resource ") + id.canonicalCloudString
    }
    func vaultName(_ value: SelectiveRemoteJSONValue?) -> String {
        guard let value, let id = try? SelectiveRemoteWholePublicationWire.id(value) else { return "Vault" }
        if let cache = SelectiveRemotePublicationPresentation.shared.caches.first(where: { $0.scope.endpoint == reference.scope.endpoint && $0.scope.accountID == reference.scope.accountID && $0.scope.deviceID == reference.scope.deviceID && $0.scope.teamID == reference.scope.teamID && $0.scope.vaultID == id }) { return cache.vaultName }
        return "Vault " + id.canonicalCloudString
    }
}

struct SelectiveRemoteWholePublicationView: View {
    @StateObject private var model: SelectiveRemoteWholePublicationModel
    private let access: SelectiveRemoteCloudAccessReference
    @State private var confirming = false
    @State private var confirmingDiscard = false
    init(reference: SelectiveRemotePublishedModelReference, access: SelectiveRemoteCloudAccessReference, section: SelectiveRemoteWholePublicationSection = .access) {
        self.access = access; _model = StateObject(wrappedValue: .init(reference: reference, title: access.title, section: section))
    }
    init(model: SelectiveRemoteWholePublicationModel, access: SelectiveRemoteCloudAccessReference) {
        self.access = access; _model = StateObject(wrappedValue: model)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(access.title).font(.title2).lineLimit(2)
            Picker(CloudAccessLocalization.text("Действие", "Action"), selection: $model.section) {
                Text(CloudAccessLocalization.text("Кто имеет доступ", "Who has access")).tag(SelectiveRemoteWholePublicationSection.access)
                Text(CloudAccessLocalization.text("Поделиться", "Share")).tag(SelectiveRemoteWholePublicationSection.share)
                if [.host, .snippet].contains(model.reference.kind) { Text(CloudAccessLocalization.text("Изменить", "Edit")).tag(SelectiveRemoteWholePublicationSection.edit) }
                if [.host, .snippet, .folder].contains(model.reference.kind) { Text(CloudAccessLocalization.text("Переместить", "Move")).tag(SelectiveRemoteWholePublicationSection.move) }
            }.pickerStyle(.segmented).disabled(model.busy || model.committed)
            if model.section == .access {
                SelectiveRemoteCloudResourceAccessView(reference: access, client: .init(client: model.client), session: .init(endpoint: model.reference.scope.endpoint), initialSection: .who)
            } else {
                inputs.disabled(!model.available || model.busy || model.blocked || model.committed)
                if let preview = model.preview { previewList(preview) } else { Spacer() }
                if !model.blocked && !model.committed {
                    HStack {
                        Button(CloudAccessLocalization.text("Просмотреть изменения всей команды", "Preview all Team changes")) { Task { await model.preparePreview() } }.disabled(!model.available || model.busy)
                        Spacer()
                        Button(CloudAccessLocalization.text("Подтвердить публикацию…", "Confirm publication…")) { confirming = true }.disabled(model.preview == nil || model.busy)
                    }
                }
            }
            if model.blocked { Button(CloudAccessLocalization.text("Проверить сохранённый результат", "Check saved result")) { Task { await model.resolve() } }.disabled(model.busy) }
            if model.blocked && model.canDiscard { Button(CloudAccessLocalization.text("Отменить незавершённую подготовку…", "Discard uncommitted preparation…")) { confirmingDiscard = true }.disabled(model.busy) }
            if !model.available && !model.blocked && !model.committed { Button(CloudAccessLocalization.text("Обновить ресурсы", "Refresh resources")) { Task { await model.refresh() } }.disabled(model.busy) }
            if model.busy { ProgressView().controlSize(.small) }
            if !model.status.isEmpty { Text(model.status).font(.callout).textSelection(.enabled) }
            if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(20).frame(minWidth: 720, minHeight: 600)
            .task { await model.load() }
            .onChange(of: model.section) { _, _ in model.discardPreview() }
            .onChange(of: model.title) { _, _ in model.discardPreview() }
            .onChange(of: model.body) { _, _ in model.discardPreview() }
            .onChange(of: model.parent) { _, _ in model.discardPreview() }
            .onChange(of: model.principal) { _, _ in model.discardPreview() }
            .onChange(of: model.mask) { _, _ in model.discardPreview() }
            .confirmationDialog(CloudAccessLocalization.text("Опубликовать проверенные изменения всей команды?", "Publish the verified changes for the whole Team?"), isPresented: $confirming) {
                Button(CloudAccessLocalization.text("Опубликовать", "Publish")) { Task { await model.publish() } }
                Button(CloudAccessLocalization.text("Отмена", "Cancel"), role: .cancel) {}
            }
            .confirmationDialog(CloudAccessLocalization.text("Отменить подготовку, если она ещё не опубликована?", "Discard preparation if it has not been committed?"), isPresented: $confirmingDiscard) {
                Button(CloudAccessLocalization.text("Отменить подготовку", "Discard preparation")) { Task { await model.discard() } }
                Button(CloudAccessLocalization.text("Назад", "Back"), role: .cancel) {}
            }
    }
    @ViewBuilder private var inputs: some View {
        switch model.section {
        case .share:
            Picker(CloudAccessLocalization.text("Участник или группа", "Member or group"), selection: $model.principal) { ForEach(model.principals, id: \.key) { Text($0.name).tag($0.key) } }
            Picker(CloudAccessLocalization.text("Прямой доступ", "Direct access"), selection: $model.mask) {
                Text(CloudAccessLocalization.text("Убрать прямой доступ", "Remove direct access")).tag(0)
                Text(CloudAccessLocalization.text("Просмотр", "View")).tag(1)
                if model.reference.kind == .credential {
                    Text(CloudAccessLocalization.text("Просмотр и раскрытие секрета", "View and reveal secret")).tag(3)
                    Text(CloudAccessLocalization.text("Изменение и раскрытие секрета", "Edit and reveal secret")).tag(7)
                    Text(CloudAccessLocalization.text("Полный доступ к ресурсу", "Full resource access")).tag(15)
                } else if model.reference.kind == .folder { Text(CloudAccessLocalization.text("Управление папкой", "Manage folder")).tag(33) }
                else {
                    if model.reference.kind != .forwarding { Text(CloudAccessLocalization.text("Просмотр и изменение", "View and edit")).tag(5) }
                    Text(CloudAccessLocalization.text("Просмотр и управление доступом", "View and manage access")).tag(9)
                }
            }
            Text(CloudAccessLocalization.text("Унаследованный доступ может сохраниться после удаления прямого назначения. Итоговые изменения показаны ниже.", "Inherited access can remain after a direct grant is removed. The resulting changes are shown below.")).font(.caption).foregroundStyle(.secondary)
        case .edit:
            TextField(CloudAccessLocalization.text("Название", "Title"), text: $model.title)
            if model.reference.kind == .snippet { TextEditor(text: $model.body).font(.system(.body, design: .monospaced)).frame(minHeight: 100, maxHeight: 180).border(.secondary.opacity(0.3)) }
        case .move:
            Picker(CloudAccessLocalization.text("Папка назначения в этом Vault", "Destination folder in this Vault"), selection: $model.parent) {
                Text(CloudAccessLocalization.text("Корень Vault", "Vault root")).tag("")
                ForEach(model.folders, id: \.id) { Text($0.name).tag($0.id) }
            }
        case .access: EmptyView()
        }
    }
    private func previewList(_ preview: SelectiveRemoteWholePublicationPreview) -> some View {
        VStack(alignment: .leading) {
            let counts = (try? preview.binding.publicationObject()["counts"]?.publicationObject()) ?? [:]
            Text("\(CloudAccessLocalization.text("Вся команда", "Whole Team")): \((try? counts["vaults"]?.publicationInteger()) ?? 0) Vault · \((try? counts["resources"]?.publicationInteger()) ?? 0) \(CloudAccessLocalization.text("ресурсов", "resources")) · \(preview.rows.count) \(CloudAccessLocalization.text("строк", "rows"))").font(.headline)
            List(Array(preview.rows.enumerated()), id: \.offset) { _, raw in
                if let row = try? raw.publicationObject() {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.vaultName(row["vaultID"])).foregroundStyle(.secondary)
                        Text(model.resourceName(row["resourceID"], vault: row["vaultID"])).font(.headline)
                        if row["type"] == .string("DELTA") {
                            Text(model.accountName(row["accountID"]) + " · " + rights(row["beforeMask"]) + " → " + rights(row["afterMask"]))
                        } else {
                            let devices = (try? row["devices"]?.publicationArray()) ?? []
                            let names = devices.compactMap { try? $0.publicationObject()["accountID"] }.map { model.accountName($0) }
                            Text((row["part"] == .string("SECRET") ? CloudAccessLocalization.text("Секрет", "Secret") : row["type"] == .string("CUSTODY") ? CloudAccessLocalization.text("Хранители", "Custodians") : CloudAccessLocalization.text("Данные", "Data")) + " · " + Array(Set(names)).sorted().joined(separator: ", ") + " · \(devices.count) " + CloudAccessLocalization.text("устройств", "devices"))
                        }
                    }.font(.caption).textSelection(.enabled)
                }
            }.frame(minHeight: 160)
        }
    }
    private func rights(_ value: SelectiveRemoteJSONValue?) -> String {
        let mask = (try? value?.publicationInteger(min: 0, max: 63)) ?? 0
        let labels: [(Int, String)] = [(1, CloudAccessLocalization.text("Просмотр", "View")), (2, CloudAccessLocalization.text("Раскрытие", "Reveal")), (4, CloudAccessLocalization.text("Изменение", "Edit")), (8, CloudAccessLocalization.text("Доступ", "Access")), (16, CloudAccessLocalization.text("Создание", "Create")), (32, CloudAccessLocalization.text("Папка", "Folder"))]
        return mask == 0 ? CloudAccessLocalization.text("Нет доступа", "No access") : labels.filter { mask & $0.0 != 0 }.map(\.1).joined(separator: ", ")
    }
}
