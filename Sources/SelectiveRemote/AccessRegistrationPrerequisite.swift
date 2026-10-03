import AppKit
import SwiftUI

@MainActor
enum AccessRegistrationPrerequisite {
    static func show(kind: CloudAccessKind) {
        let alert = NSAlert()
        alert.messageText = CloudAccessLocalization.text(
            "Отдельный доступ к объекту пока недоступен",
            "Individual access is not available for this item yet"
        )
        alert.informativeText = CloudAccessLocalization.text(
            "\(CloudAccessLocalization.kind(kind.rawValue)) использует общий доступ к Team Vault. Откройте «Доступ» у Team Vault, чтобы проверить настройки Vault и список зарегистрированных ресурсов. Если нужного объекта нет в списке, попросите владельца команды подготовить его для отдельного доступа.",
            "This \(CloudAccessLocalization.kind(kind.rawValue).lowercased()) uses whole-Vault access. Open Access on the Team Vault to check Vault settings and the registered resource list. If the item is missing, ask the team Owner to prepare it for individual access."
        )
        alert.addButton(withTitle: CloudAccessLocalization.text("Понятно", "OK"))
        alert.runModal()
    }
}

@MainActor
enum AccessResourceEntry {
    static func dispatch(reference: SelectiveRemoteCloudAccessReference?, kind: CloudAccessKind,
                         open: (SelectiveRemoteCloudAccessReference) -> Void,
                         prerequisite: (CloudAccessKind) -> Void) {
        guard let reference, reference.kind == kind else {
            prerequisite(kind)
            return
        }
        open(reference)
    }

    static func showLegacy(kind: CloudAccessKind) {
        dispatch(reference: nil, kind: kind, open: { _ in },
                 prerequisite: AccessRegistrationPrerequisite.show)
    }
}

extension AccessResourceEntry {
    static func showPublished(_ published: SelectiveRemotePublishedModelReference?, title: String, kind: CloudAccessKind, section: SelectiveRemoteWholePublicationSection = .access) {
        guard let published else { showLegacy(kind: kind); return }
        guard published.kind == kind, SelectiveRemotePublicationPresentation.shared.valid(published),
              let reference = try? published.access(displayName: title) else { return }
        let view = SelectiveRemoteWholePublicationView(reference: published, access: reference, section: section)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = reference.title; window.contentView = NSHostingView(rootView: view); window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil)
        PublishedAccessWindows.retain(window, reference: published)
    }
}

@MainActor
enum PublishedAccessWindows {
    private static var windows: [(NSWindow, SelectiveRemotePublishedModelReference)] = []
    static func retain(_ window: NSWindow, reference: SelectiveRemotePublishedModelReference) { windows.append((window, reference)) }
    static func closeInvalid() { windows.removeAll { window, reference in
        guard !SelectiveRemotePublicationPresentation.shared.valid(reference) else { return false }; window.close(); return true
    } }
}

extension AccessResourceEntry {
    static func showPublishedFolder(teamID: UUID?, path: String, type: String) {
        let candidates = SelectiveRemotePublicationPresentation.shared.folders(type: type).filter { folder in
            (teamID == nil || folder.reference.scope.teamID == teamID) && Data(folder.path.utf8) == Data(path.utf8) && !folder.reference.stale
        }
        if candidates.isEmpty { showLegacy(kind: .folder); return }
        if candidates.count == 1 { showPublished(candidates[0].reference, title: candidates[0].component, kind: .folder); return }
        // A same-name folder in another Vault is a different resource; require exact scope selection.
        guard candidates.count <= 10 else { return }
        let alert = NSAlert(); alert.messageText = CloudAccessLocalization.text("Выберите Vault папки", "Choose the folder's Vault")
        for folder in candidates { alert.addButton(withTitle: folder.vaultName) }
        alert.addButton(withTitle: CloudAccessLocalization.text("Отмена", "Cancel"))
        let selected = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if candidates.indices.contains(selected) { let folder = candidates[selected]; showPublished(folder.reference, title: folder.component, kind: .folder) }
    }
}
