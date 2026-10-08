import AppKit
import CryptoKit
import Foundation
import SwiftUI
import XCTest
@testable import SelectiveRemote

final class StagingNativeGUIHostTests: XCTestCase {
    @MainActor func testInteractiveHost() async throws {
        guard ProcessInfo.processInfo.environment["SELECTIVE_REMOTE_NATIVE_GUI_MANIFEST"] != nil else {
            throw XCTSkip("Explicit protected native GUI manifest required; no state opened")
        }
        guard let loaded = try StagingNativeManifest.loadSnapshot(path: ProcessInfo.processInfo.environment["SELECTIVE_REMOTE_NATIVE_GUI_MANIFEST"]),
              let phase = ProcessInfo.processInfo.environment["SELECTIVE_REMOTE_NATIVE_GUI_PHASE"], ["first", "recover", "resume"].contains(phase)
        else { throw StagingRealProbeError.configuration }
        let manifest = loaded.manifest, directory = loaded.directory
        let invocation = try StagingNativeInvocation.load(path: ProcessInfo.processInfo.environment["SELECTIVE_REMOTE_NATIVE_GUI_INVOCATION"], manifest: manifest, phase: phase)
        let runLock = try StagingNativeRunLock(directory: directory)
        defer { withExtendedLifetime(runLock) {} }
        let model = try StagingNativeGUIModel(loaded: loaded, phase: phase, invocation: invocation)
        try await StagingNativeWindow.run(model: model)
    }

    @available(macOS, deprecated: 14)
    @MainActor func testLocalWindowSmoke() async throws {
        guard ProcessInfo.processInfo.environment["SELECTIVE_REMOTE_NATIVE_GUI_LOCAL_SMOKE"] == "1" else {
            throw XCTSkip("Local native GUI smoke is explicit opt-in")
        }
        // This run uses no manifest, account, identity, session, filesystem or Keychain adapter.
        let app = NSApplication.shared
        let applicationDelegate = StagingNativeApplicationDelegate()
        app.delegate = applicationDelegate
        ProcessInfo.processInfo.disableAutomaticTermination("isolated native GUI host")
        defer { withExtendedLifetime(applicationDelegate) {}; app.delegate = nil; ProcessInfo.processInfo.enableAutomaticTermination("isolated native GUI host") }
        _ = app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "TEST ONLY · Native GUI local smoke"
        window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 18) {
            Text("TEST ONLY · Native isolated GUI host").font(.title2)
            Text("Local event-loop verification · no account / no network")
            SecureField("Test password / Тестовый пароль", text: .constant(""))
            Text("nativeGuiTestHost=true · productGuiAcceptance=false").font(.caption)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        app.finishLaunching()
        for _ in 0..<60 { StagingNativeWindow.pump(); try await Task.sleep(for: .milliseconds(16)) }
        let eventLoop = window.isVisible && window.contentView != nil
        if let pixels = CGWindowListCreateImage(.null, .optionIncludingWindow,
            CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
            let bitmap = NSBitmapImageRep(cgImage: pixels)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/native-gui-local-smoke.png"))
        }
        window.orderOut(nil)
        XCTAssertTrue(eventLoop)
        let binary = try StagingNativeExecutableIdentity.current()
        print("NATIVE_GUI_LOCAL_SMOKE eventLoop=true nativeGuiTestHost=true productGuiAcceptance=false pid=\(getpid()) executableSHA256=\(binary.executableSHA256) testBundleSHA256=\(binary.testBundleSHA256)")
    }
}

