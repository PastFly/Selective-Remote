import Foundation
import SwiftUI

enum ProfileOperatingSystemIdentity: String, Equatable, Sendable {
    case windows, macOS, ubuntu, debian, kali, astra, arch, manjaro, alpine, fedora
    case redHat, centOS, rocky, alma, suse, bsd, linux, ssh, telnet, serial

    var usesCustomGlyph: Bool {
        switch self {
        case .ubuntu, .debian, .kali, .astra, .arch, .manjaro, .alpine,
             .fedora, .redHat, .centOS, .rocky, .alma, .suse, .linux:
            true
        default:
            false
        }
    }

    var fallbackSystemImage: String {
        switch self {
        case .windows: "rectangle.split.2x2.fill"
        case .macOS: "apple.logo"
        case .bsd: "b.circle.fill"
        case .telnet: "network"
        case .serial: "cable.connector"
        case .ssh: "terminal.fill"
        default: "server.rack"
        }
    }

    static func resolve(
        connectionType: ConnectionType,
        osID: String,
        osLike: String,
        label: String
    ) -> ProfileOperatingSystemIdentity {
        switch connectionType {
        case .rdp: return .windows
        case .telnet: return .telnet
        case .serial: return .serial
        case .ssh: break
        }

        let id = normalize(osID)
        let like = normalize(osLike)
        let name = normalize(label)
        let identity = "\(id) \(like) \(name)"

        if token(id, isAnyOf: ["ubuntu"]) || name.contains("ubuntu") { return .ubuntu }
        if token(id, isAnyOf: ["kali"]) || name.contains("kali") { return .kali }
        if token(id, isAnyOf: ["astra", "astra-linux"]) || name.contains("astra") { return .astra }
        if token(id, isAnyOf: ["debian"]) || name.contains("debian") { return .debian }
        if token(id, isAnyOf: ["manjaro"]) || name.contains("manjaro") { return .manjaro }
        if token(id, isAnyOf: ["arch", "archlinux"]) || name.contains("arch linux") { return .arch }
        if token(id, isAnyOf: ["alpine"]) || name.contains("alpine") { return .alpine }
        if token(id, isAnyOf: ["fedora"]) || name.contains("fedora") { return .fedora }
        if token(id, isAnyOf: ["rocky"]) || name.contains("rocky") { return .rocky }
        if token(id, isAnyOf: ["almalinux", "alma"]) || name.contains("alma") { return .alma }
        if token(id, isAnyOf: ["centos"]) || name.contains("centos") { return .centOS }
        if token(id, isAnyOf: ["rhel", "redhat"]) || name.contains("red hat") { return .redHat }
        if token(id, isAnyOf: ["opensuse", "opensuse-leap", "sles", "suse"])
            || identity.contains("suse") { return .suse }
        if identity.contains("freebsd") || identity.contains("openbsd") || identity.contains("netbsd") {
            return .bsd
        }
        if identity.contains("darwin") || identity.contains("macos") { return .macOS }
        if identity.contains("windows") { return .windows }
        if identity.contains("linux") || !id.isEmpty || !like.isEmpty || !name.isEmpty { return .linux }
        return .ssh
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
    }

    private static func token(_ value: String, isAnyOf candidates: [String]) -> Bool {
        let tokens = value.split { $0 == " " || $0 == "," }.map(String.init)
        return candidates.contains(value) || candidates.contains(where: tokens.contains)
    }
}

struct ProfileOperatingSystemStyle {
    let identity: ProfileOperatingSystemIdentity
    let title: String
    let colors: [Color]

