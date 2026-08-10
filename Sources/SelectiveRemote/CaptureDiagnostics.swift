@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreMedia
import Dispatch
import Foundation
import QuartzCore
import SwiftUI

enum CapturePermissionKind: Sendable {
    case camera
    case microphone

    var title: String {
        switch self {
        case .camera: "Камера"
        case .microphone: "Микрофон"
        }
    }

    var settingsAnchor: String {
        switch self {
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        }
    }

    var usageDescriptionKey: String {
        switch self {
        case .camera: "NSCameraUsageDescription"
        case .microphone: "NSMicrophoneUsageDescription"
        }
    }
}

enum CapturePermissionState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unknown

    init(status: AVAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .notDetermined: "Ещё не запрашивалось"
        case .authorized: "Разрешено"
        case .denied: "Запрещено"
        case .restricted: "Ограничено системой"
        case .unknown: "Неизвестно"
        }
    }

    var systemImage: String {
        switch self {
        case .notDetermined: "questionmark.circle.fill"
        case .authorized: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .restricted: "lock.circle.fill"
        case .unknown: "exclamationmark.circle.fill"
        }
    }
}

enum CameraPreviewState: Equatable, Sendable {
    case idle
    case requestingPermission
    case starting
    case running

    var isBusy: Bool {
        self == .requestingPermission || self == .starting
    }
}

struct CameraPreviewInfo: Equatable, Sendable {
    let cameraName: String
    let formatDescription: String
    let usedFallback: Bool
}

enum CameraPreviewFailure: LocalizedError, Sendable {
    case missingUsageDescription
    case permissionDenied
    case noCamera
    case inputCreation(String)
    case inputRejected
    case startFailed

    var errorDescription: String? {
        switch self {
        case .missingUsageDescription:
            "В этой копии приложения отсутствует описание доступа к камере. Соберите полный пакет через scripts/build_app.sh."
        case .permissionDenied:
            "macOS не разрешила доступ к камере. Включите его в системных настройках."
        case .noCamera:
            "Подходящая камера не обнаружена. Подключите устройство и обновите список."
        case let .inputCreation(message):
            "Не удалось открыть камеру: \(message)"
        case .inputRejected:
            "AVFoundation не смогла добавить выбранную камеру в сеанс предпросмотра."
        case .startFailed:
            "AVFoundation настроила камеру, но не смогла запустить предпросмотр."
        }
    }
}

extension CameraQualityPreset {
    var previewSessionPreset: AVCaptureSession.Preset {
        switch self {
        case .economy: .vga640x480
        case .balanced: .hd1280x720
        case .high, .automatic: .hd1920x1080
        }
    }
}

private final class CameraPreviewService: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(
        label: "local.selectiveremote.camera-preview",
        qos: .userInitiated
    )

    func start(
        selectionMode: CameraSelectionMode,
        requestedID: String?,
        quality: CameraQualityPreset,
        completion: @escaping @Sendable (
            Result<CameraPreviewInfo, CameraPreviewFailure>
        ) -> Void
    ) {
        queue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }

            guard let resolution = CameraDiscovery.previewDevice(
                selectionMode: selectionMode,
                requestedID: requestedID
            ) else {
                completion(.failure(.noCamera))
                return
            }

            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: resolution.device)
            } catch {
                completion(.failure(.inputCreation(error.localizedDescription)))
                return
            }

            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                completion(.failure(.inputRejected))
                return
            }
            session.addInput(input)

            let requestedPreset = quality.previewSessionPreset
            if session.canSetSessionPreset(requestedPreset) {
                session.sessionPreset = requestedPreset
            } else if session.canSetSessionPreset(.high) {
                session.sessionPreset = .high
            }
            session.commitConfiguration()
            session.startRunning()
            guard session.isRunning else {
                completion(.failure(.startFailed))
                return
            }

            let dimensions = CMVideoFormatDescriptionGetDimensions(
                resolution.device.activeFormat.formatDescription
            )
            let format = dimensions.width > 0 && dimensions.height > 0
                ? "\(dimensions.width) × \(dimensions.height)"
                : "формат определён камерой"
            completion(.success(CameraPreviewInfo(
                cameraName: resolution.device.localizedName,
                formatDescription: format,
                usedFallback: resolution.usedFallback
            )))
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}

@MainActor
final class CaptureDiagnosticsModel: ObservableObject {
    @Published private(set) var cameraPermission: CapturePermissionState
    @Published private(set) var microphonePermission: CapturePermissionState
    @Published private(set) var microphoneName: String
    @Published private(set) var microphoneRequestInFlight = false
    @Published private(set) var previewState: CameraPreviewState = .idle
    @Published private(set) var previewInfo: CameraPreviewInfo?
    @Published var errorMessage: String?

