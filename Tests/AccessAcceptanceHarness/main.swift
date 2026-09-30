import AppKit
import Foundation
import SwiftUI
@testable import SelectiveRemote

private actor SyntheticAccessTransport {
    var replies: [String: [(Data, Int)]]
    var commitCount = 0
    let logURL: URL
    init(_ replies: [String: [(Data, Int)]], mode: String) {
        self.replies = replies
        logURL = URL(fileURLWithPath: "/private/tmp/access-acceptance-\(mode).jsonl")
        try? FileManager.default.removeItem(at: logURL)
    }
    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        let path = request.url!.path
        if path.hasSuffix("/access-commit") { commitCount += 1 }
        if let bytes = try? JSONSerialization.data(withJSONObject: ["path": path, "commits": commitCount]),
           let line = String(data: bytes, encoding: .utf8) {
            if !FileManager.default.fileExists(atPath: logURL.path) { _ = FileManager.default.createFile(atPath: logURL.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data((line + "\n").utf8))
                try? handle.close()
            }
        }
        guard var queue = replies[path], !queue.isEmpty else { throw CloudAccessError.invalidRequest }
        let reply = queue.count == 1 ? queue[0] : queue.removeFirst()
        replies[path] = queue
        return (reply.0, HTTPURLResponse(url: request.url!, statusCode: reply.1, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private struct PresentedAccessSheet: View {
    @State private var showing = true
    let coordinator: SelectiveRemoteCloudAccessCoordinator
    var body: some View {
        Text("LOCAL_VISUAL_PREVIEW")
            .frame(width: 640, height: 680)
            .sheet(isPresented: $showing) {
                SelectiveRemoteCloudResourceAccessView(coordinator: coordinator)
            }
    }
}

@MainActor
private final class AccessAcceptanceApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var transport: SyntheticAccessTransport?
    private let mode = ProcessInfo.processInfo.environment["SR_ACCESS_ACCEPTANCE_MODE"] ??
        (Bundle.main.bundleIdentifier?.hasSuffix(".invalid") == true ? "invalid" : "valid")

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set("english", forKey: "SelectiveRemote.applicationLanguage.v1")
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 640, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "LOCAL_VISUAL_PREVIEW · Access acceptance · \(mode)"
        window.contentView = NSHostingView(rootView: Text("Loading local Access fixture…"))
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task { await showSheet() }
    }

    private func showSheet() async {
        do {
            let reference = try SelectiveRemoteCloudAccessReference(teamID: UUID(), vaultID: UUID(), resourceID: UUID(), kind: .host)
            let endpoint = URL(string: "https://access.example.test")!
            let session = CloudAccessSession(endpoint: endpoint)
            let base = "/v1/teams/\(reference.teamID.canonicalCloudString)/vaults/\(reference.vaultID.canonicalCloudString)"
            func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
            let context: [String: Any] = ["formatState": "V2_PREPARING", "legacyWholeVault": false,
                "resource_registry_v2": true, "resource_acl_v2": false, "policyMutationAvailable": true,
                "groupMutationAvailable": true, "blockers": []]
            let row: [String: Any] = ["id": reference.resourceID.canonicalCloudString,
                "teamID": reference.teamID.canonicalCloudString, "vaultID": reference.vaultID.canonicalCloudString,
                "policyKind": "HOST", "parentFolderID": NSNull(), "resourceVersion": 1]
            let emptyPage: [String: Any] = ["rows": [], "nextCursor": NSNull()]
            let subject = UUID()
            let previewBase: [String: Any] = ["token": "synthetic-preview", "snapshotID": String(repeating: "a", count: 64),
                "details": [], "counts": ["pairs": mode == "invalid" ? 2 : 0, "widened": 0, "lost": 0]]
            var first = previewBase
            first["details"] = mode == "invalid" ? [["vaultID": reference.vaultID.canonicalCloudString,
                "resourceID": reference.resourceID.canonicalCloudString, "subjectUserID": subject.canonicalCloudString,
                "before": ["policyEffective": ["policyAllowed": false, "policyMask": 0, "paths": [], "blockedReasons": ["POLICY_DENIED"]]],
                "after": ["policyEffective": ["policyAllowed": false, "policyMask": 0, "paths": [], "blockedReasons": ["POLICY_DENIED"]]],
                "gainedMask": 0, "lostMask": 0]] : []
            first["nextCursor"] = mode == "invalid" ? "1" : NSNull()
            var terminal = previewBase
            terminal["details"] = []
            terminal["counts"] = ["pairs": 3, "widened": 0, "lost": 0]
            terminal["nextCursor"] = NSNull()
            var replies: [String: [(Data, Int)]] = [
                base + "/access-context": [(try data(context), 200)],
                base + "/access-resources/" + reference.resourceID.canonicalCloudString: [(try data(row), 200)],
                base + "/access-grants": [(try data(emptyPage), 200)],
                base + "/who-has-access/" + reference.resourceID.canonicalCloudString: [(try data(emptyPage), 200)],
                "/v1/teams/" + reference.teamID.canonicalCloudString + "/members":
                    [(try data(["members": [], "nextCursor": NSNull(), "total": 0]), 200)],
                base + "/access-preview": mode == "invalid" ? [(try data(first), 200), (try data(terminal), 200)] : [(try data(first), 200)],
            ]
            if mode == "valid" {
                replies[base + "/access-commit"] = [(try data(["applied": 1,
                    "grants": [["type": "GRANT_CREATE", "grantID": UUID().canonicalCloudString]],
                    "notificationCandidates": [], "counts": ["pairs": 0, "widened": 0, "lost": 0]]), 200)]
            }
            let transport = SyntheticAccessTransport(replies, mode: mode)
            self.transport = transport
            let tokens = SelectiveRemoteCloudMemoryTokenStore()
            tokens.saveToken(String(repeating: "t", count: 43), for: endpoint)
            let client = SelectiveRemoteCloudAccessClient(client: .init(tokenStore: tokens,
                dataLoader: { request in try await transport.load(request) }))
            let coordinator = SelectiveRemoteCloudAccessCoordinator(reference: reference, client: client, session: session)
            await coordinator.load()
            coordinator.setSelection([.init(kind: .user, id: subject, name: "Synthetic member")])
            window?.contentView = NSHostingView(rootView: PresentedAccessSheet(coordinator: coordinator))
        } catch {
            fputs("Access acceptance fixture failed: \(error)\n", stderr)
            NSApplication.shared.terminate(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        Task {
            if let transport { print("LOCAL_ACCESS_ACCEPTANCE mode=\(mode) commits=\(await transport.commitCount)") }
            NSApplication.shared.terminate(nil)
        }
    }

}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = AccessAcceptanceApp()
    application.delegate = delegate
    application.run()
}
