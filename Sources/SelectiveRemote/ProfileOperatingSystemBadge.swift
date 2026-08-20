import SwiftUI

struct ProfileOperatingSystemStyle {
    let title: String
    let systemImage: String
    let colors: [Color]

    static func resolve(for profile: ConnectionProfile) -> ProfileOperatingSystemStyle {
        guard profile.connectionType == .ssh else {
            return ProfileOperatingSystemStyle(
                title: "Windows / RDP",
                systemImage: "desktopcomputer",
                colors: [.blue, .indigo]
            )
        }

        let identity = [
            profile.detectedOperatingSystemID,
            profile.detectedOperatingSystemLike,
            profile.detectedOperatingSystem
        ]
        .joined(separator: " ")
        .lowercased()

        if identity.contains("ubuntu") {
            return .init(title: "Ubuntu", systemImage: "circle.grid.cross.fill", colors: [.orange, .red])
        }
        if identity.contains("kali") {
            return .init(title: "Kali Linux", systemImage: "bolt.horizontal.circle.fill", colors: [.cyan, .blue])
        }
        if identity.contains("astra") {
            return .init(title: "Astra Linux", systemImage: "star.circle.fill", colors: [.blue, .indigo])
        }
        if identity.contains("debian") {
            return .init(title: "Debian", systemImage: "circle.hexagongrid.fill", colors: [.pink, .purple])
        }
        if identity.contains("arch") || identity.contains("manjaro") {
            return .init(title: "Arch Linux", systemImage: "triangle.fill", colors: [.cyan, .blue])
        }
        if identity.contains("alpine") {
            return .init(title: "Alpine Linux", systemImage: "mountain.2.fill", colors: [.blue, .cyan])
        }
        if identity.contains("fedora") {
            return .init(title: "Fedora", systemImage: "f.circle.fill", colors: [.blue, .indigo])
        }
        if ["rhel", "red hat", "centos", "rocky", "alma"].contains(where: {
            identity.contains($0)
        }) {
            return .init(title: "Enterprise Linux", systemImage: "server.rack", colors: [.red, .orange])
        }
        if identity.contains("suse") || identity.contains("opensuse") {
            return .init(title: "SUSE", systemImage: "leaf.fill", colors: [.green, .teal])
        }
        if identity.contains("darwin") || identity.contains("macos") {
            return .init(title: "macOS", systemImage: "apple.logo", colors: [.gray, .blue])
        }
        if identity.contains("windows") {
            return .init(title: "Windows", systemImage: "rectangle.split.2x2.fill", colors: [.blue, .cyan])
        }
        if !identity.isEmpty {
            return .init(title: profile.detectedOperatingSystem, systemImage: "terminal.fill", colors: [.teal, .indigo])
        }
        return .init(title: "SSH", systemImage: "terminal.fill", colors: [.purple, .indigo])
    }
}

struct ProfileOperatingSystemBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let profile: ConnectionProfile
    let connectionActive: Bool
    let tunnelActive: Bool

    private var style: ProfileOperatingSystemStyle {
        ProfileOperatingSystemStyle.resolve(for: profile)
    }

    private var hasActivity: Bool { connectionActive || tunnelActive }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: connectionActive
                            ? [.green, .teal]
                            : (tunnelActive ? [.orange, .yellow] : style.colors),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 34, height: 34)

            Image(systemName: style.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)

            if hasActivity {
                Circle()
                    .fill(connectionActive ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
        }
        .scaleEffect(hasActivity && !reduceMotion ? 1 : 0.94)
        .shadow(
            color: connectionActive
                ? Color.green.opacity(0.24)
                : (tunnelActive ? Color.orange.opacity(0.22) : .clear),
            radius: 5
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.66), value: hasActivity)
        .accessibilityLabel(style.title)
    }
}
