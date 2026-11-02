#!/usr/bin/env python3
"""Compare the real 0.31 and current sources using only a fake Keychain."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

fixture = Path(__file__).resolve().parent
repo = fixture.parents[2]
current = (repo / 'Sources/SelectiveRemote/UnifiedCredentialVault.swift').read_text()
old = subprocess.check_output(['git', 'show', 'v0.31.0:Sources/SelectiveRemote/UnifiedCredentialVault.swift'], cwd=repo, text=True)

def isolated(source):
    return source.replace('import Security', 'import CoreFoundation').replace('UserDefaults', 'FakeDefaults')

with tempfile.TemporaryDirectory(prefix='sr-legacy-keychain-matrix-', dir='/private/tmp') as directory:
    work = Path(directory)
    (work / 'Current.swift').write_text(isolated(current))
    (work / 'Old.swift').write_text(isolated(old).replace('UnifiedCredentialVault', 'OldUnifiedCredentialVault').replace('CredentialVaultMigrationReport', 'OldCredentialVaultMigrationReport'))
    main = (fixture / 'legacy_matrix.swift').read_text()
    main = re.sub(r'(?<!Old)UnifiedCredentialVault\(defaults: FakeDefaults\(\)\)',
                  'UnifiedCredentialVault(defaults: FakeDefaults(), lockDirectory: URL(fileURLWithPath: "' + str(work / 'locks') + '"))', main)
    (work / 'main.swift').write_text(main)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / 'cache'))
    subprocess.run(['swiftc', '-module-cache-path', str(work / 'cache'), '-o', str(work / 'matrix'),
                    str(work / 'main.swift'), str(work / 'Current.swift'), str(work / 'Old.swift')], check=True, env=env)
    raise SystemExit(subprocess.run([str(work / 'matrix')], env=env).returncode)
