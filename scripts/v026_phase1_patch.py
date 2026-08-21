#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text(encoding="utf-8")

def write(path, text):
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")

def replace_once(path, old, new):
    text = read(path)
    if old not in text:
        raise SystemExit(f"pattern not found in {path}: {old[:100]!r}")
    write(path, text.replace(old, new, 1))

# Shared host-insights model + compact UI used by Server Commands.
write("Sources/SelectiveRemote/SmartTerminalFeatures.swift", r'''import Foundation
import SwiftUI

struct TerminalHostInsights: Codable, Equatable, Sendable {
    var hostname = ""
    var uptimeSeconds: Int64?
    var load1: Double?
    var load5: Double?
    var load15: Double?
    var memoryUsedBytes: Int64?
    var memoryTotalBytes: Int64?
    var rootDiskUsedBytes: Int64?
    var rootDiskTotalBytes: Int64?
    var rootDiskPercent: Int?
    var updatesAvailable: Int?
    var listeningPorts: Int?
    var loggedInUsers: Int?

    static let empty = TerminalHostInsights()

    var hasData: Bool {
        !hostname.isEmpty
            || uptimeSeconds != nil
            || load1 != nil
            || memoryTotalBytes != nil
            || rootDiskTotalBytes != nil
            || updatesAvailable != nil
            || listeningPorts != nil
            || loggedInUsers != nil
    }

    var uptimeLabel: String? {
        guard let uptimeSeconds else { return nil }
        let days = uptimeSeconds / 86_400
        let hours = (uptimeSeconds % 86_400) / 3_600
        let minutes = (uptimeSeconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    var loadLabel: String? {
        guard let load1 else { return nil }
        let values = [load1, load5, load15].compactMap { $0 }
        return values.map { String(format: "%.2f", $0) }.joined(separator: " / ")
    }

    var memoryLabel: String? {
        guard let used = memoryUsedBytes, let total = memoryTotalBytes, total > 0 else { return nil }
        return "\(Self.bytes(used)) / \(Self.bytes(total))"
    }

    var diskLabel: String? {
        if let percent = rootDiskPercent { return "\(percent)%" }
        guard let used = rootDiskUsedBytes, let total = rootDiskTotalBytes, total > 0 else { return nil }
        return "\(Self.bytes(used)) / \(Self.bytes(total))"
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }
}

struct HostInsightsSummaryView: View {
    let insights: TerminalHostInsights
    var onRun: ((String) -> Void)? = nil

    private struct Metric: Identifiable {
        let id: String
        let title: String
        let value: String
        let systemImage: String
        let command: String?
    }

    private var metrics: [Metric] {
        var result: [Metric] = []
        if let value = insights.uptimeLabel {
            result.append(.init(id: "uptime", title: "Uptime", value: value, systemImage: "clock", command: "uptime"))
        }
        if let value = insights.loadLabel {
            result.append(.init(id: "load", title: "Load", value: value, systemImage: "gauge.with.dots.needle.50percent", command: "uptime"))
        }
        if let value = insights.memoryLabel {
            result.append(.init(id: "memory", title: "RAM", value: value, systemImage: "memorychip", command: "free -h"))
        }
        if let value = insights.diskLabel {
            result.append(.init(id: "disk", title: "Disk /", value: value, systemImage: "internaldrive", command: "df -hT /"))
        }
        if let value = insights.updatesAvailable {
            result.append(.init(id: "updates", title: "Updates", value: String(value), systemImage: "arrow.down.circle", command: nil))
        }
        if let value = insights.listeningPorts {
            result.append(.init(id: "ports", title: "Listening", value: String(value), systemImage: "network", command: "ss -lntup"))
        }
        if let value = insights.loggedInUsers {
            result.append(.init(id: "users", title: "Users", value: String(value), systemImage: "person.2", command: "who"))
        }
        return result
    }

    var body: some View {
        if insights.hasData {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("Host Insights", systemImage: "chart.xyaxis.line")
                        .font(.headline)
                    if !insights.hostname.isEmpty {
                        Text(insights.hostname)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("live probe")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 125), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(metrics) { metric in
                        metricCard(metric)
                    }
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.16))
            }
        }
    }

    @ViewBuilder
    private func metricCard(_ metric: Metric) -> some View {
        let content = HStack(spacing: 8) {
            Image(systemName: metric.systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(metric.value)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))

        if let command = metric.command, let onRun {
            Button { onRun(command) } label: { content }
                .buttonStyle(.plain)
                .help("Выполнить: \(command)")
        } else {
            content
        }
    }
}
''')

