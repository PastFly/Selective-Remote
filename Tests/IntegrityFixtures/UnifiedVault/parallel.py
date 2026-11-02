#!/usr/bin/env python3
"""Race two actual-source vault writers using only a disposable file-backed fake Keychain."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

fixture = Path(__file__).resolve().parent
repo = fixture.parents[2]
source = (repo / 'Sources/SelectiveRemote/UnifiedCredentialVault.swift').read_text()
source = source.replace('import Security', 'import CoreFoundation').replace('UserDefaults', 'FakeDefaults')
if os.environ.get('SR_LOCK_TRACE'):
    source = source.replace('throw KeychainError.vaultLockUnavailable', 'fputs("LOCK_FAILURE_LINE=\\(#line) ERRNO=\\(errno)\\n", stderr); throw KeychainError.vaultLockUnavailable')
main = (fixture / 'parallel.swift').read_text()
if 'lockDirectory:' in source:
    main = main.replace('UnifiedCredentialVault(defaults: FakeDefaults())',
                        'UnifiedCredentialVault(defaults: FakeDefaults(), lockDirectory: fixtureDirectory.appendingPathComponent("locks"))')
with tempfile.TemporaryDirectory(prefix='sr-vault-parallel-', dir='/private/tmp') as directory:
    work = Path(directory)
    (work / 'Vault.swift').write_text(source)
    (work / 'main.swift').write_text(main)
    (work / 'locks').mkdir(mode=0o700)
    (work / 'item.json').write_text('{}')
    environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / 'cache'), SR_FIXTURE_DIR=str(work))
    subprocess.run(['swiftc', '-module-cache-path', str(work / 'cache'), '-o', str(work / 'fixture'),
                    str(work / 'main.swift'), str(work / 'Vault.swift')], check=True, env=environment)
    workers = [subprocess.Popen([str(work / 'fixture'), worker], env=environment) for worker in ['A', 'B']]
    try:
        exits = [worker.wait(timeout=15) for worker in workers]
    finally:
        for worker in workers:
            if worker.poll() is None:
                worker.kill()
                worker.wait()
    records = json.loads((work / 'item.json').read_text())
    intact = exits == [0, 0] and records.get('TEST-ONLY\x1fA') == 'A' and records.get('TEST-ONLY\x1fB') == 'B'
    print('TWO_PROCESS_WRITES_PRESERVED=' + ('PASS' if intact else 'FAIL'))
    raise SystemExit(0 if intact else 1)
