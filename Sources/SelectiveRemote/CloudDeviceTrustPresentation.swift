import Foundation

enum CloudDeviceTrustPresentation {
    static func failure(_ error: Error, english: Bool) -> String {
        func text(_ ru: String, _ en: String) -> String { english ? en : ru }
        if let error = error as? SelectiveRemoteCloudError {
            switch error {
            case .serviceError(_, "device_trust_unsupported"):
                return text("Подтверждение устройств недоступно в этой версии Cloud. Попросите администратора обновить Cloud, затем повторите проверку.",
                    "This Cloud version does not support device approval. Ask the administrator to update Cloud, then retry.")
            case .authenticationRequired:
                return text("Войдите в Cloud снова, чтобы проверить устройства.", "Sign in to Cloud again to check your devices.")
            case .serviceError(_, "invalid_credentials"):
                return text("Пароль аккаунта не подходит. Проверьте его и повторите подтверждение.", "The account password is incorrect. Check it and try approval again.")
            default: break
            }
        }
        if let error = error as? SelectiveRemoteDeviceTrustError {
            switch error {
            case .untrustedRoot, .invalidSignature, .staleDirectory:
                return text("Подтверждение доверия не совпадает с сохранённым или устарело. Не продолжайте: проверьте отпечатки на доверенном устройстве.",
                    "The trust confirmation differs from the saved one or is out of date. Stop and check fingerprints on a trusted device.")
            case .inactiveDevice:
                return text("Это устройство больше не подтверждено. Используйте другое доверенное устройство для восстановления доступа.",
                    "This device is no longer approved. Use another trusted device to recover access.")
            case .invalidRecord: break
            }
        }
        return text("Не удалось проверить или подтвердить устройство. Проверьте подключение и данные на обоих устройствах, затем повторите проверку.",
            "Could not check or approve the device. Check your connection and the details on both devices, then retry.")
    }

    static func requestStatus(_ status: String, english: Bool) -> String {
        switch status {
        case "pending": english ? "Awaiting approval" : "Ожидает подтверждения"
        case "challenged": english ? "Device check started" : "Проверка устройства начата"
        case "answered": english ? "Ready for approval" : "Готово к подтверждению"
        case "approved": english ? "Approved" : "Подтверждено"
        case "rejected": english ? "Rejected" : "Отклонено"
        case "expired": english ? "Request expired" : "Срок заявки истёк"
        default: english ? "Refresh the request list" : "Обновите список заявок"
        }
    }
}
