import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsReport: Equatable {
    let generatedAt: Date
    let profileCount: Int
    let runtimeCount: Int
    let problemCount: Int
    let text: String
}

enum DiagnosticsSystemInfo {
    static var macOSVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

enum DiagnosticRedactor {
    private static var rules: [(NSRegularExpression, String)] {
        [
        makeRule(
            #"(?i)(\b(?:password|passphrase|proxy[ _-]?password|proxy[ _-]?secret|keychain[ _-]?secret|secret|token)\b\s*[:=]\s*)(\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            "$1<redacted>"
        ),
        makeRule(
            #"(?i)(\b(?:proxy-authorization|authorization)\s*:\s*)[^\r\n]+"#,
            "$1<redacted>"
        ),
        makeRule(
            #"(?i)(\b[a-z][a-z0-9+.-]*://[^\s/@:]+:)[^@\s]+(@)"#,
            "$1<redacted>$2"
        ),
        makeRule(
            #"(?i)(/(?:p|gp):)[^\s]+"#,
            "$1<redacted>"
        )
        ]
    }

    static func sanitize(_ value: String?) -> String? {
        guard var output = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty
        else { return nil }

        for (regex, replacement) in rules {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
        return output
    }

    static func sanitize(_ value: String) -> String {
        sanitize(Optional(value)) ?? ""
    }

    private static func makeRule(
        _ pattern: String,
        _ replacement: String
    ) -> (NSRegularExpression, String) {
        // Patterns are compile-time constants. Falling back to a regex that can
        // never match keeps report generation non-throwing if a future edit
        // accidentally introduces an invalid expression.
        let regex = (try? NSRegularExpression(pattern: pattern))
            ?? (try! NSRegularExpression(pattern: "(?!)"))
        return (regex, replacement)
    }
}

enum DiagnosticsReportBuilder {
    static func build(
        appVersion: String,
        macOSVersion: String,
        architecture: String,
        profiles: [ConnectionProfile],
        sshKeys: [SSHKeyRecord],
        runtimeItems: [ConnectionCenterItem],
        currentError: String?,
        forwardingErrors: [UUID: String],
        generatedAt: Date = Date()
    ) -> DiagnosticsReport {
        var lines: [String] = [
            "Selective Remote Diagnostic Report",
            "Generated: \(timestamp(generatedAt))",
            "Selective Remote version: \(safe(appVersion))",
            "macOS version: \(safe(macOSVersion))",
            "Architecture: \(safe(architecture))",
            "Safety: secrets are intentionally excluded; passwords, passphrases, Keychain values and proxy secrets are never read.",
            "",
            "[Summary]",
            "Saved profiles: \(profiles.count)",
            "Runtime connections: \(runtimeItems.count)",
            "Runtime problems: \(runtimeItems.filter { $0.state.isProblem }.count)"
        ]

        if profiles.isEmpty {
            lines += ["", "[Profiles]", "No saved profiles"]
        } else {
            lines += ["", "[Profiles]"]
            for profile in profiles.sorted(by: profileSort) {
                lines.append(contentsOf: profileLines(
                    profile,
                    profiles: profiles,
                    sshKeys: sshKeys
                ))
            }
        }

        if runtimeItems.isEmpty {
            lines += ["", "[Runtime]", "No active runtime connections"]
        } else {
            lines += ["", "[Runtime]"]
            for item in runtimeItems.sorted(by: runtimeSort) {
                lines.append(contentsOf: runtimeLines(
                    item,
                    profiles: profiles,
                    sshKeys: sshKeys,
                    now: generatedAt
                ))
            }
        }

        var errors: [String] = []
        if let current = DiagnosticRedactor.sanitize(currentError) {
            errors.append("Application: \(current)")
        }
        for (id, message) in forwardingErrors.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            if let safeMessage = DiagnosticRedactor.sanitize(Optional(message)) {
                errors.append("Forwarding \(id.uuidString): \(safeMessage)")
            }
        }
        if !errors.isEmpty {
            lines += ["", "[Last errors]"] + errors
        }

        let finalText = DiagnosticRedactor.sanitize(lines.joined(separator: "\n"))
        return DiagnosticsReport(
            generatedAt: generatedAt,
            profileCount: profiles.count,
            runtimeCount: runtimeItems.count,
            problemCount: runtimeItems.filter { $0.state.isProblem }.count,
            text: finalText
        )
    }

