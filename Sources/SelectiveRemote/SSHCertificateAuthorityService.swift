import AppKit
import Foundation

struct SSHCertificateAuthorityRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var publicKeyPath: String
    var fingerprint: String
    var algorithm: String

    var privateKeyPath: String {
        publicKeyPath.hasSuffix(".pub") ? String(publicKeyPath.dropLast(4)) : publicKeyPath
    }

    var hasPrivateKey: Bool {
        FileManager.default.isReadableFile(atPath: privateKeyPath)
    }
}

enum SSHCertificateAuthorityError: LocalizedError {
    case invalidPublicKey
    case privateKeyUnavailable(String)
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPublicKey: "Выберите публичный SSH CA key (*.pub)"
        case let .privateKeyUnavailable(path): "Private CA key недоступен: \(path)"
        case let .signingFailed(message): "Не удалось подписать SSH certificate: \(message)"
        }
    }
}

enum SSHCertificateAuthorityService {
    private static let defaultsKey = "SelectiveRemote.sshCertificateAuthorities.v1"
    private static let sshKeygenPath = "/usr/bin/ssh-keygen"

    static func registered() -> [SSHCertificateAuthorityRecord] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([SSHCertificateAuthorityRecord].self, from: data)
        else { return [] }
        return records.filter { FileManager.default.isReadableFile(atPath: $0.publicKeyPath) }
    }

    static func register(publicKeyURL: URL) throws -> SSHCertificateAuthorityRecord {
        let path = publicKeyURL.path
        guard path.hasSuffix(".pub"), FileManager.default.isReadableFile(atPath: path) else {
            throw SSHCertificateAuthorityError.invalidPublicKey
        }
        let info = try fingerprint(path: path)
        var values = registered()
        if let existing = values.first(where: { $0.publicKeyPath == path }) { return existing }
        let base = publicKeyURL.deletingPathExtension().lastPathComponent
        let record = SSHCertificateAuthorityRecord(
            id: UUID(),
            name: base,
            publicKeyPath: path,
            fingerprint: info.fingerprint,
            algorithm: info.algorithm
        )
        values.append(record)
        save(values)
        return record
    }

    static func remove(_ id: UUID) {
        save(registered().filter { $0.id != id })
    }

    static func sign(
        key: SSHKeyRecord,
        authority: SSHCertificateAuthorityRecord,
        keyID: String,
        principals: String,
        validity: String
    ) throws {
        guard authority.hasPrivateKey else {
            throw SSHCertificateAuthorityError.privateKeyUnavailable(authority.privateKeyPath)
        }
        guard let publicPath = key.publicKeyPath,
              FileManager.default.isReadableFile(atPath: publicPath) else {
            throw SSHCertificateAuthorityError.invalidPublicKey
        }
        let normalizedID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrincipals = principals.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedValidity = validity.trimmingCharacters(in: .whitespacesAndNewlines)
        var args = ["-s", authority.privateKeyPath, "-I", normalizedID.isEmpty ? key.name : normalizedID]
        if !normalizedPrincipals.isEmpty { args += ["-n", normalizedPrincipals] }
        if !normalizedValidity.isEmpty { args += ["-V", normalizedValidity] }
        args.append(publicPath)
        let result = run(arguments: args)
        guard result.status == 0 else {
            throw SSHCertificateAuthorityError.signingFailed(result.output)
        }
    }

    static func chooseAndRegister() throws -> SSHCertificateAuthorityRecord? {
        let panel = NSOpenPanel()
        panel.title = "Импортировать SSH CA public key"
        panel.prompt = "Импортировать"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try register(publicKeyURL: url)
    }

    private static func save(_ values: [SSHCertificateAuthorityRecord]) {
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static func fingerprint(path: String) throws -> (fingerprint: String, algorithm: String) {
        let result = run(arguments: ["-lf", path, "-E", "sha256"])
        guard result.status == 0 else { throw SSHCertificateAuthorityError.invalidPublicKey }
        let parts = result.output.split(whereSeparator: { $0.isWhitespace })
        let fp = parts.count > 1 ? String(parts[1]) : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let algorithm: String
        if let open = result.output.lastIndex(of: "("), let close = result.output.lastIndex(of: ")"), open < close {
            algorithm = String(result.output[result.output.index(after: open)..<close])
        } else {
            algorithm = "SSH CA"
        }
        return (fp, algorithm)
    }

    private static func run(arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: sshKeygenPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (255, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

struct SSHCertificateSigningView: View {
    @Environment(\.dismiss) private var dismiss
    let key: SSHKeyRecord
    let authority: SSHCertificateAuthorityRecord
    let onSigned: () -> Void

    @State private var keyID = ""
    @State private var principals = ""
    @State private var validity = "+30d"
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Подписать SSH public key")
                .font(.title2.bold())
            Text("CA: \(authority.name) · \(authority.fingerprint)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            TextField("Key ID", text: $keyID)
                .textFieldStyle(.roundedBorder)
            TextField("Principals через запятую, например root,admin", text: $principals)
                .textFieldStyle(.roundedBorder)
            TextField("Validity OpenSSH, например +30d", text: $validity)
                .textFieldStyle(.roundedBorder)
            Label(
                "Private CA key остаётся файлом \(authority.privateKeyPath) и не копируется в Keychain.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Подписать") {
                    do {
                        try SSHCertificateAuthorityService.sign(
                            key: key,
                            authority: authority,
                            keyID: keyID,
                            principals: principals,
                            validity: validity
                        )
                        onSigned()
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!authority.hasPrivateKey)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}
