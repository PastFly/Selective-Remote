#!/usr/bin/env python3
"""Compile actual preferences migration against in-memory test preferences."""
import os
from pathlib import Path
import subprocess
import tempfile
fixture = Path(__file__).resolve().parent
repo = fixture.parents[2]
with tempfile.TemporaryDirectory(prefix='sr-native-storage-', dir='/private/tmp') as directory:
    work = Path(directory)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / 'cache'))
    subprocess.run(['swiftc', '-module-cache-path', str(work / 'cache'), '-o', str(work / 'fixture'),
                    str(fixture / 'main.swift'), str(repo / 'Sources/SelectiveRemote/NativeStorageMigration.swift')], check=True, env=env)
    raise SystemExit(subprocess.run([str(work / 'fixture')], env=env).returncode)
