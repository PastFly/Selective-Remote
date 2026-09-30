import Foundation
import Observation

@MainActor @Observable
final class SelectiveRemoteCloudAccessCoordinator {
    let reference: SelectiveRemoteCloudAccessReference
    let client: SelectiveRemoteCloudAccessClient
    let session: CloudAccessSession
    private(set) var context: CloudAccessContext?
    private(set) var resource: CloudAccessResource?
    private(set) var members: [SelectiveRemoteCloudTeamMember] = []
    private(set) var groups: [CloudAccessGroup] = []
    private(set) var grants: [CloudAccessGrant] = []
    private(set) var who: [CloudAccessWho] = []
    private(set) var devices: [CloudAccessDevice] = []
    private(set) var effective: CloudAccessEffective?
    private(set) var selection: [CloudAccessRecipient] = []
    private(set) var mask = 1
    private(set) var preview: CloudAccessPreview?
    private(set) var impacts: [CloudAccessImpact] = []
    private(set) var affectedGrants: [CloudAccessAffectedGrant] = []
    private(set) var request: CloudAccessRequest?
    private(set) var memberCursor: UUID?
    private(set) var groupCursor: UUID?
    private(set) var grantCursor: UUID?
    private(set) var whoCursor: UUID?
    private(set) var deviceCursor: UUID?
    private(set) var subjectUserID: UUID?
    private(set) var subjectDeviceID: UUID?
    private(set) var busy = false
    private(set) var errorMessage: String?
    private(set) var committed = false
    private(set) var editingGrant: CloudAccessGrant?
    private(set) var editingKind: CloudAccessKind?
    private var generation = UUID()
    private var pickerGeneration = UUID()
    private var effectiveGeneration = UUID()
    private var previewGeneration = UUID()
    private var preparedAt: Date?
    private var idempotencyKey: String?
    private var memberSearch = ""
    private var groupSearch = ""
    private var seenMemberCursors = Set<UUID>()
    private var seenGroupCursors = Set<UUID>()
    private var seenPreviewCursors = Set<String>()
    private var previewCounts: CloudAccessCounts?
    private var impactIDs = Set<String>()
    private var affectedGrantIDs = Set<UUID>()
    private var completePreview = false
    private var authoritativePolicyLoaded = false
    private var sessionActive = true
    var canMutate: Bool { sessionActive && authoritativePolicyLoaded && context?.canMutate == true && (reference.kind == .vault || resource != nil) }
    var canCommit: Bool { canMutate && !busy && completePreview && preview != nil && preview?.nextCursor == nil && request != nil && preparedAt.map { Date().timeIntervalSince($0) < 60 } == true }
    var canRepreview: Bool { preview != nil && preview?.nextCursor == nil && request != nil && canMutate && !busy && !canCommit }
    var currentKind: CloudAccessKind { editingKind ?? reference.kind }