    private static func profileLines(
        _ profile: ConnectionProfile,
        profiles: [ConnectionProfile],
        sshKeys: [SSHKeyRecord]
    ) -> [String] {
        var lines = [
            "",
            "Profile: \(safe(profile.friendlyName))",
            "Protocol: \(profile.connectionType == .rdp ? "RDP" : "SSH")",
            "Host: \(safe(profile.host))",
            "User: \(safe(profile.username.isEmpty ? "—" : profile.username))"
        ]

        switch profile.connectionType {
        case .rdp:
            if !profile.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("RDP Gateway: \(safe(profile.gatewayHost))")
            }
            lines.append("RDP window mode: \(safe(profile.rdpWindowMode.title))")
            lines.append("RDP auto reconnect: \(profile.autoReconnect ? "enabled" : "disabled")")
        case .ssh:
            lines.append("Port: \(profile.sshPort)")
            lines.append("SSH auth type: \(safe(profile.sshAuthenticationMode.title))")
            if let key = identity(for: profile, sshKeys: sshKeys) {
                lines.append("SSH key basename: \(safe(URL(fileURLWithPath: key.privateKeyPath).lastPathComponent))")
                if let certificate = SSHKeyService.certificateURL(for: key) {
                    lines.append("CertificateFile: \(safe(certificate.lastPathComponent))")
                }
            }
            if let jump = jumpHost(for: profile, profiles: profiles) {
                lines.append("Jump Host: \(safe(jump))")
            }
            lines.append("Proxy type: \(safe(profile.sshProxyMode.title))")
            lines.append("Host key policy: \(safe(profile.sshHostKeyPolicy.title))")
        }
        return lines
    }

    private static func runtimeLines(
        _ item: ConnectionCenterItem,
        profiles: [ConnectionProfile],
        sshKeys: [SSHKeyRecord],
        now: Date
    ) -> [String] {
        let profile = profile(for: item.source, profiles: profiles)
        let (parsedUser, parsedHost) = splitUserHost(item.userHost)
        let host = detailValue("Host", in: item) ?? parsedHost
        let user = detailValue("Пользователь", in: item) ?? parsedUser

        var lines = [
            "",
            "Connection type: \(safe(item.kind.title))",
            "Protocol: \(runtimeProtocol(item.kind))",
            "Profile: \(safe(item.profileName))",
            "Host: \(safe(host.isEmpty ? "—" : host))",
            "User: \(safe(user.isEmpty ? "—" : user))",
            "Port: \(item.port.map(String.init) ?? detailValue("Port", in: item) ?? "—")",
            "State: \(safe(item.state.title))"
        ]

        switch item.kind {
        case .rdp:
            if let gateway = profile?.gatewayHost.nilIfBlank
                ?? detailValue("Gateway", in: item)?.nilIfBlank {
                lines.append("RDP Gateway: \(safe(gateway))")
            }
            lines.append("RDP session/process state: \(safe(item.state.title))")
            if let pid = detailValue("PID", in: item) {
                lines.append("Process ID: \(safe(pid))")
            }
            if let mode = detailValue("Режим", in: item) {
                lines.append("Window mode: \(safe(mode))")
            }
            if let resolution = detailValue("Разрешение", in: item) {
                lines.append("Resolution: \(safe(resolution))")
            }
        case .terminal:
            lines.append("SSH auth type: \(safe(item.authentication))")
            appendSSHMetadata(
                to: &lines,
                item: item,
                profile: profile,
                profiles: profiles,
                sshKeys: sshKeys
            )
            lines.append("Terminal state: \(safe(item.state.title))")
            if let pty = detailValue("State", in: item) {
                lines.append("PTY state: \(safe(pty))")
            }
            if let geometry = detailValue("Terminal", in: item) {
                lines.append("Terminal geometry: \(safe(geometry))")
            }
        case .sftp:
            lines.append("SSH auth type: \(safe(item.authentication))")
            appendSSHMetadata(
                to: &lines,
                item: item,
                profile: profile,
                profiles: profiles,
                sshKeys: sshKeys
            )
            lines.append("SFTP state: \(safe(item.state.title))")
            if let path = detailValue("Путь", in: item) {
                lines.append("Remote path: \(safe(path))")
            }
            if let transfers = detailValue("Transfers", in: item) {
                lines.append("Active transfers: \(safe(transfers))")
            }
        case .forwarding:
            lines.append("SSH auth type: \(safe(item.authentication))")
            appendSSHMetadata(
                to: &lines,
                item: item,
                profile: profile,
                profiles: profiles,
                sshKeys: sshKeys
            )
            lines.append("Forwarding state: \(safe(item.state.title))")
            for label in ["Ownership", "Тип", "Bind", "Назначение", "SSH-host"] {
                if let value = detailValue(label, in: item) {
                    lines.append("\(label): \(safe(value))")
                }
            }
        }

        if let startedAt = item.startedAt {
            lines.append("Runtime started: \(timestamp(startedAt))")
            lines.append("Uptime: \(safe(item.uptimeText(now: now)))")
        }
        if let error = DiagnosticRedactor.sanitize(item.errorMessage) {
            lines.append("Last error: \(error)")
        }
        return lines
    }

