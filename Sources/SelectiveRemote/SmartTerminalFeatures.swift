import Foundation
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
