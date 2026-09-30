import Foundation

enum CloudAccessLocalization {
    static func text(_ ru: String, _ en: String) -> String { UpdateLocalization.text(ru: ru, en: en) }
    static var share: String { text("Поделиться", "Share") }
    static var who: String { text("Кто имеет доступ", "Who has access") }
    static var effective: String { text("Эффективный доступ", "Effective access") }
    static func error(_ error: CloudAccessError) -> String {
        switch error {
        case .invalidRequest: text("Проверьте получателей и разрешения.", "Check recipients and permissions.")
        case .invalidResponse, .scopeMismatch: text("Ответ Cloud не соответствует выбранной команде или ресурсу.", "The Cloud response does not match the selected Team or resource.")
        case .previewRequired: text("Изменения требуют нового предварительного просмотра.", "Changes require a fresh preview.")
        case .service(_, let code):
            switch code {
            case "crypto_publication_required": text("Требуется публикация зашифрованного поколения. Изменение политики сейчас недоступно.", "An encrypted generation publication is required. Policy changes are unavailable.")
            case "access_v2_preparing_required": text("Этот Vault использует общий доступ целиком. Доступ к ресурсам требует подготовки V2.", "This Vault uses whole-Vault access. Resource access requires V2 preparation.")
            case "access_preview_conflict", "access_policy_conflict": text("Политика изменилась или просмотр истёк. Повторите просмотр.", "Policy changed or the preview expired. Preview again.")
            case "access_resource_not_found": text("Ресурс отсутствует или недоступен в этом Vault.", "The resource is missing or unavailable in this Vault.")
            case "team_permission_denied", "team_access_denied": text("Для управления доступом нужна роль Owner или Admin.", "Owner or Admin is required to manage access.")
            case "access_batch_too_large": text("Изменение превышает допустимый размер. Оно не было применено частично.", "The change exceeds the limit. No partial change was applied.")
            case "group_grants_must_be_revoked_first": text("Сначала отзовите разрешения группы (1001+).", "Revoke the group's grants first (1001+).")
            default: text("Cloud не выполнил запрос доступа.", "Cloud could not complete the access request.")
            }
        }
    }
    static func permission(_ value: String) -> String {
        switch value {
        case "ViewMetadata": text("Метаданные", "View metadata")
        case "View": text("Просмотр", "View")
        case "Reveal": text("Раскрыть секрет", "Reveal")
        case "Edit": text("Редактирование", "Edit")
        case "Create": text("Создание", "Create")
        case "Manage": text("Управление папкой", "Manage")
        case "ManageAccess": text("Управление доступом", "Manage access")
        default: value
        }
    }
    static func mask(_ mask: Int, kind: CloudAccessKind) -> String { kind.permissions.filter { mask & $0.bit != 0 }.map { permission($0.name) }.joined(separator: ", ") }
    static func deviceStatus(_ code: String, english: Bool = UpdateLocalization.usesEnglish) -> String {
        let pair: (String, String)
        switch code {
        case "YES": pair = ("Доступно", "Available")
        case "NO": pair = ("Недоступно", "Unavailable")
        case "UNKNOWN": pair = ("Не подтверждено", "Unverified")
        case "WRAP_PRESENT_UNVERIFIED": pair = ("Ключ есть, не проверен", "Key present, unverified")
        case "KEY_UNAVAILABLE": pair = ("Ключ недоступен", "Key unavailable")
        default: pair = ("Статус неизвестен", "Status unknown")
        }
        return english ? pair.1 : pair.0
    }
    static func deviceReason(_ code: String, english: Bool = UpdateLocalization.usesEnglish) -> String {
        let pair: (String, String)
        switch code {
        case "POLICY_DENIED": pair = ("Политика не предоставляет доступ", "Policy does not grant access")
        case "DEVICE_NOT_ADMITTED": pair = ("Устройство не допущено", "Device is not admitted")
        case "KEY_UNAVAILABLE": pair = ("Ключ ресурса недоступен", "Resource key is unavailable")
        case "NO_DEVICE_CONTENT_PERMISSION": pair = ("Нет прав на содержимое для устройства", "No device content permission")
        default: pair = ("Причина недоступности неизвестна", "Availability reason unknown")
        }
        return english ? pair.1 : pair.0
    }
    static func revokeGuidance(hasExistingGrants: Bool, english: Bool = UpdateLocalization.usesEnglish) -> String? {
        guard hasExistingGrants else { return nil }
        return english
            ? "Revoking one path may preserve access through other paths. Preview shows the actual permission loss."
            : "Отзыв одного пути может сохранить доступ по другим путям. Предварительный просмотр показывает фактическую потерю разрешений."
    }
    static func kind(_ code: String, english: Bool = UpdateLocalization.usesEnglish) -> String {
        let pair: (String, String)
        switch code {
        case "USER": pair = ("Участник", "Member")
        case "GROUP": pair = ("Группа", "Group")
        case "RESOURCE": pair = ("Ресурс", "Resource")
        case "FOLDER": pair = ("Папка", "Folder")
        case "VAULT": pair = ("Vault", "Vault")
        default: pair = ("Тип неизвестен", "Kind unknown")
        }
        return english ? pair.1 : pair.0
    }
}
