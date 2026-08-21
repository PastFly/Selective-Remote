#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
path = ROOT / "Sources/SelectiveRemote/KeychainService.swift"
text = path.read_text(encoding="utf-8")

anchor = '''    static func deletePassword(
        profileID: UUID,
        kind: KeychainCredentialKind = .rdp
    ) throws {
        let reference = credentialReference(profileID: profileID, kind: kind)
        try UnifiedCredentialVault.shared.delete(reference: reference)
    }
'''
if anchor not in text:
    raise SystemExit("patched deletePassword anchor not found")

replacement = '''    static func authorizeSSHKeyUse(profileID: UUID, reason: String) throws {
        try authenticateTouchID(reason: reason)
    }

    static func setSSHKeyUseProtection(profileID: UUID, enabled: Bool) throws {
        if enabled && !touchIDAvailable {
            throw KeychainError.touchIDUnavailable(
                "Touch ID недоступен. Добавьте отпечаток в настройках macOS."
            )
        }
        // Preference is persisted by AppModel. No synthetic Keychain marker is
        // needed; the biometric gate is performed directly before key use.
        try? deletePassword(profileID: profileID, kind: .sshKeyAuthorization)
    }

    static func deletePassword(
        profileID: UUID,
        kind: KeychainCredentialKind = .rdp
    ) throws {
        let reference = credentialReference(profileID: profileID, kind: kind)
        try UnifiedCredentialVault.shared.delete(reference: reference)

        // SSH and Forwarding used the pre-v2 Keychain service in older builds.
        // Tombstone the legacy namespace as well so an explicit Delete cannot
        // accidentally resurrect an old per-profile password through fallback.
        if kind == .ssh || kind == .forwarding {
            let legacy = KeychainCredentialReference(
                service: legacyService,
                account: kind.account(profileID: profileID),
                kind: kind
            )
            try UnifiedCredentialVault.shared.delete(reference: legacy)
        }
    }
'''
text = text.replace(anchor, replacement, 1)
path.write_text(text, encoding="utf-8")

# Strengthen the source regression so the compatibility methods cannot be
# accidentally swallowed by a future credential-storage refactor.
test_path = ROOT / "Tests/SelectiveRemoteTests/KeychainVault0260Tests.swift"
tests = test_path.read_text(encoding="utf-8")
needle = '''    #expect(service.contains("UnifiedCredentialVault.shared.read"))
    #expect(service.contains("migrateCredentialsToUnifiedVault"))
    #expect(view.contains("Объединить пароли"))
'''
replacement_test = '''    #expect(service.contains("UnifiedCredentialVault.shared.read"))
    #expect(service.contains("migrateCredentialsToUnifiedVault"))
    #expect(service.contains("static func authorizeSSHKeyUse"))
    #expect(service.contains("static func setSSHKeyUseProtection"))
    #expect(service.contains("service: legacyService"))
    #expect(view.contains("Объединить пароли"))
'''
if needle not in tests:
    raise SystemExit("vault regression test anchor not found")
test_path.write_text(tests.replace(needle, replacement_test, 1), encoding="utf-8")

print("v0.26.0 unified vault compatibility fix applied")