    private let previewService = CameraPreviewService()
    var previewSession: AVCaptureSession { previewService.session }

    init() {
        cameraPermission = CapturePermissionState(
            status: AVCaptureDevice.authorizationStatus(for: .video)
        )
        microphonePermission = CapturePermissionState(
            status: AVCaptureDevice.authorizationStatus(for: .audio)
        )
        microphoneName = Self.currentMicrophoneName()
    }

    func refresh() {
        cameraPermission = CapturePermissionState(
            status: AVCaptureDevice.authorizationStatus(for: .video)
        )
        microphonePermission = CapturePermissionState(
            status: AVCaptureDevice.authorizationStatus(for: .audio)
        )
        microphoneName = Self.currentMicrophoneName()
    }

    func startPreview(
        selectionMode: CameraSelectionMode,
        requestedID: String?,
        quality: CameraQualityPreset
    ) {
        errorMessage = nil
        previewInfo = nil
        refresh()
        guard Self.hasUsageDescription(for: .camera) else {
            previewState = .idle
            errorMessage = CameraPreviewFailure
                .missingUsageDescription
                .localizedDescription
            return
        }

        switch cameraPermission {
        case .authorized:
            configurePreview(
                selectionMode: selectionMode,
                requestedID: requestedID,
                quality: quality
            )
        case .notDetermined:
            previewState = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refresh()
                    guard granted else {
                        self.previewState = .idle
                        self.errorMessage = CameraPreviewFailure
                            .permissionDenied
                            .localizedDescription
                        return
                    }
                    self.configurePreview(
                        selectionMode: selectionMode,
                        requestedID: requestedID,
                        quality: quality
                    )
                }
            }
        case .denied, .restricted, .unknown:
            previewState = .idle
            errorMessage = CameraPreviewFailure.permissionDenied.localizedDescription
        }
    }

    func stopPreview() {
        previewService.stop()
        previewState = .idle
        previewInfo = nil
    }

    func requestMicrophoneAccess() {
        errorMessage = nil
        microphoneRequestInFlight = false
        refresh()
        guard Self.hasUsageDescription(for: .microphone) else {
            errorMessage = "В этой копии приложения отсутствует описание доступа к микрофону. Соберите полный пакет через scripts/build_app.sh."
            return
        }
        switch microphonePermission {
        case .authorized:
            return
        case .notDetermined:
            microphoneRequestInFlight = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.microphoneRequestInFlight = false
                    self.refresh()
                    if !granted {
                        self.errorMessage = "macOS не разрешила доступ к микрофону."
                    }
                }
            }
        case .denied, .restricted, .unknown:
            errorMessage = "Доступ к микрофону выключен в системных настройках."
        }
    }

    func openPrivacySettings(_ kind: CapturePermissionKind) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func configurePreview(
        selectionMode: CameraSelectionMode,
        requestedID: String?,
        quality: CameraQualityPreset
    ) {
        previewState = .starting
        previewService.start(
            selectionMode: selectionMode,
            requestedID: requestedID,
            quality: quality
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case let .success(info):
                    self.previewInfo = info
                    self.previewState = .running
                case let .failure(error):
                    self.previewState = .idle
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private static func hasUsageDescription(
        for kind: CapturePermissionKind
    ) -> Bool {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: kind.usageDescriptionKey
        ) as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func currentMicrophoneName() -> String {
        guard hasUsageDescription(for: .microphone) else {
            return "Доступно только в полном приложении"
        }
        return AVCaptureDevice.default(for: .audio)?.localizedName
            ?? "Системный микрофон не обнаружен"
    }
}

struct CaptureDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var diagnostics = CaptureDiagnosticsModel()

    let cameraSelectionMode: CameraSelectionMode
    let selectedCameraID: String?
    let cameraSelectionDescription: String
    let cameraQuality: CameraQualityPreset
    let cameraCount: Int
    let redirectsCamera: Bool
    let redirectsMicrophone: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Проверка устройств")
                        .font(.title2.bold())
                    Text("Проверка выполняется локально до запуска RDP.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Обновить", systemImage: "arrow.clockwise") {
                    diagnostics.refresh()
                }
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            HStack(alignment: .top, spacing: 16) {
                cameraPanel
                    .frame(maxWidth: .infinity)
                microphonePanel
                    .frame(width: 285)
            }

            if let error = diagnostics.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.orange.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
            }

            Label(
                "Предпросмотр не передаёт и не записывает изображение. Камера освобождается при остановке или закрытии окна.",
                systemImage: "hand.raised.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 830, minHeight: 590)
        .onAppear { diagnostics.refresh() }
        .onDisappear { diagnostics.stopPreview() }
    }

    private var cameraPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                PermissionStatusView(
                    kind: .camera,
                    state: diagnostics.cameraPermission
                )

                ZStack {
                    CameraPreviewSurface(session: diagnostics.previewSession)
                    if diagnostics.previewState != .running {
                        VStack(spacing: 10) {
                            Image(systemName: previewPlaceholderImage)
                                .font(.system(size: 42))
                            Text(previewPlaceholderText)
                                .font(.callout.weight(.medium))
                        }
                        .foregroundStyle(.white.opacity(0.76))
                    }
                }
                .frame(height: 310)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Label(cameraSelectionDescription, systemImage: "video.fill")
                    Text("Камер обнаружено: \(cameraCount) · \(cameraQuality.details)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let info = diagnostics.previewInfo {
                        Text(
                            "Предпросмотр: \(info.cameraName) · \(info.formatDescription)"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        if info.usedFallback {
                            Label(
                                "Сохранённая камера недоступна — показана резервная",
                                systemImage: "arrow.triangle.branch"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                }

                HStack {
                    Button(
                        diagnostics.previewState == .running
                            ? "Остановить"
                            : "Запустить предпросмотр",
                        systemImage: diagnostics.previewState == .running
                            ? "stop.fill"
                            : "play.fill"
                    ) {
                        if diagnostics.previewState == .running {
                            diagnostics.stopPreview()
                        } else {
                            diagnostics.startPreview(
                                selectionMode: cameraSelectionMode,
                                requestedID: selectedCameraID,
                                quality: cameraQuality
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(diagnostics.previewState.isBusy)

                    if diagnostics.cameraPermission == .denied
                        || diagnostics.cameraPermission == .restricted {
                        Button("Настройки macOS", systemImage: "gear") {
                            diagnostics.openPrivacySettings(.camera)
                        }
                    }
                }
            }
            .padding(8)
        } label: {
            Label(
                redirectsCamera ? "Камера будет передаваться" : "Камера отключена в профиле",
                systemImage: redirectsCamera ? "video.fill" : "video.slash"
            )
        }
    }

    private var microphonePanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 13) {
                PermissionStatusView(
                    kind: .microphone,
                    state: diagnostics.microphonePermission
                )

                Label(diagnostics.microphoneName, systemImage: "mic.fill")
                    .font(.callout.weight(.medium))

                Text("FreeRDP использует системный источник звука macOS. Здесь показан активный микрофон на момент проверки.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Label(
                    redirectsMicrophone
                        ? "Передача микрофона включена в профиле"
                        : "Передача микрофона отключена в профиле",
                    systemImage: redirectsMicrophone ? "checkmark.circle" : "minus.circle"
                )
                .font(.caption)

                if diagnostics.microphonePermission == .notDetermined {
                    Button("Запросить доступ", systemImage: "checkmark.shield") {
                        diagnostics.requestMicrophoneAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(diagnostics.microphoneRequestInFlight)
                } else if diagnostics.microphonePermission == .denied
                            || diagnostics.microphonePermission == .restricted {
                    Button("Настройки macOS", systemImage: "gear") {
                        diagnostics.openPrivacySettings(.microphone)
                    }
                }

                Spacer()
            }
            .padding(8)
        } label: {
            Label("Микрофон", systemImage: "mic")
        }
    }

    private var previewPlaceholderImage: String {
        switch diagnostics.previewState {
        case .requestingPermission: "hand.raised.fill"
        case .starting: "hourglass"
        case .idle, .running: "video"
        }
    }

    private var previewPlaceholderText: String {
        switch diagnostics.previewState {
        case .requestingPermission: "Ожидаем разрешение macOS…"
        case .starting: "Запускаем выбранную камеру…"
        case .idle: "Предпросмотр остановлен"
        case .running: ""
        }
    }
}

private struct PermissionStatusView: View {
    let kind: CapturePermissionKind
    let state: CapturePermissionState

    var body: some View {
        HStack {
            Label(kind.title, systemImage: state.systemImage)
                .font(.headline)
                .foregroundStyle(tint)
            Spacer()
            Text(state.title)
                .font(.caption.bold())
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.12), in: Capsule())
        }
    }

    private var tint: Color {
        switch state {
        case .authorized: .green
        case .notDetermined: .blue
        case .denied, .restricted: .red
        case .unknown: .orange
        }
    }
}

private struct CameraPreviewSurface: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }
}

private final class CameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}
