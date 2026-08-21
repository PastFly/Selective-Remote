#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"anchor not found in {path}: {old[:160]!r}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def replace_between(path: Path, start: str, end: str, replacement: str) -> None:
    text = path.read_text(encoding="utf-8")
    start_index = text.find(start)
    if start_index < 0:
        raise SystemExit(f"start anchor not found in {path}: {start!r}")
    end_index = text.find(end, start_index)
    if end_index < 0:
        raise SystemExit(f"end anchor not found in {path}: {end!r}")
    path.write_text(text[:start_index] + replacement + text[end_index:], encoding="utf-8")


# 1) Group values must be editable independently of whether this profile inherits them.
smart = ROOT / "Sources/SelectiveRemote/SmartTerminalFeatures.swift"
replace_once(
    smart,
    'Text("Каждый параметр наследуется отдельно. Если переключатель выключен, используется значение самого профиля.")',
    'Text("Поля справа — общие значения группы и всегда доступны для редактирования. Переключатель слева только определяет, наследует ли этот параметр текущий профиль.")'
)
for line in [
    '                        .disabled(!profile.sshGroupInheritance.username)\n',
    '                        .disabled(!profile.sshGroupInheritance.port)\n',
    '                    .disabled(!profile.sshGroupInheritance.jumpHost)\n',
    '                        .disabled(!profile.sshGroupInheritance.keepAlive)\n',
    '                    .disabled(!profile.sshGroupInheritance.startupSnippet)\n',
]:
    replace_once(smart, line, '')
replace_once(
    smart,
    '''            groupVariableEditor(groupName: name)\n                .disabled(!profile.sshGroupInheritance.variables)\n                .opacity(profile.sshGroupInheritance.variables ? 1 : 0.55)''',
    '''            groupVariableEditor(groupName: name)'''
)

# 2) Fix Keychain migration. Apple explicitly forbids combining
# kSecReturnData + kSecMatchLimitAll for password items. Discover account
# attributes first, then read each secret with MatchLimitOne. This also lets
# migration finish partially if one legacy item is inaccessible/cancelled.
vault = ROOT / "Sources/SelectiveRemote/UnifiedCredentialVault.swift"
replace_once(
    vault,
    'import Security\n\n/// Stores all Selective Remote password secrets',
    '''import Security\n\nstruct CredentialVaultMigrationReport: Equatable, Sendable {\n    var discovered = 0\n    var imported = 0\n    var alreadyStored = 0\n    var failed = 0\n}\n\n/// Stores all Selective Remote password secrets'''
)
replace_between(
    vault,
    '    /// One-time migration for existing per-profile Keychain records.',
    '    private var index: Set<String> {',
    r'''    /// One-time migration for existing per-profile Keychain records.
    ///
    /// Security.framework does not allow `kSecReturnData` together with
    /// `kSecMatchLimitAll` for password items. We therefore enumerate only
    /// non-secret attributes first and then read each password individually.
    /// Old ad-hoc ACLs may still require a one-time macOS authorization per
    /// legacy item; once imported, future app builds use the single vault item.
    @discardableResult
    func importLegacyItems(services: [String]) throws -> CredentialVaultMigrationReport {
        lock.lock()
        defer { lock.unlock() }
        var secrets = try loadIfNeeded()
        var report = CredentialVaultMigrationReport()

        for service in Array(Set(services)).sorted() where service != Self.service {
            let accounts = try legacyAccounts(service: service)
            for account in accounts where !account.hasSuffix(".ssh-key-authorization") {
                report.discovered += 1
                let reference = KeychainCredentialReference(
                    service: service,
                    account: account
                )
                let key = Self.entryKey(for: reference)
                if secrets[key] != nil {
                    report.alreadyStored += 1
                    continue
                }

                switch readLegacySecret(service: service, account: account) {
                case let .success(secret):
                    guard let secret, !secret.isEmpty else { continue }
                    secrets[key] = secret
                    report.imported += 1
                case .failure:
                    // Do not abort the entire migration because one old ACL is
                    // inaccessible or the user cancelled one authorization.
                    report.failed += 1
                }
            }
        }

        if report.imported > 0 {
            try persist(secrets)
            cachedSecrets = secrets
            index = Set(secrets.keys)
        }
        return report
    }

    private func legacyAccounts(service: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        let items: [[String: Any]]
        if let array = result as? [[String: Any]] {
            items = array
        } else if let item = result as? [String: Any] {
            items = [item]
        } else {
            return []
        }
        return Array(Set(items.compactMap { $0[kSecAttrAccount as String] as? String })).sorted()
    }

    private func readLegacySecret(service: String, account: String) -> Result<String?, OSStatus> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess else { return .failure(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return .success(nil) }
        return .success(value)
    }

'''
)

