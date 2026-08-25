import AppKit
import SwiftUI

enum CredentialDisclosurePolicy {
    static let visibleNanoseconds: UInt64 = 30_000_000_000
    static let clipboardNanoseconds: UInt64 = 30_000_000_000
}

struct CredentialDisclosureField: View {
    @Binding var draftValue: String

    let hasSavedValue: Bool
    let placeholder: String
    let savedPlaceholder: String
    let identity: String
    let reveal: @MainActor () async -> String?

    @State private var showsDraft = false
    @State private var revealedValue: String?
    @State private var isAuthorizing = false
    @State private var copied = false
    @State private var revealTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let revealedValue {
                    Text(revealedValue)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .privacySensitive()
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                        .padding(.horizontal, 7)
                        .background(
                            Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.18))
                        }
                        .accessibilityLabel(
                            UpdateLocalization.text(
                                ru: "Сохранённый пароль показан",
                                en: "Saved password revealed"
                            )
                        )
                } else if showsDraft {
                    TextField(
                        hasSavedValue ? savedPlaceholder : placeholder,
                        text: $draftValue
                    )
                    .textFieldStyle(.roundedBorder)
                } else {
                    SecureField(
                        hasSavedValue ? savedPlaceholder : placeholder,
                        text: $draftValue
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }

            if !draftValue.isEmpty {
                Button {
                    showsDraft.toggle()
                } label: {
                    Image(systemName: showsDraft ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(
                    showsDraft
                        ? UpdateLocalization.text(ru: "Скрыть введённый пароль", en: "Hide entered password")
                        : UpdateLocalization.text(ru: "Показать введённый пароль", en: "Reveal entered password")
                )
            } else if hasSavedValue {
                Button {
                    toggleSavedCredential()
                } label: {
                    if isAuthorizing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: revealedValue == nil ? "eye" : "eye.slash")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isAuthorizing)
                .help(
                    revealedValue == nil
                        ? UpdateLocalization.text(
                            ru: "Показать после системной аутентификации",
                            en: "Reveal after system authentication"
                        )
                        : UpdateLocalization.text(ru: "Скрыть пароль", en: "Hide password")
                )
            }

            if let revealedValue {
                Button {
                    copyToClipboard(revealedValue)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(
                    UpdateLocalization.text(
                        ru: "Копировать; буфер будет очищен через 30 секунд",
                        en: "Copy; the clipboard will be cleared after 30 seconds"
                    )
                )
            }
        }
        .onChange(of: identity) { _, _ in conceal() }
        .onChange(of: draftValue) { _, newValue in
            if !newValue.isEmpty { conceal() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didResignActiveNotification
            )
        ) { _ in
            conceal()
        }
        .onDisappear {
            revealTask?.cancel()
            conceal()
        }
    }

    private func toggleSavedCredential() {
        if revealedValue != nil {
            conceal()
            return
        }
        revealTask?.cancel()
        isAuthorizing = true
        revealTask = Task { @MainActor in
            let secret = await reveal()
            guard !Task.isCancelled else { return }
            isAuthorizing = false
            guard let secret, !secret.isEmpty else { return }
            revealedValue = secret
            scheduleConceal()
        }
    }

    private func scheduleConceal() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: CredentialDisclosurePolicy.visibleNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            conceal()
        }
    }

    private func conceal() {
        hideTask?.cancel()
        hideTask = nil
        revealedValue = nil
        isAuthorizing = false
        copied = false
    }

    private func copyToClipboard(_ secret: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(secret, forType: .string) else { return }
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: CredentialDisclosurePolicy.clipboardNanoseconds)
            if NSPasteboard.general.string(forType: .string) == secret {
                NSPasteboard.general.clearContents()
            }
            copied = false
        }
    }
}