    init(reference: SelectiveRemoteCloudAccessReference, client: SelectiveRemoteCloudAccessClient, session: CloudAccessSession) {
        self.reference = reference; self.client = client; self.session = session
    }
    func invalidate() {
        generation = UUID(); pickerGeneration = UUID(); effectiveGeneration = UUID(); previewGeneration = UUID()
        clearPreview(); busy = false
    }
    func invalidateSession() {
        sessionActive = false
        invalidate()
        context = nil; resource = nil; members = []; groups = []; grants = []; who = []; devices = []; effective = nil
        selection = []; mask = 1; editingGrant = nil; editingKind = nil
        memberCursor = nil; groupCursor = nil; grantCursor = nil; whoCursor = nil; deviceCursor = nil
        subjectUserID = nil; subjectDeviceID = nil
        memberSearch = ""; groupSearch = ""
        seenMemberCursors = []; seenGroupCursors = []
        authoritativePolicyLoaded = false; errorMessage = nil; committed = false
    }
    private func clearPreview() {
        preview = nil; impacts = []; affectedGrants = []; request = nil; preparedAt = nil; idempotencyKey = nil; seenPreviewCursors = []
        previewCounts = nil; impactIDs = []; affectedGrantIDs = []; completePreview = false
    }
    private func invalidateDraft() { previewGeneration = UUID(); clearPreview(); busy = false; committed = false; errorMessage = nil }
    func setSelection(_ value: [CloudAccessRecipient]) {
        guard sessionActive else { return }
        guard value.count <= 20, Set(value).count == value.count, value.allSatisfy({ $0.id.isSelectiveRemoteCloudUUID }) else { errorMessage = CloudAccessError.invalidRequest.localizedDescription; return }
        selection = value; editingGrant = nil; editingKind = nil; mask = 1; invalidateDraft()
    }
    func toggleRecipient(_ value: CloudAccessRecipient) {
        var result = selection
        if let i = result.firstIndex(where: { $0.id == value.id && $0.kind == value.kind }) { result.remove(at: i) } else { result.append(value) }
        setSelection(result)
    }
    func setMask(_ value: Int) {
        guard sessionActive else { return }
        var normalized = value
        if currentKind == .credential && value & 4 != 0 { normalized |= 2 }
        guard (try? currentKind.validate(mask: normalized)) != nil else { return }
        mask = normalized; invalidateDraft()
    }
    func togglePermission(_ bit: Int, enabled: Bool) {
        var value = enabled ? mask | bit : mask & ~bit
        if currentKind == .credential && bit == 2 && !enabled { value &= ~4 }
        setMask(value)
    }
    func load() async {
        guard sessionActive else { return }
        invalidate(); let stamp = generation; busy = true; errorMessage = nil
        authoritativePolicyLoaded = false; editingGrant = nil; editingKind = nil; selection = []; mask = 1
        context = nil; resource = nil; grants = []; who = []; devices = []; effective = nil; subjectUserID = nil; subjectDeviceID = nil
        grantCursor = nil; whoCursor = nil; deviceCursor = nil
        do {
            let loaded = try await client.context(reference, session: session)
            guard stamp == generation else { return }; context = loaded
            // Registry operations are truthfully unavailable outside PREPARING.
            guard loaded.formatState == .preparing else { busy = false; return }
            if reference.kind != .vault {
                let row = try await client.getResource(reference, session: session)
                guard stamp == generation else { return }; resource = row
            }
            let page = try await client.grants(reference, session: session)
            guard stamp == generation else { return }; grants = page.rows; grantCursor = page.nextCursor
            if reference.kind != .vault {
                let page = try await client.whoHas(reference, session: session)
                guard stamp == generation else { return }; who = page.rows; whoCursor = page.nextCursor
            }
            authoritativePolicyLoaded = true; busy = false
            await loadRecipients(groups: false, search: "")
        } catch { guard stamp == generation else { return }; busy = false; authoritativePolicyLoaded = false; grants = []; who = []; effective = nil; grantCursor = nil; whoCursor = nil; errorMessage = error.localizedDescription }
    }
    func loadRecipients(groups useGroups: Bool, search: String, next: Bool = false) async {
        guard sessionActive else { return }
        guard search.count <= 120 else { return }
        pickerGeneration = UUID(); let stamp = pickerGeneration; let scope = generation
        do {
            if useGroups {
                let cursor = next && search == groupSearch ? groupCursor : nil
                if !next { seenGroupCursors = [] }
                if let cursor, !seenGroupCursors.insert(cursor).inserted { throw CloudAccessError.invalidResponse }
                let page = try await client.groups(teamID: reference.teamID, session: session, cursor: cursor, search: search)
                guard stamp == pickerGeneration, scope == generation else { return }; groups = page.rows; groupCursor = page.nextCursor; groupSearch = search
            } else {
                let cursor = next && search == memberSearch ? memberCursor : nil
                if !next { seenMemberCursors = [] }
                if let cursor, !seenMemberCursors.insert(cursor).inserted { throw CloudAccessError.invalidResponse }
                let page = try await client.members(teamID: reference.teamID, session: session, cursor: cursor, search: search)
                guard stamp == pickerGeneration, scope == generation else { return }; members = page.members; memberCursor = page.nextCursor; memberSearch = search
            }
        } catch { guard stamp == pickerGeneration, scope == generation else { return }; errorMessage = error.localizedDescription }
    }
    func loadMoreGrants() async {
        guard sessionActive else { return }
        guard let cursor = grantCursor else { return }; let stamp = generation
        do { let page = try await client.grants(reference, session: session, cursor: cursor); guard stamp == generation else { return }; guard page.nextCursor != cursor else { throw CloudAccessError.invalidResponse }; grants = page.rows; grantCursor = page.nextCursor }
        catch { guard stamp == generation else { return }; errorMessage = error.localizedDescription }
    }
    func loadMoreWho() async {
        guard sessionActive else { return }
        guard let cursor = whoCursor else { return }; let stamp = generation
        do { let page = try await client.whoHas(reference, session: session, cursor: cursor); guard stamp == generation else { return }; guard page.nextCursor != cursor else { throw CloudAccessError.invalidResponse }; who = page.rows; whoCursor = page.nextCursor }
        catch { guard stamp == generation else { return }; errorMessage = error.localizedDescription }
    }
    func selectSubject(_ id: UUID?) async {
        guard sessionActive else { return }
        effectiveGeneration = UUID(); let stamp = effectiveGeneration; let scope = generation
        subjectUserID = id; subjectDeviceID = nil; effective = nil; devices = []; deviceCursor = nil
        guard let id else { return }
        do { let page = try await client.devices(reference, subjectUserID: id, session: session); guard stamp == effectiveGeneration, scope == generation else { return }; devices = page.rows; deviceCursor = page.nextCursor }
        catch { guard stamp == effectiveGeneration, scope == generation else { return }; errorMessage = error.localizedDescription }
    }
    func loadMoreDevices() async {
        guard sessionActive else { return }
        guard let id = subjectUserID, let cursor = deviceCursor else { return }; let stamp = effectiveGeneration; let scope = generation
        do { let page = try await client.devices(reference, subjectUserID: id, session: session, cursor: cursor); guard stamp == effectiveGeneration, scope == generation else { return }; guard page.nextCursor != cursor else { throw CloudAccessError.invalidResponse }; devices = page.rows; deviceCursor = page.nextCursor }
        catch { guard stamp == effectiveGeneration, scope == generation else { return }; errorMessage = error.localizedDescription }
    }
    func selectDevice(_ id: UUID?) async {
        guard sessionActive else { return }
        effectiveGeneration = UUID(); let stamp = effectiveGeneration; let scope = generation
        subjectDeviceID = id; effective = nil
        guard let subject = subjectUserID, let id else { return }
        do { let value = try await client.effective(reference, subjectUserID: subject, subjectDeviceID: id, session: session); guard stamp == effectiveGeneration, scope == generation else { return }; effective = value }
        catch { guard stamp == effectiveGeneration, scope == generation else { return }; errorMessage = error.localizedDescription }
    }
    func edit(_ grant: CloudAccessGrant) async {
        guard sessionActive else { return }
        guard canMutate, !busy, grants.contains(where: { $0.id == grant.id && $0.version == grant.version }) else { errorMessage = CloudAccessError.previewRequired.localizedDescription; return }
        invalidateDraft(); let stamp = previewGeneration; let scope = generation
        editingGrant = nil; editingKind = nil
        do {
            let kind: CloudAccessKind
            if grant.target_kind == .vault { guard grant.target_id == reference.vaultID else { throw CloudAccessError.scopeMismatch }; kind = .vault }
            else {
                let row = try await client.getResource(reference, resourceID: grant.target_id, session: session)
                guard stamp == previewGeneration, scope == generation else { return }
                guard (grant.target_kind == .folder) == (row.policyKind == .folder) else { throw CloudAccessError.scopeMismatch }
                kind = row.policyKind
            }
            _ = try kind.validate(mask: grant.permission_mask)
            guard stamp == previewGeneration, scope == generation else { return }; editingGrant = grant; editingKind = kind; mask = grant.permission_mask
        } catch { guard stamp == previewGeneration, scope == generation else { return }; errorMessage = error.localizedDescription }
    }
    func previewSelection() async {
        guard sessionActive else { return }
        do {
            _ = try currentKind.validate(mask: mask)
            if let grant = editingGrant { await prepare(.init(changes: [.change(grantID: grant.id, expectedVersion: grant.version.value, permissionMask: mask)])); return }
            guard !selection.isEmpty else { throw CloudAccessError.invalidRequest }
            let target: CloudAccessTargetKind = reference.kind == .vault ? .vault : reference.kind == .folder ? .folder : .resource
            await prepare(.init(changes: selection.map { .create(principalKind: $0.kind, principalID: $0.id, targetKind: target, targetID: reference.resourceID, permissionMask: mask) }))
        } catch { errorMessage = error.localizedDescription }
    }
    func revoke(_ grants: [CloudAccessGrant]) async {
        guard sessionActive else { return }
        guard canMutate, !busy, grants.allSatisfy({ candidate in self.grants.contains(where: { $0.id == candidate.id && $0.version == candidate.version }) }) else { errorMessage = CloudAccessError.previewRequired.localizedDescription; return }
        await prepare(.init(changes: grants.map { .revoke(grantID: $0.id, expectedVersion: $0.version.value) }))
    }
    private func acceptPreviewPage(_ page: CloudAccessPreview, group: Bool) throws {
        let counts = page.counts
        guard (0...1000).contains(counts.pairs), (0...counts.pairs).contains(counts.widened), (0...counts.pairs).contains(counts.lost),
              !group || counts.affectedGrants.map({ (0...1000).contains($0) }) == true,
              group || counts.affectedGrants == nil else { throw CloudAccessError.invalidResponse }
        if let previewCounts { guard counts == previewCounts else { throw CloudAccessError.previewRequired } }
        else { previewCounts = counts }
        let grants = page.affectedGrants ?? []
        guard group || grants.isEmpty else { throw CloudAccessError.invalidResponse }
        for detail in page.details { guard impactIDs.insert(detail.id).inserted else { throw CloudAccessError.invalidResponse } }
        for grant in grants { guard affectedGrantIDs.insert(grant.id).inserted else { throw CloudAccessError.invalidResponse } }
        guard impactIDs.count <= counts.pairs, affectedGrantIDs.count <= (counts.affectedGrants ?? 0) else { throw CloudAccessError.invalidResponse }
        if page.nextCursor == nil {
            guard impactIDs.count == counts.pairs, affectedGrantIDs.count == (counts.affectedGrants ?? 0) else { throw CloudAccessError.invalidResponse }
            completePreview = true
        } else {
            guard !page.details.isEmpty || !grants.isEmpty else { throw CloudAccessError.invalidResponse }
            completePreview = false
        }
    }
    func prepare(_ value: CloudAccessRequest) async {
        guard sessionActive else { return }
        invalidateDraft(); guard canMutate else { errorMessage = CloudAccessError.previewRequired.localizedDescription; return }
        if value.group != nil && context?.groupMutationAvailable != true { errorMessage = CloudAccessError.service(409, "crypto_publication_required").localizedDescription; return }
        let stamp = previewGeneration; let scope = generation; busy = true
        do {
            let page = try await client.preview(reference, request: value, session: session)
            guard stamp == previewGeneration, scope == generation else { return }
            try acceptPreviewPage(page, group: value.group != nil)
            preview = page; impacts = page.details; affectedGrants = page.affectedGrants ?? []; request = value; preparedAt = Date(); idempotencyKey = UUID().canonicalCloudString; busy = false
        } catch { guard stamp == previewGeneration, scope == generation else { return }; busy = false; clearPreview(); errorMessage = error.localizedDescription }
    }
    func repreview() async {
        guard sessionActive else { return }
        guard preview != nil, canMutate, !busy, let request else { return }
        await prepare(request)
    }
    func nextPreviewPage() async {
        guard sessionActive else { return }
        guard let cursor = preview?.nextCursor, let request, let previous = preview else { return }
        let stamp = previewGeneration; let scope = generation; busy = true
        do {
            guard seenPreviewCursors.insert(cursor).inserted else { throw CloudAccessError.invalidResponse }
            let page = try await client.preview(reference, request: request, session: session, cursor: cursor)
            guard stamp == previewGeneration, scope == generation else { return }
            guard page.snapshotID == previous.snapshotID else { throw CloudAccessError.previewRequired }
            try acceptPreviewPage(page, group: request.group != nil)
            preview = page; impacts += page.details; affectedGrants += page.affectedGrants ?? []; busy = false
        } catch { guard stamp == previewGeneration, scope == generation else { return }; busy = false; clearPreview(); errorMessage = error.localizedDescription }
    }
    func commit() async -> CloudAccessCommit? {
        guard sessionActive else { return nil }
        guard canCommit, let request, let preview, let key = idempotencyKey else { errorMessage = CloudAccessError.previewRequired.localizedDescription; return nil }
        let stamp = previewGeneration; let scope = generation; busy = true
        do {
            let result = try await client.commit(reference, request: request, token: preview.token, idempotencyKey: key, session: session)
            guard stamp == previewGeneration, scope == generation else { return nil }
            // A validated receipt is final even if the subsequent read fails.
            // load clears draft/version/device state and gates writes until all policy reads succeed.
            await load()
            guard sessionActive else { return nil }
            committed = true
            if let refreshError = errorMessage {
                authoritativePolicyLoaded = false
                errorMessage = CloudAccessLocalization.text("Изменение применено. Не удалось обновить доступ; обновите данные перед следующим изменением.", "Change committed. Access could not be refreshed; refresh before another change.") + " " + refreshError
            }
            return result
        } catch { guard stamp == previewGeneration, scope == generation else { return nil }; busy = false; clearPreview(); errorMessage = error.localizedDescription; return nil }
    }
}