# Extend the remote context snapshot and probe with structured live metrics.
replace_once(
    "Sources/SelectiveRemote/TerminalRemoteContext.swift",
    '    var containers: [TerminalRemoteContainer] = []\n\n    func hasCommand',
    '    var containers: [TerminalRemoteContainer] = []\n    var insights: TerminalHostInsights = .empty\n\n    func hasCommand'
)

replace_once(
    "Sources/SelectiveRemote/TerminalRemoteContext.swift",
    'else\n    uname -srm\nfi\nfor command_name in',
    '''else
    uname -srm
fi
printf 'HOSTNAME\\t%s\\n' "$(hostname 2>/dev/null || uname -n 2>/dev/null || printf unknown)"
if [ -r /proc/uptime ]; then
    awk '{printf "UPTIME\\t%.0f\\n", $1}' /proc/uptime 2>/dev/null
fi
if [ -r /proc/loadavg ]; then
    awk '{printf "LOAD\\t%s\\t%s\\t%s\\n", $1, $2, $3}' /proc/loadavg 2>/dev/null
fi
if command -v free >/dev/null 2>&1; then
    free -b 2>/dev/null | awk '/^Mem:/ {printf "MEMORY\\t%s\\t%s\\n", $3, $2}'
fi
df -Pk / 2>/dev/null | awk 'NR == 2 {p=$5; gsub("%", "", p); printf "DISK\\t%.0f\\t%.0f\\t%s\\n", $3*1024, $2*1024, p}'
if command -v ss >/dev/null 2>&1; then
    printf 'PORTS\\t%s\\n' "$(ss -H -lntu 2>/dev/null | wc -l | tr -d ' ')"
fi
if command -v who >/dev/null 2>&1; then
    printf 'USERS\\t%s\\n' "$(who 2>/dev/null | wc -l | tr -d ' ')"
fi
if command -v apt >/dev/null 2>&1; then
    apt list --upgradable 2>/dev/null | awk 'NR > 1 {n++} END {printf "UPDATES\\t%d\\n", n+0}'
elif command -v dnf >/dev/null 2>&1; then
    dnf -q --cacheonly check-update 2>/dev/null | awk '/^[A-Za-z0-9_.+-]+[.]/{n++} END {printf "UPDATES\\t%d\\n", n+0}'
fi
for command_name in'''
)

replace_once(
    "Sources/SelectiveRemote/TerminalRemoteContext.swift",
    '        var containers: [TerminalRemoteContainer] = []\n        let safeName',
    '        var containers: [TerminalRemoteContainer] = []\n        var insights = TerminalHostInsights.empty\n        let safeName'
)

