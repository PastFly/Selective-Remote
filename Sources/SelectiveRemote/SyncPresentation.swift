import Combine
import Foundation

enum SyncScope: Equatable, Sendable {
    case personal
    case team
}

enum SyncLifecycle: Equatable, Sendable {
    case security, error, conflict, offline, syncing, pending, synced, unknown
    case signedOut, locked, disabled

    var priority: Int {
        switch self {
        case .security: 7
        case .error: 6
        case .conflict: 5
        case .offline: 4
        case .syncing: 3
        case .pending: 2
        case .synced: 1
        case .unknown, .signedOut, .locked, .disabled: 0
        }
    }

    func title(english: Bool) -> String {
        switch self {
        case .security: english ? "Action required" : "Требуется действие"
        case .error: english ? "Sync failed" : "Ошибка синхронизации"
        case .conflict: english ? "Conflict needs review" : "Конфликт требует проверки"
        case .offline: english ? "Offline" : "Нет сети"
        case .syncing: english ? "Checking…" : "Проверка…"
        case .pending: english ? "Changes awaiting confirmation" : "Изменения ожидают подтверждения"
        case .synced: english ? "Confirmed on this Mac" : "Подтверждено на этом Mac"
        case .unknown: english ? "Status unknown" : "Состояние неизвестно"
        case .signedOut: english ? "Sign in required" : "Требуется вход"
        case .locked: english ? "Unlock required" : "Требуется разблокировка"
        case .disabled: english ? "Sync disabled" : "Синхронизация выключена"
        }
    }
}

enum SyncIssue: Equatable, Sendable {
    case vaultLocked, sessionExpired, keyOrWrapperMissing, rotationRequired
    case conflict, transientFailure, unknownFailure

    static func classifyPersonal(_ error: Error) -> Self {
        if let error = error as? SelectiveRemotePersonalVaultError {
            switch error {
            case .uploadConflict, .remoteVaultNotEmpty: return .conflict
            case .invalidEnvelope, .cryptoFailure: return .keyOrWrapperMissing
            case .invalidRecoveryPhrase, .emptyLocalVault,
                 .legacyMigrationRequiresLocalData: return .unknownFailure
            }
        }
        if error as? SelectiveRemoteCloudError == .authenticationRequired {
            return .sessionExpired
        }
        return .unknownFailure
    }
}

enum SyncMaterialization: Equatable, Sendable {
    case unknown, confirmed, hiddenFailClosed
}

struct SyncScopeSnapshot: Equatable, Sendable {
    let scope: SyncScope
    let lifecycle: SyncLifecycle
    let issue: SyncIssue?
    let lastConfirmedAt: Date?
    let appliedRevision: Int?
    let observedRemoteRevision: Int?
    let observedAt: Date?
    let pendingLocalChanges: Bool?
    let materialization: SyncMaterialization
    let checkedVaultCount: Int?

    init(scope: SyncScope, lifecycle: SyncLifecycle, issue: SyncIssue?,
         lastConfirmedAt: Date?, appliedRevision: Int?,
         observedRemoteRevision: Int?, observedAt: Date?,
         pendingLocalChanges: Bool?, materialization: SyncMaterialization,
         checkedVaultCount: Int? = nil) {
        self.scope = scope
        self.lifecycle = lifecycle
        self.issue = issue
        self.lastConfirmedAt = lastConfirmedAt
        self.appliedRevision = appliedRevision
        self.observedRemoteRevision = observedRemoteRevision
        self.observedAt = observedAt
        self.pendingLocalChanges = pendingLocalChanges
        self.materialization = materialization
        self.checkedVaultCount = checkedVaultCount
    }

    static func unknown(_ scope: SyncScope) -> Self {
        .init(scope: scope, lifecycle: .unknown, issue: nil, lastConfirmedAt: nil,
              appliedRevision: nil, observedRemoteRevision: nil, observedAt: nil,
              pendingLocalChanges: nil, materialization: .unknown,
              checkedVaultCount: nil)
    }
}

@MainActor
final class SyncPresentationStore: ObservableObject {
    static let shared = SyncPresentationStore()

    @Published private(set) var personal = SyncScopeSnapshot.unknown(.personal)
    @Published private(set) var team = SyncScopeSnapshot.unknown(.team)
    private(set) var generation = UUID()
    private var accountKey: String?
    private var activeTeamCycle: (token: UUID, generation: UUID)?

    var aggregate: SyncLifecycle {
        let visible = [personal.lifecycle, team.lifecycle].filter {
            ![.signedOut, .locked, .disabled].contains($0)
        }
        guard !visible.isEmpty else { return personal.lifecycle }
        let highest = visible.max { $0.priority < $1.priority } ?? .unknown
        return highest == .synced && !visible.allSatisfy({ $0 == .synced })
            ? .unknown : highest
    }

    func setAccount(endpoint: String?, deviceID: String?) {
        let next = Self.accountKey(endpoint: endpoint, deviceID: deviceID)
        guard next != accountKey else { return }
        accountKey = next
        invalidateSession()
    }

    func invalidateSession() {
        generation = UUID()
        activeTeamCycle = nil
        personal = .unknown(.personal)
        team = .unknown(.team)
    }

