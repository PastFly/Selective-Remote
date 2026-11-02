#!/usr/bin/env python3
"""Exercise actual old/current profile and snippet save bodies with fake preferences."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

fixture = Path(__file__).resolve().parent
repo = fixture.parents[2]
def old(path):
    return subprocess.check_output(['git', 'show', 'v0.31.0:' + path], cwd=repo, text=True)
def current(path):
    return (repo / path).read_text()
def extract(source, pattern):
    match = re.search(pattern, source, re.S)
    if not match:
        raise RuntimeError('source no longer matches fixture: ' + pattern)
    return match.group(1)
profile_path = 'Sources/SelectiveRemote/AppModel.swift'
snippet_path = 'Sources/SelectiveRemote/TerminalCommandHistory.swift'
def make_app(source, name):
    key = extract(source, r'private let profilesKey = ([^\n]+)')
    body = extract(source, r'    private func saveProfiles\(\) \{\n(.*?)\n    \}').replace('UserDefaults.standard', 'FakePreferences.standard')
    return f'class {name} {{ var profiles: [Record] = []; let profilesKey = {key}\nfunc saveProfiles() {{\n{body}\n}}\n}}\n'
def make_snippets(source, name):
    key = extract(source, r'static let templates = ([^\n]+)')
    body = extract(source, r'    private func persistTemplates\(\) \{\n(.*?)\n    \}')
    return f'class {name} {{ var storedTemplates: [Record] = []; var snippetRevision = 0; let defaults = FakePreferences.standard; enum Key {{ static let templates = {key} }}\nfunc persistTemplates() {{\n{body}\n}}\n}}\n'
main = '''import Foundation
struct Record: Codable { let id: String }
final class FakePreferences: NativePreferencesAccess {
 static let standard = FakePreferences()
 var values: [String: Any] = [:]
 func object(forKey key: String) -> Any? { values[key] }
 func data(forKey key: String) -> Data? { values[key] as? Data }
 func set(_ value: Any?, forKey key: String) { values[key] = value }
 func synchronize() -> Bool { true }
}
'''
main += make_app(old(profile_path), 'OldApp') + make_app(current(profile_path), 'NewApp')
main += make_snippets(old(snippet_path), 'OldSnippets') + make_snippets(current(snippet_path), 'NewSnippets')
main += '''
let defaults = FakePreferences.standard
let original = Record(id: "original"), oldEdit = Record(id: "old-edit"), newEdit = Record(id: "new-edit")
let oldApp = OldApp(), newApp = NewApp(), oldSnippets = OldSnippets(), newSnippets = NewSnippets()
oldApp.profiles = [original]; oldApp.saveProfiles()
oldSnippets.storedTemplates = [original]; oldSnippets.persistTemplates()
try NativeStorageMigration.prepare(defaults)
newApp.profiles = try JSONDecoder().decode([Record].self, from: defaults.data(forKey: newApp.profilesKey)!)
newSnippets.storedTemplates = try JSONDecoder().decode([Record].self, from: defaults.data(forKey: NewSnippets.Key.templates)!)
oldApp.profiles.append(oldEdit); oldApp.saveProfiles()
oldSnippets.storedTemplates.append(oldEdit); oldSnippets.persistTemplates()
newApp.profiles.append(newEdit); newApp.saveProfiles()
newSnippets.storedTemplates.append(newEdit); newSnippets.persistTemplates()
func ids(_ key: String) throws -> Set<String> { Set(try JSONDecoder().decode([Record].self, from: defaults.data(forKey: key)!).map(\\.id)) }
let oldHosts = try ids(oldApp.profilesKey), newHosts = try ids(newApp.profilesKey)
let oldSnips = try ids(OldSnippets.Key.templates), newSnips = try ids(NewSnippets.Key.templates)
let isolated = oldHosts == ["original", "old-edit"] && newHosts == ["original", "new-edit"] && oldSnips == oldHosts && newSnips == newHosts
print("OLD_AND_NEW_COLLECTION_WRITES_PRESERVED=" + (isolated ? "PASS" : "FAIL"))
if !isolated { exit(1) }
'''
with tempfile.TemporaryDirectory(prefix='sr-native-collections-', dir='/private/tmp') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(main)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / 'cache'))
    subprocess.run(['swiftc', '-module-cache-path', str(work / 'cache'), '-o', str(work / 'fixture'), str(work / 'main.swift'),
                    str(repo / 'Sources/SelectiveRemote/NativeStorageMigration.swift')], check=True, env=env)
    raise SystemExit(subprocess.run([str(work / 'fixture')], env=env).returncode)
