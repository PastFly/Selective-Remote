import CoreGraphics
import Foundation
import SwiftUI

enum SelectiveRemoteHostDragIdentity {
    case personalHost(UUID)
    case personalFolder(String)
    case teamHost(UUID)
    case teamFolder(vaultID: UUID, path: String)

    var value: String {
        switch self {
        case let .personalHost(id): "personal-host:\(id.uuidString)"
        case let .personalFolder(path): "personal-folder:\(path)"
        case let .teamHost(id): "team-host:\(id.uuidString)"
        case let .teamFolder(vaultID, path): "team-folder:\(vaultID.uuidString):\(path)"
        }
    }
}

/// Keeps selection and native drag on the same card surface, including in lists.
struct SelectiveRemoteDraggableHostCard<Content: View>: View {
    let identity: String
    let select: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .focusable()
            .onKeyPress(.return) {
                select()
                return .handled
            }
            .onKeyPress(.space) {
                select()
                return .handled
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, select)
            .draggable(identity)
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
        min(780, max(0, availableWidth - reservedWidth - 8))
    }
}

enum SelectiveRemoteSSHHeaderLayout {
    enum Mode { case regular, compact, minimum }

    static func minimumWidth(for mode: Mode) -> CGFloat {
        switch mode {
        case .regular: 760
        case .compact: 400
        case .minimum: 0
        }
    }

    static func mode(width: CGFloat) -> Mode {
        if width >= minimumWidth(for: .regular) { return .regular }
        if width >= minimumWidth(for: .compact) { return .compact }
        return .minimum
    }
}

enum SelectiveRemoteTerminalToolbarLayout {
    enum Mode { case regular, compact, minimum }

    static func minimumWidth(for mode: Mode) -> CGFloat {
        switch mode {
        case .regular: 1000
        case .compact: 480
        case .minimum: 0
        }
    }

    static func mode(width: CGFloat) -> Mode {
        if width >= minimumWidth(for: .regular) { return .regular }
        if width >= minimumWidth(for: .compact) { return .compact }
        return .minimum
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