    static func resolve(for profile: ConnectionProfile) -> ProfileOperatingSystemStyle {
        let identity = ProfileOperatingSystemIdentity.resolve(
            connectionType: profile.connectionType,
            osID: profile.detectedOperatingSystemID,
            osLike: profile.detectedOperatingSystemLike,
            label: profile.detectedOperatingSystem
        )

        switch identity {
        case .windows: .init(identity: identity, title: "Windows / RDP", colors: [.blue, .indigo])
        case .macOS: .init(identity: identity, title: "macOS", colors: [.gray, .blue])
        case .ubuntu: .init(identity: identity, title: "Ubuntu", colors: [.orange, .red])
        case .debian: .init(identity: identity, title: "Debian", colors: [.pink, .purple])
        case .kali: .init(identity: identity, title: "Kali Linux", colors: [.cyan, .blue])
        case .astra: .init(identity: identity, title: "Astra Linux", colors: [.blue, .indigo])
        case .arch: .init(identity: identity, title: "Arch Linux", colors: [.cyan, .blue])
        case .manjaro: .init(identity: identity, title: "Manjaro", colors: [.green, .teal])
        case .alpine: .init(identity: identity, title: "Alpine Linux", colors: [.blue, .cyan])
        case .fedora: .init(identity: identity, title: "Fedora", colors: [.blue, .indigo])
        case .redHat: .init(identity: identity, title: "Red Hat Enterprise Linux", colors: [.red, .black])
        case .centOS: .init(identity: identity, title: "CentOS Stream", colors: [.purple, .indigo])
        case .rocky: .init(identity: identity, title: "Rocky Linux", colors: [.green, .teal])
        case .alma: .init(identity: identity, title: "AlmaLinux", colors: [.blue, .orange])
        case .suse: .init(identity: identity, title: "SUSE", colors: [.green, .teal])
        case .bsd: .init(identity: identity, title: "BSD", colors: [.red, .orange])
        case .linux:
            .init(
                identity: identity,
                title: profile.detectedOperatingSystem.isEmpty ? "Linux" : profile.detectedOperatingSystem,
                colors: [.teal, .indigo]
            )
        case .ssh: .init(identity: identity, title: "SSH", colors: [.purple, .indigo])
        case .telnet: .init(identity: identity, title: "Telnet", colors: [.orange, .red])
        case .serial: .init(identity: identity, title: "Serial", colors: [.teal, .blue])
        }
    }
}

private struct HostPlatformGlyph: View {
    let identity: ProfileOperatingSystemIdentity

