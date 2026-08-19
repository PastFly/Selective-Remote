import SwiftUI

struct SFTPTransferActivitySnapshot: Equatable, Sendable {
    let hasItems: Bool
    let activeCount: Int
    let hasPausedTransfers: Bool

    init(items: [SFTPTransferItem]) {
        hasItems = !items.isEmpty
        activeCount = items.filter { !$0.phase.isTerminal }.count
        hasPausedTransfers = items.contains { $0.phase == .paused }
    }
}

@MainActor
struct SFTPWorkspaceTransferSummaryView: View {
    @ObservedObject private var leftQueue: SFTPTransferQueue
    @ObservedObject private var rightQueue: SFTPTransferQueue

    private let leftTitle: String
    private let leftSystemImage: String
    private let rightTitle: String
    private let rightSystemImage: String
    @Binding private var isExpanded: Bool

    init(
        tab: SFTPWorkspaceTab,
        isExpanded: Binding<Bool>
    ) {
        _leftQueue = ObservedObject(wrappedValue: tab.left.session.transfers)
        _rightQueue = ObservedObject(wrappedValue: tab.right.session.transfers)
        leftTitle = tab.left.title
        leftSystemImage = tab.left.systemImage
        rightTitle = tab.right.title
        rightSystemImage = tab.right.systemImage
        _isExpanded = isExpanded
    }

    var body: some View {
        if hasItems {
            DisclosureGroup(isExpanded: $isExpanded) {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        if !leftQueue.items.isEmpty {
                            queueSection(
                                leftQueue,
                                title: leftTitle,
                                systemImage: leftSystemImage
                            )
                        }
                        if !rightQueue.items.isEmpty {
                            queueSection(
                                rightQueue,
                                title: rightTitle,
                                systemImage: rightSystemImage
                            )
                        }
                    }
                    .padding(.top, 7)
                }
                .frame(maxHeight: 220)
            } label: {
                Label(
                    "Передачи · активных: \(leftQueue.activeCount + rightQueue.activeCount)",
                    systemImage: "arrow.up.arrow.down.circle"
                )
                .font(.headline)
            }
        }
    }

    private var hasItems: Bool {
        !leftQueue.items.isEmpty || !rightQueue.items.isEmpty
    }

    private func queueSection(
        _ queue: SFTPTransferQueue,
        title: String,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                Spacer()
                Picker(
                    "При совпадении имён",
                    selection: Binding(
                        get: { queue.conflictPolicy },
                        set: { queue.conflictPolicy = $0 }
                    )
                ) {
                    ForEach(SFTPConflictPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)

                if queue.items.contains(where: { $0.phase == .paused }) {
                    Button("Продолжить все", systemImage: "play.fill") {
                        queue.resumeAll()
                    }
                    .labelStyle(.iconOnly)
                } else if queue.items.contains(where: { $0.phase == .running }) {
                    Button("Пауза", systemImage: "pause.fill") {
                        queue.pauseAll()
                    }
                    .labelStyle(.iconOnly)
                }
                Button("Отменить все", systemImage: "xmark") {
                    queue.cancelAll()
                }
                .labelStyle(.iconOnly)
                .disabled(queue.activeCount == 0)
                Button("Очистить завершённые", systemImage: "trash") {
                    queue.clearFinished()
                }
                .labelStyle(.iconOnly)
                .disabled(!queue.items.contains(where: { $0.phase.isTerminal }))
            }

            ForEach(queue.items.reversed()) { item in
                transferRow(item, queue: queue)
            }
        }
        .padding(8)
        .background(
            Color.primary.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func transferRow(
        _ item: SFTPTransferItem,
        queue: SFTPTransferQueue
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.direction.systemImage)
                .foregroundStyle(item.phase == .failed ? Color.red : Color.blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(item.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text("· \(item.direction.title)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(item.phase.title)
                        .font(.caption)
                        .foregroundStyle(item.phase == .failed ? Color.red : Color.secondary)
                }

                HStack(spacing: 5) {
                    Text(item.source).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "arrow.right")
                    Text(item.destination).lineLimit(1).truncationMode(.middle)
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .help("\(item.source) → \(item.destination)")

                if let fraction = item.fractionCompleted {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else if item.phase == .running {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                HStack(spacing: 5) {
                    Text(item.progressText)
                    if let fraction = item.fractionCompleted {
                        Text("· \(Int((fraction * 100).rounded()))%")
                    }
                    if let speed = item.speedText {
                        Text("· \(speed)")
                    }
                    if let eta = item.etaText {
                        Text("· ETA \(eta)")
                    }
                    if let error = item.errorMessage {
                        Text("· \(error)")
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            switch item.phase {
            case .running:
                Button("Пауза", systemImage: "pause.fill") { queue.pause(item.id) }
                    .labelStyle(.iconOnly)
            case .paused:
                Button("Продолжить", systemImage: "play.fill") { queue.resume(item.id) }
                    .labelStyle(.iconOnly)
            case .failed, .cancelled:
                Button("Повторить", systemImage: "arrow.clockwise") { queue.retry(item.id) }
                    .labelStyle(.iconOnly)
            default:
                EmptyView()
            }
            if !item.phase.isTerminal {
                Button("Отменить", systemImage: "xmark") { queue.cancel(item.id) }
                    .labelStyle(.iconOnly)
            }
        }
    }
}
