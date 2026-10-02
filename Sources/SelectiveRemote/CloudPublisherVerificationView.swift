import AppKit
import SwiftUI

@MainActor
enum SelectiveRemotePublisherVerificationSheet {
    private static var windows: [String: (window: NSWindow, session: SelectiveRemotePublicationSession)] = [:]
    static func present(challenge: SelectiveRemotePublisherVerification, reader: SelectiveRemoteVaultPublicationCoordinator, session: SelectiveRemotePublicationSession) {
        closeInvalid()
        if let existing = windows[challenge.id], !existing.window.isVisible { windows.removeValue(forKey: challenge.id) }
        guard (try? session.check()) != nil, windows[challenge.id] == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = CloudAccessLocalization.text("Проверить издателя", "Verify publishing identity")
        window.contentView = NSHostingView(rootView: PublisherVerificationForm(challenge: challenge, reader: reader, session: session, close: { [weak window] in window?.close(); windows.removeValue(forKey: challenge.id) }))
        window.isReleasedWhenClosed = false; windows[challenge.id] = (window, session); window.center(); window.makeKeyAndOrderFront(nil)
    }
    static func closeAll() { windows.values.forEach { $0.window.close() }; windows = [:] }
    static func closeInvalid() {
        for (id, item) in windows where (try? item.session.check()) == nil { item.window.close(); windows.removeValue(forKey: id) }
    }
}

private struct PublisherVerificationForm: View {
    let challenge: SelectiveRemotePublisherVerification
    let reader: SelectiveRemoteVaultPublicationCoordinator
    let session: SelectiveRemotePublicationSession
    let close: () -> Void
    @State private var entered = ""
    @State private var failure: String?
    @State private var busy = false
    @FocusState private var fingerprintFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(CloudAccessLocalization.text("Проверить издателя публикации", "Verify publishing identity")).font(.title2)
            Text(challenge.publisherAccountID.canonicalCloudString).font(.caption.monospaced())
            Text(challenge.fingerprint).font(.body.monospaced()).textSelection(.enabled)
            Text(CloudAccessLocalization.text("Получите отпечаток отдельно: сравните его лично или через уже проверенного хранителя. Отпечаток с этой страницы сам по себе не подтверждает доверие. Введите независимо полученный отпечаток.", "Obtain the fingerprint independently: compare it in person or through an already verified custodian. A fingerprint copied from this page alone does not establish trust. Enter the independently obtained fingerprint."))
            TextField(CloudAccessLocalization.text("Независимо полученный отпечаток", "Independently obtained fingerprint"), text: $entered)
                .textFieldStyle(.roundedBorder).focused($fingerprintFocused)
                .accessibilityLabel(CloudAccessLocalization.text("Независимо полученный отпечаток", "Independently obtained fingerprint"))
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Button(CloudAccessLocalization.text("Отмена", "Cancel"), action: close)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(CloudAccessLocalization.text("Проверить и сохранить", "Verify and save")) {
                    busy = true
                    Task { @MainActor in
                        do {
                            try session.check()
                            try await reader.confirmPublisher(challenge, independentlyObtainedFingerprint: entered.trimmingCharacters(in: .whitespacesAndNewlines))
                            try session.check(); close()
                            _ = try? await SelectiveRemoteTeamVaultAutoSync.shared.synchronizeConfiguredAccountNow()
                        } catch { failure = CloudAccessLocalization.text("Отпечаток или текущая сессия не подтверждены.", "The fingerprint or current session could not be verified."); busy = false }
                    }
                }.disabled(busy || entered.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).onAppear { fingerprintFocused = true }
    }
}
