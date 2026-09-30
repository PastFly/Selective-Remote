import SwiftUI

enum CloudAccessSection: Int, Sendable { case share, who, effective }

struct SelectiveRemoteCloudResourceAccessView: View {
    @State private var model: SelectiveRemoteCloudAccessCoordinator
    let onCommitted: (CloudAccessCommit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var recipientGroups = false
    @State private var search = ""
    @State private var confirmation = false
    @FocusState private var searchFocused: Bool

    init(reference: SelectiveRemoteCloudAccessReference, client: SelectiveRemoteCloudAccessClient, session: CloudAccessSession, initialSection: CloudAccessSection = .share, onCommitted: @escaping (CloudAccessCommit) -> Void = { _ in }) {
        _model = State(initialValue: .init(reference: reference, client: client, session: session)); _tab = State(initialValue: initialSection.rawValue); self.onCommitted = onCommitted
    }
    // Fixture hosts inject the same coordinator/client with a test-only transport.
    // No production fixture mode, synthetic data branch or authorization bypass.
    init(coordinator: SelectiveRemoteCloudAccessCoordinator, initialSection: CloudAccessSection = .share, onCommitted: @escaping (CloudAccessCommit) -> Void = { _ in }) {
        _model = State(initialValue: coordinator); _tab = State(initialValue: initialSection.rawValue); self.onCommitted = onCommitted
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(CloudAccessLocalization.share, systemImage: "person.crop.circle.badge.checkmark").font(.title2)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(CloudAccessLocalization.text("Закрыть", "Close")) { model.invalidate(); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(model.reference.title).font(.headline).textSelection(.enabled).lineLimit(2)
            Text("Team \(model.reference.teamID.canonicalCloudString) · Vault \(model.reference.vaultID.canonicalCloudString)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            if let context = model.context { CloudAccessStateView(context: context) }
            if model.reference.kind == .vault,
               let formatState = model.context?.formatState,
               RegisteredResourceDirectory.available(in: formatState) {
                SelectiveRemoteRegisteredResourcePicker(
                    vault: model.reference, client: model.client, session: model.session,
                    onCommitted: onCommitted
                )
            }
            if let error = model.errorMessage { CloudAccessErrorView(message: error) { Task { await model.load() } } }
            if model.committed { Label(CloudAccessLocalization.text("Сервер подтвердил изменение доступа.", "The server committed the access change."), systemImage: "checkmark.circle").foregroundStyle(.green) }
            Picker(CloudAccessLocalization.text("Раздел доступа", "Access view"), selection: $tab) {
                Text(CloudAccessLocalization.share).tag(0)
                Text(CloudAccessLocalization.who).tag(1)
                Text(CloudAccessLocalization.effective).tag(2)
            }.pickerStyle(.segmented).labelsHidden()
                .accessibilityLabel(CloudAccessLocalization.text("Раздел доступа", "Access view"))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.context?.formatState == .preparing {
                        switch tab {
                        case 0: shareBody
                        case 1: whoBody
                        default: effectiveBody
                        }
                        if let preview = model.preview { previewBody(preview) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(CloudAccessLocalization.text("Обновить", "Refresh")) { Task { await model.load() } }.disabled(model.busy)
                Spacer()
                if model.preview?.nextCursor != nil {
                    Button(CloudAccessLocalization.text("Следующая страница последствий", "Next impact page")) { Task { await model.nextPreviewPage() } }.disabled(model.busy)
                } else if model.preview != nil {
                    Button(CloudAccessLocalization.text("Подтвердить…", "Confirm…")) { confirmation = true }
                        .keyboardShortcut(.defaultAction).disabled(!model.canCommit)
                } else if tab == 0 {
                    Button(CloudAccessLocalization.text("Просмотреть изменение", "Preview change")) { Task { await model.previewSelection() } }
                        .keyboardShortcut(.defaultAction).disabled(!model.canMutate || model.busy || (model.selection.isEmpty && model.editingGrant == nil))
                }
            }
        }
        .padding(20).frame(minWidth: 440, idealWidth: 640, maxWidth: 760, minHeight: 460, idealHeight: 680, maxHeight: 850)
        .task {
            if model.context == nil { await model.load() }
            searchFocused = true
        }
        .onDisappear { model.invalidate() }
        .alert(CloudAccessLocalization.text("Применить просмотренное изменение?", "Apply the previewed change?"), isPresented: $confirmation) {
            Button(CloudAccessLocalization.text("Отмена", "Cancel"), role: .cancel) {}
            Button(CloudAccessLocalization.text("Применить", "Apply")) {
                Task { if let result = await model.commit() { onCommitted(result) } }
            }.disabled(!model.canCommit)
        } message: {
            Text(CloudAccessLocalization.text("Сервер повторно проверит политику, членство и срок просмотра. Доступ по политике не подтверждает наличие ключа на устройстве.", "The server rechecks policy, membership and preview expiry. Policy access does not confirm a usable device key."))
        }
    }
    private var shareBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let grant = model.editingGrant {
                Text(CloudAccessLocalization.text("Изменение разрешения", "Change grant")).font(.headline)
                Text("\(grant.target_kind.rawValue) · \(grant.target_id.canonicalCloudString)").font(.caption).textSelection(.enabled)
                Button(CloudAccessLocalization.text("Новый доступ", "New access")) { model.setSelection([]) }
            } else {
                Picker(CloudAccessLocalization.text("Получатели", "Recipients"), selection: $recipientGroups) {
                    Text(CloudAccessLocalization.text("Участники", "Members")).tag(false)
                    Text(CloudAccessLocalization.text("Группы", "Groups")).tag(true)
                }.pickerStyle(.segmented)
                HStack {
                    TextField(CloudAccessLocalization.text("Найти получателя", "Search recipients"), text: $search)
                        .textFieldStyle(.roundedBorder).focused($searchFocused)
                        .onSubmit { Task { await model.loadRecipients(groups: recipientGroups, search: search) } }
                    Button(CloudAccessLocalization.text("Найти", "Search")) { Task { await model.loadRecipients(groups: recipientGroups, search: search) } }
                }
                .onChange(of: recipientGroups) { _, value in Task { await model.loadRecipients(groups: value, search: search) } }
                if !model.selection.isEmpty {
                    FlowAccessRecipients(selection: model.selection) { model.toggleRecipient($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if recipientGroups {
                        if model.groups.isEmpty { Text(CloudAccessLocalization.text("На этой странице нет групп.", "No groups on this page.")).foregroundStyle(.secondary) }
                        ForEach(model.groups) { g in recipientRow(.init(kind: .group, id: g.id, name: g.name)) }
                    } else {
                        if model.members.isEmpty { Text(CloudAccessLocalization.text("На этой странице нет участников.", "No members on this page.")).foregroundStyle(.secondary) }
                        ForEach(model.members) { m in recipientRow(.init(kind: .user, id: m.userID, name: "\(m.displayName) · @\(m.username)")) }
                    }
                }
                .padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button(CloudAccessLocalization.text("Первая страница", "First page")) { Task { await model.loadRecipients(groups: recipientGroups, search: search) } }
                    Spacer()
                    Button(CloudAccessLocalization.text("Следующая страница", "Next page")) { Task { await model.loadRecipients(groups: recipientGroups, search: search, next: true) } }
                        .disabled(recipientGroups ? model.groupCursor == nil : model.memberCursor == nil)
                }
            }
            permissionEditor
            Divider()
            Text(CloudAccessLocalization.text("Разрешения в Vault", "Grants in this Vault")).font(.headline)
            ForEach(model.grants) { grant in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(CloudAccessLocalization.kind(grant.principal_kind.rawValue)) · \(grant.principal_id.canonicalCloudString)").font(.caption).textSelection(.enabled)
                    Text("\(CloudAccessLocalization.kind(grant.target_kind.rawValue)) · \(grant.target_id.canonicalCloudString)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(CloudAccessLocalization.text("Изменить", "Change")) { Task { await model.edit(grant) } }
                        Button(CloudAccessLocalization.text("Просмотр отзыва", "Preview revoke"), role: .destructive) { Task { await model.revoke([grant]) } }
                    }.disabled(!model.canMutate || model.busy)
                }.padding(.vertical, 3)
            }
            if model.grantCursor != nil { Button(CloudAccessLocalization.text("Следующая страница разрешений", "Next grants page")) { Task { await model.loadMoreGrants() } } }
            if let guidance = CloudAccessLocalization.revokeGuidance(hasExistingGrants: !model.grants.isEmpty) {
                Text(guidance).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func recipientRow(_ recipient: CloudAccessRecipient) -> some View {
        let selected = model.selection.contains { $0.id == recipient.id && $0.kind == recipient.kind }
        return Button { model.toggleRecipient(recipient) } label: {
            HStack { Image(systemName: selected ? "checkmark.circle.fill" : "circle"); Text(recipient.name).lineLimit(1); Spacer() }.contentShape(Rectangle())
        }.buttonStyle(.plain).padding(4)
            .accessibilityLabel(recipient.name).accessibilityValue(selected ? CloudAccessLocalization.text("Выбран", "Selected") : CloudAccessLocalization.text("Не выбран", "Not selected"))
            .disabled(!model.canMutate || model.busy)
    }
    private var permissionEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(CloudAccessLocalization.text("Разрешения", "Permissions")).font(.headline)
            HStack {
                Button(CloudAccessLocalization.permission(model.currentKind == .credential ? "ViewMetadata" : "View")) { model.setMask(1) }
                if let edit = model.currentKind.editMask { Button(CloudAccessLocalization.permission("Edit")) { model.setMask(edit) } }
                Button(CloudAccessLocalization.text("Все разрешения", "All permissions")) { model.setMask(model.currentKind.allowedMask) }
            }
            ForEach(model.currentKind.permissions, id: \.bit) { permission in
                Toggle(CloudAccessLocalization.permission(permission.name), isOn: Binding(get: { model.mask & permission.bit != 0 }, set: { model.togglePermission(permission.bit, enabled: $0) }))
            }
            if model.currentKind == .credential { Text(CloudAccessLocalization.text("Редактирование включает раскрытие секрета.", "Edit includes Reveal.")).font(.caption).foregroundStyle(.secondary) }
        }.disabled(!model.canMutate || model.busy)
    }
    private var whoBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.reference.kind == .vault {
                Text(CloudAccessLocalization.text("Для списка путей выберите зарегистрированный ресурс. Разрешения Vault показаны во вкладке «Поделиться».", "Select a registered resource to inspect its access paths. Vault grants appear in Share."))
            } else {
                ForEach(model.who) { entry in
                    Text(entry.userID.canonicalCloudString).font(.headline).textSelection(.enabled)
                    CloudAccessPolicyView(policy: entry.policyEffective)
                }
                if model.who.isEmpty { Text(CloudAccessLocalization.text("Сервер не вернул участников с доступом.", "The server returned no members with access.")) }
                if model.whoCursor != nil { Button(CloudAccessLocalization.text("Следующая страница участников", "Next members page")) { Task { await model.loadMoreWho() } } }
            }
        }
    }
    private var effectiveBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.reference.kind == .vault {
                Text(CloudAccessLocalization.text("Эффективный доступ устройства проверяется для зарегистрированного ресурса.", "Device effective access is checked for a registered resource."))
            } else {
                Picker(CloudAccessLocalization.text("Участник", "Member"), selection: Binding(get: { model.subjectUserID }, set: { value in Task { await model.selectSubject(value) } })) {
                    Text(CloudAccessLocalization.text("Выберите участника", "Choose member")).tag(UUID?.none)
                    ForEach(model.members) { member in Text(member.displayName).tag(Optional(member.userID)) }
                }
                HStack {
                    Button(CloudAccessLocalization.text("Первая страница участников", "First members page")) { Task { await model.loadRecipients(groups: false, search: "") } }
                    Button(CloudAccessLocalization.text("Следующая страница участников", "Next members page")) { Task { await model.loadRecipients(groups: false, search: "", next: true) } }.disabled(model.memberCursor == nil)
                }
                Picker(CloudAccessLocalization.text("Устройство участника", "Member's device"), selection: Binding(get: { model.subjectDeviceID }, set: { value in Task { await model.selectDevice(value) } })) {
                    Text(CloudAccessLocalization.text("Выберите устройство", "Choose device")).tag(UUID?.none)
                    ForEach(model.devices) { device in Text("\(device.name) · \(device.platform)\(device.admitted ? "" : " · " + CloudAccessLocalization.text("не допущено", "not admitted"))").tag(Optional(device.id)) }
                }.disabled(model.subjectUserID == nil)
                if model.deviceCursor != nil { Button(CloudAccessLocalization.text("Следующая страница устройств", "Next devices page")) { Task { await model.loadMoreDevices() } } }
                if let effective = model.effective {
                    CloudAccessPolicyView(policy: effective.policyEffective)
                    if let device = effective.deviceUsability {
                        Text(CloudAccessLocalization.text("Доступность на устройстве", "Device usability") + ": " + CloudAccessLocalization.deviceStatus(device.effectiveUsable.rawValue)).font(.headline)
                        Text(CloudAccessLocalization.text("Ключ", "Key") + ": " + CloudAccessLocalization.deviceStatus(device.cryptoAvailable)).font(.caption)
                        ForEach(device.cryptoAvailableByPermission.keys.sorted(), id: \.self) { key in
                            Text("\(CloudAccessLocalization.permission(key)): \(CloudAccessLocalization.deviceStatus(device.cryptoAvailableByPermission[key] ?? "UNKNOWN")) · \(CloudAccessLocalization.deviceStatus(device.effectiveUsableByPermission[key] ?? "UNKNOWN"))").font(.caption)
                        }
                        ForEach(device.blockedReasons, id: \.self) { Text(CloudAccessLocalization.deviceReason($0)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Text(CloudAccessLocalization.text("UNKNOWN означает: наличие обёртки не подтверждает расшифровку. Устройство выбирается явно для участника.", "UNKNOWN means a present wrapper does not prove decryption. Choose the member's device explicitly."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func previewBody(_ preview: CloudAccessPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(CloudAccessLocalization.text("Последствия изменения", "Change impact")).font(.headline)
            Text(CloudAccessLocalization.text("Пар", "Pairs") + ": \(preview.counts.pairs) · " + CloudAccessLocalization.text("Расширен", "Widened") + ": \(preview.counts.widened) · " + CloudAccessLocalization.text("Потерян", "Lost") + ": \(preview.counts.lost)")
            ForEach(model.impacts) { impact in
                Text("\(impact.subjectUserID.canonicalCloudString) · \(impact.resourceID.canonicalCloudString)").font(.caption).textSelection(.enabled)
                Text("+\(impact.gainedMask) / −\(impact.lostMask)").font(.caption.monospacedDigit())
                Text(CloudAccessLocalization.text("До", "Before")).font(.caption.bold())
                CloudAccessPolicyView(policy: impact.before.policyEffective)
                Text(CloudAccessLocalization.text("После", "After")).font(.caption.bold())
                CloudAccessPolicyView(policy: impact.after.policyEffective)
                if impact.lostMask == 0 && !impact.after.policyEffective.paths.isEmpty { Text(CloudAccessLocalization.text("Доступ сохранён другими путями.", "Access remains through other paths.")).font(.caption) }
            }
            ForEach(model.affectedGrants) { grant in Text("\(grant.targetKind.rawValue) · \(grant.targetID.canonicalCloudString) · \(grant.permissionMask)").font(.caption) }
            if preview.nextCursor != nil { Text(CloudAccessLocalization.text("Просмотрите все страницы перед подтверждением.", "Review every page before confirmation.")).font(.caption) }
        }
    }
}

private struct FlowAccessRecipients: View {
    let selection: [CloudAccessRecipient]
    let remove: (CloudAccessRecipient) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(selection, id: \.self) { recipient in
                HStack { Text(recipient.name).lineLimit(1); Button { remove(recipient) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel(CloudAccessLocalization.text("Убрать получателя", "Remove recipient") + " " + recipient.name) }
                    .padding(5).background(.quaternary, in: Capsule())
            }
        }
    }
}
struct CloudAccessStateView: View {
    let context: CloudAccessContext
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(context.formatState.rawValue).font(.caption.bold())
            if context.formatState == .v1Active { Text(CloudAccessLocalization.error(.service(409, "access_v2_preparing_required"))) }
            if context.formatState == .ready || context.formatState == .active { Text(CloudAccessLocalization.error(.service(409, "crypto_publication_required"))) }
            ForEach(context.blockers, id: \.self) { blocker in
                if blocker == "crypto_publication_required" && context.canMutate {
                    Text(CloudAccessLocalization.text("Изменения групп требуют публикации зашифрованного поколения.", "Group changes require an encrypted generation publication."))
                } else { Text(CloudAccessLocalization.error(.service(409, blocker))) }
            }
            if context.formatState == .preparing { Text(CloudAccessLocalization.text("Политика в подготовке V2. Это не подтверждает публикацию или расшифровку.", "Policy in V2 preparation. This does not confirm publication or decryption.")) }
        }.font(.caption).foregroundStyle(.secondary)
    }
}
struct CloudAccessErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View { HStack { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red); Spacer(); Button(CloudAccessLocalization.text("Повторить", "Retry"), action: retry) }.font(.caption) }
}
struct CloudAccessPolicyView: View {
    let policy: CloudAccessPolicy
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(CloudAccessLocalization.text("Политика", "Policy") + ": " + (policy.policyAllowed ? CloudAccessLocalization.text("разрешено", "allowed") : CloudAccessLocalization.text("запрещено", "denied"))).font(.caption)
            ForEach(policy.paths) { path in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(CloudAccessLocalization.kind(path.principalKind.rawValue)) · \(path.principalID.canonicalCloudString)")
                    Text("\(CloudAccessLocalization.kind(path.grantTargetKind.rawValue)) · \(path.grantTargetID.canonicalCloudString)")
                    Text((path.sourceType == .direct ? CloudAccessLocalization.text("Прямой", "Direct") : CloudAccessLocalization.text("Наследуемый", "Inherited")) + " · " + path.permissions.map(CloudAccessLocalization.permission).joined(separator: ", "))
                }.font(.caption).textSelection(.enabled).padding(6).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
            }
            ForEach(policy.blockedReasons, id: \.self) { Text(CloudAccessLocalization.deviceReason($0)).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