    var body: some View {
        if identity.usesCustomGlyph {
            Canvas { context, size in
                let side = min(size.width, size.height)
                let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
                let point: (CGFloat, CGFloat) -> CGPoint = { x, y in
                    CGPoint(x: origin.x + x * side, y: origin.y + y * side)
                }
                let rect: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect = { x, y, width, height in
                    CGRect(
                        x: origin.x + x * side, y: origin.y + y * side,
                        width: width * side, height: height * side
                    )
                }
                let stroke = StrokeStyle(
                    lineWidth: max(1.35, side * 0.085), lineCap: .round, lineJoin: .round
                )
                let thinStroke = StrokeStyle(
                    lineWidth: max(1.05, side * 0.06), lineCap: .round, lineJoin: .round
                )
                let white = GraphicsContext.Shading.color(.white)

                func line(_ points: [CGPoint], closed: Bool = false, style: StrokeStyle? = nil) {
                    guard let first = points.first else { return }
                    var path = Path()
                    path.move(to: first)
                    for value in points.dropFirst() { path.addLine(to: value) }
                    if closed { path.closeSubpath() }
                    context.stroke(path, with: white, style: style ?? stroke)
                }

                func fill(_ points: [CGPoint]) {
                    guard let first = points.first else { return }
                    var path = Path()
                    path.move(to: first)
                    for value in points.dropFirst() { path.addLine(to: value) }
                    path.closeSubpath()
                    context.fill(path, with: white)
                }

                func circle(_ x: CGFloat, _ y: CGFloat, _ diameter: CGFloat, filled: Bool = true) {
                    let path = Path(ellipseIn: rect(x, y, diameter, diameter))
                    if filled { context.fill(path, with: white) }
                    else { context.stroke(path, with: white, style: thinStroke) }
                }

                switch identity {
                case .ubuntu:
                    context.stroke(Path(ellipseIn: rect(0.27, 0.27, 0.46, 0.46)), with: white, style: stroke)
                    circle(0.72, 0.43, 0.18)
                    circle(0.12, 0.18, 0.18)
                    circle(0.13, 0.67, 0.18)
                case .debian:
                    var spiral = Path()
                    spiral.move(to: point(0.78, 0.46))
                    spiral.addCurve(to: point(0.28, 0.32), control1: point(0.72, 0.16), control2: point(0.29, 0.13))
                    spiral.addCurve(to: point(0.29, 0.72), control1: point(0.08, 0.47), control2: point(0.19, 0.73))
                    spiral.addCurve(to: point(0.68, 0.67), control1: point(0.43, 0.88), control2: point(0.72, 0.79))
                    spiral.addCurve(to: point(0.59, 0.39), control1: point(0.81, 0.52), control2: point(0.69, 0.35))
                    spiral.addCurve(to: point(0.42, 0.49), control1: point(0.49, 0.35), control2: point(0.39, 0.41))
                    context.stroke(spiral, with: white, style: stroke)
                case .kali:
                    line([
                        point(0.13, 0.72), point(0.32, 0.30), point(0.42, 0.53),
                        point(0.61, 0.18), point(0.55, 0.49), point(0.84, 0.35),
                        point(0.61, 0.72), point(0.44, 0.61), point(0.31, 0.78)
                    ], closed: true)
                case .astra:
                    var points: [CGPoint] = []
                    for index in 0 ..< 10 {
                        let angle = -CGFloat.pi / 2 + CGFloat(index) * CGFloat.pi / 5
                        let radius: CGFloat = index.isMultiple(of: 2) ? 0.38 : 0.16
                        points.append(point(0.5 + cos(angle) * radius, 0.5 + sin(angle) * radius))
                    }
                    fill(points)
                case .arch:
                    fill([
                        point(0.50, 0.10), point(0.88, 0.84), point(0.64, 0.68),
                        point(0.50, 0.38), point(0.36, 0.68), point(0.12, 0.84)
                    ])
                case .manjaro:
                    fill([point(0.14, 0.14), point(0.86, 0.14), point(0.86, 0.36), point(0.37, 0.36), point(0.37, 0.86), point(0.14, 0.86)])
                    fill([point(0.47, 0.47), point(0.64, 0.47), point(0.64, 0.86), point(0.47, 0.86)])
                    fill([point(0.74, 0.47), point(0.86, 0.47), point(0.86, 0.86), point(0.74, 0.86)])
                case .alpine:
                    line([
                        point(0.08, 0.78), point(0.39, 0.27), point(0.53, 0.49),
                        point(0.66, 0.32), point(0.92, 0.78)
                    ])
                    line([point(0.23, 0.63), point(0.39, 0.48), point(0.49, 0.63)], style: thinStroke)
                case .fedora:
                    context.stroke(Path(ellipseIn: rect(0.19, 0.18, 0.50, 0.50)), with: white, style: stroke)
                    context.stroke(Path(ellipseIn: rect(0.42, 0.42, 0.38, 0.38)), with: white, style: stroke)
                    line([point(0.50, 0.22), point(0.50, 0.78)], style: thinStroke)
                case .redHat:
                    fill([
                        point(0.15, 0.58), point(0.33, 0.53), point(0.39, 0.24),
                        point(0.68, 0.24), point(0.76, 0.53), point(0.88, 0.59),
                        point(0.82, 0.72), point(0.24, 0.72)
                    ])
                    line([point(0.14, 0.75), point(0.36, 0.84), point(0.70, 0.82), point(0.88, 0.70)], style: thinStroke)
                case .centOS:
                    fill([point(0.50, 0.08), point(0.67, 0.25), point(0.57, 0.25), point(0.57, 0.43), point(0.43, 0.43), point(0.43, 0.25), point(0.33, 0.25)])
                    fill([point(0.92, 0.50), point(0.75, 0.67), point(0.75, 0.57), point(0.57, 0.57), point(0.57, 0.43), point(0.75, 0.43), point(0.75, 0.33)])
                    fill([point(0.50, 0.92), point(0.33, 0.75), point(0.43, 0.75), point(0.43, 0.57), point(0.57, 0.57), point(0.57, 0.75), point(0.67, 0.75)])
                    fill([point(0.08, 0.50), point(0.25, 0.33), point(0.25, 0.43), point(0.43, 0.43), point(0.43, 0.57), point(0.25, 0.57), point(0.25, 0.67)])
                case .rocky:
                    fill([
                        point(0.10, 0.82), point(0.34, 0.35), point(0.47, 0.55),
                        point(0.64, 0.18), point(0.91, 0.82), point(0.63, 0.65),
                        point(0.48, 0.76), point(0.33, 0.61)
                    ])
                case .alma:
                    circle(0.40, 0.10, 0.22)
                    circle(0.67, 0.39, 0.22)
                    circle(0.39, 0.67, 0.22)
                    circle(0.11, 0.39, 0.22)
                    circle(0.42, 0.42, 0.16, filled: false)
                case .suse:
                    context.stroke(Path(ellipseIn: rect(0.12, 0.19, 0.72, 0.58)), with: white, style: stroke)
                    circle(0.58, 0.34, 0.12)
                    var tail = Path()
                    tail.move(to: point(0.38, 0.62))
                    tail.addCurve(to: point(0.88, 0.70), control1: point(0.50, 0.89), control2: point(0.78, 0.84))
                    context.stroke(tail, with: white, style: thinStroke)
                case .linux:
                    context.fill(Path(ellipseIn: rect(0.26, 0.20, 0.48, 0.65)), with: white)
                    context.fill(Path(ellipseIn: rect(0.37, 0.08, 0.26, 0.28)), with: white)
                    let dark = GraphicsContext.Shading.color(.black.opacity(0.42))
                    context.fill(Path(ellipseIn: rect(0.41, 0.16, 0.07, 0.09)), with: dark)
                    context.fill(Path(ellipseIn: rect(0.53, 0.16, 0.07, 0.09)), with: dark)
                    fill([point(0.45, 0.28), point(0.55, 0.28), point(0.50, 0.36)])
                    line([point(0.25, 0.79), point(0.14, 0.88)], style: thinStroke)
                    line([point(0.75, 0.79), point(0.86, 0.88)], style: thinStroke)
                default:
                    break
                }
            }
        } else {
            Image(systemName: identity.fallbackSystemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

private struct HostConnectionPulse: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { context in
            let duration = 1.35
            let elapsed = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: duration)
            let progress = CGFloat(elapsed / duration)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(Double(0.72 * (1 - progress))), lineWidth: 1.5)
                .frame(width: 34, height: 34)
                .scaleEffect(0.92 + progress * 0.28)
        }
        .allowsHitTesting(false)
    }
}

