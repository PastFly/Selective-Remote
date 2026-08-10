import SwiftUI

struct MonitorMapView: View {
    let displays: [DisplayDescriptor]
    let selectedIDs: Set<String>
    let primaryID: String?
    let onToggle: (DisplayDescriptor) -> Void
    let onPrimary: (DisplayDescriptor) -> Void

    var body: some View {
        GeometryReader { geometry in
            let bounds = unionBounds
            let scale = min(
                (geometry.size.width - 36) / max(bounds.width, 1),
                (geometry.size.height - 36) / max(bounds.height, 1)
            )

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))

                ForEach(Array(displays.enumerated()), id: \.element.id) { index, display in
                    let selected = selectedIDs.contains(display.id)
                    monitor(display, number: index + 1, selected: selected)
                        .frame(
                            width: max(display.frame.width * scale, 110),
                            height: max(display.frame.height * scale, 74)
                        )
                        .position(
                            x: 18 + (display.frame.midX - bounds.minX) * scale,
                            y: 18 + (bounds.maxY - display.frame.midY) * scale
                        )
                }
            }
        }
    }

    private var unionBounds: CGRect {
        displays.map(\.frame).reduce(.null) { $0.union($1) }
    }

    private func monitor(_ display: DisplayDescriptor, number: Int, selected: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 5) {
                HStack {
                    Text("\(number)")
                        .font(.title2.bold())
                    Spacer()
                }
                Text(display.name)
                    .font(.caption.bold())
                    .lineLimit(1)
                Text("\(display.resolutionText) · \(display.refreshText)")
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(10)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onTapGesture { onToggle(display) }

            Button {
                onPrimary(display)
            } label: {
                Image(systemName: primaryID == display.id ? "star.fill" : "star")
                    .foregroundStyle(primaryID == display.id ? Color.yellow : (selected ? Color.white : Color.secondary))
                    .padding(9)
            }
            .buttonStyle(.plain)
            .help("Сделать основным монитором Windows")
        }
        .contextMenu {
            Button("Сделать основным") { onPrimary(display) }
        }
    }
}
