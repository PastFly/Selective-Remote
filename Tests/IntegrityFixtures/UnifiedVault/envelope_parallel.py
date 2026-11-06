#!/usr/bin/env python3
"""Race actual Cloud envelope updates against a disposable fake Keychain."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile

fixture = Path(__file__).resolve().parent
logout_mode = os.environ.get('SR_TEST_LOGOUT') == '1'
repo = fixture.parents[2]
vault = (repo / 'Sources/SelectiveRemote/UnifiedCredentialVault.swift').read_text()
vault = vault.replace('import Security', 'import CoreFoundation').replace('UserDefaults', 'FakeDefaults')
vault = vault.replace('static let shared = UnifiedCredentialVault()',
    'static let shared = UnifiedCredentialVault(lockDirectory: fixtureDirectory.appendingPathComponent("locks"))')
cloud = (repo / 'Sources/SelectiveRemote/CloudSecureEnvelopeStore.swift').read_text().replace('import Security', 'import CoreFoundation')
main = (fixture / 'parallel.swift').read_text().split('let vault = UnifiedCredentialVault')[0]
main += '''
struct SelectiveRemoteDeviceTrustPin: Codable, Equatable {}
struct SelectiveRemoteDeviceTrustBootstrapBundle: Codable, Equatable {}
func SecItemDelete(_ query: CFDictionary) -> OSStatus { errSecItemNotFound }
let store = SelectiveRemoteCloudSecureEnvelopeStore()
let endpoint = URL(string: "https://test-only.invalid")!
didWait = true
var saved = false
for _ in 0..<200 {
 do {
  try store.update(for: endpoint) { envelope in
   let mine = fixtureDirectory.appendingPathComponent("mutation-" + workerID)
   let peer = fixtureDirectory.appendingPathComponent("mutation-" + (workerID == "A" ? "B" : "A"))
   _ = FileManager.default.createFile(atPath: mine.path, contents: Data())
   let deadline = Date().addingTimeInterval(0.7)
   while !FileManager.default.fileExists(atPath: peer.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
   if workerID == "A" { envelope.sessionToken = ProcessInfo.processInfo.environment["SR_TEST_LOGOUT"] == "1" ? nil : "test-token" }
   else { envelope.teamDevicePrivateKeys["test-device"] = Data("test-key".utf8) }
  }
  saved = true
  break
 } catch KeychainError.concurrentVaultWrite { Thread.sleep(forTimeInterval: 0.01) }
}
if !saved { exit(2) }
'''
with tempfile.TemporaryDirectory(prefix='sr-envelope-parallel-', dir='/private/tmp') as directory:
    work = Path(directory)
    (work / 'Vault.swift').write_text(vault)
    (work / 'Cloud.swift').write_text(cloud)
    (work / 'main.swift').write_text(main)
    (work / 'locks').mkdir(mode=0o700)
    (work / 'locks' / 'unified-credentials.lock').touch(mode=0o600)
    key = '\x1eprotected-data\x1fcloud-secure-envelope.v1\x1fhttps://test-only.invalid'
    initial = b'{"sessionToken":"old-test-token"}' if logout_mode else b'{}'
    (work / 'item.json').write_text(json.dumps({key: base64.b64encode(initial).decode()}))
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / 'cache'), SR_FIXTURE_DIR=str(work))
    subprocess.run(['swiftc', '-module-cache-path', str(work / 'cache'), '-o', str(work / 'fixture'),
                    str(work / 'main.swift'), str(work / 'Vault.swift'), str(work / 'Cloud.swift')], check=True, env=env)
    workers = [subprocess.Popen([str(work / 'fixture'), worker], env=env) for worker in ['A', 'B']]
    try:
        exits = [worker.wait(timeout=15) for worker in workers]
    finally:
        for worker in workers:
            if worker.poll() is None:
                worker.kill()
                worker.wait()
    data = json.loads((work / 'item.json').read_text())
    envelope = json.loads(base64.b64decode(data[key]))
    token_ok = envelope.get('sessionToken') is None if logout_mode else envelope.get('sessionToken') == 'test-token'
    intact = exits == [0, 0] and token_ok and envelope.get('teamDevicePrivateKeys', {}).get('test-device') == base64.b64encode(b'test-key').decode()
    label = 'CONCURRENT_LOGOUT_NOT_UNDONE' if logout_mode else 'TWO_PROCESS_CLOUD_UPDATES_PRESERVED'
    print(label + '=' + ('PASS' if intact else 'FAIL'))
    raise SystemExit(0 if intact else 1)