struct ProfileOperatingSystemBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let profile: ConnectionProfile
    let connectionActive: Bool
    let tunnelActive: Bool

    private var style: ProfileOperatingSystemStyle { ProfileOperatingSystemStyle.resolve(for: profile) }
    private var hasActivity: Bool { connectionActive || tunnelActive }
    private var activityColor: Color { connectionActive ? .green : .orange }

    var body: some View {
        ZStack {
            if hasActivity && !reduceMotion { HostConnectionPulse(color: activityColor) }

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    if hasActivity {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(activityColor.opacity(0.9), lineWidth: 1.5)
                    }
                }
                .frame(width: 34, height: 34)

            HostPlatformGlyph(identity: style.identity)
                .frame(width: 22, height: 22)

            if profile.connectionType == .ssh {
                Text(profile.sshTerminalProtocol == .mosh ? "M" : ">_")
                    .font(.system(size: 6, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.54), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.42), lineWidth: 0.5))
                    .offset(x: 12, y: 12)
            }

            if hasActivity {
                Circle()
                    .fill(activityColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .offset(x: 13, y: -13)
            }
        }
        .frame(width: 38, height: 38)
        .scaleEffect(hasActivity && !reduceMotion ? 1 : 0.96)
        .shadow(color: hasActivity ? activityColor.opacity(0.28) : .clear, radius: 5)
        .animation(.spring(response: 0.28, dampingFraction: 0.68), value: hasActivity)
        .accessibilityLabel(style.title)
    }
}