# 3) Report partial migration instead of collapsing everything into one error.
keychain = ROOT / "Sources/SelectiveRemote/KeychainService.swift"
replace_once(
    keychain,
    '''    @discardableResult\n    static func migrateCredentialsToUnifiedVault() throws -> Int {\n        try UnifiedCredentialVault.shared.importLegacyItems(\n            services: [service, legacyService]\n        )\n    }''',
    '''    @discardableResult\n    static func migrateCredentialsToUnifiedVault() throws -> CredentialVaultMigrationReport {\n        try UnifiedCredentialVault.shared.importLegacyItems(\n            services: [service, legacyService]\n        )\n    }'''
)

credential_view = ROOT / "Sources/SelectiveRemote/CredentialVaultView.swift"
replace_once(
    credential_view,
    '''    private func migrateCredentialVault() {\n        do {\n            let imported = try KeychainService.migrateCredentialsToUnifiedVault()\n            unifiedVaultMessage = imported > 0\n                ? "Перенесено записей: \\(imported). Теперь SSH/RDP/SFTP/Forwarding используют один Keychain Vault, который кэшируется только до завершения приложения."\n                : "Новых записей для переноса нет. Единый Vault уже готов к работе."\n        } catch {\n            unifiedVaultMessage = "Не удалось объединить пароли: \\(error.localizedDescription)"\n        }\n    }''',
    '''    private func migrateCredentialVault() {\n        do {\n            let report = try KeychainService.migrateCredentialsToUnifiedVault()\n            if report.discovered == 0 {\n                unifiedVaultMessage = "Старых записей для переноса не найдено. Единый Vault уже готов к работе."\n            } else if report.failed > 0 {\n                unifiedVaultMessage = "Перенесено: \\(report.imported), уже в Vault: \\(report.alreadyStored), не удалось прочитать: \\(report.failed). Недоступные записи можно перенести позже повторным запуском или при обычном подключении к профилю."\n            } else {\n                unifiedVaultMessage = "Перенесено: \\(report.imported), уже в Vault: \\(report.alreadyStored). Теперь сохранённые пароли используют единый Keychain Vault."\n            }\n        } catch {\n            unifiedVaultMessage = "Не удалось объединить пароли: \\(error.localizedDescription)"\n        }\n    }'''
)
replace_once(
    credential_view,
    '                .help("Однократно переносит сохранённые пароли в один защищённый Keychain Vault. После ad-hoc обновления приложению потребуется доступ максимум к одной записи вместо отдельного запроса для каждого профиля.")',
    '                .help("Однократно переносит старые сохранённые пароли в единый Keychain Vault. При первой миграции macOS ещё может запросить доступ к отдельным старым записям; после переноса будущие сборки используют одну Vault-запись.")'
)

# 4) Right-click host -> Edit always opens Connections / General.
content = ROOT / "Sources/SelectiveRemote/ContentView.swift"
replace_once(
    content,
    '''        Divider()\n        Button(\n            item.isFavorite ? "Убрать из избранного" : "В избранное",''',
    '''        Button("Изменить", systemImage: "pencil") {\n            model.selectProfile(item.id)\n            setMainArea(.connections)\n            selectedTab = .general\n        }\n\n        Divider()\n        Button(\n            item.isFavorite ? "Убрать из избранного" : "В избранное",'''
)

