export function deviceTrustFailureCopy(error, locale = "ru") {
  const text = (ru, en) => locale.startsWith("en") ? en : ru;
  switch (error?.message) {
    case "device_trust_unsupported":
      return text("Подтверждение устройств недоступно в этой версии Cloud. Попросите администратора обновить Cloud, затем обновите страницу.",
        "This Cloud version does not support device approval. Ask the administrator to update Cloud, then refresh this page.");
    case "authentication_required":
      return text("Войдите в аккаунт снова, чтобы проверить устройства.", "Sign in again to check your devices.");
    case "invalid_credentials":
      return text("Пароль аккаунта не подходит. Проверьте его и повторите подтверждение.", "The account password is incorrect. Check it and try approval again.");
    case "device_trust_recovery_required":
      return text("На этом устройстве нет сохранённого подтверждения доверия. Используйте другое доверенное устройство для восстановления.",
        "This device has no saved trust confirmation. Use another trusted device to recover access.");
    case "device_trust_root_conflict":
    case "device_trust_key_substitution":
      return text("Подтверждение устройства не совпадает с сохранённым. Не продолжайте: сравните отпечатки на доверенном устройстве.",
        "Device approval does not match the saved confirmation. Stop and compare fingerprints on a trusted device.");
    default:
      return text("Не удалось проверить или подтвердить устройство. Проверьте подключение и данные на обоих устройствах, затем обновите страницу.",
        "Could not check or approve the device. Check your connection and the details on both devices, then refresh this page.");
  }
}

export function deviceTrustRequestStatus(status, locale = "ru") {
  const labels = {
    pending: ["Ожидает подтверждения", "Awaiting approval"],
    challenged: ["Проверка устройства начата", "Device check started"],
    answered: ["Готово к подтверждению", "Ready for approval"],
    approved: ["Подтверждено", "Approved"],
    rejected: ["Отклонено", "Rejected"],
    expired: ["Срок заявки истёк", "Request expired"],
  };
  const pair = labels[status] ?? ["Обновите список заявок", "Refresh the request list"];
  return pair[locale.startsWith("en") ? 1 : 0];
}
