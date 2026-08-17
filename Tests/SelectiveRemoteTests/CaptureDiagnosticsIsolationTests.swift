import Foundation
import Testing

@Test("TCC callbacks не наследуют MainActor CaptureDiagnosticsModel")
func capturePermissionCallbacksUseSendableBridge() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/CaptureDiagnostics.swift"), encoding: .utf8)
    #expect(source.contains("private enum CapturePermissionBridge"))
    #expect(source.contains("completion: @escaping @Sendable (Bool) -> Void"))
    #expect(source.contains("CapturePermissionBridge.request(for: .video)"))
    #expect(source.contains("CapturePermissionBridge.request(for: .audio)"))
    #expect(!source.contains("AVCaptureDevice.requestAccess(for: .video) { [weak self]"))
    #expect(!source.contains("AVCaptureDevice.requestAccess(for: .audio) { [weak self]"))
}
