#!/usr/bin/env python3
"""Exercise actual CA list and removal methods with synthetic preferences."""
from pathlib import Path
import os, re, subprocess, tempfile
repo = Path(__file__).resolve().parents[3]
source = (repo / 'Sources/SelectiveRemote/SSHCertificateAuthorityService.swift').read_text()
def method(pattern):
    match = re.search(pattern, source, re.S)
    if not match: raise RuntimeError('CA method not found')
    return match.group(0).replace('UserDefaults.standard', 'FakeDefaults.standard')
main = '''import Foundation
struct SSHCertificateAuthorityRecord: Codable { let id: UUID; let publicKeyPath: String }
final class FakeDefaults {
 static let standard = FakeDefaults()
 var values: [String: Data] = [:]
 func data(forKey key: String) -> Data? { values[key] }
 func set(_ value: Data, forKey key: String) { values[key] = value }
}
enum Service {
 static let defaultsKey = "test"
'''
main += method(r'    static func registered\(\) -> \[SSHCertificateAuthorityRecord\] \{.*?\n    \}')
main += '\n' + method(r'    private static func allRecords\(\) -> \[SSHCertificateAuthorityRecord\] \{.*?\n    \}')
main += '\n' + method(r'    static func remove\(_ id: UUID\) \{.*?\n    \}')
main += '\n' + method(r'    private static func save\(_ values: \[SSHCertificateAuthorityRecord\]\) \{.*?\n    \}')
main += '''\n}
let keep = UUID(), remove = UUID()
let original = [SSHCertificateAuthorityRecord(id: keep, publicKeyPath: "/test-only/unavailable.pub"), SSHCertificateAuthorityRecord(id: remove, publicKeyPath: "/test-only/other-unavailable.pub")]
FakeDefaults.standard.set(try JSONEncoder().encode(original), forKey: "test")
Service.remove(remove)
let result = try JSONDecoder().decode([SSHCertificateAuthorityRecord].self, from: FakeDefaults.standard.data(forKey: "test")!)
let preserved = result.map(\\.id) == [keep]
print("UNAVAILABLE_CA_RECORD_PRESERVED=" + (preserved ? "PASS" : "FAIL"))
if !preserved { exit(1) }
'''
with tempfile.TemporaryDirectory(prefix='sr-ca-test-', dir='/private/tmp') as d:
    work = Path(d); (work / 'main.swift').write_text(main)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / 'cache'))
    subprocess.run(['swiftc', '-module-cache-path', str(work / 'cache'), '-o', str(work / 'fixture'), str(work / 'main.swift')], check=True, env=env)
    raise SystemExit(subprocess.run([str(work / 'fixture')], env=env).returncode)
