#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"anchor not found in {path}: {old[:120]!r}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


# 1) Make SSH automation discoverable as its own profile tab.
content = ROOT / "Sources/SelectiveRemote/ContentView.swift"
replace_once(content,
'''    case terminal = "Терминал"\n    case sftp = "SFTP"''',
'''    case terminal = "Терминал"\n    case automation = "Автоматизация"\n    case sftp = "SFTP"''')
replace_once(content,
'''        case .terminal: "terminal"\n        case .sftp: "folder.badge.gearshape"''',
'''        case .terminal: "terminal"\n        case .automation: "gearshape.2"\n        case .sftp: "folder.badge.gearshape"''')
replace_once(content,
'''            [.general, .authentication, .route, .terminal, .sftp, .forwarding, .security]''',
'''            [.general, .authentication, .route, .automation, .terminal, .sftp, .forwarding, .security]''')
replace_once(content,
'''        case .terminal:\n            UpdateLocalization.text(ru: "Терминал", en: "Terminal")\n        case .sftp:''',
'''        case .terminal:\n            UpdateLocalization.text(ru: "Терминал", en: "Terminal")\n        case .automation:\n            UpdateLocalization.text(ru: "Автоматизация", en: "Automation")\n        case .sftp:''')
replace_once(content,
'''        case .terminal:\n            UpdateLocalization.text(ru: "Командная строка", en: "Command line")\n        case .sftp:''',
'''        case .terminal:\n            UpdateLocalization.text(ru: "Командная строка", en: "Command line")\n        case .automation:\n            UpdateLocalization.text(ru: "Startup Snippets и группы", en: "Startup Snippets & groups")\n        case .sftp:''')
replace_once(content,
'''        case .terminal:\n            UpdateLocalization.text(\n                ru: "Полноразмерный Terminal Workspace этого SSH-профиля.",\n                en: "Full-size Terminal Workspace for this SSH profile."\n            )\n        case .sftp:''',
'''        case .terminal:\n            UpdateLocalization.text(\n                ru: "Полноразмерный Terminal Workspace этого SSH-профиля.",\n                en: "Full-size Terminal Workspace for this SSH profile."\n            )\n        case .automation:\n            UpdateLocalization.text(\n                ru: "Startup Snippet, переменные и наследование настроек SSH-группы.",\n                en: "Startup Snippet, variables, and SSH group inheritance."\n            )\n        case .sftp:''')
replace_once(content,
'''        case .terminal: EmptyView()\n        case .sftp: EmptyView()''',
'''        case .terminal: EmptyView()\n        case .automation:\n            SSHAutomationSettingsView(\n                profile: profileBinding,\n                sshProfiles: model.profiles.filter { $0.connectionType == .ssh }\n            )\n        case .sftp: EmptyView()''')
replace_once(content,
'''\n            SSHAutomationSettingsView(\n                profile: profileBinding,\n                sshProfiles: model.profiles.filter { $0.connectionType == .ssh }\n            )\n        }\n    }\n\n    private func credentialEditor(''',
'''\n        }\n    }\n\n    private func credentialEditor(''')

# 2) Explain why group inheritance may not be visible yet.
smart = ROOT / "Sources/SelectiveRemote/SmartTerminalFeatures.swift"
replace_once(smart,
'''                if hasGroup {\n                    Divider()\n                    groupSection\n                }''',
'''                Divider()\n                if hasGroup {\n                    groupSection\n                } else {\n                    VStack(alignment: .leading, spacing: 8) {\n                        Label("Наследование настроек группы", systemImage: "square.stack.3d.up")\n                            .font(.headline)\n                        Text("У этого SSH-профиля пока нет группы. Назначьте группу во вкладке «Основное» — здесь сразу появятся общие username, порт, Jump Host, Keepalive, Startup Snippet и переменные группы.")\n                            .font(.caption)\n                            .foregroundStyle(.secondary)\n                    }\n                    .padding(10)\n                    .frame(maxWidth: .infinity, alignment: .leading)\n                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))\n                }''')

