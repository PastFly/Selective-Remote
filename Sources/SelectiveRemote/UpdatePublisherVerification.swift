import Foundation

struct UpdatePublisherIdentity: Equatable, Sendable {
    let bundleIdentifier: String
    let teamIdentifier: String

    private func escapedRequirementLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
    }

    var requirementSource: String {
        let bundle = escapedRequirementLiteral(bundleIdentifier)
        let team = escapedRequirementLiteral(teamIdentifier)
        return """
        anchor apple generic and identifier "\(bundle)" and \
        certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
        certificate leaf[field.1.2.840.113635.100.6.1.13] exists and \
        certificate leaf[subject.OU] = "\(team)"
        """
    }

    var requirementArgument: String { "=" + requirementSource }

    static func official(from bundle: Bundle) throws -> Self {
        guard let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              let teamIdentifier = bundle.object(
                forInfoDictionaryKey: "SelectiveRemoteExpectedTeamIdentifier"
              ) as? String,
              teamIdentifier.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
            throw UpdateInstallerError.missingPublisherIdentity
        }
        return Self(bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier)
    }
}

enum UpdatePublisherSignatureKind: Equatable, Sendable {
    case developerIDApplication
    case adHoc
    case otherCertificate
    case unsigned
}

struct UpdatePublisherEvidence: Equatable, Sendable {
    let integrityValid: Bool
    let bundleIdentifier: String?
    let teamIdentifier: String?
    let signatureKind: UpdatePublisherSignatureKind
}

enum UpdatePublisherPolicy {
    static func accepts(
        _ evidence: UpdatePublisherEvidence,
        expected: UpdatePublisherIdentity
    ) -> Bool {
        evidence.integrityValid
            && evidence.bundleIdentifier == expected.bundleIdentifier
            && evidence.teamIdentifier == expected.teamIdentifier
            && evidence.signatureKind == .developerIDApplication
    }
}

enum UpdatePublisherVerifier {
    static func verifyApplication(
        at applicationURL: URL,
        expected: UpdatePublisherIdentity
    ) throws {
        let candidateBundle = Bundle(url: applicationURL)
        let candidateIdentifier = candidateBundle?.bundleIdentifier

        do {
            _ = try runCodesign([
                "--verify", "--deep", "--strict", applicationURL.path,
            ])
            let signingDetails = try runCodesign([
                "-d", "--verbose=4", applicationURL.path,
            ])
            let teamIdentifier = signingDetails
                .split(separator: "\n")
                .first(where: { $0.hasPrefix("TeamIdentifier=") })
                .map { String($0.dropFirst("TeamIdentifier=".count)) }
            _ = try runCodesign([
                "--verify", "--deep", "--strict",
                "-R", expected.requirementArgument,
                applicationURL.path,
            ])
            let evidence = UpdatePublisherEvidence(
                integrityValid: true,
                bundleIdentifier: candidateIdentifier,
                teamIdentifier: teamIdentifier,
                signatureKind: .developerIDApplication
            )
            guard UpdatePublisherPolicy.accepts(evidence, expected: expected) else {
                throw UpdateInstallerError.invalidPublisherIdentity
            }
        } catch let error as UpdateInstallerError {
            throw error
        } catch {
            throw UpdateInstallerError.invalidPublisherIdentity
        }
    }

    private static func runCodesign(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        guard process.terminationStatus == 0 else {
            throw UpdateInstallerError.invalidPublisherIdentity
        }
        return String(decoding: data, as: UTF8.self)
    }
}

enum UpdateInstallationScript {
    static func make() -> String {
        #"""
#!/bin/sh
set -eu
PID="$1"
SRC="$2"
DST="$3"
MOUNT="$4"
DMG="$5"
CLEANUP_DMG="$6"
PUBLISHER_REQUIREMENT="$7"
while /bin/kill -0 "$PID" 2>/dev/null; do
    /bin/sleep 0.2
done
BACKUP="${DST}.selective-remote-backup.$$"
/bin/rm -rf "$BACKUP"
if ! /bin/mv "$DST" "$BACKUP"; then
    /usr/bin/open "$DST" >/dev/null 2>&1 || true
    /usr/bin/hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    exit 1
fi
if /usr/bin/ditto "$SRC" "$DST" && /usr/bin/codesign --verify --deep --strict -R "$PUBLISHER_REQUIREMENT" "$DST"; then
    /bin/rm -rf "$BACKUP"
    /usr/bin/open "$DST"
else
    /bin/rm -rf "$DST"
    /bin/mv "$BACKUP" "$DST"
    /usr/bin/open "$DST"
    exit 1
fi
/usr/bin/hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
if [ "$CLEANUP_DMG" = "1" ]; then
    /bin/rm -f "$DMG"
fi
/bin/rm -f "$0"
"""#
    }
}
