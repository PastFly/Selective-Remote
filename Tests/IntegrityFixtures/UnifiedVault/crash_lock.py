#!/usr/bin/env python3
"""Kill a test-only writer after its read; verify lock release and data survival."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

fixture = Path(__file__).resolve().parent
repo = fixture.parents[2]
source = (repo / 'Sources/SelectiveRemote/UnifiedCredentialVault.swift').read_text().replace('import Security', 'import CoreFoundation').replace('UserDefaults', 'FakeDefaults')
main = (fixture / 'parallel.swift').read_text().replace('UnifiedCredentialVault(defaults: FakeDefaults())',
    'UnifiedCredentialVault(defaults: FakeDefaults(), lockDirectory: fixtureDirectory.appendingPathComponent("locks"))')
with tempfile.TemporaryDirectory(prefix='sr-crash-lock-', dir='/private/tmp') as directory:
    work = Path(directory)
    (work / 'Vault.swift').write_text(source)
    (work / 'main.swift').write_text(main)
    (work / 'locks').mkdir(mode=0o700)
    original = 'TEST-ONLY\x1foriginal'
    (work / 'item.json').write_text(json.dumps({original: 'original'}))
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / 'cache'), SR_FIXTURE_DIR=str(work))
    subprocess.run(['swiftc', '-module-cache-path', str(work / 'cache'), '-o', str(work / 'fixture'),
                    str(work / 'main.swift'), str(work / 'Vault.swift')], check=True, env=env)
    first = subprocess.Popen([str(work / 'fixture'), 'A'], env=env)
    try:
        deadline = time.monotonic() + 10
        while not (work / 'read-A').exists() and time.monotonic() < deadline:
            if first.poll() is not None:
                raise RuntimeError('writer exited before the read checkpoint')
            time.sleep(0.002)
        if not (work / 'read-A').exists():
            raise RuntimeError('writer did not reach the read checkpoint')
        first.kill()
        first.wait(timeout=5)
        second = subprocess.run([str(work / 'fixture'), 'B'], env=env, timeout=10)
        records = json.loads((work / 'item.json').read_text())
        intact = second.returncode == 0 and records.get(original) == 'original' and records.get('TEST-ONLY\x1fB') == 'B' and 'TEST-ONLY\x1fA' not in records
        print('CRASH_RELEASES_LOCK_AND_PRESERVES_DATA=' + ('PASS' if intact else 'FAIL'))
        raise SystemExit(0 if intact else 1)
    finally:
        if first.poll() is None:
            first.kill()
            first.wait()
