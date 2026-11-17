#!/usr/bin/env python3
"""Run two actual lease clients against a disposable directory, never app data."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

fixture = Path(__file__).resolve().parent
repo = fixture.parents[2]
with tempfile.TemporaryDirectory(prefix='sr-native-lease-', dir='/private/tmp') as directory:
    work = Path(directory)
    env = dict(os.environ, SR_LEASE_TEST_DIR=str(work / 'locks'), CLANG_MODULE_CACHE_PATH=str(work / 'cache'))
    subprocess.run(['swiftc', '-module-cache-path', str(work / 'cache'), '-o', str(work / 'fixture'),
                    str(fixture / 'main.swift'), str(repo / 'Sources/SelectiveRemote/NativeStorageLease.swift')], check=True, env=env)
    first = subprocess.Popen([str(work / 'fixture'), 'hold'], stdout=subprocess.PIPE, text=True, env=env)
    try:
        if first.stdout.readline().strip() != 'LEASE_ACQUIRED':
            raise RuntimeError('first process did not acquire the lease')
        second = subprocess.run([str(work / 'fixture')], env=env, text=True, capture_output=True, timeout=5)
        busy = second.returncode == 3 and 'LEASE_BUSY' in second.stdout
        first.kill()
        first.wait(timeout=5)
        after = subprocess.run([str(work / 'fixture')], env=env, text=True, capture_output=True, timeout=5)
        recovered = after.returncode == 0 and 'LEASE_ACQUIRED' in after.stdout
        print('SECOND_INSTANCE_BLOCKED=' + ('PASS' if busy else 'FAIL'))
        print('LEASE_RELEASED_AFTER_CRASH=' + ('PASS' if recovered else 'FAIL'))
        raise SystemExit(0 if busy and recovered else 1)
    finally:
        if first.poll() is None:
            first.kill()
            first.wait()