# 3) Unified credential vault: one Keychain record for all app passwords.
vault = ROOT / "Sources/SelectiveRemote/UnifiedCredentialVault.swift"
vault.write_text(r'''import Foundation
import Security

/// Stores all Selective Remote password secrets inside one generic-password
/// Keychain item. Ad-hoc signed builds get a new designated identity after an
/// update, so legacy per-profile Keychain ACLs can ask for authorization once
/// per item. A single vault reduces that to one Keychain authorization and the
/// decoded vault is cached only in process memory for the lifetime of the app.
final class UnifiedCredentialVault: @unchecked Sendable {
    static let shared = UnifiedCredentialVault()
    static let service = "local.selectiveremote.credentials.unified.v1"
    static let account = "credential-vault"

    private let lock = NSRecursiveLock()
    private var cachedSecrets: [String: String]?
    private let defaults: UserDefaults
    private let indexKey = "SelectiveRemote.keychain.unifiedVault.index.v1"
    private let suppressedLegacyKey = "SelectiveRemote.keychain.unifiedVault.suppressedLegacy.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func entryKey(for reference: KeychainCredentialReference) -> String {
        reference.service + "\u{1F}" + reference.account
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return index.count
    }

    func contains(reference: KeychainCredentialReference) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.entryKey(for: reference)
        if let cachedSecrets { return cachedSecrets[key] != nil }
        return index.contains(key)
    }

    func isLegacySuppressed(reference: KeychainCredentialReference) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return suppressedLegacy.contains(Self.entryKey(for: reference))
    }

    func read(reference: KeychainCredentialReference) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        let secrets = try loadIfNeeded()
        return secrets[Self.entryKey(for: reference)]
    }

    func save(_ secret: String, reference: KeychainCredentialReference) throws {
        lock.lock()
        defer { lock.unlock() }
        var secrets = try loadIfNeeded()
        let key = Self.entryKey(for: reference)
        secrets[key] = secret
        try persist(secrets)
        cachedSecrets = secrets
        var updatedIndex = index
        updatedIndex.insert(key)
        index = updatedIndex
        var suppressed = suppressedLegacy
        suppressed.remove(key)
        suppressedLegacy = suppressed
    }

    func delete(reference: KeychainCredentialReference) throws {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.entryKey(for: reference)
        var secrets = try loadIfNeeded()
        if secrets.removeValue(forKey: key) != nil {
            try persist(secrets)
            cachedSecrets = secrets
        }
        var updatedIndex = index
        updatedIndex.remove(key)
        index = updatedIndex
        var suppressed = suppressedLegacy
        suppressed.insert(key)
        suppressedLegacy = suppressed
    }

    func unlock() throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try loadIfNeeded()
    }

    /// One-time migration for existing per-profile Keychain records. The query
    /// is performed per Selective Remote service with MatchLimitAll, so macOS
    /// can authorize the batch instead of the app issuing 100 independent reads.
    @discardableResult
    func importLegacyItems(services: [String]) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        var secrets = try loadIfNeeded()
        var imported = 0

        for service in Array(Set(services)).sorted() where service != Self.service {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else {
                throw KeychainError.unexpectedStatus(status)
            }

            let items: [[String: Any]]
            if let array = result as? [[String: Any]] {
                items = array
            } else if let item = result as? [String: Any] {
                items = [item]
            } else {
                continue
            }

            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      let data = item[kSecValueData as String] as? Data,
                      let secret = String(data: data, encoding: .utf8),
                      !secret.isEmpty
                else { continue }
                let reference = KeychainCredentialReference(
                    service: service,
                    account: account
                )
                let key = Self.entryKey(for: reference)
                if secrets[key] != secret {
                    secrets[key] = secret
                    imported += 1
                }
            }
        }

        if imported > 0 {
            try persist(secrets)
            cachedSecrets = secrets
            index = Set(secrets.keys)
        }
        return imported
    }

    private var index: Set<String> {
        get { Set(defaults.stringArray(forKey: indexKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: indexKey) }
    }

    private var suppressedLegacy: Set<String> {
        get { Set(defaults.stringArray(forKey: suppressedLegacyKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: suppressedLegacyKey) }
    }

    private func loadIfNeeded() throws -> [String: String] {
        if let cachedSecrets { return cachedSecrets }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            cachedSecrets = [:]
            return [:]
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            throw KeychainError.invalidData
        }
        cachedSecrets = decoded
        index = Set(decoded.keys)
        return decoded
    }

    private func persist(_ secrets: [String: String]) throws {
        let data = try JSONEncoder().encode(secrets)
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        let updateStatus = SecItemUpdate(
            key as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
        var item = key
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }
}
''', encoding="utf-8")

