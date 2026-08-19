import Foundation
import LocalAuthentication
import Security


private final class TouchIDResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var succeeded = false
    private var error: Error?

    func complete(success: Bool, error: Error?) {
        lock.lock()
        succeeded = success
        self.error = error
        finished = true
        lock.unlock()
    }

    func snapshot() -> (finished: Bool, succeeded: Bool, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (finished, succeeded, error)
    }
}

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData
    case touchIDUnavailable(String)
    case biometricAuthenticationFailed(String)
    case recoveryFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil).map { $0 as String }
                ?? "неизвестная ошибка"
            if status == errSecMissingEntitlement {
                return "Keychain не разрешил доступ к старой записи (-34018). Нажмите «Восстановить доступ» рядом с SSH-паролем и сохраните пароль заново."
            }
            return "Ошибка Keychain: \(message) (\(status))"
        case .invalidData:
            return "Keychain вернул некорректные данные"
        case let .touchIDUnavailable(message):
            return message
        case let .biometricAuthenticationFailed(message):
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
    case proxy

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
        case .proxy:
            "\(profileID.uuidString).proxy"
        }
    }
}

enum KeychainService {
    // Keep the original service only for legacy reads. 0.20.3 moves SSH
    // credentials to a fresh namespace so an inaccessible ACL created by an
    // older/ad-hoc-signed build can never block replacing the password.
    static let legacyService = "local.selectiveremote.credentials"
    static let service = "local.selectiveremote.credentials.v2"

