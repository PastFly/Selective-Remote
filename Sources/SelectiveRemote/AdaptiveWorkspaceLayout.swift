import CoreGraphics

enum AdaptiveWorkspaceLayout {
    static let singleColumnProfileWidth: CGFloat = 900
    static let stackedSFTPPanesWidth: CGFloat = 1_100
    static let detailNavigationWidth: CGFloat = 1_180
    static let profileInspectorWidth: CGFloat = 1_120

    static func usesSingleColumnProfileEditor(width: CGFloat) -> Bool {
        width < singleColumnProfileWidth
    }

    static func usesStackedSFTPPanes(width: CGFloat) -> Bool {
        width < stackedSFTPPanesWidth
    }

    static func usesDetailNavigation(width: CGFloat) -> Bool {
        width < detailNavigationWidth
    }

    static func showsProfileInspector(width: CGFloat) -> Bool {
        width >= profileInspectorWidth
    }
}