# 5) Regression coverage.
tests = ROOT / "Tests/SelectiveRemoteTests/Build139RegressionTests.swift"
tests.write_text(r'''import Foundation
import Testing
@testable import SelectiveRemote

private func source(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

@Test("Group configuration stays editable independently of profile inheritance")
func groupConfigurationEditingRegression() throws {
    let text = try source("Sources/SelectiveRemote/SmartTerminalFeatures.swift")
    #expect(text.contains("Поля справа — общие значения группы и всегда доступны для редактирования"))
    #expect(!text.contains(".disabled(!profile.sshGroupInheritance.username)"))
    #expect(!text.contains(".disabled(!profile.sshGroupInheritance.port)"))
    #expect(!text.contains(".disabled(!profile.sshGroupInheritance.jumpHost)"))
    #expect(!text.contains(".disabled(!profile.sshGroupInheritance.keepAlive)"))
    #expect(!text.contains(".disabled(!profile.sshGroupInheritance.startupSnippet)"))
}

@Test("Keychain migration never requests all password data in one query")
func keychainMigrationQueryRegression() throws {
    let text = try source("Sources/SelectiveRemote/UnifiedCredentialVault.swift")
    #expect(text.contains("private func legacyAccounts(service: String)"))
    #expect(text.contains("private func readLegacySecret(service: String, account: String)"))
    #expect(text.contains("kSecMatchLimit as String: kSecMatchLimitAll,\n            kSecReturnAttributes as String: true"))
    #expect(text.contains("kSecReturnData as String: true,\n            kSecMatchLimit as String: kSecMatchLimitOne"))
    #expect(!text.contains("kSecMatchLimit as String: kSecMatchLimitAll,\n                kSecReturnAttributes as String: true,\n                kSecReturnData as String: true"))
}

@Test("Profile context menu has direct Edit navigation to General")
func profileContextMenuEditRegression() throws {
    let text = try source("Sources/SelectiveRemote/ContentView.swift")
    #expect(text.contains("Button(\"Изменить\", systemImage: \"pencil\")"))
    #expect(text.contains("setMainArea(.connections)\n            selectedTab = .general"))
}
''', encoding="utf-8")

# 6) Candidate metadata.
build = ROOT / "scripts/build_app.sh"
replace_once(build, 'BUILD_NUMBER="138"', 'BUILD_NUMBER="139"')

ru = ROOT / "CHANGELOG.md"
replace_once(
    ru,
    '''## 0.26.0\n\n''',
    '''## 0.26.0\n\n- Исправлено редактирование Group inheritance: общие значения SSH-группы теперь всегда можно менять, а переключатели наследования отвечают только за применение конкретного значения к текущему профилю.\n- Исправлена миграция «Объединить пароли»: устранена ошибка Keychain `-50` за счёт корректного двухэтапного чтения старых записей; частично недоступные записи больше не срывают перенос остальных.\n- В контекстное меню хоста добавлено «Изменить»: команда сразу открывает «Подключения → Основное» выбранного профиля из любого рабочего пространства.\n'''
)
en = ROOT / "CHANGELOG_EN.md"
replace_once(
    en,
    '''## 0.26.0\n\n''',
    '''## 0.26.0\n\n- Fixed Group inheritance editing: shared SSH group values are now always editable, while inheritance switches only control whether the current profile applies each group value.\n- Fixed Merge Passwords migration: removed Keychain `-50` by using a valid two-stage legacy lookup, and inaccessible legacy items no longer abort migration of the remaining credentials.\n- Added Edit to the host context menu; it jumps directly to Connections → General for the selected profile from any workspace.\n'''
)

print("v0.26.0 build 139 patch applied")