    private static let sshPasswordTouchIDDefaultsKey = "SelectiveRemote.sshPasswordUserPresenceProfiles.v1"
    private static let forwardingPasswordTouchIDDefaultsKey = "SelectiveRemote.forwardingPasswordUserPresenceIDs.v1"

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
            service: credentialService(for: kind),
            account: kind.account(profileID: profileID),
            kind: kind
        )
    }

    private static func credentialService(for kind: KeychainCredentialKind) -> String {
        switch kind {
        case .ssh, .forwarding, .sshKeyAuthorization, .proxy:
            return service
        case .rdp, .gateway:
            return legacyService
        }
    }

    static func requiresTouchID(reference: KeychainCredentialReference) -> Bool {
        guard let kind = reference.kind else { return false }
        let defaultsKey: String
        let suffix: String
        switch kind {
        case .ssh:
            defaultsKey = sshPasswordTouchIDDefaultsKey
            suffix = ".ssh"
        case .forwarding:
            defaultsKey = forwardingPasswordTouchIDDefaultsKey
            suffix = ".forwarding"
        default:
            return false
        }
        guard reference.account.hasSuffix(suffix) else { return false }
        let profile = String(reference.account.dropLast(suffix.count))
        return Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).contains(profile)
    }

    static func authenticateTouchID(reason: String) throws {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var availabilityError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &availabilityError),
              context.biometryType == .touchID else {
            throw KeychainError.touchIDUnavailable(
                availabilityError?.localizedDescription
                    ?? "Touch ID недоступен. Добавьте отпечаток в настройках macOS."
            )
        }

        let semaphore = DispatchSemaphore(value: 0)
        let result = TouchIDResultBox()
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        ) { success, error in
            result.complete(success: success, error: error)
            semaphore.signal()
        }

        if Thread.isMainThread {
            while !result.snapshot().finished {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: Date(timeIntervalSinceNow: 0.05)
                )
            }
        } else {
            semaphore.wait()
        }

        let outcome = result.snapshot()
        guard outcome.succeeded else {
            let message = (outcome.error as? LAError).map { error -> String in
                switch error.code {
                case .userCancel, .appCancel, .systemCancel:
                    return "Touch ID отменён. SSH-пароль не был передан."
                case .biometryLockout:
                    return "Touch ID временно заблокирован после нескольких неудачных попыток. Разблокируйте Touch ID в macOS и повторите."
                default:
                    return error.localizedDescription
                }
            } ?? outcome.error?.localizedDescription ?? "Touch ID не подтвердил доступ."
            throw KeychainError.biometricAuthenticationFailed(message)
        }
    }

    static func passwordExists(reference: KeychainCredentialReference) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
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
        var authenticationContext: LAContext?
        if let authenticationPrompt, !authenticationPrompt.isEmpty {
            let context = LAContext()
            context.localizedReason = authenticationPrompt
            authenticationContext = context
            query[kSecUseAuthenticationContext as String] = context
        }
        _ = authenticationContext
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
        let primary = credentialReference(profileID: profileID, kind: kind)
        if let value = try readPassword(reference: primary, authenticationPrompt: authenticationPrompt) {
            return value
        }
        // Best-effort compatibility with 0.20.2 and older. An inaccessible legacy
        // ACL is treated as stale rather than preventing the user from saving a
        // fresh credential in the v2 namespace.
        guard kind == .ssh || kind == .forwarding else { return nil }
        let legacy = KeychainCredentialReference(
            service: legacyService,
            account: kind.account(profileID: profileID),
            kind: kind
        )
        do {
            return try readPassword(reference: legacy, authenticationPrompt: authenticationPrompt)
        } catch let error as KeychainError where error.needsCredentialRepair {
            return nil
        }
    }

    static func savePassword(
        _ password: String,
        profileID: UUID,
        kind: KeychainCredentialKind = .rdp,
        requiresUserPresence: Bool = false
    ) throws {
        let targetService = credentialService(for: kind)
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: targetService,
            kSecAttrAccount as String: kind.account(profileID: profileID)
        ]

        var item = key
        item[kSecValueData as String] = Data(password.utf8)
        if requiresUserPresence && !touchIDAvailable {
            throw KeychainError.touchIDUnavailable(
                "Touch ID недоступен. Добавьте отпечаток в настройках macOS или отключите защиту Touch ID для этого секрета."
            )
        }
        // Deliberately use the traditional generic-password keychain item here.
        // Biometric access control on the data-protection keychain requires a
        // stable entitled identity and returns -34018 in our ad-hoc GitHub
        // builds. The secret still lives in Keychain; Touch ID is enforced by
        // LocalAuthentication immediately before the app reads it.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        // Recreate the item so replacement is deterministic.
        let deleteStatus = SecItemDelete(key as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(deleteStatus)
        }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    static func authorizeSSHKeyUse(profileID: UUID, reason: String) throws {
        try authenticateTouchID(reason: reason)
    }

    static func setSSHKeyUseProtection(profileID: UUID, enabled: Bool) throws {
        if enabled && !touchIDAvailable {
            throw KeychainError.touchIDUnavailable(
                "Touch ID недоступен. Добавьте отпечаток в настройках macOS."
            )
        }
        // Preference is persisted by AppModel. No synthetic Keychain marker is
        // needed; the biometric gate is performed directly before key use.
        try? deletePassword(profileID: profileID, kind: .sshKeyAuthorization)
    }

    static func deletePassword(
        profileID: UUID,
        kind: KeychainCredentialKind = .rdp
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: credentialService(for: kind),
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
        // 0.20.3 no longer has to delete an inaccessible legacy ACL. A fresh
        // namespace is used for SSH/Forwarding, so recovery simply clears the
        // current app-owned record and leaves any unreadable legacy record
        // orphaned and harmless.
        try? deletePassword(profileID: profileID, kind: kind)
        if kind == .ssh || kind == .forwarding {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: kind.account(profileID: profileID)
            ]
            _ = SecItemDelete(legacyQuery as CFDictionary)
        }
    }

    static func deleteAllPasswords(profileID: UUID) throws {
        try deletePassword(profileID: profileID, kind: .rdp)
        try deletePassword(profileID: profileID, kind: .gateway)
        try deletePassword(profileID: profileID, kind: .ssh)
        try deletePassword(profileID: profileID, kind: .sshKeyAuthorization)
        try deletePassword(profileID: profileID, kind: .proxy)
    }
}

struct KeychainCredentialReference: Equatable, Sendable {
    let service: String
    let account: String
    let kind: KeychainCredentialKind?

    init(service: String, account: String, kind: KeychainCredentialKind? = nil) {
        self.service = service
        self.account = account
        self.kind = kind
    }
}
