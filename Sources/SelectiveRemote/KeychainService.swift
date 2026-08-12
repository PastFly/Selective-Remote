import Foundation
import LocalAuthentication
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData
    case touchIDUnavailable(String)
    case recoveryFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil).map { $0 as String }
                ?? "неизвестная ошибка"
            if status == errSecMissingEntitlement {
                return "Keychain не разрешил доступ к старой записи (-34018). Нажмите «Исправить доступ» рядом с SSH-паролем и сохраните пароль заново."
            }
            return "Ошибка Keychain: \(message) (\(status))"
        case .invalidData:
            return "Keychain вернул некорректные данные"
        case let .touchIDUnavailable(message):
            return message
        case let .recoveryFailed(message):
            return message
        }
    }

    var needsCredentialRepair: Bool {
        if case let .unexpectedStatus(status) = self {
            return status == errSecMissingEntitlement || status == errSecAuthFailed
        }
        return false
    }
}

enum KeychainCredentialKind: String {
    case rdp
    case gateway
    case ssh
    case forwarding
    case sshKeyAuthorization

    func account(profileID: UUID) -> String {
        switch self {
        case .rdp:
            profileID.uuidString
        case .gateway:
            "\(profileID.uuidString).gateway"
        case .ssh:
            "\(profileID.uuidString).ssh"
        case .forwarding:
            "\(profileID.uuidString).forwarding"
        case .sshKeyAuthorization:
            "\(profileID.uuidString).ssh-key-authorization"
        }
    }
}

enum KeychainService {
    static let service = "local.selectiveremote.credentials"

    static var touchIDAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            && context.biometryType == .touchID
    }

    static func credentialReference(
        profileID: UUID,
        kind: KeychainCredentialKind
    ) -> KeychainCredentialReference {
        KeychainCredentialReference(
            service: service,
            account: kind.account(profileID: profileID)
        )
    }

    static func readPassword(
        reference: KeychainCredentialReference,
        authenticationPrompt: String? = nil
    ) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let authenticationPrompt, !authenticationPrompt.isEmpty {
            query[kSecUseOperationPrompt as String] = authenticationPrompt
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    static func readPassword(
        profileID: UUID,
        kind: KeychainCredentialKind = .rdp,
        authenticationPrompt: String? = nil
    ) throws -> String? {
        try readPassword(
            reference: credentialReference(profileID: profileID, kind: kind),
            authenticationPrompt: authenticationPrompt
        )
    }

    static func savePassword(
        _ password: String,
        profileID: UUID,
        kind: KeychainCredentialKind = .rdp,
        requiresUserPresence: Bool = false
    ) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.account(profileID: profileID)
        ]

        var item = key
        item[kSecValueData as String] = Data(password.utf8)
        if requiresUserPresence {
            guard touchIDAvailable else {
                throw KeychainError.touchIDUnavailable(
                    "Touch ID недоступен. Добавьте отпечаток в настройках macOS или отключите защиту Touch ID для этого секрета."
                )
            }
            var accessError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .biometryCurrentSet,
                &accessError
            ) else {
                let message = accessError.map {
                    CFErrorCopyDescription($0.takeRetainedValue()) as String
                } ?? "не удалось создать биометрическую политику Keychain"
                throw KeychainError.touchIDUnavailable(message)
            }
            item[kSecAttrAccessControl as String] = access
        } else {
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }

        // kSecAttrAccessControl cannot be changed safely in-place. Recreate the
        // item so switching Touch ID on/off has deterministic semantics.
        let deleteStatus = SecItemDelete(key as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            let deleteError = KeychainError.unexpectedStatus(deleteStatus)
            if deleteError.needsCredentialRepair {
                try deleteWithSecurityTool(profileID: profileID, kind: kind)
            } else {
                throw deleteError
            }
        }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    static func authorizeSSHKeyUse(profileID: UUID, reason: String) throws {
        guard try readPassword(
            profileID: profileID,
            kind: .sshKeyAuthorization,
            authenticationPrompt: reason
        ) != nil else {
            throw KeychainError.invalidData
        }
    }

    static func setSSHKeyUseProtection(profileID: UUID, enabled: Bool) throws {
        if enabled {
            try savePassword(
                UUID().uuidString,
                profileID: profileID,
                kind: .sshKeyAuthorization,
                requiresUserPresence: true
            )
        } else {
            try deletePassword(profileID: profileID, kind: .sshKeyAuthorization)
        }
    }

    static func deletePassword(
        profileID: UUID,
        kind: KeychainCredentialKind = .rdp
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.account(profileID: profileID)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Recovery for a legacy login-keychain ACL that the current build can no
    /// longer access (for example after an ad-hoc signature changed and the
    /// user accidentally chose an incorrect permanent authorization).
    ///
    /// First use SecItemDelete. If macOS reports a stale authorization problem,
    /// ask the system `security` utility to remove only this app-owned generic
    /// password record. The caller must then ask the user to save the SSH
    /// password again; no secret is exported or copied during recovery.
    static func repairPasswordAccess(
        profileID: UUID,
        kind: KeychainCredentialKind
    ) throws {
        do {
            try deletePassword(profileID: profileID, kind: kind)
            return
        } catch let error as KeychainError where error.needsCredentialRepair {
            try deleteWithSecurityTool(profileID: profileID, kind: kind)
        }
    }

    private static func deleteWithSecurityTool(
        profileID: UUID,
        kind: KeychainCredentialKind
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "delete-generic-password",
            "-s", service,
            "-a", kind.account(profileID: profileID)
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw KeychainError.recoveryFailed(
                "Не удалось запустить системное восстановление Keychain: \(error.localizedDescription)"
            )
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus == 0 || output.localizedCaseInsensitiveContains("could not be found") {
            return
        }
        throw KeychainError.recoveryFailed(
            "macOS не смогла удалить повреждённую запись Keychain. Откройте «Пароли и связка ключей» в Системных настройках и удалите запись сервиса \(service), затем сохраните пароль заново.\n\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        )
    }

    static func deleteAllPasswords(profileID: UUID) throws {
        try deletePassword(profileID: profileID, kind: .rdp)
        try deletePassword(profileID: profileID, kind: .gateway)
        try deletePassword(profileID: profileID, kind: .ssh)
        try deletePassword(profileID: profileID, kind: .sshKeyAuthorization)
    }
}

struct KeychainCredentialReference: Equatable, Sendable {
    let service: String
    let account: String
}
