import SwiftUI

struct NotificationBellButton: View {
    let attentionCount: Int
    let english: Bool
    let action: () -> Void

    @FocusState private var hasKeyboardFocus: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "bell")
                    .foregroundStyle(.secondary)
                if attentionCount > 0 {
                    Text(attentionCount > 9 ? "9+" : "\(attentionCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(NotificationBellStyle())
        .focused($hasKeyboardFocus)
        .focusEffectDisabled()
        .overlay {
            // Keep keyboard focus visible without the native borderless button's filled ring.
            if hasKeyboardFocus && controlActiveState == .key {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .padding(-4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .help(english ? "Notifications" : "Уведомления")
        .accessibilityLabel(english
            ? "Notifications: \(attentionCount) need attention"
            : "Уведомления: требуют внимания \(attentionCount)")
    }
}

private struct NotificationBellStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