replace_once(
    "Sources/SelectiveRemote/TerminalRemoteContext.swift",
    '''            if kind == "OS" {
                osID = String(value.prefix(80)).lowercased()
                if parts.count >= 3 {
                    osLike = String(parts[2].trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)).lowercased()
                }
                continue
            }
            let range = NSRange(value.startIndex..., in: value)''',
    '''            if kind == "OS" {
                osID = String(value.prefix(80)).lowercased()
                if parts.count >= 3 {
                    osLike = String(parts[2].trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)).lowercased()
                }
                continue
            }
            switch kind {
            case "HOSTNAME":
                insights.hostname = String(value.prefix(160))
                continue
            case "UPTIME":
                insights.uptimeSeconds = Int64(value)
                continue
            case "LOAD":
                insights.load1 = Double(value)
                if parts.count >= 3 { insights.load5 = Double(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) }
                if parts.count >= 4 { insights.load15 = Double(parts[3].trimmingCharacters(in: .whitespacesAndNewlines)) }
                continue
            case "MEMORY":
                insights.memoryUsedBytes = Int64(value)
                if parts.count >= 3 { insights.memoryTotalBytes = Int64(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) }
                continue
            case "DISK":
                insights.rootDiskUsedBytes = Int64(value)
                if parts.count >= 3 { insights.rootDiskTotalBytes = Int64(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) }
                if parts.count >= 4 { insights.rootDiskPercent = Int(parts[3].trimmingCharacters(in: .whitespacesAndNewlines)) }
                continue
            case "UPDATES":
                insights.updatesAvailable = Int(value)
                continue
            case "PORTS":
                insights.listeningPorts = Int(value)
                continue
            case "USERS":
                insights.loggedInUsers = Int(value)
                continue
            default:
                break
            }
            let range = NSRange(value.startIndex..., in: value)'''
)

replace_once(
    "Sources/SelectiveRemote/TerminalRemoteContext.swift",
    '            containers: containers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }\n        )',
    '            containers: containers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },\n            insights: insights\n        )'
)

# Add generic live-metric commands to the same discovery catalog used by autocomplete.
replace_once(
    "Sources/SelectiveRemote/TerminalRemoteContext.swift",
    '''        if commands.contains("who") {
            add("who", "Активные пользовательские сеансы", "Безопасность сервера", "security users sessions")
        }

        return TerminalRemoteContextSnapshot(''',
    '''        if commands.contains("who") {
            add("who", "Активные пользовательские сеансы", "Безопасность сервера", "security users sessions")
        }
        if commands.contains("uptime") {
            add("uptime", "Uptime и load average", "Host Insights", "uptime load health")
        }
        if commands.contains("free") {
            add("free -h", "Использование оперативной памяти", "Host Insights", "memory ram health")
        }

        return TerminalRemoteContextSnapshot('''
)

# Surface Host Insights above the existing Server Commands categories.
replace_once(
    "Sources/SelectiveRemote/ServerCommands.swift",
    '''            .padding(16)

            Divider()

            if category == .services {''',
    '''            .padding(16)

            if context.insights.hasData {
                HostInsightsSummaryView(insights: context.insights, onRun: onRun)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            Divider()

            if category == .services {'''
)

