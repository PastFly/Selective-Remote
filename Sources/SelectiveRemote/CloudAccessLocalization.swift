import Foundation

enum CloudAccessLocalization {
    static func text(_ ru: String, _ en: String) -> String { UpdateLocalization.text(ru: ru, en: en) }
    static var share: String { text("Поделиться", "Share") }
    static var who: String { text("Кто имеет доступ", "Who has access") }
    static var effective: String { text("Доступ на устройстве", "Device access") }
    static func error(_ error: CloudAccessError) -> String {
        switch error {
        case .invalidRequest: text("Проверьте получателей и разрешения.", "Check recipients and permissions.")
        case .invalidResponse, .scopeMismatch: text("Ответ Cloud не соответствует выбранной команде или ресурсу.", "The Cloud response does not match the selected Team or resource.")
        case .previewRequired: text("Изменения требуют нового предварительного просмотра.", "Changes require a fresh preview.")
        case .service(_, let code):
            switch code {
            case "crypto_publication_required": text("Изменение доступа для этого Vault пока недоступно. Обратитесь к владельцу команды.", "Access changes for this Vault are currently unavailable. Contact the team Owner.")
            case "access_v2_preparing_required": text("Сейчас доступ предоставляется ко всему Vault. Чтобы делиться отдельными объектами, попросите владельца команды подготовить Vault.", "Access currently covers the whole Vault. Ask the team Owner to prepare this Vault for sharing individual items.")
            case "access_preview_conflict", "access_policy_conflict": text("Разрешения изменились или просмотр истёк. Просмотрите изменение ещё раз.", "Permissions changed or the preview expired. Preview the change again.")
            case "access_resource_not_found": text("Ресурс отсутствует или недоступен в этом Vault.", "The resource is missing or unavailable in this Vault.")
            case "team_permission_denied", "team_access_denied": text("Для управления доступом нужна роль Owner или Admin.", "Owner or Admin is required to manage access.")
            case "access_batch_too_large": text("Изменение превышает допустимый размер. Оно не было применено частично.", "The change exceeds the limit. No partial change was applied.")
            case "group_grants_must_be_revoked_first": text("Сначала отзовите все разрешения этой группы. Затем повторите удаление группы.", "Revoke all access granted to this group, then delete the group again.")
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
    static func devicePermissionRows(_ device: CloudAccessDeviceUsability, kind: CloudAccessKind) -> [(permission: String, usability: CloudAccessUsability)] {
        kind.permissions.compactMap { permission in
            guard let status = device.effectiveUsableByPermission[permission.name] else { return nil }
            return (permission.name, CloudAccessUsability(rawValue: status) ?? .unknown)
        }
    }
    static func deviceGuidance(_ code: String, english: Bool = UpdateLocalization.usesEnglish) -> String {
        let pair: (String, String)
        switch code {
        case "POLICY_DENIED": pair = ("У участника нет нужных разрешений. Проверьте, кто имеет доступ.", "The member lacks the required permissions. Check who has access.")
        case "DEVICE_NOT_ADMITTED": pair = ("Устройство ещё не разрешено для команды. Обратитесь к владельцу или администратору команды.", "This device is not approved for the team. Contact the team Owner or Admin.")
        case "KEY_UNAVAILABLE": pair = ("Это устройство пока не может открыть ресурс. Попросите владельца команды проверить доступ.", "This device cannot open the resource yet. Ask the team Owner to check access.")
        case "NO_DEVICE_CONTENT_PERMISSION": pair = ("Для открытия содержимого на этом устройстве не хватает разрешений. Проверьте доступ участника.", "Content cannot be opened on this device with the current permissions. Check the member's access.")
        default: pair = ("Причина недоступности не подтверждена. Обновите данные и проверьте выбранное устройство.", "The reason is unverified. Refresh and check the selected device.")
        }
        return english ? pair.1 : pair.0
    }
    static func state(_ state: CloudAccessFormatState) -> String {
        switch state {
        case .v1Active: text("Общий доступ к Vault", "Whole-Vault access")
        case .preparing: text("Доступ к отдельным ресурсам", "Individual resource access")
        case .ready, .active: text("Настройки доступа доступны только для просмотра", "Access settings are read-only")
        }
    }
    static func pathSource(_ path: CloudAccessPath) -> String {
        if path.sourceType == .direct { return text("Прямой доступ к этому ресурсу", "Granted on this resource") }
        return switch path.grantTargetKind {
        case .folder: text("Наследуется от родительской папки", "Inherited from a parent folder")
        case .vault: text("Наследуется от Vault", "Inherited from the Vault")
        case .resource: text("Наследуемый доступ", "Inherited access")
        }
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
        case "HOST": pair = ("Хост", "Host")
        case "CREDENTIAL": pair = ("Учётные данные", "Credential")
        case "SNIPPET": pair = ("Фрагмент", "Snippet")
        case "FORWARDING": pair = ("Переадресация", "Forwarding")
        case "FOLDER": pair = ("Папка", "Folder")
        case "VAULT": pair = ("Vault", "Vault")
        default: pair = ("Тип неизвестен", "Kind unknown")
        }
        return english ? pair.1 : pair.0
    }
}
