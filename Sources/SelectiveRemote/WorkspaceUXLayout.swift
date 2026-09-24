import AppKit
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

/// A left click commits only on mouse-up; moving past the threshold starts one drag.
struct SelectiveRemoteHostCardPointerSequence {
    enum Action: Equatable { case none, select, beginDrag }

    let threshold: CGFloat
    private var origin: CGPoint?
    private var dragging = false

    init(threshold: CGFloat) {
        self.threshold = threshold
    }

    mutating func press(at point: CGPoint) {
        origin = point
        dragging = false
    }

    mutating func move(to point: CGPoint) -> Action {
        guard let origin, !dragging,
              hypot(point.x - origin.x, point.y - origin.y) >= threshold
        else { return .none }
        dragging = true
        return .beginDrag
    }

    mutating func release() -> Action {
        defer { origin = nil; dragging = false }
        return origin != nil && !dragging ? .select : .none
    }

    mutating func cancel() {
        origin = nil
        dragging = false
    }
}

enum SelectiveRemoteHostSelectionTransition {
    static func needsTransition(
        currentID: String?, requestedID: String, detailsVisible: Bool, alreadyInHosts: Bool
    ) -> Bool {
        currentID != requestedID || !detailsVisible || !alreadyInHosts
    }
}

enum SelectiveRemoteHostCardNavigation {
    enum Direction { case up, down, left, right }

    static func nextIndex(
        from index: Int, direction: Direction, frames: [CGRect]
    ) -> Int? {
        guard frames.indices.contains(index) else { return nil }
        let current = frames[index]
        return frames.indices.filter { $0 != index }.compactMap { candidate -> (Int, CGFloat)? in
            let frame = frames[candidate]
            let primary: CGFloat
            let transverse: CGFloat
            switch direction {
            case .up:
                primary = frame.midY - current.midY
                transverse = abs(frame.midX - current.midX)
            case .down:
                primary = current.midY - frame.midY
                transverse = abs(frame.midX - current.midX)
            case .left:
                primary = current.midX - frame.midX
                transverse = abs(frame.midY - current.midY)
            case .right:
                primary = frame.midX - current.midX
                transverse = abs(frame.midY - current.midY)
            }
            guard primary > 1 else { return nil }
            return (candidate, primary + transverse * 2)
        }
        .min { $0.1 < $1.1 }?.0
    }
}

/// AppKit owns the whole card's left pointer path; the SwiftUI content remains visual only.
private struct SelectiveRemoteHostCardPointerSurface: NSViewRepresentable {
    let identity: String
    let navigationScope: String
    let previewTitle: String
    let select: () -> Void

    func makeNSView(context: Context) -> PointerView {
        PointerView()
    }

    func updateNSView(_ view: PointerView, context: Context) {
        view.identity = identity
        view.navigationScope = navigationScope
        view.previewTitle = previewTitle
        view.select = select
    }

    final class PointerView: NSView, NSDraggingSource {
        var identity = ""
        var navigationScope = ""
        var previewTitle = ""
        var select: (() -> Void)?
        private var pointer = SelectiveRemoteHostCardPointerSequence(threshold: 4)

        override var acceptsFirstResponder: Bool { true }
        override var isOpaque: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Let the card's SwiftUI context menu handle secondary clicks.
            if NSApp.currentEvent?.type == .rightMouseDown { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 1 else {
                pointer.cancel()
                return
            }
            pointer.press(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard pointer.move(to: point) == .beginDrag else { return }
            let item = NSPasteboardItem()
            item.setString(identity, forType: .string)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            draggingItem.setDraggingFrame(bounds, contents: dragPreview())
            beginDraggingSession(with: [draggingItem], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if pointer.release() == .select {
                window?.makeFirstResponder(self)
                select?()
            }
        }

        override func keyDown(with event: NSEvent) {
            if event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == " " {
                select?()
            } else if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                      let direction = Self.direction(for: event.keyCode),
                      navigate(direction) {
                return
            } else {
                super.keyDown(with: event)
            }
        }

        private static func direction(for keyCode: UInt16) -> SelectiveRemoteHostCardNavigation.Direction? {
            switch keyCode {
            case 123: .left
            case 124: .right
            case 125: .down
            case 126: .up
            default: nil
            }
        }

        private func navigate(_ direction: SelectiveRemoteHostCardNavigation.Direction) -> Bool {
            guard let contentView = window?.contentView else { return false }
            let cards = Self.cards(in: contentView).filter {
                $0.navigationScope == navigationScope && $0.window === window
                    && !$0.isHidden && !$0.visibleRect.isEmpty
            }
            guard let index = cards.firstIndex(where: { $0 === self }),
                  let next = SelectiveRemoteHostCardNavigation.nextIndex(
                    from: index, direction: direction,
                    frames: cards.map { $0.convert($0.bounds, to: nil) }
                  )
            else { return false }
            let target = cards[next]
            target.scrollToVisible(target.bounds)
            window?.makeFirstResponder(target)
            target.select?()
            return true
        }

        private static func cards(in view: NSView) -> [PointerView] {
            var result = view.subviews.flatMap(cards(in:))
            if let card = view as? PointerView { result.append(card) }
            return result
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation { .move }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                             operation: NSDragOperation) {
            pointer.cancel()
        }

        private func dragPreview() -> NSImage {
            let size = NSSize(width: max(120, bounds.width), height: max(38, bounds.height))
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 9, yRadius: 9).fill()
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 9, yRadius: 9).stroke()
            (previewTitle as NSString).draw(
                in: NSRect(x: 12, y: (size.height - 20) / 2, width: size.width - 24, height: 20),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                 .foregroundColor: NSColor.labelColor]
            )
            image.unlockFocus()
            return image
        }
    }
}

/// Keeps selection and native drag on the same complete card surface.
struct SelectiveRemoteDraggableHostCard<Content: View>: View {
    let identity: String
    let navigationScope: String
    let previewTitle: String
    let select: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .contentShape(Rectangle())
            .overlay {
                SelectiveRemoteHostCardPointerSurface(
                    identity: identity, navigationScope: navigationScope,
                    previewTitle: previewTitle, select: select
                )
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, select)
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
