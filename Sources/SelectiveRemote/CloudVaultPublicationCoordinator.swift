import CryptoKit
import Foundation

struct SelectiveRemotePublisherVerification: Error, Identifiable, Sendable {
    let scope: SelectiveRemotePublicationScope
    let publisherAccountID: UUID
    let fingerprint: String
    let bundle: SelectiveRemoteJSONValue
    var id: String { scope.key + publisherAccountID.canonicalCloudString }
}

actor SelectiveRemoteVaultPublicationCoordinator {
    let scope: SelectiveRemotePublicationScope
    let session: SelectiveRemotePublicationSession
    private let remote: any SelectiveRemoteVaultPublicationRemote
    private let identity: SelectiveRemoteTeamDeviceIdentity
    private let store: SelectiveRemoteVaultPublicationStore
    private let ownPin: @Sendable (URL, UUID) throws -> SelectiveRemoteDeviceTrustPin?
    private let advanceOwnPin: @Sendable (URL, SelectiveRemoteDeviceTrustPin, SelectiveRemoteDeviceTrustPin) throws -> Void
    private var current: SelectiveRemotePublicationCache?
    init(scope: SelectiveRemotePublicationScope, session: SelectiveRemotePublicationSession,
         remote: any SelectiveRemoteVaultPublicationRemote, identity: SelectiveRemoteTeamDeviceIdentity,
         store: SelectiveRemoteVaultPublicationStore,
         ownPin: @escaping @Sendable (URL, UUID) throws -> SelectiveRemoteDeviceTrustPin? = { try SelectiveRemoteDeviceTrustLocalStore().pin(endpoint: $0, accountID: $1) },
         advanceOwnPin: @escaping @Sendable (URL, SelectiveRemoteDeviceTrustPin, SelectiveRemoteDeviceTrustPin) throws -> Void = { try SelectiveRemoteDeviceTrustLocalStore().advance(endpoint: $0, expected: $1, next: $2) }) {
        self.scope = scope; self.session = session; self.remote = remote; self.identity = identity; self.store = store
        self.ownPin = ownPin; self.advanceOwnPin = advanceOwnPin
    }
    private func read(_ route: String, generation: String? = nil, hash: String? = nil, cursor: String? = nil) async throws -> SelectiveRemoteJSONValue {
        try session.check()
        let result = try await remote.publicationRead(scope: scope, route: route, generation: generation, hash: hash, cursor: cursor)
        try session.check()
        return result
    }
    private func root(_ text: String) throws -> P256.Signing.PublicKey {
        guard let raw = Data(selectiveRemoteBase64URL: text, expectedLength: 65) else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        return try .init(x963Representation: raw)
    }
    private func readerKeyVersion() async throws -> Int {
        try session.check()
        let snapshot = try await remote.publicationOwnTrust(endpoint: scope.endpoint)
        try session.check()
        guard snapshot.state == "ROOT_PUBLISHED", let text = snapshot.rootPublicKey,
              let directory = snapshot.checkpoint, let certificate = snapshot.certificates?.first(where: { $0.payload.deviceID == scope.deviceID }),
              let pin = try ownPin(scope.endpoint, scope.accountID) else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        let verified = try SelectiveRemoteDeviceTrustV1.verify(rootPublicKey: root(text), certificate: certificate, directory: directory, pin: pin, expectedDeviceID: scope.deviceID)
        guard certificate.payload.accountID == scope.accountID, verified.publicKey == identity.publicKey, identity.deviceID == scope.deviceID else { throw SelectiveRemotePublicationError.subject }
        let next = SelectiveRemoteDeviceTrustPin(accountID: pin.accountID, rootFingerprint: pin.rootFingerprint, highWater: verified.highWater, checkpointDigest: try SelectiveRemoteDeviceTrustV1.directoryDigest(directory))
        try session.check(); try advanceOwnPin(scope.endpoint, pin, next); try session.check()
        return certificate.payload.keyVersion
    }
    private func verifyPublisher(_ value: SelectiveRemoteJSONValue, header: SelectiveRemoteJSONValue, advance: Bool) throws -> String {
        let p = try value.publicationObject(["headerHash", "generationID", "accountID", "deviceID", "keyVersion", "rootPublicKey", "certificate", "checkpoint"])
        let h = try SelectiveRemoteVaultPublicationV1.headerPayload(header)
        guard p["headerHash"] == .string(try SelectiveRemoteVaultPublicationV1.hash("header", header)), p["generationID"] == h["generationID"],
              p["accountID"] == h["publisherAccountID"], p["deviceID"] == h["publisherDeviceID"], p["keyVersion"] == h["publisherKeyVersion"] else { throw SelectiveRemotePublicationError.scope }
        let accountID = UUID(uuidString: try p["accountID"]!.publicationString())!, deviceID = UUID(uuidString: try p["deviceID"]!.publicationString())!
        let text = try p["rootPublicKey"]!.publicationString(), key = try root(text)
        let certificate = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteSignedDeviceCertificate.self, from: p["certificate"]!)
        let directory = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteSignedDeviceDirectory.self, from: p["checkpoint"]!)
        guard certificate.payload.accountID == accountID, certificate.payload.deviceID == deviceID,
              certificate.payload.keyVersion == (try p["keyVersion"]!.publicationInteger()), directory.payload.accountID == accountID else { throw SelectiveRemotePublicationError.subject }
        let own = accountID == scope.accountID
        let pin = try own ? ownPin(scope.endpoint, accountID) : store.publisherPin(endpoint: scope.endpoint, teamID: scope.teamID, accountID: accountID)
        guard let pin else {
            guard !own, advance else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
            // Candidate signature verification validates the challenge, never authorizes decryption.
            let candidate = SelectiveRemoteDeviceTrustPin(accountID: accountID, rootFingerprint: SelectiveRemoteDeviceTrustV1.fingerprint(key), highWater: directory.payload.version, checkpointDigest: try SelectiveRemoteDeviceTrustV1.directoryDigest(directory))
            _ = try SelectiveRemoteDeviceTrustV1.verify(rootPublicKey: key, certificate: certificate, directory: directory, pin: candidate, expectedDeviceID: deviceID)
            throw SelectiveRemotePublisherVerification(scope: scope, publisherAccountID: accountID, fingerprint: candidate.rootFingerprint, bundle: value)
        }
        let verified = try SelectiveRemoteDeviceTrustV1.verify(rootPublicKey: key, certificate: certificate, directory: directory, pin: pin, expectedDeviceID: deviceID)
        if advance {
            let next = SelectiveRemoteDeviceTrustPin(accountID: accountID, rootFingerprint: pin.rootFingerprint, highWater: verified.highWater, checkpointDigest: try SelectiveRemoteDeviceTrustV1.directoryDigest(directory))
            try session.check()
            if own { try advanceOwnPin(scope.endpoint, pin, next) }
            else { try store.savePublisherPin(next, expected: pin, scope: scope, session: session) }
            try session.check()
        }
        return text
    }
    func confirmPublisher(_ challenge: SelectiveRemotePublisherVerification, independentlyObtainedFingerprint: String) throws {
        try session.check()
        guard challenge.scope == scope, challenge.publisherAccountID != scope.accountID,
              independentlyObtainedFingerprint == challenge.fingerprint else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        let p = try challenge.bundle.publicationObject()
        let key = try root(p["rootPublicKey"]!.publicationString())
        let directory = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteSignedDeviceDirectory.self, from: p["checkpoint"]!)
        let cert = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteSignedDeviceCertificate.self, from: p["certificate"]!)
        let pin = SelectiveRemoteDeviceTrustPin(accountID: challenge.publisherAccountID, rootFingerprint: SelectiveRemoteDeviceTrustV1.fingerprint(key), highWater: directory.payload.version, checkpointDigest: try SelectiveRemoteDeviceTrustV1.directoryDigest(directory))
        guard pin.rootFingerprint == independentlyObtainedFingerprint, cert.payload.accountID == pin.accountID,
              p["accountID"] == .string(pin.accountID.canonicalCloudString), p["deviceID"] == .string(cert.payload.deviceID.canonicalCloudString),
              try p["keyVersion"]!.publicationInteger() == cert.payload.keyVersion else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        _ = try SelectiveRemoteDeviceTrustV1.verify(rootPublicKey: key, certificate: cert, directory: directory, pin: pin, expectedDeviceID: cert.payload.deviceID)
        try store.savePublisherPin(pin, expected: nil, scope: scope, session: session)
    }
    private func decrypt(_ response: SelectiveRemoteJSONValue, descriptor: SelectiveRemoteJSONValue, cache: SelectiveRemotePublicationCache) throws -> SelectiveRemotePublishedPart {
        try session.check()
        let r = try response.publicationObject(["headerHash", "generationID", "descriptor", "envelope", "entry", "proof"])
        let header = try SelectiveRemoteVaultPublicationV1.headerPayload(cache.header)
        guard r["headerHash"] == .string(cache.headerHash), r["generationID"] == header["generationID"], r["descriptor"] == descriptor else { throw SelectiveRemotePublicationError.scope }
        let rootText = try cache.publisher.publicationObject()["rootPublicKey"]!.publicationString()
        try SelectiveRemoteVaultPublicationV1.verifyDescriptor(descriptor, header: cache.header, rootPublicKey: rootText, envelope: r["envelope"], entry: r["entry"], proof: r["proof"])
        let entry = try r["entry"]!.publicationObject(["accountID", "deviceKeyVersion", "wrapper"])
        let wrapper = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteResourceKeyWrapper.self, from: entry["wrapper"]!)
        let subject = try cache.subject.publicationObject(["accountID", "deviceID", "membershipID", "membershipEpoch"])
        guard entry["accountID"] == .string(scope.accountID.canonicalCloudString),
              try entry["deviceKeyVersion"]!.publicationInteger() == cache.readerKeyVersion,
              wrapper.context.deviceID == scope.deviceID, subject["deviceID"] == .string(scope.deviceID.canonicalCloudString),
              subject["accountID"] == .string(scope.accountID.canonicalCloudString),
              wrapper.context.membershipID.canonicalCloudString == (try subject["membershipID"]!.publicationString()),
              wrapper.context.membershipEpoch == (try subject["membershipEpoch"]!.publicationInteger()) else { throw SelectiveRemotePublicationError.subject }
        let envelope = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteResourceCipherEnvelope.self, from: r["envelope"]!)
        var cek = try SelectiveRemoteResourceCryptoV2.unwrap(wrapper, with: identity.privateKey, context: wrapper.context)
        defer { cek.resetBytes(in: 0..<cek.count) }
        var plaintext = try SelectiveRemoteResourceCryptoV2.decrypt(envelope, cek: cek, context: envelope.context)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let part = try SelectiveRemotePublicationPartDecoder.decode(plaintext, descriptor: descriptor, header: cache.header)
        try session.check()
        return part
    }
    private func pointer(_ cache: SelectiveRemotePublicationCache) async throws {
        let response = try await read("header").publicationObject(["header", "headerHash", "subject", "inventory"])
        guard response["header"] == cache.header, response["headerHash"] == .string(cache.headerHash), response["subject"] == cache.subject, response["inventory"] == cache.inventory else { throw SelectiveRemoteCloudError.serviceError(409, "publication_changed") }
    }
    static func authenticationLoss(_ error: Error) -> Bool {
        if case SelectiveRemoteCloudError.authenticationRequired = error { return true }
        if case let SelectiveRemoteCloudError.serviceError(status, _) = error { return status == 401 }
        return false
    }
    private func retire(_ error: Error, payloadStamp: SelectiveRemotePublicationPayloadStamp, retirementSession: SelectiveRemotePublicationSession) async {
        if Self.authenticationLoss(error) {
            do { try retirementSession.prepareAuthenticationLossRetirement(); _ = try store.retireScopes(session: retirementSession, selection: .all) } catch {}
            await MainActor.run {
                let presentation = SelectiveRemotePublicationPresentation.shared
                for cache in presentation.caches where cache.scope.endpoint == session.endpoint && cache.scope.accountID == session.accountID && cache.scope.deviceID == session.deviceID {
                    presentation.detach(scope: cache.scope, expectedSession: session)
                }
            }
        } else if Self.authoritative(error) {
            try? store.removePayload(scope: scope, session: session, expectedStamp: payloadStamp)
            await MainActor.run { SelectiveRemotePublicationPresentation.shared.detach(scope: scope, expectedSession: session) }
        }
    }
    static func authoritative(_ error: Error) -> Bool {
        if case SelectiveRemoteCloudError.authenticationRequired = error { return true }
        if case let SelectiveRemoteCloudError.serviceError(status, code) = error { return status == 401 || status == 403 || status == 404 || code == "publication_repair_required" }
        return false
    }
    static func transient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case let SelectiveRemoteCloudError.serviceError(status, _) = error { return status >= 500 }
        return false
    }
    func load(teamName: String, vaultName: String, role: SelectiveRemoteCloudTeamRole) async throws -> SelectiveRemotePublicationCache {
        let payloadStamp = try store.payloadStamp(scope: scope)
        var retirementSession = session
        do {
            try session.check(); try store.captureRetirementOwners(session: session)
            retirementSession = try session.retirementSnapshot()
            let highWater = try store.highWater(scope: scope)
            let response = try await read("header").publicationObject(["header", "headerHash", "subject", "inventory"])
            let header = response["header"]!, h = try SelectiveRemoteVaultPublicationV1.headerPayload(header)
            let generation = try h["generationID"]!.publicationString(), hash = try response["headerHash"]!.publicationString()
            let publisher = try await read("publisher", generation: generation, hash: hash)
            let publisherRoot = try verifyPublisher(publisher, header: header, advance: true)
            let verified = try SelectiveRemoteVaultPublicationV1.verifyHeader(header, rootPublicKey: publisherRoot, teamID: scope.teamID.canonicalCloudString, vaultID: scope.vaultID.canonicalCloudString, highWater: highWater)
            guard verified.hash == hash else { throw SelectiveRemotePublicationError.scope }
            let subject = try response["subject"]!.publicationObject(["accountID", "deviceID", "membershipID", "membershipEpoch"])
            guard subject["accountID"] == .string(scope.accountID.canonicalCloudString), subject["deviceID"] == .string(scope.deviceID.canonicalCloudString) else { throw SelectiveRemotePublicationError.subject }
            let keyVersion = try await readerKeyVersion()
            var descriptors: [SelectiveRemoteJSONValue] = [], cursors = Set<String>(), cursor: String?
            repeat {
                let page = try await read("directory", generation: generation, hash: hash, cursor: cursor).publicationObject(["headerHash", "generationID", "inventory", "descriptors", "nextCursor"])
                guard page["headerHash"] == .string(hash), page["generationID"] == .string(generation), page["inventory"] == response["inventory"] else { throw SelectiveRemotePublicationError.scope }
                let values = try page["descriptors"]!.publicationArray()
                guard values.count <= 100, descriptors.count + values.count <= 2000,
                      !values.isEmpty || page["nextCursor"] == .null else { throw SelectiveRemotePublicationError.incomplete }
                for d in values { try SelectiveRemoteVaultPublicationV1.verifyDescriptor(d, header: header, rootPublicKey: publisherRoot) }
                descriptors += values
                cursor = page["nextCursor"] == .null ? nil : try page["nextCursor"]!.publicationString()
                if let cursor { guard cursor.utf8.count <= 4096, cursors.insert(cursor).inserted else { throw SelectiveRemotePublicationError.incomplete } }
            } while cursor != nil
            try SelectiveRemoteVaultPublicationV1.verifyInventory(response["inventory"]!, descriptors: descriptors, header: header, rootPublicKey: publisherRoot, subject: response["subject"]!)
            var cache = SelectiveRemotePublicationCache(scope: scope, teamName: teamName, vaultName: vaultName, role: role, header: header, headerHash: hash, subject: response["subject"]!, inventory: response["inventory"]!, publisher: publisher, descriptors: descriptors, readerPublicKey: identity.publicKey, readerKeyVersion: keyVersion, parts: [])
            var parts: [SelectiveRemotePublishedPart] = []
            for descriptor in descriptors {
                let d = try SelectiveRemoteVaultPublicationV1.descriptorPayload(descriptor)
                guard d["part"] != .string("SECRET") else { continue }
                let route = "resources/" + (try d["resourceID"]!.publicationString()) + "/parts/" + (try d["part"]!.publicationString())
                let value = try await read(route, generation: generation, hash: hash)
                parts.append(try decrypt(value, descriptor: descriptor, cache: cache))
            }
            cache = .init(scope: cache.scope, teamName: teamName, vaultName: vaultName, role: role, header: header, headerHash: hash, subject: cache.subject, inventory: cache.inventory, publisher: publisher, descriptors: descriptors, readerPublicKey: identity.publicKey, readerKeyVersion: keyVersion, parts: parts)
            // Ordinary model validation runs before durability or presentation.
            _ = try cache.materializedSnapshot()
            try await pointer(cache)
            try session.check(); try store.commit(cache, expected: highWater, session: session); try session.check()
            try store.captureRetirementOwners(session: session)
            current = cache
            return cache
        } catch {
            current = nil
            await retire(error, payloadStamp: payloadStamp, retirementSession: retirementSession)
            if Self.transient(error) { return try offline() }
            await MainActor.run { SelectiveRemotePublicationPresentation.shared.detach(scope: scope, expectedSession: session) }
            throw error
        }
    }
    func offline() throws -> SelectiveRemotePublicationCache {
        try session.check()
        guard var cache = try store.load(scope: scope, session: session), cache.readerKeyVersion > 0,
              cache.readerPublicKey == identity.publicKey, identity.deviceID == scope.deviceID else { throw SelectiveRemotePublicationError.subject }
        let publisherRoot = try verifyPublisher(cache.publisher, header: cache.header, advance: false)
        _ = try SelectiveRemoteVaultPublicationV1.verifyHeader(cache.header, rootPublicKey: publisherRoot, teamID: scope.teamID.canonicalCloudString, vaultID: scope.vaultID.canonicalCloudString, highWater: store.highWater(scope: scope))
        for d in cache.descriptors { try SelectiveRemoteVaultPublicationV1.verifyDescriptor(d, header: cache.header, rootPublicKey: publisherRoot) }
        try SelectiveRemoteVaultPublicationV1.verifyInventory(cache.inventory, descriptors: cache.descriptors, header: cache.header, rootPublicKey: publisherRoot, subject: cache.subject)
        let expected = cache.descriptors.filter { (try? SelectiveRemoteVaultPublicationV1.descriptorPayload($0)["part"]) != .string("SECRET") }
        guard expected.count == cache.parts.count else { throw SelectiveRemotePublicationError.incomplete }
        for (part, descriptor) in zip(cache.parts, expected) {
            guard try SelectiveRemotePublicationPartDecoder.decode(part.plaintext, descriptor: descriptor, header: cache.header) == part else { throw SelectiveRemotePublicationError.scope }
        }
        cache.stale = true; _ = try cache.materializedSnapshot(); try session.check(); current = cache
        return cache
    }
    func secretRecord(resourceID: UUID, expectedHeaderHash: String? = nil) async throws -> SelectiveRemoteVaultRecord {
        if let expectedHeaderHash { guard current?.headerHash == expectedHeaderHash else { throw SelectiveRemotePublicationError.scope } }
        let payloadStamp = try store.payloadStamp(scope: scope)
        var retirementSession = session
        do {
            try session.check(); try store.captureRetirementOwners(session: session)
            retirementSession = try session.retirementSnapshot()
            guard let cache = current, !cache.stale, let descriptor = cache.descriptors.first(where: {
                guard let p = try? SelectiveRemoteVaultPublicationV1.descriptorPayload($0) else { return false }
                return p["resourceID"] == .string(resourceID.canonicalCloudString) && p["kind"] == .string("CREDENTIAL") && p["part"] == .string("SECRET")
            }) else { throw SelectiveRemotePublicationError.subject }
            try await pointer(cache)
            guard current?.headerHash == cache.headerHash else { throw CancellationError() }
            let generation = try SelectiveRemoteVaultPublicationV1.headerPayload(cache.header)["generationID"]!.publicationString()
            let response = try await read("resources/" + resourceID.canonicalCloudString + "/parts/SECRET", generation: generation, hash: cache.headerHash)
            guard current?.headerHash == cache.headerHash else { throw CancellationError() }
            let part = try decrypt(response, descriptor: descriptor, cache: cache)
            let payload = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: part.plaintext).publicationObject()
            let record = try payload["record"]!.publicationObject(), data = try record["data"]!.publicationObject()
            _ = try data["secret"]!.publicationString()
            let decodedRecord = try SelectiveRemotePublicationPartDecoder.runtimeRecord(payload["record"]!, resourceID: resourceID)
            try await pointer(cache); try session.check()
            guard current?.headerHash == cache.headerHash else { throw CancellationError() }
            return decodedRecord
        } catch {
            current = nil
            await retire(error, payloadStamp: payloadStamp, retirementSession: retirementSession)
            await MainActor.run { SelectiveRemotePublicationPresentation.shared.detach(scope: scope, expectedSession: session) }
            throw error
        }
    }
    func reveal(resourceID: UUID, expectedHeaderHash: String? = nil) async throws -> String {
        let record = try await secretRecord(resourceID: resourceID, expectedHeaderHash: expectedHeaderHash)
        try session.check()
        return try record.data.publicationObject()["secret"]!.publicationString()
    }

}
