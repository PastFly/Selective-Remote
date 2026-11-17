import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Staging runner native payload compatibility")
struct StagingLifecyclePayloadTests {
    @Test("Actual runner records survive Browser V1 crypto and native typed import", arguments: ["host", "credential", "snippet", "forwarding"])
    func browserPayload(type: String) throws {
        // Only fresh synthetic local test data. This is serializer evidence,
        // never a substitute for real staging/native acceptance.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = """
        import {stagingV1Records} from './cloud/tests/browser/staging-real-lifecycle.mjs';
        import {createEmptyVaultDocument,upsertVaultRecord} from './cloud/public/vault-model.js';
        import {generateVaultKey} from './cloud/public/vault-crypto.js';
        import {encryptTeamVaultPayload,decryptTeamVaultPayload} from './cloud/public/team-vault-crypto.js';
        const records=stagingV1Records(),deviceID=crypto.randomUUID();let document=createEmptyVaultDocument();
        for(const record of records) document=upsertVaultRecord(document,{...record,deviceID});
        const vaultKey=await generateVaultKey(),scope={type:'team',teamID:crypto.randomUUID(),vaultID:crypto.randomUUID()};
        const envelope=await encryptTeamVaultPayload({vaultKey,payload:document,scope,baseRevision:0,keyGeneration:1});
        const restored=await decryptTeamVaultPayload({vaultKey,envelope,scope});
        restored.records=restored.records.filter(record=>record.type===process.argv[1]);
        process.stdout.write(JSON.stringify(restored));
        """
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--input-type=module", "-e", script, type]
        process.currentDirectoryURL = root
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Local Browser payload generator failed")
        let document = try SelectiveRemoteVaultDocument.decode(bytes)
        let record = try #require(document.records.first)
        let decoded = try SelectiveRemotePersonalVaultImporter.decode(document)
        if type != "credential" {
            let exported = try SelectiveRemotePersonalVaultExporter.makeExport(
                profiles: decoded.profiles, credentials: decoded.credentials,
                snippets: decoded.snippets, forwarding: decoded.forwarding, deviceID: UUID()
            )
            let roundTrip = try SelectiveRemotePersonalVaultImporter.decode(exported.document)
            // The native exporter intentionally serializes dates to ISO8601
            // seconds. Compare its canonical representation, not Date's
            // subsecond precision from the web Host default initializer.
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let roundTripProfiles = try encoder.encode(roundTrip.profiles)
            let initialProfiles = try encoder.encode(decoded.profiles)
            #expect(roundTripProfiles == initialProfiles)
            #expect(roundTrip.snippets == decoded.snippets)
            #expect(roundTrip.forwarding == decoded.forwarding)
        }
        switch type {
        case "host":
            let profile = try #require(decoded.profiles.first)
            #expect(profile.id == record.id)
            #expect(profile.host == "synthetic.invalid")
            #expect(profile.group == "Acceptance/Nested")
            #expect(profile.connectionType == .ssh)
        case "credential":
            // Native intentionally retains standalone Browser credentials in
            // the document rather than creating an unreachable Keychain item.
            #expect(decoded.credentials.isEmpty)
        case "snippet":
            let snippet = try #require(decoded.snippets.first)
            #expect(snippet.id == record.id)
            #expect(snippet.command == "printf test-only")
        case "forwarding":
            let forward = try #require(decoded.forwarding.first)
            #expect(forward.id == record.id)
            #expect(forward.rule.id == record.id)
            #expect(forward.rule.kind == .local)
            #expect(forward.rule.bindAddress == "127.0.0.1")
            #expect(forward.rule.sourcePort == 19090)
            #expect(forward.rule.destinationPort == 19091)
            #expect(forward.connection.isValidCustomConnection)
        default: Issue.record("Unexpected record type")
        }
    }
}
