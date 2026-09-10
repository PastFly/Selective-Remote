import Foundation

actor SelectiveRemotePersonalVaultCredentialCollector {
    static let shared = SelectiveRemotePersonalVaultCredentialCollector()
    private var authorizedForSession = false

    func collect(
        profiles: [ConnectionProfile],
        forwarding: [IndependentPortForward]
    ) async throws -> [SelectiveRemotePersonalVaultCredentialInput] {
        if !authorizedForSession {
            try await KeychainService.authenticateDeviceOwner(reason: UpdateLocalization.text(
                ru: "Разрешить Selective Remote синхронизировать сохранённые пароли через зашифрованный Personal Vault",
                en: "Allow Selective Remote to sync saved passwords through the encrypted Personal Vault"
            ))
            authorizedForSession = true
        }
        var result: [SelectiveRemotePersonalVaultCredentialInput] = []
        for profile in profiles {
            switch profile.connectionType {
            case .rdp:
                try append(&result, sourceID: profile.id, kind: .rdp, title: "\(profile.friendlyName) · RDP", username: profile.username)
                if !profile.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try append(&result, sourceID: profile.id, kind: .gateway, title: "\(profile.friendlyName) · Gateway", username: profile.gatewayUsername)
                }
            case .ssh, .telnet:
                try append(&result, sourceID: profile.id, kind: .ssh, title: "\(profile.friendlyName) · \(profile.connectionType.title)", username: profile.username)
                if profile.sshProxyMode != .none {
                    try append(&result, sourceID: profile.id, kind: .proxy, title: "\(profile.friendlyName) · Proxy", username: profile.sshProxyUsername)
                }
            case .serial:
                break
            }
        }
        for item in forwarding {
            try append(&result, sourceID: item.id, kind: .forwarding, title: "\(item.rule.displayName) · Forwarding", username: item.connection.username)
        }
        return result
    }

    func collectSSHKeys(_ records: [SSHKeyRecord]) async throws
        -> [SelectiveRemotePersonalVaultSSHKeyInput]
    {
        if !authorizedForSession {
            try await KeychainService.authenticateDeviceOwner(reason: UpdateLocalization.text(
                ru: "Разрешить Selective Remote синхронизировать приватные SSH-ключи через зашифрованный Personal Vault",
                en: "Allow Selective Remote to sync private SSH keys through the encrypted Personal Vault"
            ))
            authorizedForSession = true
        }
        let fileManager = FileManager.default
        return try records.map { record in
            let privateURL = URL(fileURLWithPath: record.privateKeyPath).standardizedFileURL
            let privateKey = try boundedFile(at: privateURL, fileManager: fileManager)
            let publicKey: Data?
            if let publicPath = record.publicKeyPath {
                publicKey = try boundedFile(
                    at: URL(fileURLWithPath: publicPath).standardizedFileURL,
                    fileManager: fileManager
                )
            } else {
                publicKey = nil
            }
            let certificateURL = URL(fileURLWithPath: record.privateKeyPath + "-cert.pub").standardizedFileURL
            let certificate = fileManager.isReadableFile(atPath: certificateURL.path)
                ? try boundedFile(at: certificateURL, fileManager: fileManager)
                : nil
            return .init(record: record, privateKey: privateKey, publicKey: publicKey, certificate: certificate)
        }
    }

    private func append(
        _ values: inout [SelectiveRemotePersonalVaultCredentialInput],
        sourceID: UUID,
        kind: KeychainCredentialKind,
        title: String,
        username: String
    ) throws {
        guard let secret = try KeychainService.readPassword(profileID: sourceID, kind: kind), !secret.isEmpty else { return }
        values.append(.init(sourceID: sourceID, kind: kind, title: title, username: username, secret: secret))
    }

    private func boundedFile(at url: URL, fileManager: FileManager) throws -> Data {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              (1 ... 1_048_576).contains(size)
        else { throw SelectiveRemotePersonalVaultError.invalidEnvelope }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}
