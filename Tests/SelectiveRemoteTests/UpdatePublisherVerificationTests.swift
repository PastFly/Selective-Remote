import Foundation
import Testing
@testable import SelectiveRemote

struct UpdatePublisherVerificationTests {
    private let expected = UpdatePublisherIdentity(
        bundleIdentifier: "local.selectiveremote",
        teamIdentifier: "ABCDE12345"
    )

    @Test("Exact Developer ID Application publisher is accepted")
    func exactPublisherAccepted() {
        let evidence = UpdatePublisherEvidence(
            integrityValid: true,
            bundleIdentifier: "local.selectiveremote",
            teamIdentifier: "ABCDE12345",
            signatureKind: .developerIDApplication
        )

        #expect(UpdatePublisherPolicy.accepts(evidence, expected: expected))
    }

    @Test("Wrong TeamIdentifier is rejected")
    func wrongTeamRejected() {
        let evidence = UpdatePublisherEvidence(
            integrityValid: true,
            bundleIdentifier: "local.selectiveremote",
            teamIdentifier: "ZZZZZ99999",
            signatureKind: .developerIDApplication
        )

        #expect(!UpdatePublisherPolicy.accepts(evidence, expected: expected))
    }

    @Test("Wrong Developer ID identity kind is rejected")
    func wrongDeveloperIdentityRejected() {
        let evidence = UpdatePublisherEvidence(
            integrityValid: true,
            bundleIdentifier: "local.selectiveremote",
            teamIdentifier: "ABCDE12345",
            signatureKind: .otherCertificate
        )

        #expect(!UpdatePublisherPolicy.accepts(evidence, expected: expected))
    }

    @Test("Ad-hoc signature is rejected")
    func adHocRejected() {
        let evidence = UpdatePublisherEvidence(
            integrityValid: true,
            bundleIdentifier: "local.selectiveremote",
            teamIdentifier: nil,
            signatureKind: .adHoc
        )

        #expect(!UpdatePublisherPolicy.accepts(evidence, expected: expected))
    }

    @Test("Unsigned application is rejected")
    func unsignedRejected() {
        let evidence = UpdatePublisherEvidence(
            integrityValid: false,
            bundleIdentifier: "local.selectiveremote",
            teamIdentifier: nil,
            signatureKind: .unsigned
        )

        #expect(!UpdatePublisherPolicy.accepts(evidence, expected: expected))
    }

    @Test("Correct bundle identifier with a different publisher is rejected")
    func correctBundleWrongPublisherRejected() {
        let evidence = UpdatePublisherEvidence(
            integrityValid: true,
            bundleIdentifier: "local.selectiveremote",
            teamIdentifier: "OTHER12345",
            signatureKind: .developerIDApplication
        )

        #expect(!UpdatePublisherPolicy.accepts(evidence, expected: expected))
    }

    @Test("Tampered application is rejected")
    func tamperedApplicationRejected() {
        let evidence = UpdatePublisherEvidence(
            integrityValid: false,
            bundleIdentifier: "local.selectiveremote",
            teamIdentifier: "ABCDE12345",
            signatureKind: .developerIDApplication
        )

        #expect(!UpdatePublisherPolicy.accepts(evidence, expected: expected))
    }

    @Test("Publisher requirement binds Apple Developer ID, bundle, and exact TeamIdentifier")
    func publisherRequirementIsExact() {
        let requirement = expected.requirementSource

        #expect(requirement.contains(#"anchor apple generic"#))
        #expect(requirement.contains(#"identifier "local.selectiveremote""#))
        #expect(requirement.contains(#"certificate leaf[subject.OU] = "ABCDE12345""#))
        #expect(requirement.contains("1.2.840.113635.100.6.1.13"))
        #expect(requirement.contains("1.2.840.113635.100.6.2.6"))
    }

    @Test("Transactional installer revalidates publisher before deleting rollback backup")
    func postCopyPublisherVerificationPrecedesBackupDeletion() throws {
        let script = UpdateInstallationScript.make()
        let copy = try #require(script.range(of: #"/usr/bin/ditto "$SRC" "$DST""#))
        let verify = try #require(script.range(of: #"/usr/bin/codesign --verify --deep --strict -R "$PUBLISHER_REQUIREMENT" "$DST""#))
        let deleteBackup = try #require(script.range(of: #"/bin/rm -rf "$BACKUP""#, range: verify.upperBound..<script.endIndex))

        #expect(copy.lowerBound < verify.lowerBound)
        #expect(verify.lowerBound < deleteBackup.lowerBound)
    }

    @Test("Mounted update verifies both the installed trust root and candidate before install")
    func installedAndCandidatePublisherVerificationIsPresent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let installer = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SelectiveRemote/UpdateInstaller.swift"
            ),
            encoding: .utf8
        )
        let current = try #require(installer.range(
            of: "at: Bundle.main.bundleURL"
        ))
        let candidate = try #require(installer.range(
            of: "verifyApplication(at: appURL"
        ))
        let mounted = try #require(installer.range(
            of: "return MountedSelectiveRemoteUpdate("
        ))

        #expect(current.lowerBound < candidate.lowerBound)
        #expect(candidate.lowerBound < mounted.lowerBound)
    }
}
