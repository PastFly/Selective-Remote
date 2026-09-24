import SwiftUI

/// Reports the row's true minimum width to ViewThatFits before text can compress.
struct SelectiveRemoteMeasuredHeaderRow<Identity: View, Trailing: View>: View {
    let minimumIdentityWidth: CGFloat
    var spacing: CGFloat = 8
    @ViewBuilder let identity: () -> Identity
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        SelectiveRemoteMeasuredHeaderLayout(
            minimumIdentityWidth: minimumIdentityWidth, spacing: spacing
        ) {
            identity()
            trailing()
        }
    }
}

private struct SelectiveRemoteMeasuredHeaderLayout: Layout {
    let minimumIdentityWidth: CGFloat
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let trailing = subviews[1].sizeThatFits(.unspecified)
        let minimum = minimumIdentityWidth + spacing + trailing.width
        let width = max(proposal.width ?? minimum, minimum)
        let identity = subviews[0].sizeThatFits(
            ProposedViewSize(width: width - spacing - trailing.width, height: proposal.height)
        )
        return CGSize(width: width, height: max(identity.height, trailing.height))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) {
        guard subviews.count == 2 else { return }
        let trailing = subviews[1].sizeThatFits(.unspecified)
        let identityWidth = max(0, bounds.width - spacing - trailing.width)
        let identity = subviews[0].sizeThatFits(
            ProposedViewSize(width: identityWidth, height: bounds.height)
        )
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY - identity.height / 2),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: identityWidth, height: identity.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.maxX - trailing.width, y: bounds.midY - trailing.height / 2),
            anchor: .topLeading, proposal: .unspecified
        )
    }
}

struct SelectiveRemoteSSHHeaderIdentity: View {
    let title: String
    let endpoint: String
    let showsBadge: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.indigo, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "terminal.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    if showsBadge {
                        Text("SSH")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.indigo)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.indigo.opacity(0.10), in: Capsule())
                            .fixedSize()
                    }
                }
                Text(endpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .clipped()
        .help("\(title) · \(endpoint)")
    }
}
