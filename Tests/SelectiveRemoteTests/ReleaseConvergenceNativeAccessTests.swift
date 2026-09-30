import AppKit
import Foundation
import SwiftUI
import Testing
import Vision
@testable import SelectiveRemote

@Suite(.serialized)
struct ReleaseConvergenceNativeAccessTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SR_CAPTURE_ACCESS_MATRIX"] != nil))
    @MainActor func lifecycleCodesStayOutOfNativePresentation() async throws {
        let languageKey = "SelectiveRemote.applicationLanguage.v1"
        let priorLanguage = UserDefaults.standard.object(forKey: languageKey)
        defer {
            if let priorLanguage { UserDefaults.standard.set(priorLanguage, forKey: languageKey) }
            else { UserDefaults.standard.removeObject(forKey: languageKey) }
        }
        for language in ["english", "russian"] {
            UserDefaults.standard.set(language, forKey: languageKey)
            for state in [CloudAccessFormatState.v1Active, .preparing, .ready, .active] {
                let context = CloudAccessContext(formatState: state, legacyWholeVault: state == .v1Active,
                    resource_registry_v2: state != .v1Active, resource_acl_v2: state == .active,
                    policyMutationAvailable: true, groupMutationAvailable: false,
                    blockers: state == .v1Active ? ["access_v2_preparing_required"] : ["crypto_publication_required"])
                let text = try await nativeAccessRenderedText(CloudAccessStateView(context: context),
                    name: "state-\(state.rawValue.lowercased())-\(language)")
                #expect(!text.contains(state.rawValue))
                #expect(!text.contains("V2"))
                #expect(!text.contains("encrypted generation"))
                #expect(!text.contains("зашифрованного поколения"))
                #expect(context.canMutate == (state == .preparing))
            }
            let direct = CloudAccessPath(id: UUID(), principalKind: .user, principalID: UUID(),
                grantTargetKind: .resource, grantTargetID: UUID(), sourceType: .direct,
                mask: 1, effectiveMask: 1, permissions: ["View"], permission: "View")
            let inherited = CloudAccessPath(id: UUID(), principalKind: .group, principalID: UUID(),
                grantTargetKind: .folder, grantTargetID: UUID(), sourceType: .inherited,
                mask: 1, effectiveMask: 1, permissions: ["View"], permission: "View")
            _ = try await nativeAccessRenderedText(CloudAccessPolicyView(policy: .init(
                policyAllowed: true, policyMask: 1, paths: [direct, inherited], blockedReasons: [])),
                name: "direct-inherited-\(language)")
        }
    }

    @Test @MainActor func permissionRowsUseDeviceUsabilityEvenWithoutCryptoMetadata() async throws {
        let languageKey = "SelectiveRemote.applicationLanguage.v1"
        let priorLanguage = UserDefaults.standard.object(forKey: languageKey)
        UserDefaults.standard.set("english", forKey: languageKey)
        defer {
            if let priorLanguage { UserDefaults.standard.set(priorLanguage, forKey: languageKey) }
            else { UserDefaults.standard.removeObject(forKey: languageKey) }
        }
        let reference = try SelectiveRemoteCloudAccessReference(teamID: UUID(), vaultID: UUID(), resourceID: UUID(), kind: .credential)
        let subject = UUID(), device = UUID()
        let session = CloudAccessSession(endpoint: URL(string: "https://native-access.example.test")!)
        let base = "/v1/teams/\(reference.teamID.canonicalCloudString)/vaults/\(reference.vaultID.canonicalCloudString)"
        let emptyPage: [String: Any] = ["rows": [], "nextCursor": NSNull()]
        let replies: [String: [String: Any]] = [
            base + "/access-context": ["formatState": "V2_PREPARING", "legacyWholeVault": false, "resource_registry_v2": true, "resource_acl_v2": false, "policyMutationAvailable": true, "groupMutationAvailable": false, "blockers": []],
            base + "/access-resources/" + reference.resourceID.canonicalCloudString: ["id": reference.resourceID.canonicalCloudString, "teamID": reference.teamID.canonicalCloudString, "vaultID": reference.vaultID.canonicalCloudString, "policyKind": "CREDENTIAL", "parentFolderID": NSNull(), "resourceVersion": 1],
            base + "/access-grants": emptyPage,
            base + "/who-has-access/" + reference.resourceID.canonicalCloudString: emptyPage,
            "/v1/teams/" + reference.teamID.canonicalCloudString + "/members": ["members": [], "nextCursor": NSNull(), "total": 0],
            base + "/access-devices": ["rows": [["id": device.canonicalCloudString, "name": "Native test Mac", "platform": "mac", "admitted": true]], "nextCursor": NSNull()],
            base + "/effective-access/" + reference.resourceID.canonicalCloudString: [
                "policyEffective": ["policyAllowed": true, "policyMask": 7, "paths": [], "blockedReasons": []],
                "deviceUsability": ["deviceID": device.canonicalCloudString, "effectiveUsable": "UNKNOWN", "cryptoAvailable": "WRAP_PRESENT_UNVERIFIED", "cryptoAvailableByPermission": [:], "effectiveUsableByPermission": ["ViewMetadata": "YES", "Reveal": "NO", "Edit": "UNKNOWN"], "blockedReasons": []]
            ]
        ]
        let transport = NativeAccessReplies(try replies.mapValues { try JSONSerialization.data(withJSONObject: $0) })
        let tokens = SelectiveRemoteCloudMemoryTokenStore()
        tokens.saveToken(String(repeating: "t", count: 43), for: session.endpoint)
        let client = SelectiveRemoteCloudAccessClient(client: .init(tokenStore: tokens, dataLoader: { try await transport.load($0) }))
        let model = SelectiveRemoteCloudAccessCoordinator(reference: reference, client: client, session: session)
        await model.load()
        await model.selectSubject(subject)
        await model.selectDevice(device)
        #expect(model.errorMessage == nil)
        #expect(model.effective?.deviceUsability?.effectiveUsable == .unknown)

        let usability = try #require(model.effective?.deviceUsability)
        let rows = CloudAccessLocalization.devicePermissionRows(usability, kind: .credential)
        #expect(rows.map(\.permission) == ["ViewMetadata", "Reveal", "Edit"])
        #expect(rows.map(\.usability) == [.yes, .no, .unknown])
        guard ProcessInfo.processInfo.environment["SR_CAPTURE_ACCESS_MATRIX"] != nil else { return }

        let text = try await nativeAccessRenderedText(
            SelectiveRemoteCloudResourceAccessView(coordinator: model, initialSection: .effective),
            name: "device-usability-en"
        )
        #expect(text.contains("View metadata: Available"))
        #expect(text.contains("Reveal: Unavailable"))
        #expect(text.contains("Edit: Unverified"))
        #expect(!text.contains("Key:"))
        #expect(!text.lowercased().contains("wrapper"))
        #expect(!text.contains("V2_PREPARING"))
    }
}

private actor NativeAccessReplies {
    let replies: [String: Data]
    init(_ replies: [String: Data]) { self.replies = replies }
    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let data = try #require(replies[url.path])
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@MainActor
private func nativeAccessRenderedText<V: View>(_ view: V, name: String) async throws -> String {
    let host = NSHostingView(rootView: view.frame(width: 640, height: 680))
    host.frame = CGRect(x: 0, y: 0, width: 640, height: 680)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(100))
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    let image = try #require(CGWindowListCreateImage(.null, .optionIncludingWindow,
        CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
    let capture = try #require(ProcessInfo.processInfo.environment["SR_CAPTURE_ACCESS_MATRIX"])
    let output = URL(fileURLWithPath: capture, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: output.appending(path: name + ".png"))
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: image).perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    try text.write(to: output.appending(path: name + "-ocr.txt"), atomically: true, encoding: .utf8)
    return text
}
