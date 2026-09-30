import AppKit

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
