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
            "Protocol: \(profile.connectionType.title)",
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
        case .telnet:
            lines.append("Port: \(profile.sshPort)")
            lines.append("Encryption: disabled")
        case .serial:
            lines.append("Device: \(safe(profile.serialDevicePath))")
            lines.append("Baud rate: \(profile.serialBaudRate)")
            lines.append(
                "Format: \(profile.serialDataBits)\(profile.serialParity.rawValue.prefix(1).uppercased())\(profile.serialStopBits)"
            )
            lines.append("Flow control: \(safe(profile.serialFlowControl.rawValue))")
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
        case .sftp:
            profileID = nil
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Pane: String, CaseIterable, Identifiable {
        case overview
        case systemCheck
        case connections
        case rdp
        case ssh
        case sftp
        case forwarding
        case errors
        case environment
        case raw

        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: "Общее"
            case .systemCheck: "Проверка системы"
            case .connections: "Подключения"
            case .rdp: "RDP"
            case .ssh: "SSH / Terminal"
            case .sftp: "SFTP"
            case .forwarding: "Туннели"
            case .errors: "Ошибки"
            case .environment: "Окружение"
            case .raw: "Сырой отчёт"
            }
        }
    }

    @State private var generatedAt = Date()
    @State private var exportError: String?
    @State private var selectedPane: Pane = .overview
    @State private var searchText = ""

    private var snapshot: ConnectionCenterSnapshot {
        model.connectionCenterSnapshot(now: generatedAt)
    }
    private var report: DiagnosticsReport {
        DiagnosticsReportBuilder.build(
            appVersion: AppBuildInfo.version,
            macOSVersion: DiagnosticsSystemInfo.macOSVersion,
            architecture: DiagnosticsSystemInfo.architecture,
            profiles: model.profiles,
            sshKeys: model.sshKeys,
            runtimeItems: snapshot.items,
            currentError: model.errorMessage,
            forwardingErrors: model.sshTunnelLastErrors,
            generatedAt: generatedAt
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            summary
            toolbar
            if selectedPane == .raw {
                rawReport
            } else {
                ScrollView {
                    selectedPaneContent
                        .id(selectedPane)
                        .transition(.opacity)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.bottom, 18)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selectedPane)
            }
        }
        .frame(maxWidth: 1180, alignment: .topLeading)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                Text("Безопасное представление состояния подключений и окружения")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Обновить", systemImage: "arrow.clockwise") {
                model.refreshConnectionCenterRuntimeState()
                generatedAt = Date()
            }
            Button("Копировать диагностику", systemImage: "doc.on.doc") {
                copyDiagnostic()
            }
            .buttonStyle(.borderedProminent)
            Button("Экспортировать диагностику", systemImage: "square.and.arrow.up") {
                exportDiagnostic()
            }
        }
    }

    private var summary: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 165), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            Button {
                model.openInstalledReleaseNotes()
            } label: {
                summaryCard("Версия", AppBuildInfo.displayText, "app.badge", .blue)
            }
            .buttonStyle(.plain)
            .help(UpdateLocalization.text(
                ru: "Открыть историю изменений",
                en: "Open release history"
            ))
            summaryCard("macOS", shortMacOSVersion, "macbook", .secondary)
            summaryCard("Активные сессии", "\(report.runtimeCount)", "point.3.connected.trianglepath.dotted", .green)
            summaryCard(
                "Проблемы",
                "\(report.problemCount)",
                "exclamationmark.triangle.fill",
                report.problemCount == 0 ? .secondary : .red
            )
        }
    }

    private func summaryCard(
        _ title: String,
        _ value: String,
        _ systemImage: String,
        _ color: Color
    ) -> some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.13))
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.monospacedDigit())
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Раздел", selection: $selectedPane) {
                ForEach(Pane.allCases) { pane in
                    Text(LocalizedStringKey(pane.title)).tag(pane)
                }
            }
            .frame(width: 210)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Поиск в диагностике", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 220, maxWidth: 420, minHeight: 34)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Spacer()
            HStack(spacing: 4) {
                Text("Активных:")
                Text("\(visibleRuntimeItems.count)")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var selectedPaneContent: some View {
        switch selectedPane {
        case .overview:
            VStack(alignment: .leading, spacing: 14) {
                safetyBanner
                overviewCounts
                if report.problemCount > 0 {
                    problemList
                } else {
                    ContentUnavailableView(
                        "Проблем не обнаружено",
                        systemImage: "checkmark.circle",
                        description: Text("Активные подключения не сообщают ошибок или состояний переподключения.")
                    )
                }
            }
        case .systemCheck:
            DiagnosticsSystemCheckView(model: model)
        case .connections, .rdp, .ssh, .sftp, .forwarding:
            runtimeList
        case .errors:
            problemList
        case .environment:
            environmentView
        case .raw:
            EmptyView()
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
                Text("Пароли, кодовые фразы, значения Связки ключей, секреты прокси и содержимое приватных ключей не читаются. Для SSH ID и CertificateFile показывается только имя файла.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var overviewCounts: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
            compactCount("RDP", snapshot.rdpCount, "desktopcomputer")
            compactCount("SSH / Terminal", snapshot.terminalCount, "terminal")
            compactCount("SFTP", snapshot.sftpCount, "folder")
            compactCount("Forwarding", snapshot.tunnelCount, "arrow.left.arrow.right")
        }
    }

    private func compactCount(_ title: String, _ value: Int, _ icon: String) -> some View {
        HStack {
            Label {
                Text(LocalizedStringKey(title))
            } icon: {
                Image(systemName: icon)
            }
            Spacer()
            Text("\(value)")
                .font(.headline.monospacedDigit())
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var runtimeList: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if visibleRuntimeItems.isEmpty {
                ContentUnavailableView(
                    "Нет подходящих активных подключений",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            } else {
                ForEach(visibleRuntimeItems) { item in
                    runtimeCard(item)
                }
            }
        }
    }

    private func runtimeCard(_ item: ConnectionCenterItem) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: item.kind.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(item.state.color.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.profileName)
                        .font(.headline)
                    Text(targetText(item))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.state.color)
                        .frame(width: 7, height: 7)
                    Text(LocalizedStringKey(item.state.title))
                    if item.startedAt != nil {
                        Text("· \(item.uptimeText(now: generatedAt))")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
            }

            HStack(spacing: 14) {
                diagnosticFact("Тип", item.kind.title)
                diagnosticFact("Аутентификация", safeValue(label: "Auth", value: item.authentication))
                if let route = item.route, !route.isEmpty {
                    diagnosticFact("Маршрут", safeValue(label: "Route", value: route))
                }
            }

            if let error = item.errorMessage, !error.isEmpty {
                Label(DiagnosticRedactor.sanitize(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            DisclosureGroup("Подробности") {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(item.detailSections) { section in
                        let rows = safeRows(section.rows)
                        if !rows.isEmpty {
                            Text(LocalizedStringKey(section.title))
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            ForEach(rows) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(LocalizedStringKey(row.label))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 130, alignment: .leading)
                                    Text(safeValue(label: row.label, value: row.value))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }

            HStack {
                Spacer()
                Button("Копировать секцию", systemImage: "doc.on.doc") {
                    copyRuntimeItem(item)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private func diagnosticFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(label))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var problemList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ошибки и предупреждения")
                .font(.headline)
            if let error = model.errorMessage, !error.isEmpty, matchesSearch(error) {
                problemRow("Приложение", DiagnosticRedactor.sanitize(error))
            }
            ForEach(model.sshTunnelLastErrors.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                if let value = model.sshTunnelLastErrors[id], matchesSearch(value) {
                    problemRow("Туннели", DiagnosticRedactor.sanitize(value))
                }
            }
            ForEach(snapshot.items.filter { $0.state.isProblem && matchesRuntimeSearch($0) }) { item in
                problemRow(item.profileName, item.errorMessage.map(DiagnosticRedactor.sanitize) ?? item.state.title)
            }
            if report.problemCount == 0 && model.errorMessage == nil && model.sshTunnelLastErrors.isEmpty {
                Text("Нет активных проблем")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func problemRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(11)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
    }

    private var environmentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Окружение")
                .font(.headline)
            diagnosticEnvironmentRow("Версия", AppBuildInfo.displayText)
            diagnosticEnvironmentRow("macOS", DiagnosticsSystemInfo.macOSVersion)
            diagnosticEnvironmentRow("Архитектура", DiagnosticsSystemInfo.architecture)
            diagnosticEnvironmentRow("Профили", "\(report.profileCount)")
            diagnosticEnvironmentRow("Активные сессии", "\(report.runtimeCount)")
            Text("Переменные окружения и секреты здесь намеренно не отображаются.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func diagnosticEnvironmentRow(_ label: String, _ value: String) -> some View {
        LabeledContent {
            Text(DiagnosticRedactor.sanitize(value))
                .textSelection(.enabled)
        } label: {
            Text(LocalizedStringKey(label))
        }
    }

    private var rawReport: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Сырой отчёт")
                    .font(.headline)
                Spacer()
                Text("безопасный текст")
                    .font(.caption)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var visibleRuntimeItems: [ConnectionCenterItem] {
        snapshot.items.filter { item in
            paneMatches(item) && matchesRuntimeSearch(item)
        }
    }

    private func paneMatches(_ item: ConnectionCenterItem) -> Bool {
        switch selectedPane {
        case .overview, .connections: true
        case .systemCheck: false
        case .rdp: item.kind == .rdp
        case .ssh: item.kind == .terminal
        case .sftp: item.kind == .sftp
        case .forwarding: item.kind == .forwarding
        case .errors: item.state.isProblem
        case .environment, .raw: false
        }
    }

    private func matchesRuntimeSearch(_ item: ConnectionCenterItem) -> Bool {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let values = [
            item.kind.title,
            item.profileName,
            item.userHost,
            item.route ?? "",
            item.authentication,
            item.state.title,
            item.errorMessage ?? ""
        ]
        return values.contains { value in
            matchesSearch(value)
        }
    }

    private func matchesSearch(_ value: String) -> Bool {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        return value.localizedCaseInsensitiveContains(searchText)
    }

    private func targetText(_ item: ConnectionCenterItem) -> String {
        guard let port = item.port else { return item.userHost }
        return "\(item.userHost):\(port)"
    }

    private func safeRows(_ rows: [ConnectionCenterDetailRow]) -> [ConnectionCenterDetailRow] {
        rows.filter { !isSensitiveLabel($0.label) }
    }

    private func isSensitiveLabel(_ label: String) -> Bool {
        let lower = label.lowercased()
        return ["password", "passphrase", "keychain value", "proxy secret", "private key contents"]
            .contains(where: lower.contains)
    }

    private func safeValue(label: String, value: String) -> String {
        var safe = DiagnosticRedactor.sanitize(value)
        let lower = label.lowercased()
        if lower.contains("identity") || lower.contains("ssh key") || lower.contains("certificate") || lower.contains("certificatefile") {
            if safe.contains("/") {
                safe = URL(fileURLWithPath: safe).lastPathComponent
            }
        }
        return safe
    }

    private func copyRuntimeItem(_ item: ConnectionCenterItem) {
        var lines = [
            "Type: \(item.kind.title)",
            "Profile: \(DiagnosticRedactor.sanitize(item.profileName))",
            "Target: \(DiagnosticRedactor.sanitize(targetText(item)))",
            "State: \(item.state.title)",
            "Auth: \(safeValue(label: "Auth", value: item.authentication))"
        ]
        if let route = item.route, !route.isEmpty {
            lines.append("Route: \(safeValue(label: "Route", value: route))")
        }
        for section in item.detailSections {
            let rows = safeRows(section.rows)
            guard !rows.isEmpty else { continue }
            lines.append("")
            lines.append("[\(section.title)]")
            for row in rows {
                lines.append("\(row.label): \(safeValue(label: row.label, value: row.value))")
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
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
        panel.title = String(localized: "Экспорт диагностики")
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