# Make autocomplete command/argument aware instead of literal-substring only.
replace_once(
    "Sources/SelectiveRemote/TerminalResources/terminal-host.js",
    '''    const matchingEntries = (entries, query, limit = Number.POSITIVE_INFINITY) => {
        const normalized = query.trim().toLocaleLowerCase();
        if (!normalized) {
            return entries.slice(0, limit);
        }
        return entries
            .map((entry, order) => {
                const command = entry.command.toLocaleLowerCase();
                const details = `${entry.title || ""} ${entry.description || ""} ${entry.category || ""} ${entry.keywords || ""}`
                    .toLocaleLowerCase();
                const commandIndex = command.indexOf(normalized);
                const detailsIndex = details.indexOf(normalized);
                const rank = commandIndex === 0 ? 0
                    : commandIndex > 0 ? 1
                        : detailsIndex === 0 ? 2
                            : detailsIndex > 0 ? 3 : 4;
                return { entry, order, rank };
            })
            .filter((candidate) => candidate.rank < 4)
            .sort((left, right) => left.rank - right.rank || left.order - right.order)
            .slice(0, limit)
            .map((candidate) => candidate.entry);
    };''',
    '''    const normalizedAutocompleteCommand = (value) => value
        .trim()
        .toLocaleLowerCase()
        .replace(/^sudo\\s+/, "")
        .replace(/\\s+/g, " ");

    const orderedTokenPrefixMatch = (command, query) => {
        const commandTokens = normalizedAutocompleteCommand(command).split(" ").filter(Boolean);
        const queryTokens = normalizedAutocompleteCommand(query).split(" ").filter(Boolean);
        if (queryTokens.length === 0 || queryTokens.length > commandTokens.length) {
            return false;
        }
        let cursor = 0;
        for (const queryToken of queryTokens) {
            let matched = false;
            while (cursor < commandTokens.length) {
                const candidate = commandTokens[cursor++];
                if (candidate.startsWith(queryToken)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                return false;
            }
        }
        return true;
    };

    const matchingEntries = (entries, query, limit = Number.POSITIVE_INFINITY) => {
        const normalized = query.trim().toLocaleLowerCase();
        if (!normalized) {
            return entries.slice(0, limit);
        }
        return entries
            .map((entry, order) => {
                const command = entry.command.toLocaleLowerCase();
                const normalizedCommand = normalizedAutocompleteCommand(command);
                const normalizedQuery = normalizedAutocompleteCommand(normalized);
                const details = `${entry.title || ""} ${entry.description || ""} ${entry.category || ""} ${entry.keywords || ""}`
                    .toLocaleLowerCase();
                const commandIndex = command.indexOf(normalized);
                const normalizedIndex = normalizedCommand.indexOf(normalizedQuery);
                const detailsIndex = details.indexOf(normalized);
                const tokenMatch = orderedTokenPrefixMatch(command, normalized);
                const rank = commandIndex === 0 || normalizedIndex === 0 ? 0
                    : commandIndex > 0 || normalizedIndex > 0 ? 1
                        : tokenMatch ? 2
                            : detailsIndex >= 0 ? 3 : 4;
                return { entry, order, rank };
            })
            .filter((candidate) => candidate.rank < 4)
            .sort((left, right) => left.rank - right.rank || left.order - right.order)
            .slice(0, limit)
            .map((candidate) => candidate.entry);
    };'''
)

# Focused regression tests for the first productivity layer.
write("Tests/SelectiveRemoteTests/TerminalProductivity0260Tests.swift", r'''import Foundation
import Testing
@testable import SelectiveRemote

@Test("Remote probe parses Host Insights without losing server commands")
func parsesHostInsights() throws {
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.host = "server.example.test"
    profile.username = "admin"
    let settings = try SSHConnectionSettings(profile: profile, identity: nil, jumpHost: nil)
    let output = """
    SYSTEM\tUbuntu 24.04
    OS\tubuntu\tdebian
    HOSTNAME\tprod-api-01
    UPTIME\t183845
    LOAD\t0.12\t0.20\t0.30
    MEMORY\t4294967296\t8589934592
    DISK\t10737418240\t21474836480\t50
    PORTS\t17
    USERS\t3
    UPDATES\t12
    COMMAND\tsystemctl
    COMMAND\tuptime
    SERVICE\tnginx.service\tactive\trunning
    """

    let snapshot = TerminalRemoteContextService.parse(output: output, settings: settings)
    #expect(snapshot.insights.hostname == "prod-api-01")
    #expect(snapshot.insights.uptimeSeconds == 183845)
    #expect(snapshot.insights.load1 == 0.12)
    #expect(snapshot.insights.memoryTotalBytes == 8_589_934_592)
    #expect(snapshot.insights.rootDiskPercent == 50)
    #expect(snapshot.insights.listeningPorts == 17)
    #expect(snapshot.insights.loggedInUsers == 3)
    #expect(snapshot.insights.updatesAvailable == 12)
    #expect(snapshot.services.map(\.name) == ["nginx.service"])
    #expect(snapshot.suggestions.contains(where: { $0.command == "uptime" }))
}

@Test("Terminal autocomplete supports token-prefix arguments and sudo normalization")
func smartAutocompleteSourceRegression() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/TerminalResources/terminal-host.js"),
        encoding: .utf8
    )
    #expect(source.contains("const orderedTokenPrefixMatch"))
    #expect(source.contains("replace(/^sudo\\s+/, \"\")"))
    #expect(source.contains("tokenMatch ? 2"))
}
''')

print("v0.26.0 phase 1 patch applied")