# Route all password reads/writes through the unified vault, preserving legacy fallback.
keychain = ROOT / "Sources/SelectiveRemote/KeychainService.swift"
replace_once(keychain,
'''    static func passwordExists(reference: KeychainCredentialReference) -> Bool {\n        let query: [String: Any] = [''',
'''    static func passwordExists(reference: KeychainCredentialReference) -> Bool {\n        if UnifiedCredentialVault.shared.contains(reference: reference) { return true }\n        if UnifiedCredentialVault.shared.isLegacySuppressed(reference: reference) { return false }\n        let query: [String: Any] = [''')
replace_once(keychain,
'''    static func readPassword(\n        reference: KeychainCredentialReference,\n        authenticationPrompt: String? = nil\n    ) throws -> String? {\n        var query: [String: Any] = [''',
'''    static func readPassword(\n        reference: KeychainCredentialReference,\n        authenticationPrompt: String? = nil\n    ) throws -> String? {\n        if let value = try UnifiedCredentialVault.shared.read(reference: reference) {\n            return value\n        }\n        if UnifiedCredentialVault.shared.isLegacySuppressed(reference: reference) {\n            return nil\n        }\n        var query: [String: Any] = [''')
replace_once(keychain,
'''        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {\n            throw KeychainError.invalidData\n        }\n        return value\n    }''',
'''        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {\n            throw KeychainError.invalidData\n        }\n        // Lazy migration: once a legacy record has been authorized, future\n        // sessions and future app builds use the single unified vault item.\n        try? UnifiedCredentialVault.shared.save(value, reference: reference)\n        return value\n    }''')

start = keychain.read_text(encoding="utf-8")
old_save_start = start.index("    static func savePassword(\n")
old_delete_start = start.index("    static func deletePassword(\n", old_save_start)
new_save = r'''    static func savePassword(
        _ password: String,
        profileID: UUID,
        kind: KeychainCredentialKind = .rdp,
        requiresUserPresence: Bool = false
    ) throws {
        if requiresUserPresence && !touchIDAvailable {
            throw KeychainError.touchIDUnavailable(
                "Touch ID недоступен. Добавьте отпечаток в настройках macOS или отключите защиту Touch ID для этого секрета."
            )
        }
        let reference = credentialReference(profileID: profileID, kind: kind)
        try UnifiedCredentialVault.shared.save(password, reference: reference)
    }

    static var unifiedVaultEntryCount: Int {
        UnifiedCredentialVault.shared.entryCount
    }

    static func unlockUnifiedCredentialVault() throws {
        try UnifiedCredentialVault.shared.unlock()
    }

    @discardableResult
    static func migrateCredentialsToUnifiedVault() throws -> Int {
        try UnifiedCredentialVault.shared.importLegacyItems(
            services: [service, legacyService]
        )
    }

'''
start = start[:old_save_start] + new_save + start[old_delete_start:]
keychain.write_text(start, encoding="utf-8")

# Replace deletePassword with vault deletion + legacy tombstone. Old physical
# items may remain orphaned; they are intentionally ignored after explicit delete.
text = keychain.read_text(encoding="utf-8")
old_delete_start = text.index("    static func deletePassword(\n")
repair_start = text.index("    /// Recovery for a legacy login-keychain ACL", old_delete_start)
new_delete = r'''    static func deletePassword(
        profileID: UUID,
        kind: KeychainCredentialKind = .rdp
    ) throws {
        let reference = credentialReference(profileID: profileID, kind: kind)
        try UnifiedCredentialVault.shared.delete(reference: reference)
    }

'''
text = text[:old_delete_start] + new_delete + text[repair_start:]
keychain.write_text(text, encoding="utf-8")

