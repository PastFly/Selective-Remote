import CoreGraphics
import Foundation
import SwiftUI

enum SelectiveRemoteHostCardDragPolicy {
    static let minimumDistance: CGFloat = 8

    static func shouldStart(
        horizontal: CGFloat,
        vertical: CGFloat,
        isInteractiveControl: Bool
    ) -> Bool {
        guard !isInteractiveControl else { return false }
        return hypot(horizontal, vertical) >= minimumDistance
    }
}

enum SelectiveRemoteHostCatalogLayout {
    static func showsCatalog(
        preference: Bool,
        availableWidth: CGFloat,
        detailVisible: Bool
    ) -> Bool {
        preference && (availableWidth >= 760 || !detailVisible)
    }
}

enum SelectiveRemoteAdaptiveToolbarLayout {
    enum Mode { case regular, compact }

    static func mode(availableWidth: CGFloat, regularControlsWidth: CGFloat) -> Mode {
        availableWidth >= regularControlsWidth + 198 ? .regular : .compact
    }

    static func searchWidth(availableWidth: CGFloat, reservedWidth: CGFloat) -> CGFloat {
        min(420, max(190, availableWidth - reservedWidth - 8))
    }
}

enum SelectiveRemoteSnippetCommandLayout {
    static func height(for command: String) -> CGFloat {
        let lineCount = command.split(separator: "\n", omittingEmptySubsequences: false).count
        return min(260, 72 + CGFloat(max(0, lineCount - 1)) * 22)
    }
}

/// Keeps search and its related controls together, with one compact contract for narrow columns.
struct SelectiveRemoteAdaptiveToolbar<Search: View, Controls: View, Overflow: View>: View {
    let regularControlsWidth: CGFloat
    @ViewBuilder let search: () -> Search
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let overflow: () -> Overflow

    var body: some View {
        GeometryReader { geometry in
            let mode = SelectiveRemoteAdaptiveToolbarLayout.mode(
                availableWidth: geometry.size.width,
                regularControlsWidth: regularControlsWidth
            )
            HStack(spacing: 8) {
                search()
                    .frame(width: SelectiveRemoteAdaptiveToolbarLayout.searchWidth(
                        availableWidth: geometry.size.width,
                        reservedWidth: mode == .regular ? regularControlsWidth : 44
                    ))
                if mode == .regular { controls() }
                else { overflow() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 36)
    }
}
