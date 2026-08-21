#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
vault = ROOT / "Sources/SelectiveRemote/UnifiedCredentialVault.swift"
text = vault.read_text(encoding="utf-8")

old = '''                switch readLegacySecret(service: service, account: account) {\n                case let .success(secret):\n                    guard let secret, !secret.isEmpty else { continue }\n                    secrets[key] = secret\n                    report.imported += 1\n                case .failure:\n                    // Do not abort the entire migration because one old ACL is\n                    // inaccessible or the user cancelled one authorization.\n                    report.failed += 1\n                }'''
new = '''                let read = readLegacySecret(service: service, account: account)\n                if read.status == errSecSuccess {\n                    guard let secret = read.value, !secret.isEmpty else { continue }\n                    secrets[key] = secret\n                    report.imported += 1\n                } else if read.status != errSecItemNotFound {\n                    // Do not abort the entire migration because one old ACL is\n                    // inaccessible or the user cancelled one authorization.\n                    report.failed += 1\n                }'''
if old not in text:
    raise SystemExit("migration result switch anchor not found")
text = text.replace(old, new, 1)

old = '''    private func readLegacySecret(service: String, account: String) -> Result<String?, OSStatus> {\n        let query: [String: Any] = [\n            kSecClass as String: kSecClassGenericPassword,\n            kSecAttrService as String: service,\n            kSecAttrAccount as String: account,\n            kSecReturnData as String: true,\n            kSecMatchLimit as String: kSecMatchLimitOne\n        ]\n        var result: CFTypeRef?\n        let status = SecItemCopyMatching(query as CFDictionary, &result)\n        if status == errSecItemNotFound { return .success(nil) }\n        guard status == errSecSuccess else { return .failure(status) }\n        guard let data = result as? Data,\n              let value = String(data: data, encoding: .utf8)\n        else { return .success(nil) }\n        return .success(value)\n    }'''
new = '''    private func readLegacySecret(service: String, account: String) -> (value: String?, status: OSStatus) {\n        let query: [String: Any] = [\n            kSecClass as String: kSecClassGenericPassword,\n            kSecAttrService as String: service,\n            kSecAttrAccount as String: account,\n            kSecReturnData as String: true,\n            kSecMatchLimit as String: kSecMatchLimitOne\n        ]\n        var result: CFTypeRef?\n        let status = SecItemCopyMatching(query as CFDictionary, &result)\n        guard status == errSecSuccess else { return (nil, status) }\n        guard let data = result as? Data,\n              let value = String(data: data, encoding: .utf8)\n        else { return (nil, errSecDecode) }\n        return (value, errSecSuccess)\n    }'''
if old not in text:
    raise SystemExit("legacy secret helper anchor not found")
text = text.replace(old, new, 1)
vault.write_text(text, encoding="utf-8")
print("build 139 migration helper typing fixed")
