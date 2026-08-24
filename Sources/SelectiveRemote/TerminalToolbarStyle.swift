import SwiftUI

private struct TerminalToolbarContainerModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .controlSize(.regular)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
    }
}

extension View {
    func terminalToolbarContainer() -> some View {
        modifier(TerminalToolbarContainerModifier())
    }
}
