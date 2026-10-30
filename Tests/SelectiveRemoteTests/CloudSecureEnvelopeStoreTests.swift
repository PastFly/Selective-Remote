import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Cloud envelope updates avoid unchanged persistence")
struct CloudSecureEnvelopeStoreTests {
    private let endpoint = URL(string: "https://synthetic-envelope-update.example.invalid")!

    @Test("Missing fallback data neither creates nor deletes an envelope")
    func missingFallbackDoesNotPersist() throws {
        let memory = EnvelopeUpdateMemory()
        let store = memory.store()
        try store.update(for: endpoint) { envelope in
            #expect(envelope.sessionToken == nil)
            #expect(envelope.personalVaultKeyMaterials["missing-device"] == nil)
        }
        #expect(memory.reads == 1)
        #expect(memory.writes == 0)
        #expect(memory.deletes == 0)
        #expect(memory.value == nil)
    }

    @Test("Reading a fallback or assigning an equal value does not rewrite existing secrets")
    func unchangedExistingEnvelopeDoesNotPersist() throws {
        let original = SelectiveRemoteCloudSecureEnvelope(
            sessionToken: "synthetic-token", teamDevicePrivateKeys: ["device": Data([1, 2, 3])]
        )
        let memory = EnvelopeUpdateMemory(original)
        let store = memory.store()
        try store.update(for: endpoint) { envelope in
            #expect(envelope.personalVaultKeyMaterials["missing-device"] == nil)
            envelope.sessionToken = "synthetic-token"
        }
        #expect(memory.reads == 1)
        #expect(memory.writes == 0)
        #expect(memory.deletes == 0)
        #expect(memory.value == original)
    }

    @Test("Actual changes persist once, and removing the final value deletes once")
    func changedEnvelopeStillPersists() throws {
        let memory = EnvelopeUpdateMemory()
        let store = memory.store()
        try store.update(for: endpoint) { $0.sessionToken = "synthetic-token" }
        #expect(memory.writes == 1)
        #expect(memory.deletes == 0)
        #expect(memory.value?.sessionToken == "synthetic-token")
        try store.update(for: endpoint) { $0.sessionToken = nil }
        #expect(memory.writes == 1)
        #expect(memory.deletes == 1)
        #expect(memory.value == nil)
    }

    @Test("A mutation that throws never persists its partial edit")
    func failedMutationDoesNotPersist() throws {
        let original = SelectiveRemoteCloudSecureEnvelope(sessionToken: "synthetic-token")
        let memory = EnvelopeUpdateMemory(original)
        let store = memory.store()
        #expect(throws: CancellationError.self) {
            try store.update(for: endpoint) {
                $0.sessionToken = "partial-change"
                throw CancellationError()
            }
        }
        #expect(memory.writes == 0)
        #expect(memory.deletes == 0)
        #expect(memory.value == original)
    }
}

// Every persistence operation is replaced. This fixture cannot invoke Keychain,
// UnifiedCredentialVault, legacy migration, or a user-data path.
private final class EnvelopeUpdateMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SelectiveRemoteCloudSecureEnvelope?
    private var readCount = 0
    private var writeCount = 0
    private var deleteCount = 0
    init(_ initial: SelectiveRemoteCloudSecureEnvelope? = nil) { stored = initial }
    var value: SelectiveRemoteCloudSecureEnvelope? { lock.withLock { stored } }
    var reads: Int { lock.withLock { readCount } }
    var writes: Int { lock.withLock { writeCount } }
    var deletes: Int { lock.withLock { deleteCount } }
    func store() -> SelectiveRemoteCloudSecureEnvelopeStore {
        .init(storage: .init(
            read: { _ in self.lock.withLock { self.readCount += 1; return self.stored } },
            write: { value, _ in self.lock.withLock { self.writeCount += 1; self.stored = value } },
            delete: { _ in self.lock.withLock { self.deleteCount += 1; self.stored = nil } }
        ))
    }
}
