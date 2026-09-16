import AppKit
import SwiftUI

enum SelectiveRemoteWorkspaceChrome {
    static let accent = Color(red: 0.25, green: 0.82, blue: 0.63)
    static let accentStrong = Color(red: 0.12, green: 0.68, blue: 0.49)

    static func surface(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.045)
            : Color.black.opacity(0.035)
    }

    static func elevatedSurface(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.075)
            : Color.white.opacity(0.72)
    }

    static func border(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.09)
    }
}

private struct SelectiveRemoteWorkspaceSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .background(
                selected
                    ? SelectiveRemoteWorkspaceChrome.accent.opacity(colorScheme == .dark ? 0.15 : 0.11)
                    : SelectiveRemoteWorkspaceChrome.surface(colorScheme),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        selected
                            ? SelectiveRemoteWorkspaceChrome.accent.opacity(0.58)
                            : SelectiveRemoteWorkspaceChrome.border(colorScheme),
                        lineWidth: selected ? 1.25 : 1
                    )
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func selectiveRemoteWorkspaceSurface(
        cornerRadius: CGFloat = 14,
        selected: Bool = false
    ) -> some View {
        modifier(
            SelectiveRemoteWorkspaceSurfaceModifier(
                cornerRadius: cornerRadius,
                selected: selected
            )
        )
    }
}

struct SelectiveRemoteNavigationButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background(
                selected
                    ? SelectiveRemoteWorkspaceChrome.accent.opacity(colorScheme == .dark ? 0.16 : 0.12)
                    : (configuration.isPressed ? Color.primary.opacity(0.06) : Color.clear),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(SelectiveRemoteWorkspaceChrome.accent)
                        .frame(width: 3, height: 18)
                        .padding(.leading, 2)
                }
            }
            .contentShape(Rectangle())
    }
}

/// A macOS checkbox style with an explicit outline in both light and dark appearances.
/// Child views that opt into `.toggleStyle(.switch)` keep the native switch style.
struct SelectiveRemoteCheckboxToggleStyle: ToggleStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(
                            configuration.isOn
                                ? Color.accentColor
                                : Color(nsColor: .controlBackgroundColor)
                        )
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            configuration.isOn
                                ? Color.accentColor
                                : checkboxBorder,
                            lineWidth: configuration.isOn ? 1.5 : 1.25
                        )
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(nsColor: .selectedControlTextColor))
                    }
                }
                .frame(width: 17, height: 17)
                .accessibilityHidden(true)

                configuration.label
                    .foregroundStyle(Color.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }

    private var checkboxBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.52)
            : Color.black.opacity(0.46)
    }
}