@MainActor
private enum StagingNativeWindow {
    static func pump() {
        let app = NSApplication.shared
        while let event = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            app.sendEvent(event)
        }
        app.updateWindows()
    }
    static func run(model: StagingNativeGUIModel) async throws {
        let app = NSApplication.shared
        let applicationDelegate = StagingNativeApplicationDelegate()
        app.delegate = applicationDelegate
        ProcessInfo.processInfo.disableAutomaticTermination("isolated native GUI host")
        defer { withExtendedLifetime(applicationDelegate) {}; app.delegate = nil; ProcessInfo.processInfo.enableAutomaticTermination("isolated native GUI host") }
        _ = app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 740),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "TEST ONLY · Native isolated GUI · " + model.phase
        window.contentView = NSHostingView(rootView: StagingNativeGUIView(model: model))
        window.minSize = NSSize(width: 740, height: 620)
        let delegate = StagingNativeWindowDelegate { model.cancel() }
        window.delegate = delegate
        model.finish = {}
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        app.finishLaunching()
        // The test runner owns MainActor. Suspend between native event dispatches;
        // a nested blocking NSApplication.run() would starve GUI Tasks in the test runner.
        while !model.shouldExit {
            pump()
            try await Task.sleep(for: .milliseconds(16))
        }
        window.orderOut(nil)
        withExtendedLifetime(delegate) {}
        model.network.invalidateAndCancel()
        guard model.completed else { throw StagingRealProbeError.acceptance }
    }
}

@MainActor
private final class StagingNativeApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateCancel }
}

@MainActor
private final class StagingNativeWindowDelegate: NSObject, NSWindowDelegate {
    let close: () -> Void
    init(close: @escaping () -> Void) { self.close = close }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}

@MainActor
private final class StagingNativeGUIModel: ObservableObject {
    @Published var password = ""
    @Published var fingerprint = ""
    @Published var checkpointText = ""
    @Published var publicKeyConfirmed = false
    @Published var status = "Generate a new native identity / Создать отдельное устройство"
    @Published var busy = false
    @Published var identity: SelectiveRemoteTeamDeviceIdentity?
    @Published var loggedIn = false
    @Published var admitted = false
    @Published var rows: [String] = []
    @Published var offlineVerified = false
    @Published var loaded = false
    @Published var verification: SelectiveRemotePublisherVerification?
    @Published var publisherFingerprint = ""
    let phase: String
    let directory: URL
    var manifest: StagingNativeManifest
    let deviceID: UUID
    let stores: StagingNativeStores
    let identities: SelectiveRemoteTeamDeviceIdentityManager
    let client: SelectiveRemoteCloudAPIClient
    let publicationStore: SelectiveRemoteVaultPublicationStore
    let network: URLSession
    let processID = UUID()
    var prior: StagingNativeEvidence?
    var coordinator: SelectiveRemoteVaultPublicationCoordinator?
    var completed = false
    var shouldExit = false
    var finish: (() -> Void)?
    private var activeTask: Task<Void, Never>?
    private var acceptance = StagingNativeAcceptance()
    private var manifestSHA256: String
    private var checkpoint: StagingNativeCheckpoint
    private let invocation: StagingNativeInvocation

