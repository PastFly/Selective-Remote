import AppKit
import SwiftUI

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
