#!/usr/bin/env python3
"""Compile the actual vault against a disposable fake Keychain; never accesses user secrets."""
import os
from pathlib import Path
import subprocess
import tempfile

fixture = Path(__file__).resolve().parent
repo = fixture.parents[2]
source = (repo / 'Sources/SelectiveRemote/UnifiedCredentialVault.swift').read_text()
if 'import Security' not in source or 'UserDefaults' not in source:
    raise RuntimeError('vault source no longer matches the isolated fixture')
source = source.replace('import Security', 'import CoreFoundation').replace('UserDefaults', 'FakeDefaults')
with tempfile.TemporaryDirectory(prefix='sr-unified-vault-fixture-', dir='/private/tmp') as directory:
    work = Path(directory)
    (work / 'Vault.swift').write_text(source)
    main = (fixture / 'main.swift').read_text().replace(
        'UnifiedCredentialVault(defaults: FakeDefaults())',
        'UnifiedCredentialVault(defaults: FakeDefaults(), lockDirectory: URL(fileURLWithPath: "' + str(work / 'locks') + '"))',
    )
    main = main.replace(
        'UnifiedCredentialVault(defaults: oldDefaults)',
        'UnifiedCredentialVault(defaults: oldDefaults, lockDirectory: URL(fileURLWithPath: "' + str(work / 'locks') + '"))',
    )
    (work / 'main.swift').write_text(main)
    cache = work / 'cache'
    environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache), SR_FIXTURE_DIR=str(work))
    subprocess.run(['swiftc', '-module-cache-path', str(cache), '-o', str(work / 'fixture'),
                    str(work / 'main.swift'), str(work / 'Vault.swift')], check=True, env=environment)
    raise SystemExit(subprocess.run([str(work / 'fixture')], env=environment).returncode)