    init(loaded: StagingNativeLoadedManifest, phase: String, invocation: StagingNativeInvocation) throws {
        let manifest = loaded.manifest, directory = loaded.directory
        self.manifest = manifest; self.directory = directory; self.phase = phase
        self.manifestSHA256 = loaded.sha256; self.invocation = invocation
        let storage = StagingNativeKeychain(service: manifest.service, accountID: manifest.accountID)
        if phase == "first" {
            guard !FileManager.default.fileExists(atPath: directory.appending(path: "first.json").path) else { throw StagingRealProbeError.protection }
            checkpoint = try StagingNativeCheckpoint.reserve(manifest: manifest, storage: storage, processID: processID)
        } else {
            checkpoint = try StagingNativeCheckpoint.recover(manifest: manifest, storage: storage)
        }
        deviceID = checkpoint.deviceID
        stores = StagingNativeStores(endpoint: manifest.endpoint, accountID: manifest.accountID, deviceID: deviceID, storage: storage)
        identities = SelectiveRemoteTeamDeviceIdentityManager(store: stores)
        let restoredDeviceID = checkpoint.deviceID
        let raw = try stores.privateKeyRepresentation(for: manifest.endpoint, deviceID: restoredDeviceID)
        let restoredIdentity: SelectiveRemoteTeamDeviceIdentity?
        if let raw { restoredIdentity = try SelectiveRemoteTeamDeviceIdentity(deviceID: restoredDeviceID, privateKeyRepresentation: raw) }
        else { restoredIdentity = nil }
        identity = restoredIdentity
        if phase == "resume" {
            let data = try StagingNativeProtectedFile.read(directory.appending(path: "first.json").path)
            let previous = try JSONDecoder().decode(StagingNativeEvidence.self, from: data)
            guard previous.formatVersion == 2, previous.status == "PASS", ["first", "recover"].contains(previous.phase),
                  previous.runID == manifest.runID, previous.accountID == manifest.accountID,
                  previous.teamID == manifest.teamID, previous.vaultID == manifest.vaultID,
                  previous.deviceID == deviceID, previous.generationID == manifest.generationID,
                  previous.manifestSHA256 == loaded.sha256, previous.sequence == manifest.sequence,
                  previous.headerHash == manifest.headerHash, previous.binary == invocation.binary,
                  previous.launchNonce != invocation.nonce, previous.nativeGuiTestHost, !previous.productGuiAcceptance,
                  previous.networkReloadVerified, previous.secretsVerified == manifest.secrets.count,
                  previous.publicKey == restoredIdentity?.publicKey, previous.processID != processID, previous.pid != getpid(),
                  try stores.token(for: manifest.endpoint) != nil,
                  try stores.pin(endpoint: manifest.endpoint, accountID: manifest.accountID) == previous.ownPin
            else { throw StagingRealProbeError.protection }
            prior = previous; loggedIn = true
        }
        let cacheDirectory = directory.appending(path: "native-cache")
        if phase == "first" {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try StagingRealProbeConfig.privateDirectory(cacheDirectory)
        for file in try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else { throw StagingRealProbeError.permissions }
        }
        publicationStore = try .init(directory: cacheDirectory, protected: stores)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
        network = URLSession(configuration: config, delegate: StagingRealNoRedirect(), delegateQueue: nil)
        let store = publicationStore
        client = SelectiveRemoteCloudAPIClient(session: network, tokenStore: stores, publicationStore: { store })
        if phase == "resume" { status = "Reopened native identity. Verify offline cache before HTTPS / Проверить кэш до HTTPS" }
        if phase == "recover" { status = "Original native checkpoint reopened. Revalidate persisted state / Проверить сохранённое устройство" }
    }
    private func saveCheckpoint(_ stage: String) throws {
        guard let identity else { throw StagingRealProbeError.protection }
        let order = ["reserved", "identity", "login", "approval", "admission", "materialized"]
        let retained = (order.firstIndex(of: checkpoint.stage) ?? 0) > (order.firstIndex(of: stage) ?? 0) ? checkpoint.stage : stage
        checkpoint = checkpoint.advanced(stage: retained, publicKey: identity.publicKey,
            pin: try stores.pin(endpoint: manifest.endpoint, accountID: manifest.accountID))
        try checkpoint.save(storage: stores.storage)
    }
    private func invalidateAcceptance() {
        if let attempt = acceptance.attemptID { acceptance.fail(attempt) }
        loaded = false; rows = []
    }
    func revalidateRecovery() async throws {
        guard phase == "recover", identity != nil else { throw StagingRealProbeError.protection }
        invalidateAcceptance()
        guard try stores.token(for: manifest.endpoint) != nil else {
            status = "Original key retained. Sign in to the same approved account / Войти в тот же аккаунт"; return
        }
        let team = try await validateScope(requireLegacyVault: checkpoint.recoveryRequiresLegacyVault)
        loggedIn = true
        let inspection = try await trust().inspect()
        if ["admission", "materialized"].contains(checkpoint.stage) {
            guard inspection.phase == .certified, let raw = try stores.read("admission"), let identity else { throw StagingRealProbeError.trust }
            let expectation = try JSONDecoder().decode(StagingNativeAdmissionExpectation.self, from: raw)
            guard expectation.runID == manifest.runID, expectation.accountID == manifest.accountID,
                  expectation.teamID == team.id, expectation.vaultID == manifest.vaultID,
                  expectation.membershipID == team.membershipID, expectation.membershipEpoch == team.membershipEpoch,
                  expectation.deviceID == deviceID, expectation.publicKey == identity.publicKey else { throw StagingRealProbeError.scope }
            admitted = true
            if checkpoint.stage == "materialized" {
                let cached = try await reader().offline()
                guard cached.readerPublicKey == identity.publicKey else { throw StagingRealProbeError.protection }
                _ = try cached.materializedSnapshot() // Recovery check only; fresh HTTPS is still required for Finish.
            }
        }
        try write(status: "RECOVERY_REVALIDATED", name: "public.json")
        status = "Original identity/session/trust reopened; continue protocol or fresh HTTPS / Продолжить проверку"
    }
    private func trust() -> SelectiveRemoteCloudDeviceTrustCoordinator {
        .init(endpoint: manifest.endpoint, client: client, accountID: manifest.accountID,
              deviceID: deviceID, local: stores, identities: identities)
    }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        activeTask = Task {
            defer { busy = false; activeTask = nil }
            do { try await action() }
            catch { password = ""; invalidateAcceptance(); status = "Step failed safely. Check public test prerequisites / Шаг не выполнен" }
        }
    }
    func generate() async throws {
        guard phase != "resume", identity == nil else { throw StagingRealProbeError.scope }
        identity = try await identities.identity(endpoint: manifest.endpoint, deviceID: deviceID)
        try saveCheckpoint("identity")
        try write(status: "IDENTITY_READY", name: "public.json")
        status = "Confirm public key fingerprint in the custodian browser / Подтвердить отпечаток в браузере"
    }
    func login() async throws {
        guard phase != "resume", let identity, publicKeyConfirmed else { throw StagingRealProbeError.scope }
        let transient = password; password = ""
        let user = try await client.login(endpoint: manifest.endpoint, email: manifest.email,
            password: transient, device: .thisMac(id: deviceID, publicKey: identity.publicKey))
        guard user.id == manifest.accountID else {
            try stores.removeToken(for: manifest.endpoint); throw StagingRealProbeError.scope
        }
        try saveCheckpoint("login")
        loggedIn = true; status = "Login complete. Pair using independently confirmed root/checkpoint / Подтвердите корень"
        try write(status: "LOGIN_READY", name: "public.json")
    }
    func pair() async throws {
        guard loggedIn, phase != "resume", fingerprint == manifest.rootFingerprint,
              checkpointText == manifest.checkpointDigest else { throw StagingRealProbeError.trust }
        let inspection = try await trust().inspect()
        if inspection.phase == .pairingRequired { _ = try await trust().pair(fingerprint: fingerprint, checkpointDigest: checkpointText) }
        try await trust().requestApproval()
        try saveCheckpoint("approval")
        try write(status: "APPROVAL_REQUESTED", name: "public.json")
        status = "Custodian: offer challenge, then click Answer / Куратор: предложить challenge"
    }
    func answer() async throws {
        let requests = try await client.deviceTrustRequests(endpoint: manifest.endpoint)
        guard let request = requests.first(where: { $0.deviceID == deviceID && $0.status == "challenged" }) else { throw StagingRealProbeError.trust }
        try await trust().answer(request)
        try write(status: "CHALLENGE_ANSWERED", name: "public.json")
        status = "Custodian: finish certificate approval and Team device admission before migration / Завершить допуск"
    }
    private func validateScope(requireLegacyVault: Bool = false) async throws -> SelectiveRemoteCloudTeam {
        try await manifest.authorizedTeam(client: client, stores: stores, identity: identity, requireLegacyVault: requireLegacyVault)
    }
    func verifyAdmission() async throws {
        guard phase != "resume", let identity, try await trust().inspect().phase == .certified else { throw StagingRealProbeError.trust }
        let team = try await validateScope(requireLegacyVault: true)
        let expectation = try StagingNativeAdmissionExpectation.load(directory: directory, manifest: manifest,
            deviceID: deviceID, publicKey: identity.publicKey)
        guard expectation.membershipID == team.membershipID, expectation.membershipEpoch == team.membershipEpoch
        else { throw StagingRealProbeError.scope }
        // Eligibility is independent native HTTPS evidence; explicit admission is Browser custodian evidence.
        let devices = try await client.teamKeyDevices(endpoint: manifest.endpoint, teamID: manifest.teamID, vaultID: manifest.vaultID)
        guard devices.contains(where: { $0.deviceID == deviceID && $0.publicKey == identity.publicKey &&
            $0.membershipID == expectation.membershipID && $0.membershipEpoch == expectation.membershipEpoch })
        else { throw StagingRealProbeError.trust }
        try stores.save(JSONEncoder().encode(expectation), key: "admission")
        admitted = true
        try saveCheckpoint("admission")
        try write(status: "TEAM_ADMISSION_EXPECTATION_RECORDED", name: "public.json")
        status = "Browser admission expectation recorded; native eligibility verified. Custodian must prove admission before migration / Ожидание допуска записано"
    }
    func refreshExpectations() throws {
        let path = ProcessInfo.processInfo.environment["SELECTIVE_REMOTE_NATIVE_GUI_MANIFEST"]
        guard let next = try StagingNativeManifest.loadSnapshot(path: path), next.directory == directory,
              next.manifest.runID == manifest.runID, next.manifest.accountID == manifest.accountID,
              next.manifest.email == manifest.email, next.manifest.approvedRuntimeConfigPath == manifest.approvedRuntimeConfigPath,
              next.manifest.teamID == manifest.teamID, next.manifest.vaultID == manifest.vaultID,
              next.manifest.teamName == manifest.teamName, next.manifest.vaultName == manifest.vaultName,
              next.manifest.endpoint == manifest.endpoint, next.manifest.rootFingerprint == manifest.rootFingerprint
        else { throw StagingRealProbeError.scope }
        manifest = next.manifest; manifestSHA256 = next.sha256
    }
    private func reader() async throws -> SelectiveRemoteVaultPublicationCoordinator {
        if let coordinator { return coordinator }
        guard let identity, let token = try stores.token(for: manifest.endpoint),
              try stores.read("admission") != nil else { throw StagingRealProbeError.protection }
        guard let session = try stores.isolatedPublicationSession(endpoint: manifest.endpoint, token: token, deviceID: deviceID)
        else { throw StagingRealProbeError.protection }
        let stores = stores
        let reader = SelectiveRemoteVaultPublicationCoordinator(scope: manifest.scope(deviceID: deviceID), session: session,
            remote: client, identity: identity, store: publicationStore,
            ownPin: { try stores.pin(endpoint: $0, accountID: $1) },
            advanceOwnPin: { try stores.advance(endpoint: $0, expected: $1, next: $2) },
            detachPresentation: { _, _, _ in })
        coordinator = reader; return reader
    }
    private func check(_ cache: SelectiveRemotePublicationCache, stale: Bool, expected manifest: StagingNativeManifest) throws -> [String] {
        let h = try SelectiveRemoteVaultPublicationV1.headerPayload(cache.header)
        guard cache.scope == manifest.scope(deviceID: deviceID), cache.stale == stale,
              cache.headerHash == manifest.headerHash, cache.readerPublicKey == identity?.publicKey,
              h["generationID"] == .string(manifest.generationID.canonicalCloudString),
              h["sequence"] == .number(Double(manifest.sequence)),
              try publicationStore.highWater(scope: cache.scope) == .init(sequence: manifest.sequence, hash: manifest.headerHash),
              let admission = try stores.read("admission") else { throw StagingRealProbeError.acceptance }
        let member = try JSONDecoder().decode(StagingNativeAdmissionExpectation.self, from: admission)
        let subject = try cache.subject.publicationObject()
        guard subject["membershipID"] == .string(member.membershipID.canonicalCloudString),
              subject["membershipEpoch"] == .number(Double(member.membershipEpoch)) else { throw StagingRealProbeError.trust }
        let snapshot = try cache.materializedSnapshot()
        let hosts = try SelectiveRemoteTeamHostMaterializer.materialize(snapshot)
        let snippets = try SelectiveRemoteTeamSnippetMaterializer.materialize(snapshot)
        let credentials = try cache.credentials(), forwardings = try cache.forwardings(), folders = try cache.folders()
        guard StagingRealProbeConfig.Counts(hosts: hosts.count, snippets: snippets.count, credentials: credentials.count,
            forwardings: forwardings.count, folders: folders.count) == manifest.counts else { throw StagingRealProbeError.acceptance }
        return hosts.map { "Host · " + $0.address } + snippets.map { "Snippet · " + $0.title } + credentials.map { "Credential · " + $0.title } + forwardings.map { "Forwarding · " + $0.title } + folders.map { "Folder · " + $0.path }
    }
    func offline() async throws {
        guard phase == "resume", !offlineVerified else { throw StagingRealProbeError.scope }
        let cache = try await reader().offline()
        rows = try check(cache, stale: true, expected: manifest)
        offlineVerified = true; status = "Offline production models/high-water verified. Continue with fresh HTTPS / Кэш проверен"
        try write(status: "OFFLINE_VERIFIED", name: "public.json")
    }
    func load() async throws {
        let attempt = UUID()
        acceptance.begin(attempt); loaded = false; rows = []; verification = nil
        do {
            try write(status: "HTTPS_ATTEMPT_STARTED", name: "public.json")
            guard phase == "resume" ? offlineVerified : admitted else { throw StagingRealProbeError.scope }
            try refreshExpectations()
            let expected = manifest, expectedDigest = manifestSHA256
            let team = try await validateScope()
            let cache = try await reader().load(teamName: team.name, vaultName: expected.vaultName, role: team.role)
            let rendered = try check(cache, stale: false, expected: expected)
            var verified = 0
            for secret in expected.secrets {
                let value = try await reader().reveal(resourceID: secret.resourceID, expectedHeaderHash: expected.headerHash)
                guard StagingRealProbe.sha256(Data(value.utf8)) == secret.sha256 else { throw StagingRealProbeError.acceptance }
                verified += 1
            }
            try acceptance.accept(attempt, manifestSHA256: expectedDigest, sequence: expected.sequence,
                headerHash: expected.headerHash, generationID: expected.generationID, secretsVerified: verified,
                requiredSecrets: expected.secrets.count, rows: rendered)
            try saveCheckpoint("materialized")
            loaded = true; rows = acceptance.rows
            status = "HTTPS production materialization and SECRET digests PASS / Проверка HTTPS выполнена"
            try write(status: "MATERIALIZED", name: "public.json")
        } catch let candidate as SelectiveRemotePublisherVerification {
            acceptance.fail(attempt); loaded = false; rows = []; verification = candidate
            try? write(status: "PUBLISHER_CONFIRMATION_REQUIRED", name: "public.json")
            status = "Confirm publisher fingerprint from custodian, then retry HTTPS / Подтвердите издателя"
        } catch {
            acceptance.fail(attempt); loaded = false; rows = []
            try? write(status: "HTTPS_ATTEMPT_REJECTED", name: "public.json")
            throw error
        }
    }
    func confirmPublisher() async throws {
        guard phase != "resume", let verification, publisherFingerprint == verification.fingerprint else { throw StagingRealProbeError.trust }
        try await reader().confirmPublisher(verification, independentlyObtainedFingerprint: publisherFingerprint)
        self.verification = nil
        status = "Publisher confirmed. Retry HTTPS / Издатель подтверждён"
    }
    func complete() throws {
        do {
            try refreshExpectations()
            guard loaded, acceptance.canFinish(manifestSHA256: manifestSHA256), phase != "resume" || offlineVerified
            else { throw StagingRealProbeError.acceptance }
        } catch {
            invalidateAcceptance(); try? write(status: "FINISH_REJECTED", name: "public.json")
            throw error
        }
        try write(status: "PASS", name: "phase-" + invocation.nonce.uuidString.lowercased() + ".json")
        try write(status: "PASS", name: phase == "resume" ? "resume.json" : "first.json")
        completed = true; shouldExit = true; finish?()
    }
    func cancel() { password = ""; activeTask?.cancel(); completed = false; shouldExit = true }
    private func write(status: String, name: String) throws {
        guard let identity else { throw StagingRealProbeError.protection }
        let accepted = acceptance.accepted
        let evidence = StagingNativeEvidence(formatVersion: 2, nativeGuiTestHost: true, productGuiAcceptance: false, runID: manifest.runID,
            phase: phase, launchNonce: invocation.nonce, pid: getpid(), processID: processID, previousProcessID: prior?.processID.uuidString ?? "",
            accountID: manifest.accountID, teamID: manifest.teamID, vaultID: manifest.vaultID, deviceID: deviceID,
            generationID: accepted?.generationID ?? manifest.generationID, publicKey: identity.publicKey,
            publicKeyFingerprint: SelectiveRemoteCloudDeviceTrustCoordinator.keyFingerprint(identity.publicKey), status: status,
            sequence: accepted?.sequence ?? manifest.sequence, headerHash: accepted?.headerHash ?? manifest.headerHash,
            manifestSHA256: accepted?.manifestSHA256 ?? manifestSHA256, acceptedAttemptID: accepted?.attemptID.uuidString ?? "",
            counts: manifest.counts, binary: invocation.binary,
            ownPin: try stores.pin(endpoint: manifest.endpoint, accountID: manifest.accountID),
            offlineVerified: offlineVerified, networkReloadVerified: loaded && accepted != nil, secretsVerified: accepted?.secretsVerified ?? 0)
        try evidence.write(directory: directory, name: name)
    }
}

