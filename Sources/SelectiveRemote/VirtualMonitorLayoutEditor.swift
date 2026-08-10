import SwiftUI

struct VirtualMonitorLayoutEditor: View {
    let displays: [DisplayDescriptor]
    let placements: [DisplayPlacement]
    let editable: Bool
    let onMove: (String, VirtualDisplayPosition) -> Void

    @State private var dragOffsets: [String: CGSize] = [:]

    var body: some View {
        GeometryReader { geometry in
            let layout = drawingLayout(in: geometry.size)
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                grid

                ForEach(placements, id: \.id) { placement in
                    let display = displays.first(where: { $0.id == placement.id })
                    let offset = dragOffsets[placement.id] ?? .zero
                    monitorCard(
                        name: display?.name ?? "Дисплей",
                        placement: placement
                    )
                    .frame(
                        width: max(94, placement.virtualFrame.width * layout.scale),
                        height: max(58, placement.virtualFrame.height * layout.scale)
                    )
                    .position(
                        x: layout.padding
                            + (placement.virtualFrame.midX - layout.bounds.minX) * layout.scale
                            + offset.width,
                        y: layout.padding
                            + (placement.virtualFrame.midY - layout.bounds.minY) * layout.scale
                            + offset.height
                    )
                    .gesture(dragGesture(for: placement, scale: layout.scale))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var grid: some View {
        Canvas { context, size in
            let spacing: CGFloat = 24
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(.secondary.opacity(0.08)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private func monitorCard(name: String, placement: DisplayPlacement) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(placement.isPrimary ? Color.accentColor : Color.blue.opacity(0.72))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            VStack(spacing: 4) {
                HStack {
                    Image(systemName: editable ? "arrow.up.and.down.and.arrow.left.and.right" : "display")
                    Spacer()
                    if placement.isPrimary {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }
                Text(name)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text("x: \(Int(placement.virtualFrame.minX)), y: \(Int(placement.virtualFrame.minY))")
                    .font(.system(size: 9, design: .monospaced))
                    .opacity(0.86)
            }
            .foregroundStyle(.white)
            .padding(8)
        }
        .contentShape(Rectangle())
    }

    private func dragGesture(for placement: DisplayPlacement, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard editable else { return }
                dragOffsets[placement.id] = value.translation
            }
            .onEnded { value in
                guard editable else { return }
                dragOffsets[placement.id] = nil
                let step = 20
                let rawX = Int((placement.virtualFrame.minX + value.translation.width / scale).rounded())
                let rawY = Int((placement.virtualFrame.minY + value.translation.height / scale).rounded())
                let snappedX = Int((Double(rawX) / Double(step)).rounded()) * step
                let snappedY = Int((Double(rawY) / Double(step)).rounded()) * step
                onMove(
                    placement.id,
                    VirtualDisplayPosition(x: snappedX, y: snappedY)
                )
            }
    }

    private func drawingLayout(in size: CGSize) -> (
        bounds: CGRect,
        scale: CGFloat,
        padding: CGFloat
    ) {
        let padding: CGFloat = 22
        guard let first = placements.first else {
            return (CGRect(x: 0, y: 0, width: 1, height: 1), 1, padding)
        }
        let bounds = placements.dropFirst().reduce(first.virtualFrame) {
            $0.union($1.virtualFrame)
        }
        let usableWidth = max(1, size.width - padding * 2)
        let usableHeight = max(1, size.height - padding * 2)
        let scale = min(
            usableWidth / max(1, bounds.width),
            usableHeight / max(1, bounds.height)
        )
        return (bounds, max(0.02, scale), padding)
    }
}
