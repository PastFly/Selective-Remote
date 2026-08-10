import Foundation

enum ProfileTransferError: LocalizedError {
    case unsupportedFormat
    case emptyDocument
    case invalidRDPFile

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "Неподдерживаемый формат профилей"
        case .emptyDocument:
            "Файл не содержит профилей"
        case .invalidRDPFile:
            "Не удалось прочитать параметры из файла .rdp"
        }
    }
}

struct SelectiveRemoteProfileArchive: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let profiles: [ConnectionProfile]

    init(profiles: [ConnectionProfile]) {
        schemaVersion = 2
        exportedAt = Date()
        self.profiles = profiles
    }
}

enum SelectiveRemoteProfileCodec {
    static func encode(_ profiles: [ConnectionProfile]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let sanitized = profiles.map { profile in
            var value = profile
            value.sshIdentityID = nil
            return value
        }
        return try encoder.encode(SelectiveRemoteProfileArchive(profiles: sanitized))
    }

    static func decode(_ data: Data) throws -> [ConnectionProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let archive = try? decoder.decode(SelectiveRemoteProfileArchive.self, from: data) {
            guard (1...2).contains(archive.schemaVersion) else {
                throw ProfileTransferError.unsupportedFormat
            }
            guard !archive.profiles.isEmpty else { throw ProfileTransferError.emptyDocument }
            return archive.profiles
        }

        // Accept early development exports that contained a bare profile array.
        if let profiles = try? decoder.decode([ConnectionProfile].self, from: data),
           !profiles.isEmpty {
            return profiles
        }
        let legacyDecoder = JSONDecoder()
        if let profiles = try? legacyDecoder.decode([ConnectionProfile].self, from: data),
           !profiles.isEmpty {
            return profiles
        }
        throw ProfileTransferError.unsupportedFormat
    }
}

enum RDPFileCodec {
    static func decode(_ data: Data, suggestedName: String? = nil) throws -> ConnectionProfile {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16LittleEndian)
        else { throw ProfileTransferError.invalidRDPFile }

        var fields: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            fields[String(parts[0]).lowercased()] = String(parts[2])
        }

        guard let address = fields["full address"], !address.isEmpty else {
            throw ProfileTransferError.invalidRDPFile
        }

        var profile = ConnectionProfile()
        profile.connectionType = .rdp
        profile.host = address
        let trimmedName = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        profile.friendlyName = trimmedName.isEmpty ? address : trimmedName
        profile.username = fields["username"] ?? ""
        profile.gatewayHost = fields["gatewayhostname"] ?? ""
        profile.gatewayUsername = fields["gatewayusername"] ?? ""
        profile.startFullScreen = fields["screen mode id"] != "1"
        profile.rdpWindowMode = profile.startFullScreen ? .fullScreen : .fixedWindow
        profile.windowWidth = fields["desktopwidth"].flatMap(Int.init) ?? profile.windowWidth
        profile.windowHeight = fields["desktopheight"].flatMap(Int.init) ?? profile.windowHeight
        profile.autoReconnect = fields["autoreconnection enabled"] != "0"
        profile.adminSession = fields["administrative session"] == "1"
        profile.redirectPrinters = fields["redirectprinters"] == "1"
        profile.redirectMicrophone = fields["audiocapturemode"] == "1"
        profile.redirectCamera = !(fields["camerastoredirect"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        profile.clipboardMode = fields["redirectclipboard"] == "0" ? .disabled : .bidirectional

        switch fields["audiomode"] {
        case "1": profile.audioMode = .remote
        case "2": profile.audioMode = .muted
        default: profile.audioMode = .local
        }
        if let scale = fields["desktopscalefactor"].flatMap(Int.init),
           let value = WindowsScale(rawValue: scale) {
            profile.windowsScale = value
        }
        return profile
    }

    static func encode(_ profile: ConnectionProfile) -> Data {
        let audioMode: Int
        switch profile.audioMode {
        case .local: audioMode = 0
        case .remote: audioMode = 1
        case .muted: audioMode = 2
        }

        let lines = [
            "full address:s:\(profile.host)",
            "username:s:\(profile.username)",
            "screen mode id:i:\(profile.rdpWindowMode == .fullScreen ? 2 : 1)",
            "desktopwidth:i:\(profile.windowWidth)",
            "desktopheight:i:\(profile.windowHeight)",
            "use multimon:i:\(profile.selectedDisplayIDs.count > 1 ? 1 : 0)",
            "desktopscalefactor:i:\(profile.windowsScale.rawValue)",
            "devicescalefactor:i:\(profile.windowsScale.rawValue)",
            "audiomode:i:\(audioMode)",
            "audiocapturemode:i:\(profile.redirectMicrophone ? 1 : 0)",
            "camerastoredirect:s:\(profile.redirectCamera ? "*" : "")",
            "redirectclipboard:i:\(profile.clipboardMode == .disabled ? 0 : 1)",
            "redirectprinters:i:\(profile.redirectPrinters ? 1 : 0)",
            "autoreconnection enabled:i:\(profile.autoReconnect ? 1 : 0)",
            "administrative session:i:\(profile.adminSession ? 1 : 0)",
            "gatewayhostname:s:\(profile.gatewayHost)",
            "gatewayusername:s:\(profile.gatewayUsername)"
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
