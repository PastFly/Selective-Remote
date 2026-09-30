import AppKit

@MainActor
enum AccessRegistrationPrerequisite {
    static func show(kind: CloudAccessKind) {
        let alert = NSAlert()
        alert.messageText = CloudAccessLocalization.text(
            "Для этого объекта нужен ресурс реестра V2",
            "This item needs a V2 registry resource"
        )
        alert.informativeText = CloudAccessLocalization.text(
            "Объект \(kind.rawValue) хранится в Legacy Team Vault. Локальный ID и путь не являются подтверждённым ID ресурса доступа. Откройте Доступ у Team Vault, чтобы выбрать зарегистрированный сервером ресурс. Связь с этим объектом требует отдельной миграции и публикации ключей.",
            "This \(kind.rawValue) item is stored in a legacy Team Vault. Its local ID or path is not a verified access resource ID. Open Access on the Team Vault to select a server registered resource. Linking it to this item requires separate migration and key publication."
        )
        alert.addButton(withTitle: CloudAccessLocalization.text("Понятно", "OK"))
        alert.runModal()
    }
}