    private static func appendSSHMetadata(
        to lines: inout [String],
        item: ConnectionCenterItem,
        profile: ConnectionProfile?,
        profiles: [ConnectionProfile],
        sshKeys: [SSHKeyRecord]
    ) {
        let key: SSHKeyRecord? = {
            if let profile, let key = identity(for: profile, sshKeys: sshKeys) {
                return key
            }
            guard let identityName = detailValue("SSH ID", in: item) else { return nil }
            return sshKeys.first(where: { $0.name == identityName })
        }()

        if let key {
            lines.append("SSH key basename: \(safe(URL(fileURLWithPath: key.privateKeyPath).lastPathComponent))")
            if let certificate = SSHKeyService.certificateURL(for: key) {
                lines.append("CertificateFile: \(safe(certificate.lastPathComponent))")
            }
        }

        if let jump = detailValue("Jump Host", in: item)?.nilIfBlank
            ?? profile.flatMap({ jumpHost(for: $0, profiles: profiles) }) {
            lines.append("Jump Host: \(safe(jump))")
        }

        let proxyType: String
        if let proxy = detailValue("Proxy", in: item)?.nilIfBlank {
            proxyType = proxy.components(separatedBy: "·").first?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "Configured"
        } else if let profile {
            proxyType = profile.sshProxyMode.title
        } else {
            proxyType = "Без прокси"
        }
        lines.append("Proxy type: \(safe(proxyType))")
    }

    private static func identity(
        for profile: ConnectionProfile,
        sshKeys: [SSHKeyRecord]
    ) -> SSHKeyRecord? {
        guard let keyID = profile.sshIdentityID else { return nil }
        return sshKeys.first(where: { $0.id == keyID })
    }

    private static func jumpHost(
        for profile: ConnectionProfile,
        profiles: [ConnectionProfile]
    ) -> String? {
        guard let jumpID = profile.sshJumpHostProfileID,
              let jump = profiles.first(where: { $0.id == jumpID && $0.connectionType == .ssh })
        else { return nil }
        let user = jump.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = user.isEmpty ? jump.host : "\(user)@\(jump.host)"
        return jump.sshPort == 22 ? destination : "\(destination):\(jump.sshPort)"
    }

    private static func profile(
        for source: ConnectionCenterSource,
        profiles: [ConnectionProfile]
    ) -> ConnectionProfile? {
        let profileID: UUID?
        switch source {
        case let .rdp(id):
            profileID = id
        case let .terminal(scope, _):
            if case let .profile(id) = scope { profileID = id } else { profileID = nil }
        case let .sftp(scope):
            if case let .profile(id) = scope { profileID = id } else { profileID = nil }
        case let .profileTunnel(id, _):
            profileID = id
        case .independentTunnel:
            profileID = nil
        }
        guard let profileID else { return nil }
        return profiles.first(where: { $0.id == profileID })
    }

    private static func detailValue(
        _ label: String,
        in item: ConnectionCenterItem
    ) -> String? {
        item.detailSections
            .lazy
            .flatMap(\.rows)
            .first(where: { $0.label == label })?
            .value
    }

