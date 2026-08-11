import Darwin
import Combine
import Foundation

enum SFTPTransferDirection: String, Sendable {
    case upload
    case download

    var title: String { self == .upload ? "На сервер" : "На этот Mac" }
    var systemImage: String { self == .upload ? "arrow.up.circle" : "arrow.down.circle" }
}

enum SFTPTransferPhase: String, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .queued: "В очереди"
        case .running: "Передаётся"
        case .paused: "Приостановлено"
        case .completed: "Готово"
        case .failed: "Ошибка"
        case .cancelled: "Отменено"
        }
    }

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

enum SFTPConflictPolicy: String, CaseIterable, Identifiable, Sendable {
    case rename
    case replace
    case skip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rename: "Сохранить оба"
        case .replace: "Заменять"
        case .skip: "Пропускать"
        }
    }
}

struct SFTPTransferItem: Identifiable, Sendable {
    let id: UUID
    let direction: SFTPTransferDirection
    let name: String
    let source: String
    let destination: String
    let totalBytes: Int64?
    let createdAt: Date
    var phase: SFTPTransferPhase
    var transferredBytes: Int64
    var bytesPerSecond: Double
    var errorMessage: String?

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(transferredBytes) / Double(totalBytes)))
    }

    var progressText: String {
        if let totalBytes {
            let done = ByteCountFormatter.string(fromByteCount: transferredBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(done) из \(total)"
        }
        return phase.title
    }

    var speedText: String? {
        guard bytesPerSecond > 0 else { return nil }
        return ByteCountFormatter.string(
            fromByteCount: Int64(bytesPerSecond.rounded()),
            countStyle: .file
        ) + "/с"
    }
}

final class SFTPProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private weak var process: Process?
    private var wantsPause = false
    private var wantsCancel = false

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let pause = wantsPause
        let cancel = wantsCancel
        lock.unlock()
        if cancel {
            process.terminate()
        } else if pause {
            Darwin.kill(process.processIdentifier, SIGSTOP)
        }
    }

    func detach(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }

    func pause() {
        lock.lock()
        wantsPause = true
        let pid = process?.processIdentifier
        lock.unlock()
        if let pid { Darwin.kill(pid, SIGSTOP) }
    }

    func resume() {
        lock.lock()
        wantsPause = false
        let pid = process?.processIdentifier
        lock.unlock()
        if let pid { Darwin.kill(pid, SIGCONT) }
    }

    func cancel() {
        lock.lock()
        wantsCancel = true
        let running = process
        let wasPaused = wantsPause
        wantsPause = false
        lock.unlock()
        if wasPaused, let running {
            Darwin.kill(running.processIdentifier, SIGCONT)
        }
        running?.terminate()
    }
}

private final class SFTPTransferOperationState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

struct SFTPTransferRequest: @unchecked Sendable {
    let item: SFTPTransferItem
    let operation: @Sendable (_ resume: Bool, _ control: SFTPProcessControl) throws -> Void
    let progressProbe: @Sendable () -> Int64?
    let completion: @MainActor @Sendable () -> Void
}

@MainActor
final class SFTPTransferQueue: ObservableObject {
    @Published private(set) var items: [SFTPTransferItem] = []
    @Published var conflictPolicy: SFTPConflictPolicy = .rename

    private var requests: [UUID: SFTPTransferRequest] = [:]
    private var controls: [UUID: SFTPProcessControl] = [:]
    private var worker: Task<Void, Never>?

    var activeCount: Int {
        items.filter { !$0.phase.isTerminal }.count
    }

    var completedCount: Int {
        items.filter { $0.phase == .completed }.count
    }

    func enqueue(_ request: SFTPTransferRequest) {
        requests[request.item.id] = request
        items.append(request.item)
        startWorkerIfNeeded()
    }

    func pause(_ id: UUID) {
        guard let index = index(of: id), items[index].phase == .running else { return }
        controls[id]?.pause()
        items[index].phase = .paused
    }

