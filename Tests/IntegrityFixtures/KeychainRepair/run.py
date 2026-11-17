#!/usr/bin/env python3
"""Run actual repair logic with a recording fake legacy Keychain."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
fixture = Path(__file__).resolve().parent
repo = fixture.parents[2]
source = (repo / 'Sources/SelectiveRemote/KeychainService.swift').read_text()
match = re.search(r'    static func repairPasswordAccess\(\n(.*?)\n    \}', source, re.S)
if not match:
    raise RuntimeError('repair method changed; update fixture deliberately')
method = 'static func repairPasswordAccess(\n' + match.group(1) + '\n}'
main = '''import Foundation
import CoreFoundation
let kSecClass = "class", kSecClassGenericPassword = "generic", kSecAttrService = "service", kSecAttrAccount = "account"
enum Kind { case ssh, forwarding; func account(profileID: UUID) -> String { "synthetic" } }
typealias KeychainCredentialKind = Kind
var legacyDeletes = 0
func SecItemDelete(_ query: CFDictionary) -> Int32 { legacyDeletes += 1; return 0 }
enum Failure: Error { case denied }
enum FakeService {
 static let legacyService = "test-only"
 static var fail = false
 static func deletePassword(profileID: UUID, kind: Kind) throws { if fail { throw Failure.denied } }
'''
main += method + '\n}\n'
main += '''
let id = UUID()
try FakeService.repairPasswordAccess(profileID: id, kind: .ssh)
let originalPreserved = legacyDeletes == 0
FakeService.fail = true
var rejected = false
do { try FakeService.repairPasswordAccess(profileID: id, kind: .ssh) } catch { rejected = true }
print("REPAIR_PRESERVES_LEGACY_ITEM=" + (originalPreserved ? "PASS" : "FAIL"))
print("REPAIR_FAILURE_IS_REPORTED=" + (rejected && legacyDeletes == 0 ? "PASS" : "FAIL"))
if !originalPreserved || !rejected || legacyDeletes != 0 { exit(1) }
'''
with tempfile.TemporaryDirectory(prefix='sr-keychain-repair-', dir='/private/tmp') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(main)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / 'cache'))
    subprocess.run(['swiftc', '-module-cache-path', str(work / 'cache'), '-o', str(work / 'fixture'), str(work / 'main.swift')], check=True, env=env)
    raise SystemExit(subprocess.run([str(work / 'fixture')], env=env).returncode)
