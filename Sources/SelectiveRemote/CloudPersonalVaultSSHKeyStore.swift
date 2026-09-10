import Foundation

enum SelectiveRemotePersonalVaultSSHKeyStore {
    static func install(
        _ values: [SelectiveRemotePersonalVaultSSHKeyInput],
        fileManager: FileManager = .default
    ) throws -> [SSHKeyRecord] {
        guard !values.isEmpty else { return [] }
        let root = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory)
            .appendingPathComponent("Selective Remote", isDirectory: true)
            .appendingPathComponent("Cloud SSH Keys", isDirectory: true)
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        return try values.map { value in
            let directory = root.appendingPathComponent(value.record.id.uuidString.lowercased(), isDirectory: true)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let originalName = URL(fileURLWithPath: value.record.privateKeyPath).lastPathComponent
            let filename = safeFilename(originalName.isEmpty ? "id_ssh" : originalName)
            let privateURL = directory.appendingPathComponent(filename)
            try write(value.privateKey, to: privateURL, permissions: 0o600, fileManager: fileManager)

            var restored = value.record
            restored.privateKeyPath = privateURL.path
            if let publicKey = value.publicKey {
                let publicURL = directory.appendingPathComponent(filename + ".pub")
                try write(publicKey, to: publicURL, permissions: 0o644, fileManager: fileManager)
                restored.publicKeyPath = publicURL.path
            } else {
                restored.publicKeyPath = nil
            }
            if let certificate = value.certificate {
                try write(
                    certificate,
                    to: URL(fileURLWithPath: privateURL.path + "-cert.pub"),
                    permissions: 0o644,
                    fileManager: fileManager
                )
            }
            return restored
        }
    }

    private static func write(
        _ data: Data,
        to url: URL,
        permissions: Int,
        fileManager: FileManager
    ) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        try fileManager.moveItem(at: temporary, to: url)
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let filtered = String(value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" })
        return filtered.isEmpty ? "id_ssh" : String(filtered.prefix(120))
    }
}