    func resume(_ id: UUID) {
        guard let index = index(of: id), items[index].phase == .paused else { return }
        controls[id]?.resume()
        items[index].phase = .running
    }

    func cancel(_ id: UUID) {
        guard let index = index(of: id), !items[index].phase.isTerminal else { return }
        controls[id]?.cancel()
        items[index].phase = .cancelled
        items[index].errorMessage = nil
    }

    func retry(_ id: UUID) {
        guard let index = index(of: id),
              items[index].phase == .failed || items[index].phase == .cancelled
        else { return }
        items[index].phase = .queued
        items[index].errorMessage = nil
        items[index].bytesPerSecond = 0
        // Mark the next attempt as resumable. OpenSSH reget/reput also work
        // when the partial target is empty, while preserving completed bytes.
        items[index].transferredBytes = max(1, items[index].transferredBytes)
        startWorkerIfNeeded()
    }

    func pauseAll() {
        for item in items where item.phase == .running { pause(item.id) }
    }

    func resumeAll() {
        for item in items where item.phase == .paused { resume(item.id) }
        startWorkerIfNeeded()
    }

    func cancelAll() {
        for item in items where !item.phase.isTerminal { cancel(item.id) }
    }

    func clearFinished() {
        let finished = Set(items.filter { $0.phase.isTerminal }.map(\.id))
        items.removeAll { finished.contains($0.id) }
        for id in finished {
            requests.removeValue(forKey: id)
            controls.removeValue(forKey: id)
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.runNext()
        }
    }

    private func runNext() async {
        defer { worker = nil }
        while let next = items.first(where: { $0.phase == .queued })?.id {
            guard let request = requests[next], let itemIndex = index(of: next) else { continue }
            let isResume = items[itemIndex].transferredBytes > 0
            let control = SFTPProcessControl()
            controls[next] = control
            items[itemIndex].phase = .running
            items[itemIndex].errorMessage = nil
            let started = Date()

            let operationState = SFTPTransferOperationState()
            let operation = Task.detached(priority: .userInitiated) {
                defer { operationState.markFinished() }
                try request.operation(isResume, control)
            }
            while !operationState.isFinished {
                // Progress probes may perform filesystem or SFTP I/O. Never run
                // them on MainActor: a slow stat/list request used to freeze row
                // selection and make the progress UI appear stuck.
                let measured = await Task.detached(priority: .utility) {
                    request.progressProbe()
                }.value
                updateProgress(next, request: request, started: started, measured: measured)
                try? await Task.sleep(for: .milliseconds(800))
            }

            do {
                try await operation.value
                guard let current = index(of: next), items[current].phase != .cancelled else {
                    controls.removeValue(forKey: next)
                    continue
                }
                updateProgress(next, request: request, started: started, measured: nil, completed: true)
                items[current].phase = .completed
                items[current].errorMessage = nil
                request.completion()
            } catch {
                guard let current = index(of: next) else { continue }
                if items[current].phase != .cancelled {
                    items[current].phase = .failed
                    items[current].errorMessage = error.localizedDescription
                }
            }
            controls.removeValue(forKey: next)
        }
    }

    private func updateProgress(
        _ id: UUID,
        request: SFTPTransferRequest,
        started: Date,
        measured: Int64?,
        completed: Bool = false
    ) {
        guard let index = index(of: id) else { return }
        let measured = measured ?? items[index].transferredBytes
        if completed, let total = items[index].totalBytes {
            items[index].transferredBytes = total
        } else {
            items[index].transferredBytes = max(items[index].transferredBytes, measured)
        }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 0.2 {
            items[index].bytesPerSecond = Double(items[index].transferredBytes) / elapsed
        }
    }

    private func index(of id: UUID) -> Int? {
        items.firstIndex(where: { $0.id == id })
    }
}
