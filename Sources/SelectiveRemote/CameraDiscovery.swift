import AVFoundation
import Foundation

enum CameraDeviceKind: Int, Equatable, Hashable {
    case builtIn
    case external
    case continuity

    var title: String {
        switch self {
        case .builtIn: "Встроенная"
        case .external: "Внешняя"
        case .continuity: "Камера iPhone"
        }
    }

    var systemImage: String {
        switch self {
        case .builtIn: "laptopcomputer"
        case .external: "video"
        case .continuity: "iphone"
        }
    }
}

struct CameraDeviceDescriptor: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let kind: CameraDeviceKind

    var displayName: String { "\(name) · \(kind.title)" }
}

struct CameraPreviewDeviceResolution {
    let device: AVCaptureDevice
    let usedFallback: Bool
}

enum CameraSelectionToken {
    static let builtIn = "selection:built-in"
    static let automatic = "selection:automatic"
    private static let devicePrefix = "device:"

    static func device(_ id: String) -> String { devicePrefix + id }

    static func deviceID(from token: String) -> String? {
        guard token.hasPrefix(devicePrefix) else { return nil }
        let value = String(token.dropFirst(devicePrefix.count))
        return value.isEmpty ? nil : value
    }
}

enum CameraDiscovery {
    static func currentDevices() -> [CameraDeviceDescriptor] {
        let devices = discoveredVideoDevices()
        var seen: Set<String> = []
        return devices
            .compactMap { device -> CameraDeviceDescriptor? in
                let id = identifier(for: device.uniqueID)
                guard seen.insert(id).inserted else { return nil }
                return CameraDeviceDescriptor(
                    id: id,
                    name: device.localizedName,
                    kind: kind(for: device)
                )
            }
            .sorted {
                if $0.kind.rawValue != $1.kind.rawValue {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return $0.id < $1.id
            }
    }

    static func previewDevice(
        selectionMode: CameraSelectionMode,
        requestedID: String?
    ) -> CameraPreviewDeviceResolution? {
        let devices = discoveredVideoDevices()
        let builtIn = devices.first { kind(for: $0) == .builtIn }
        let systemDefault = AVCaptureDevice.default(for: .video) ?? devices.first

        switch selectionMode {
        case .automatic:
            guard let systemDefault else { return nil }
            return CameraPreviewDeviceResolution(
                device: systemDefault,
                usedFallback: false
            )
        case .builtIn:
            if let builtIn {
                return CameraPreviewDeviceResolution(
                    device: builtIn,
                    usedFallback: false
                )
            }
            guard let systemDefault else { return nil }
            return CameraPreviewDeviceResolution(
                device: systemDefault,
                usedFallback: true
            )
        case .specific:
            if let requestedID,
               let exact = devices.first(where: {
                   identifier(for: $0.uniqueID) == requestedID
               }) {
                return CameraPreviewDeviceResolution(
                    device: exact,
                    usedFallback: false
                )
            }
            guard let fallback = builtIn ?? systemDefault else { return nil }
            return CameraPreviewDeviceResolution(
                device: fallback,
                usedFallback: true
            )
        }
    }

    private static func discoveredVideoDevices() -> [AVCaptureDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .external,
                .continuityCamera
            ],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices
    }

    /// Must stay byte-for-byte compatible with cameraIdentifier() in the
    /// Objective-C++ RDPECAM backend. Raw AVFoundation unique IDs never leave
    /// the local process or appear in exported profiles and diagnostics.
    static func identifier(for uniqueID: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in uniqueID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "mac-%016llx", hash)
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        guard value.count == 20, value.hasPrefix("mac-") else { return false }
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return value.dropFirst(4).unicodeScalars.allSatisfy {
            hexadecimal.contains($0)
        }
    }

    private static func kind(for device: AVCaptureDevice) -> CameraDeviceKind {
        switch device.deviceType {
        case .builtInWideAngleCamera:
            .builtIn
        case .continuityCamera:
            .continuity
        default:
            .external
        }
    }
}
