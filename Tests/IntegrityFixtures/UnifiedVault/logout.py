#!/usr/bin/env python3
"""Exercise the actual Cloud token store using a disposable fake Keychain."""
import os
from pathlib import Path
import subprocess
import tempfile

fixture = Path(__file__).resolve().parent
repo = fixture.parents[2]
def source(name):
    return (repo / 'Sources/SelectiveRemote' / name).read_text().replace('import Security', 'import CoreFoundation').replace('UserDefaults', 'FakeDefaults')
vault = source('UnifiedCredentialVault.swift').replace('static let shared = UnifiedCredentialVault()',
    'static let shared = UnifiedCredentialVault(lockDirectory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SR_FIXTURE_DIR"]!).appendingPathComponent("locks"))')
if os.environ.get('SR_LOCK_TRACE'):
    vault = vault.replace('throw KeychainError.vaultLockUnavailable', 'fputs("LOCK_FAILURE_LINE=\\(#line) ERRNO=\\(errno)\\n", stderr); throw KeychainError.vaultLockUnavailable')
    vault = vault.replace('guard active.path == lockPath else {', 'guard active.path == lockPath else { fputs("ACTIVE=\\(active.path) CURRENT=\\(lockPath)\\n", stderr);')
cloud = source('CloudSecureEnvelopeStore.swift')
session = source('CloudSessionStore.swift')
main = (fixture / 'main.swift').read_text().split('let first = KeychainCredentialReference')[0]
main += '''
struct SelectiveRemoteDeviceTrustPin: Codable, Equatable, Sendable {}
struct SelectiveRemoteDeviceTrustBootstrapBundle: Codable, Equatable, Sendable {}
func SecItemDelete(_ query: CFDictionary) -> OSStatus {
 if FakeKeychain.failWrite { return injectedFailure }
 return FakeKeychain.records.removeValue(forKey: FakeKeychain.key(query)) == nil ? errSecItemNotFound : errSecSuccess
}
let endpoint = URL(string: "https://test-only.invalid")!
let legacyKey = "local.selectiveremote.credentials.unified.v1|credential-vault"
let protectedKey = "\\u{1E}protected-data\\u{1F}cloud-secure-envelope.v1\\u{1F}" + endpoint.absoluteString
let envelope = try JSONEncoder().encode(SelectiveRemoteCloudSecureEnvelope(sessionToken: "synthetic-token"))
let original = try JSONEncoder().encode([protectedKey: envelope.base64EncodedString()])
FakeKeychain.records[legacyKey] = original
let store = SelectiveRemoteCloudKeychainTokenStore()
let before = try store.token(for: endpoint)
let hashBeforeFailedLogout = FakeKeychain.hash()
FakeKeychain.failWrite = true
var failedLogoutReported = false
do { try store.removeToken(for: endpoint) } catch { failedLogoutReported = true }
FakeKeychain.failWrite = false
let tokenAfterFailure = try store.token(for: endpoint)
let failureSafe = failedLogoutReported && FakeKeychain.hash() == hashBeforeFailedLogout && tokenAfterFailure == "synthetic-token"
print("FAILED_LOGOUT_PRESERVES_DATA_AND_REPORTS_ERROR=" + (failureSafe ? "PASS" : "FAIL"))
try store.removeToken(for: endpoint)
let after = try store.token(for: endpoint)
let preserved = FakeKeychain.records[legacyKey] == original
// A pre-upgrade writer can write its stale source again after logout.
FakeKeychain.records[legacyKey] = original
let reopened = try SelectiveRemoteCloudKeychainTokenStore().token(for: endpoint)
let target = "local.selectiveremote.credentials.unified.v2|credential-vault"
FakeKeychain.records.removeValue(forKey: target)
var deletionRejected = false
do { _ = try SelectiveRemoteCloudKeychainTokenStore().token(for: endpoint) } catch { deletionRejected = true }
let safe = before == "synthetic-token" && after == nil && reopened == nil && preserved && deletionRejected
print("ACTUAL_TOKEN_STORE_NO_REIMPORT_AFTER_LOGOUT=" + (safe ? "PASS" : "FAIL"))
if !safe || !failureSafe { exit(1) }
'''
with tempfile.TemporaryDirectory(prefix='sr-logout-fixture-', dir='/private/tmp') as directory:
    work = Path(directory)
    for name, contents in [('Vault.swift', vault), ('Cloud.swift', cloud), ('Session.swift', session), ('main.swift', main)]:
        (work / name).write_text(contents)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / 'cache'), SR_FIXTURE_DIR=str(work))
    subprocess.run(['swiftc', '-module-cache-path', str(work / 'cache'), '-o', str(work / 'fixture'),
                    *[str(work / name) for name in ['main.swift', 'Vault.swift', 'Cloud.swift', 'Session.swift']]], check=True, env=env)
    raise SystemExit(subprocess.run([str(work / 'fixture')], env=env).returncode)