# 4) Surface one-time migration in the Keychain screen.
credential_view = ROOT / "Sources/SelectiveRemote/CredentialVaultView.swift"
replace_once(credential_view,
'''    @State private var knownHostProfileCreationEntry: SSHKnownHostEntry?\n''',
'''    @State private var knownHostProfileCreationEntry: SSHKnownHostEntry?\n    @State private var unifiedVaultMessage: String?\n''')
replace_once(credential_view,
'''            Spacer()\n\n            if presentation == .sheet {''',
'''            Spacer()\n\n            VStack(alignment: .trailing, spacing: 3) {\n                Button {\n                    migrateCredentialVault()\n                } label: {\n                    Label("Объединить пароли", systemImage: "lock.square.stack")\n                }\n                .buttonStyle(.bordered)\n                .help("Однократно переносит сохранённые пароли в один защищённый Keychain Vault. После ad-hoc обновления приложению потребуется доступ максимум к одной записи вместо отдельного запроса для каждого профиля.")\n                Text("Единый Vault: \\(KeychainService.unifiedVaultEntryCount)")\n                    .font(.caption2.monospacedDigit())\n                    .foregroundStyle(.secondary)\n            }\n\n            if presentation == .sheet {''')
replace_once(credential_view,
'''        baseLayout\n            .onAppear(perform: handleAppear)\n            .onChange(of: selection) { _, _ in''',
'''        baseLayout\n            .onAppear(perform: handleAppear)\n            .alert("Единый Keychain Vault", isPresented: Binding(\n                get: { unifiedVaultMessage != nil },\n                set: { if !$0 { unifiedVaultMessage = nil } }\n            )) {\n                Button("OK", role: .cancel) { unifiedVaultMessage = nil }\n            } message: {\n                Text(unifiedVaultMessage ?? "")\n            }\n            .onChange(of: selection) { _, _ in''')
replace_once(credential_view,
'''    private func handleAppear() {''',
'''    private func migrateCredentialVault() {\n        do {\n            let imported = try KeychainService.migrateCredentialsToUnifiedVault()\n            unifiedVaultMessage = imported > 0\n                ? "Перенесено записей: \\(imported). Теперь SSH/RDP/SFTP/Forwarding используют один Keychain Vault, который кэшируется только до завершения приложения."\n                : "Новых записей для переноса нет. Единый Vault уже готов к работе."\n        } catch {\n            unifiedVaultMessage = "Не удалось объединить пароли: \\(error.localizedDescription)"\n        }\n    }\n\n    private func handleAppear() {''')

# 5) Regression coverage without touching the real login Keychain in CI.
tests = ROOT / "Tests/SelectiveRemoteTests/KeychainVault0260Tests.swift"
tests.write_text(r'''import Foundation
import Testing
@testable import SelectiveRemote

@Test("Unified Keychain Vault uses one deterministic entry namespace")
func unifiedVaultEntryKeyIsStable() {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let ssh = KeychainService.credentialReference(profileID: id, kind: .ssh)
    let proxy = KeychainService.credentialReference(profileID: id, kind: .proxy)
    #expect(UnifiedCredentialVault.entryKey(for: ssh) != UnifiedCredentialVault.entryKey(for: proxy))
    #expect(UnifiedCredentialVault.entryKey(for: ssh).contains(id.uuidString))
}

@Test("SSH profile exposes Automation as a dedicated settings tab")
func automationTabSourceRegression() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )
    #expect(source.contains("case automation = \"Автоматизация\""))
    #expect(source.contains("case .automation:"))
    #expect(source.contains("SSHAutomationSettingsView"))
}

@Test("Keychain reads unified vault before legacy per-profile records")
func unifiedVaultRoutingSourceRegression() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let service = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/KeychainService.swift"),
        encoding: .utf8
    )
    let view = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/CredentialVaultView.swift"),
        encoding: .utf8
    )
    #expect(service.contains("UnifiedCredentialVault.shared.read"))
    #expect(service.contains("migrateCredentialsToUnifiedVault"))
    #expect(view.contains("Объединить пароли"))
}
''', encoding="utf-8")

# 6) Candidate metadata.
build = ROOT / "scripts/build_app.sh"
replace_once(build, 'BUILD_NUMBER="137"', 'BUILD_NUMBER="138"')

ru = ROOT / "CHANGELOG.md"
replace_once(ru,
'''## 0.26.0\n\n''',
'''## 0.26.0\n\n- Startup Snippets, Terminal Variables и Group inheritance вынесены в отдельную видимую вкладку «Автоматизация» SSH-профиля; если группа не назначена, интерфейс прямо объясняет, где её включить.\n- Добавлен единый Keychain Vault для паролей RDP/SSH/Proxy/Forwarding: после первого доступа секреты читаются из одной Keychain-записи и кэшируются только в памяти до завершения приложения, что устраняет лавину системных запросов после ad-hoc обновлений.\n- В разделе «Связка ключей» добавлена однократная команда «Объединить пароли» для пакетного переноса существующих per-profile записей в единый Vault.\n''')
en = ROOT / "CHANGELOG_EN.md"
replace_once(en,
'''## 0.26.0\n\n''',
'''## 0.26.0\n\n- Startup Snippets, Terminal Variables, and Group inheritance now have a dedicated visible Automation tab in SSH profile settings; profiles without a group get an explicit setup hint.\n- Added a unified Keychain Vault for RDP/SSH/Proxy/Forwarding passwords: after the first authorization, secrets are read from one Keychain record and cached only in memory until the app exits, preventing a storm of per-profile prompts after ad-hoc updates.\n- The Keychain screen now includes a one-time Merge Passwords action that batch-migrates existing per-profile records into the unified Vault.\n''')

print("v0.26.0 build 138 Keychain vault and Automation UX patch applied")