@MainActor
private struct StagingNativeGUIView: View {
    @ObservedObject var model: StagingNativeGUIModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("TEST ONLY · Isolated native GUI host / Изолированный тест").font(.title2.bold())
                Text("nativeGuiTestHost=true · productGuiAcceptance=false").font(.caption).foregroundStyle(.secondary)
                Text(model.manifest.runID + " · " + model.phase).textSelection(.enabled)
                Text(model.status).accessibilityIdentifier("native-host-status")
                if let identity = model.identity {
                    Text("Device: " + model.deviceID.uuidString).font(.caption).textSelection(.enabled)
                    Text(SelectiveRemoteCloudDeviceTrustCoordinator.keyFingerprint(identity.publicKey)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if model.phase != "resume" {
                    if model.phase == "recover" {
                        Button("Revalidate saved checkpoint / Проверить сохранённое состояние") { model.perform { try await model.revalidateRecovery() } }
                    }
                    Button("1. Generate native key / Создать ключ") { model.perform { try await model.generate() } }.disabled(model.identity != nil)
                    Toggle("Public native fingerprint independently confirmed / Отпечаток подтверждён", isOn: $model.publicKeyConfirmed)
                    Text(model.manifest.email).font(.caption).textSelection(.enabled)
                    SecureField("Test account password / Пароль тестового аккаунта", text: $model.password).textFieldStyle(.roundedBorder)
                    Button("2. Sign in / Войти") { model.perform { try await model.login() } }.disabled(model.identity == nil || !model.publicKeyConfirmed || model.loggedIn)
                    TextField("Confirmed root fingerprint / Отпечаток корня", text: $model.fingerprint).textFieldStyle(.roundedBorder)
                    TextField("Confirmed checkpoint digest / Digest checkpoint", text: $model.checkpointText).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("3. Pair + request / Запросить допуск") { model.perform { try await model.pair() } }
                        Button("4. Answer challenge / Ответить") { model.perform { try await model.answer() } }
                        Button("5. Record admission expectation / Записать допуск") { model.perform { try await model.verifyAdmission() } }
                    }.disabled(!model.loggedIn)
                } else {
                    Button("1. Verify persisted offline models / Проверить офлайн") { model.perform { try await model.offline() } }.disabled(model.offlineVerified)
                }
                if let challenge = model.verification {
                    Text("Publisher: " + challenge.fingerprint).font(.caption).textSelection(.enabled)
                    TextField("Independently confirmed publisher fingerprint", text: $model.publisherFingerprint).textFieldStyle(.roundedBorder)
                    Button("Confirm publisher / Подтвердить издателя") { model.perform { try await model.confirmPublisher() } }
                }
                Button("Load real HTTPS + verify SECRET / HTTPS + проверка SECRET") { model.perform { try await model.load() } }
                    .disabled(model.phase == "resume" ? !model.offlineVerified : !model.admitted)
                Divider()
                Text("Production materialized synthetic records / Тестовые модели").font(.headline)
                ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in Text(row).textSelection(.enabled) }
                Button("Finish this process / Завершить процесс") { model.perform { try model.complete() } }.disabled(!model.loaded)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).disabled(model.busy)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
