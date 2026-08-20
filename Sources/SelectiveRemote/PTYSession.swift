import Combine
import Darwin
import Foundation
import PTYBridge

enum PTYProcessError: LocalizedError {
    case executableUnavailable(String)
    case alreadyRunning
    case invalidArgument
    case spawnFailed(String)

    var errorDescription: String? {
        switch self {
        case let .executableUnavailable(path):
            "Системная команда недоступна: \(path)"
        case .alreadyRunning:
            "В этом терминале уже выполняется команда"
        case .invalidArgument:
            "Команда терминала содержит недопустимый нулевой символ"
        case let .spawnFailed(message):
            "Не удалось создать псевдотерминал: \(message)"
        }
    }
}

final class PTYProcess: @unchecked Sendable {
    var onOutput: (@Sendable (Data) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?

    private let stateLock = NSLock()
    private let ioQueue = DispatchQueue(
        label: "ru.selectiveremote.pty.io",
        qos: .userInitiated
    )
    private var processID: pid_t?
    private var masterFileDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var pendingWriteData = Data()
    private var writeRetryScheduled = false

    var isRunning: Bool {
        stateLock.withLock { processID != nil }
    }

    func start(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        columns: UInt16 = 100,
        rows: UInt16 = 30
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw PTYProcessError.executableUnavailable(executable)
        }
        guard !isRunning else { throw PTYProcessError.alreadyRunning }
        guard !executable.contains("\0"),
              !arguments.contains(where: { $0.contains("\0") }),
              workingDirectory?.contains("\0") != true
        else {
            throw PTYProcessError.invalidArgument
        }

        let argumentValues = [executable] + arguments
        let environmentValues = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var primary: Int32 = -1
        let directory = workingDirectory ?? ""
        let child: pid_t = executable.withCString { executablePointer in
            directory.withCString { directoryPointer in
                withMutableCStringArray(argumentValues) { argumentPointers in
                    withMutableCStringArray(environmentValues) { environmentPointers in
                        selectiveremote_spawn_pty(
                            executablePointer,
                            argumentPointers,
                            environmentPointers,
                            directoryPointer,
                            columns,
                            rows,
                            &primary
                        )
                    }
                }
            }
        }
        guard child > 0, primary >= 0 else {
            throw PTYProcessError.spawnFailed(Self.currentPOSIXError())
        }

        let descriptor = primary
        stateLock.withLock {
            processID = child
            masterFileDescriptor = descriptor
        }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: ioQueue
        )
        source.setEventHandler { [weak self] in
            self?.readAvailableData()
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        readSource = source
        source.resume()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var exitCode: Int32 = 255
            if selectiveremote_wait_pty(child, &exitCode) != 0 {
                exitCode = 255
            }
            self?.complete(exitCode: exitCode)
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        ioQueue.async { [weak self] in
            self?.enqueueWrite(data)
        }
    }

