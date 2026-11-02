#!/usr/bin/env python3
"""Run the actual SSH agent removal methods with a recording fake command."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

fixture = Path(__file__).resolve().parent
repo = fixture.parents[2]
source = (repo / 'Sources/SelectiveRemote/SSHService.swift').read_text()
def method(name):
    match = re.search(r'    static func ' + name + r'\(_ key: SSHKeyRecord\) throws \{\n(.*?)\n    \}', source, re.S)
    if not match:
        raise RuntimeError('missing actual source method: ' + name)
    return 'static func ' + name + '(_ key: SSHKeyRecord) throws {\n' + match.group(1) + '\n}'
main = '''import Foundation
struct SSHKeyRecord { let privateKeyPath: String }
enum SSHKeyServiceError: Error { case agentFailed(String), sharedKeychainRemovalUnsafe }
enum FakeSSH {
 static var calls: [[String]] = []
 static let sshAddPath = "/test-only/ssh-add"
 static func agentEnvironment() throws -> [String: String] { [:] }
 static func run(executable: String, arguments: [String], environment: [String: String]) throws -> (status: Int32, output: String) {
  calls.append(arguments); return (0, "")
 }
 static func cleanOutput(_ value: String) -> String { value }
'''
main += method('removeFromAgentAndKeychain') + '\n' + method('removeFromAgent') + '\n}\n'
main += '''
let key = SSHKeyRecord(privateKeyPath: "/test-only/key")
var rejected = false
do { try FakeSSH.removeFromAgentAndKeychain(key) } catch { rejected = true }
let keychainSafe = rejected && FakeSSH.calls.isEmpty
try FakeSSH.removeFromAgent(key)
let agentOnly = FakeSSH.calls == [["-d", "/test-only/key"]]
print("SHARED_KEYCHAIN_DELETE_REJECTED=" + (keychainSafe ? "PASS" : "FAIL"))
print("AGENT_ONLY_REMOVAL_SAFE=" + (agentOnly ? "PASS" : "FAIL"))
if !keychainSafe || !agentOnly { exit(1) }
'''
with tempfile.TemporaryDirectory(prefix='sr-ssh-removal-', dir='/private/tmp') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(main)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / 'cache'))
    subprocess.run(['swiftc', '-module-cache-path', str(work / 'cache'), '-o', str(work / 'fixture'), str(work / 'main.swift')], check=True, env=env)
    raise SystemExit(subprocess.run([str(work / 'fixture')], env=env).returncode)