    private static func splitUserHost(_ value: String) -> (String, String) {
        guard let marker = value.lastIndex(of: "@") else { return ("", value) }
        return (
            String(value[..<marker]),
            String(value[value.index(after: marker)...])
        )
    }

    private static func runtimeProtocol(_ kind: ConnectionCenterKind) -> String {
        switch kind {
        case .rdp: "RDP"
        case .terminal: "SSH"
        case .sftp: "SFTP over SSH"
        case .forwarding: "SSH Forwarding"
        }
    }

    private static func profileSort(_ lhs: ConnectionProfile, _ rhs: ConnectionProfile) -> Bool {
        if lhs.connectionType != rhs.connectionType {
            return lhs.connectionType.rawValue < rhs.connectionType.rawValue
        }
        return lhs.friendlyName.localizedStandardCompare(rhs.friendlyName) == .orderedAscending
    }

    private static func runtimeSort(_ lhs: ConnectionCenterItem, _ rhs: ConnectionCenterItem) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.profileName.localizedStandardCompare(rhs.profileName) == .orderedAscending
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func safe(_ value: String) -> String {
        DiagnosticRedactor.sanitize(value)
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct DiagnosticsCenterView: View {
    @ObservedObject var model: AppModel

    @State private var generatedAt = Date()
    @State private var exportError: String?

    private var report: DiagnosticsReport {
        DiagnosticsReportBuilder.build(
            appVersion: AppBuildInfo.version,
            macOSVersion: DiagnosticsSystemInfo.macOSVersion,
            architecture: DiagnosticsSystemInfo.architecture,
            profiles: model.profiles,
            sshKeys: model.sshKeys,
            runtimeItems: model.connectionCenterSnapshot(now: generatedAt).items,
            currentError: model.errorMessage,
            forwardingErrors: model.sshTunnelLastErrors,
            generatedAt: generatedAt
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            summary
            safetyBanner
            reportPreview
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Не удалось экспортировать диагностику", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Центр диагностики")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Один безопасный отчёт по конфигурации и реальному runtime приложения")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Обновить", systemImage: "arrow.clockwise") {
                model.refreshConnectionCenterRuntimeState()
                generatedAt = Date()
            }
            Button("Copy Diagnostic", systemImage: "doc.on.doc") {
                copyDiagnostic()
            }
            .buttonStyle(.borderedProminent)
            Button("Export Diagnostic", systemImage: "square.and.arrow.up") {
                exportDiagnostic()
            }
        }
    }

    private var summary: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 170), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            summaryCard(
                title: "Selective Remote",
                value: AppBuildInfo.displayText,
                systemImage: "app.badge",
                color: .blue
            )
            summaryCard(
                title: "macOS",
                value: shortMacOSVersion,
                systemImage: "macbook",
                color: .secondary
            )
            summaryCard(
                title: "Runtime",
                value: "\(report.runtimeCount)",
                systemImage: "point.3.connected.trianglepath.dotted",
                color: .green
            )
            summaryCard(
                title: "Проблемы",
                value: "\(report.problemCount)",
                systemImage: "exclamationmark.triangle.fill",
                color: report.problemCount == 0 ? .secondary : .red
            )
        }
    }

    private func summaryCard(
        title: String,
        value: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(color.opacity(0.13))
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.monospacedDigit())
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private var safetyBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("Безопасный диагностический отчёт")
                    .font(.headline)
                Text("Пароли, passphrase, значения Keychain и proxy secrets не читаются и не экспортируются. SSH-ключи и сертификаты указываются только по имени файла.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.green.opacity(0.2))
        }
    }

    private var reportPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Предпросмотр отчёта")
                    .font(.headline)
                Spacer()
                Text("\(report.profileCount) профилей · \(report.runtimeCount) runtime")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollView([.vertical, .horizontal]) {
                Text(report.text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var shortMacOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private func copyDiagnostic() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.text, forType: .string)
    }

    private func exportDiagnostic() {
        let report = report
        let panel = NSSavePanel()
        panel.title = "Export Diagnostic"
        panel.nameFieldStringValue = exportFilename(report.generatedAt)
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportFilename(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "SelectiveRemote-Diagnostic-\(formatter.string(from: date)).txt"
    }
}