    func resize(columns: UInt16, rows: UInt16) {
        guard columns > 0, rows > 0 else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            let descriptor = stateLock.withLock { masterFileDescriptor }
            if descriptor >= 0 {
                _ = selectiveremote_resize_pty(descriptor, columns, rows)
            }
        }
    }

    func terminate() {
        let child = stateLock.withLock { processID }
        guard let child else { return }
        _ = selectiveremote_signal_pty(child, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .seconds(3)
        ) { [weak self] in
            guard let self,
                  stateLock.withLock({ processID }) == child
            else { return }
            _ = selectiveremote_signal_pty(child, SIGKILL)
        }
    }

    deinit {
        terminate()
        readSource?.cancel()
    }

    private func readAvailableData() {
        let descriptor = stateLock.withLock { masterFileDescriptor }
        guard descriptor >= 0 else { return }

        var bytes = [UInt8](repeating: 0, count: 32_768)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                onOutput?(Data(bytes[0..<count]))
                continue
            }
            if count == 0 || errno == EIO {
                return
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            return
        }
    }

    private func enqueueWrite(_ data: Data) {
        pendingWriteData.append(data)
        flushPendingWrites()
    }

    private func flushPendingWrites() {
        let descriptor = stateLock.withLock { masterFileDescriptor }
        guard descriptor >= 0 else {
            pendingWriteData.removeAll()
            return
        }

        while !pendingWriteData.isEmpty {
            let written = pendingWriteData.withUnsafeBytes { rawBuffer -> Int in
                guard let pointer = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(descriptor, pointer, rawBuffer.count)
            }
            if written > 0 {
                pendingWriteData.removeFirst(written)
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, (errno == EAGAIN || errno == EWOULDBLOCK) {
                scheduleWriteRetry()
                return
            } else {
                pendingWriteData.removeAll()
                return
            }
        }
    }

    private func scheduleWriteRetry() {
        guard !writeRetryScheduled else { return }
        writeRetryScheduled = true
        ioQueue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
            guard let self else { return }
            writeRetryScheduled = false
            flushPendingWrites()
        }
    }

    private func complete(exitCode: Int32) {
        stateLock.withLock {
            processID = nil
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            readAvailableData()
            stateLock.withLock {
                masterFileDescriptor = -1
            }
            pendingWriteData.removeAll()
            readSource?.cancel()
            readSource = nil
            onTermination?(exitCode)
        }
    }

    private static func currentPOSIXError() -> String {
        String(cString: strerror(errno))
    }

    private func withMutableCStringArray<Result>(
        _ values: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = values.map { value in
            value.withCString { strdup($0) }
        }
        pointers.append(nil)
        defer {
            pointers.dropLast().forEach { pointer in
                free(pointer)
            }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

enum EmbeddedTerminalPhase: Equatable {
    case idle
    case starting(String)
    case running(String)
    case stopping
    case finished(Int32)

    var isRunning: Bool {
        switch self {
        case .starting, .running, .stopping:
            true
        case .idle, .finished:
            false
        }
    }

    var title: String {
        switch self {
        case .idle:
            "Терминал не запущен"
        case let .starting(command):
            "Запуск: \(command)"
        case let .running(command):
            "Выполняется: \(command)"
        case .stopping:
            "Завершение…"
        case let .finished(code):
            code == 0 ? "Команда завершена" : "Команда завершилась с кодом \(code)"
        }
    }
}

@MainActor
final class TerminalSessionModel: ObservableObject {
    typealias OutputObserver = @MainActor (Data) -> Void
    typealias Completion = @MainActor (Int32) -> Void

    @Published private(set) var phase = EmbeddedTerminalPhase.idle
    @Published private(set) var commandTitle = ""
    @Published private(set) var startedAt: Date?
    @Published private(set) var reconnectProgress: SmartReconnectProgress?
    @Published private(set) var terminalColumns = 100
    @Published private(set) var terminalRows = 30

    private var process: PTYProcess?
    private var outputObservers: [UUID: OutputObserver] = [:]
    private var replayBuffer = Data()
    private var completion: Completion?
    private var columns: UInt16 = 100
    private var rows: UInt16 = 30
    private let maximumReplayBytes = 2 * 1_024 * 1_024
    private var displayRefreshTask: Task<Void, Never>?
    private var stopRequested = false
    private(set) var lastTerminationWasRequested = false

    var isRunning: Bool { phase.isRunning }

    @discardableResult
    func addOutputObserver(_ observer: @escaping OutputObserver) -> UUID {
        let id = UUID()
        outputObservers[id] = observer
        if !replayBuffer.isEmpty {
            observer(Data("\u{001B}c".utf8))
            observer(replayBuffer)
        }
        return id
    }

    func removeOutputObserver(_ id: UUID) {
        outputObservers.removeValue(forKey: id)
    }

    func start(
        executable: String,
        arguments: [String],
        title: String,
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        completion: Completion? = nil
    ) throws {
        guard !isRunning else { throw PTYProcessError.alreadyRunning }

        let newProcess = PTYProcess()
        var processEnvironment = environment ?? ProcessInfo.processInfo.environment
        processEnvironment["TERM"] = "xterm-256color"
        processEnvironment["COLORTERM"] = "truecolor"
        processEnvironment["TERM_PROGRAM"] = "SelectiveRemote"
        processEnvironment["TERM_PROGRAM_VERSION"] = AppBuildInfo.version

        commandTitle = title
        startedAt = nil
        stopRequested = false
        lastTerminationWasRequested = false
        phase = .starting(title)
        self.completion = completion
        resetOutput()
        appendLocalText("\(AppBrand.name) · \(title)\r\n\r\n")

        newProcess.onOutput = { [weak self] data in
            Task { @MainActor [weak self] in
                self?.receive(data)
            }
        }
        newProcess.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                self?.didTerminate(exitCode: exitCode)
            }
        }

        do {
            try newProcess.start(
                executable: executable,
                arguments: arguments,
                environment: processEnvironment,
                workingDirectory: workingDirectory,
                columns: columns,
                rows: rows
            )
            process = newProcess
            startedAt = Date()
            phase = .running(title)
        } catch {
            startedAt = nil
            phase = .finished(255)
            self.completion = nil
            appendLocalText("\r\nНе удалось запустить команду: \(error.localizedDescription)\r\n")
            throw error
        }
    }

    func sendInput(_ data: Data) {
        process?.send(data)
    }

    func resize(columns: Int, rows: Int) {
        updateTerminalSize(columns: columns, rows: rows, force: false)
    }

    /// Forces a real SIGWINCH round-trip for full-screen terminal applications.
    /// Merely writing the same TIOCSWINSZ geometry does not reliably emit SIGWINCH
    /// on Unix, so nano/vim/tmux may keep a screen that belonged to the old WebView.
    /// Pulse the row count by one and immediately restore the real geometry.
    func refreshDisplay() {
        guard isRunning, let process else { return }

        displayRefreshTask?.cancel()
        let realColumns = columns
        let realRows = rows
        let pulseRows: UInt16 = realRows > 5 ? realRows - 1 : realRows + 1

        process.resize(columns: realColumns, rows: pulseRows)
        displayRefreshTask = Task { @MainActor [weak self, weak process] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self, self.isRunning, let process else { return }
            process.resize(columns: realColumns, rows: realRows)
        }
    }

    private func updateTerminalSize(columns: Int, rows: Int, force: Bool) {
        // SwiftUI can briefly lay a tab out at a near-zero size while changing
        // sections or hiding the sidebar. Do not forward that transient 2×1
        // geometry to interactive programs: nano/vim would redraw against it
        // before the real WebView size arrives.
        guard columns >= 20, rows >= 5 else { return }
        let normalizedColumns = min(columns, 2_000)
        let normalizedRows = min(rows, 1_000)
        let safeColumns = UInt16(clamping: normalizedColumns)
        let safeRows = UInt16(clamping: normalizedRows)
        guard force || safeColumns != self.columns || safeRows != self.rows else { return }
        self.columns = safeColumns
        self.rows = safeRows
        terminalColumns = Int(safeColumns)
        terminalRows = Int(safeRows)
        process?.resize(columns: safeColumns, rows: safeRows)
    }

    func stop() {
        stopRequested = true
        reconnectProgress = nil
        guard isRunning else { return }
        displayRefreshTask?.cancel()
        displayRefreshTask = nil
        phase = .stopping
        process?.terminate()
    }

    func setReconnectProgress(_ progress: SmartReconnectProgress?) {
        reconnectProgress = progress
    }

    func recentOutputText(maximumBytes: Int = 16_384) -> String {
        let count = min(maximumBytes, replayBuffer.count)
        guard count > 0 else { return "" }
        let data = Data(replayBuffer.suffix(count))
        return String(decoding: data, as: UTF8.self)
    }

    func clear() {
        resetOutput()
        notifyOutput(Data("\u{001B}c".utf8))
    }

    private func resetOutput() {
        replayBuffer.removeAll(keepingCapacity: true)
        notifyOutput(Data("\u{001B}c".utf8))
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        replayBuffer.append(data)
        if replayBuffer.count > maximumReplayBytes {
            replayBuffer.removeFirst(replayBuffer.count - maximumReplayBytes)
        }
        notifyOutput(data)
    }

    private func appendLocalText(_ text: String) {
        receive(Data(text.utf8))
    }

    private func notifyOutput(_ data: Data) {
        outputObservers.values.forEach { $0(data) }
    }

    private func didTerminate(exitCode: Int32) {
        process = nil
        startedAt = nil
        let terminationRequested = stopRequested
        lastTerminationWasRequested = terminationRequested
        stopRequested = false
        phase = .finished(exitCode)
        if terminationRequested {
            appendLocalText("\r\n\r\n[\(AppBrand.name)] Сессия отключена пользователем.\r\n")
        } else {
            appendLocalText(
                "\r\n\r\n[\(AppBrand.name)] Процесс завершён"
                    + (exitCode == 0 ? ".\r\n" : " с кодом \(exitCode).\r\n")
            )
        }
        let handler = completion
        completion = nil
        handler?(exitCode)
    }
}