    func matchesAccount(endpoint: String, deviceID: String) -> Bool {
        accountKey != nil && accountKey == Self.accountKey(endpoint: endpoint, deviceID: deviceID)
    }

    private static func accountKey(endpoint: String?, deviceID: String?) -> String? {
        guard let endpoint, let deviceID else { return nil }
        let normalized = (try? SelectiveRemoteCloudEndpoint.normalized(endpoint))?.absoluteString
            ?? endpoint
        return "\(normalized)|\(deviceID.lowercased())"
    }

    func begin(_ scope: SyncScope) {
        update(scope, lifecycle: .syncing, issue: nil, pending: nil)
    }

    func recordPersonalSuccess(revision: Int, generation expectedGeneration: UUID? = nil) {
        guard expectedGeneration == nil || expectedGeneration == generation else { return }
        let now = Date()
        personal = .init(scope: .personal, lifecycle: .synced, issue: nil,
                         lastConfirmedAt: now, appliedRevision: revision,
                         observedRemoteRevision: revision, observedAt: now,
                         pendingLocalChanges: false, materialization: .confirmed,
                         checkedVaultCount: nil)
    }

    func recordPersonalFailure(_ issue: SyncIssue) {
        update(.personal, lifecycle: issue == .conflict ? .conflict :
               [.vaultLocked, .sessionExpired, .keyOrWrapperMissing, .rotationRequired].contains(issue)
                    ? .security : .error,
               issue: issue, pending: personal.pendingLocalChanges)
    }

    func recordPersonalUnknown() {
        update(.personal, lifecycle: .unknown, issue: nil,
               pending: personal.pendingLocalChanges)
    }

    func beginTeamCycle(token: UUID) {
        activeTeamCycle = (token, generation)
        begin(.team)
    }

    func completeTeamCycle(_ report: SelectiveRemoteTeamVaultAutoSyncReport,
                           token: UUID) {
        guard activeTeamCycle?.token == token,
              activeTeamCycle?.generation == generation else { return }
        activeTeamCycle = nil
        recordTeamReport(report)
    }

    func failTeamCycle(token: UUID) {
        guard activeTeamCycle?.token == token,
              activeTeamCycle?.generation == generation else { return }
        activeTeamCycle = nil
        recordTeamFailure()
    }

    func recordTeamReport(_ report: SelectiveRemoteTeamVaultAutoSyncReport) {
        let lifecycle: SyncLifecycle
        let issue: SyncIssue?
        if report.rotations > 0 || report.pendingWrappers > 0 {
            lifecycle = .security
            issue = report.rotations > 0 ? .rotationRequired : .keyOrWrapperMissing
        } else if report.failures > 0 {
            lifecycle = .error
            issue = .unknownFailure
        } else if report.conflicts > 0 {
            lifecycle = .conflict
            issue = .conflict
        } else if report.scannedVaults > 0 &&
                  report.synchronizedVaults + report.uploadedVaults + report.emptyVaults
                    == report.scannedVaults {
            lifecycle = .synced
            issue = nil
        } else {
            lifecycle = .unknown
            issue = nil
        }
        let now = Date()
        team = .init(scope: .team, lifecycle: lifecycle, issue: issue,
                     lastConfirmedAt: lifecycle == .synced ? now : team.lastConfirmedAt,
                     appliedRevision: nil,
                     observedRemoteRevision: nil, observedAt: now,
                     pendingLocalChanges: lifecycle == .synced ? false : nil,
                     materialization: report.pendingWrappers > 0 || report.rotations > 0
                        ? .hiddenFailClosed : lifecycle == .synced ? .confirmed : .unknown,
                     checkedVaultCount: report.scannedVaults > 0 ? report.scannedVaults : nil)
    }

    func recordTeamFailure(_ issue: SyncIssue = .unknownFailure) {
        update(.team, lifecycle: .error, issue: issue, pending: nil)
    }

    func setPrerequisite(_ scope: SyncScope, lifecycle: SyncLifecycle) {
        guard [.signedOut, .locked, .disabled, .unknown].contains(lifecycle) else { return }
        update(scope, lifecycle: lifecycle, issue: nil, pending: nil)
    }

    func retry(_ scope: SyncScope) {
        let snapshot = scope == .personal ? personal : team
        guard snapshot.lifecycle != .syncing else { return }
        begin(scope)
        NotificationCenter.default.post(
            name: scope == .personal ? .selectiveRemotePersonalVaultSyncNow :
                .selectiveRemoteTeamVaultSyncNow,
            object: nil
        )
    }

    private func update(_ scope: SyncScope, lifecycle: SyncLifecycle,
                        issue: SyncIssue?, pending: Bool?) {
        let old = scope == .personal ? personal : team
        let next = SyncScopeSnapshot(scope: scope, lifecycle: lifecycle, issue: issue,
                                     lastConfirmedAt: old.lastConfirmedAt,
                                     appliedRevision: old.appliedRevision,
                                     observedRemoteRevision: old.observedRemoteRevision,
                                     observedAt: Date(), pendingLocalChanges: pending,
                                     materialization: old.materialization,
                                     checkedVaultCount: old.checkedVaultCount)
        if scope == .personal { personal = next } else { team = next }
    }
}
