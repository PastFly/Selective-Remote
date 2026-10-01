const copy = {
  title: ["Доступ и общий доступ", "Access & sharing"],
  members: ["Участники", "Members"],
  groups: ["Группы", "Groups"],
  resourceKind: ["Тип ресурсов", "Resource kind"],
  allKinds: ["Все типы", "All kinds"],
  resources: ["Ресурсы", "Resources"],
  vault: ["Хранилище", "Vault"],
  chooseVault: ["Выберите хранилище", "Choose a Vault"],
  chooseTeam: ["Выберите команду", "Choose a Team"],
  search: ["Поиск", "Search"],
  pageSearch: ["Поиск названия на этой странице", "Search labels on this page"],
  more: ["Следующая страница", "Next page"],
  refresh: ["Обновить", "Refresh"],
  loading: ["Загрузка…", "Loading…"],
  empty: ["На этой странице ничего нет", "Nothing on this page"],
  preview: ["Проверить последствия", "Preview consequences"],
  confirm: ["Подтвердить изменение", "Confirm change"],
  cancel: ["Отмена", "Cancel"],
  committed: ["Изменение сохранено", "Change saved"],
  createGroup: ["Создать группу", "Create group"],
  rename: ["Переименовать", "Rename"],
  delete: ["Удалить группу", "Delete group"],
  groupName: ["Название группы", "Group name"],
  addMember: ["Добавить участника", "Add member"],
  removeMember: ["Убрать из группы", "Remove from group"],
  groupMembers: ["Состав группы", "Group members"],
  recipient: ["Получатели", "Recipients"],
  selected: ["Выбрано", "Selected"],
  view: ["Просмотр", "View"],
  edit: ["Редактирование", "Edit"],
  manage: ["Управление", "Manage"],
  custom: ["Свой набор", "Custom"],
  scope: ["Область изменения", "Change scope"],
  resourceScope: ["Выбранные ресурсы", "Selected resources"],
  folderScope: ["Выбранные папки", "Selected folders"],
  vaultScope: ["Всё хранилище", "Whole Vault"],
  grant: ["Добавить доступ", "Grant access"],
  move: ["Переместить ресурс", "Move resource"],
  change: ["Изменить права", "Change permissions"],
  revoke: ["Отозвать эту выдачу", "Revoke this grant"],
  bulkRevoke: ["Отозвать выбранные выдачи", "Revoke selected grants"],
  grants: ["Прямые выдачи", "Direct grants"],
  who: ["Кому доступно", "Who has access permission"],
  paths: ["Все пути доступа", "All access paths"],
  direct: ["Прямой", "Direct"],
  inherited: ["Унаследован от контейнера", "Inherited from container"],
  policy: ["Разрешение на доступ", "Access permission"],
  key: ["Открытие данных", "Opening data"],
  usability: ["Доступность на устройстве", "Device availability"],
  notChecked: ["Не проверено", "Not checked"],
  WRAP_PRESENT_UNVERIFIED: ["Открытие данных ещё не проверено", "Opening data is unverified"],
  KEY_UNAVAILABLE: ["Данные нельзя открыть на этом устройстве", "Data cannot be opened on this device"],
  NO: ["Недоступно", "Unavailable"],
  NOT_REQUIRED: ["Не требуется", "Not required"],
  allowed: ["разрешён", "allowed"],
  denied: ["запрещён", "denied"],
  USER: ["Участник", "Member"],
  GROUP: ["Группа", "Group"],
  RESOURCE: ["Ресурс", "Resource"],
  FOLDER: ["Папка", "Folder"],
  VAULT: ["Хранилище", "Vault"],
  HOST: ["Хост", "Host"],
  CREDENTIAL: ["Учётные данные", "Credential"],
  SNIPPET: ["Сниппет", "Snippet"],
  FORWARDING: ["Туннель", "Forwarding"],
  device: ["Устройство участника", "Member device"],
  chooseDevice: ["Выберите конкретное устройство", "Choose an explicit device"],
  checkDevice: ["Проверить устройство", "Check device"],
  unknown: [
    "Доступ на устройстве не подтверждён",
    "Availability on this device is unverified",
  ],
  yes: ["Доступ на устройстве подтверждён", "Available on this device"],
  no: ["На устройстве недоступно", "Unavailable on device"],
  before: ["До", "Before"],
  after: ["После", "After"],
  gained: ["Добавленные права", "Gained permissions"],
  lost: ["Утраченные права", "Lost permissions"],
  affected: ["Затронутые выдачи", "Affected grants"],
  gainedPairs: ["Участник и ресурс: права расширены", "Member/resource pairs with more permissions"],
  lostPairs: ["Участник и ресурс: права сокращены", "Member/resource pairs with fewer permissions"],
  none: ["Нет", "None"],
  V1_ACTIVE: ["Общее хранилище", "Whole Vault access"],
  V2_PREPARING: ["Настройка доступа", "Access setup"],
  V2_READY: ["Доступ подготовлен", "Access prepared"],
  V2_ACTIVE: ["Используется", "In use"],
  stateUnknown: ["Состояние неизвестно", "Status unknown"],
  previewMore: ["Загрузить последствия дальше", "Load more consequences"],
  previewIncomplete: [
    "Сначала загрузите все последствия",
    "Load all consequences before confirming",
  ],
  limits: [
    "До 50 изменений, 20 получателей, 1000 пар участник/ресурс. Пакет применяется целиком.",
    "Up to 50 changes, 20 recipients, 1000 member/resource pairs. All changes are saved together.",
  ],
  opaque: [
    "Названия видны, когда это устройство может безопасно открыть данные с вашим разрешением на доступ. Иначе показаны тип и идентификатор.",
    "Names appear when this device can securely open data with your access permission. Otherwise the type and identifier are shown.",
  ],
  preparing: [
    "Хранилище готовится к использованию. Изменение прав доступа не подтверждает, что участник сможет открыть данные на своём устройстве.",
    "The Vault is being prepared for use. Changing access permissions does not confirm that a member can open data on their device.",
  ],
  legacy: [
    "Доступ применяется ко всему хранилищу. Настройка доступа к отдельным ресурсам здесь недоступна: сначала нужно подготовить хранилище.",
    "Access applies to the whole Vault. Access to individual resources is unavailable here until the Vault is prepared.",
  ],
  publication: [
    "Изменения доступа здесь недоступны. Для этого хранилища сначала нужно подготовить и применить новое защищённое обновление доступа.",
    "Access changes are unavailable here. This Vault first needs a new secure access update to be prepared and applied.",
  ],
  groupPublication: [
    "Изменения групп недоступны: защищённые данные команды используют текущий состав групп.",
    "Group changes are unavailable because the Team’s secure data uses the current group membership.",
  ],
  permissionDenied: ["Нет разрешения на изменение", "No permission to modify"],
  View: ["Просмотр", "View"],
  ViewMetadata: ["Просмотр метаданных", "View metadata"],
  Reveal: ["Раскрытие секрета", "Reveal secret"],
  Edit: ["Редактирование", "Edit"],
  ManageAccess: ["Управление доступом", "Manage access"],
  Create: ["Создание ресурсов", "Create resources"],
  Manage: ["Управление папкой", "Manage folder"],
  folderConsequence: [
    "От папки наследуется только просмотр; управление папкой не передаёт управление доступом.",
    "Only viewing is inherited from a folder; managing a folder does not grant permission to manage access.",
  ],
  vaultConsequence: [
    "Выдача на всё хранилище расширяет просмотр на вложенные ресурсы.",
    "A whole Vault grant extends viewing to contained resources.",
  ],
  preserved: [
    "Другие пути сохраняются: отзыв одной выдачи может оставить эффективный доступ.",
    "Other paths remain: revoking one grant may preserve effective access.",
  ],
  firstGrant: [
    "Предпросмотр показывает права, которые получат выбранные получатели.",
    "Preview shows the permissions the selected recipients will gain.",
  ],
  expired: [
    "Предпросмотр устарел. Обновите данные и проверьте последствия снова.",
    "Preview is stale. Refresh and preview again.",
  ],
  retry: ["Повторить", "Retry"],
};
const errors = {
  access_resource_not_found: [
    "Ресурс недоступен или удалён. Обновите выдачи доступа.",
    "Resource unavailable or deleted. Refresh access grants.",
  ],
  access_commit_in_progress: [
    "Изменение сохраняется. Дождитесь ответа сервера.",
    "Change is being committed. Wait for the server response.",
  ],
  access_result_too_large: [
    "Результат превышает лимит. Уменьшите область.",
    "Result exceeds the limit. Narrow the scope.",
  ],
  invalid_grant_permission: [
    "Права не подходят выбранному типу ресурса.",
    "Permissions do not match the selected resource kind.",
  ],
  credential_edit_requires_reveal: [
    "Для редактирования учётных данных нужно разрешение на раскрытие секрета.",
    "Editing a credential requires permission to reveal its secret.",
  ],
  team_not_found: [
    "Команда недоступна. Обновите список команд.",
    "Team unavailable. Refresh the Team list.",
  ],
  access_group_not_found: [
    "Группа недоступна. Обновите список групп.",
    "Group unavailable. Refresh the group list.",
  ],
  authentication_required: [
    "Сессия завершена. Войдите снова.",
    "Session ended. Sign in again.",
  ],
  access_preview_conflict: copy.expired,
  access_policy_conflict: copy.expired,
  crypto_publication_required: copy.publication,
  access_v2_preparing_required: copy.legacy,
  access_batch_too_large: [
    "Пакет превышает лимит. Уменьшите область; изменений не было.",
    "Batch exceeds the limit. Narrow the scope; no changes were applied.",
  ],
  group_grants_must_be_revoked_first: [
    "Сначала отзовите выдачи этой группы (1001+). Группа не удалена.",
    "Revoke this group’s grants first (1001+). The group was not deleted.",
  ],
  team_permission_denied: copy.permissionDenied,
  team_access_denied: copy.permissionDenied,
  access_scope_mismatch: [
    "Ответ не относится к выбранной области. Обновите данные.",
    "Response does not match the selected scope. Refresh.",
  ],
  invalid_access_response: [
    "Ответ сервера не прошёл проверку. Обновите данные.",
    "Server response failed validation. Refresh.",
  ],
  invalid_access_permissions: [
    "Выберите допустимые права. Для редактирования учётных данных нужно разрешение на раскрытие секрета.",
    "Choose valid permissions. Editing a credential requires permission to reveal its secret.",
  ],
  access_preview_incomplete: copy.previewIncomplete,
  invalid_access_request: [
    "Выберите ресурсы и получателей в одной области.",
    "Select resources and recipients in one scope.",
  ],
  invalid_access_group_name: [
    "Введите название до 120 символов.",
    "Enter a name up to 120 characters.",
  ],
  access_group_name_exists: [
    "Группа с таким названием уже существует.",
    "A group with this name already exists.",
  ],
  invalid_access_device: [
    "Выберите конкретное устройство участника.",
    "Choose an explicit member device.",
  ],
  network_unavailable: [
    "Соединение недоступно. Повторите загрузку.",
    "Connection unavailable. Retry loading.",
  ],
};
export function accessCopy(key, locale = "ru") {
  const pair = copy[key];
  return pair ? pair[locale === "en" ? 1 : 0] : key;
}
export function accessErrorCopy(error, locale = "ru") {
  const pair = errors[error?.code ?? error?.message];
  return (pair ?? [
    "Не удалось выполнить действие. Обновите данные и повторите.",
    "Action failed. Refresh and try again.",
  ])[locale === "en" ? 1 : 0];
}
export function accessConsequence(detail, locale = "ru", kind = detail.policyKind) {
  const suffix = detail.lostMask && detail.after?.policyEffective?.paths?.length
    ? accessCopy("preserved", locale)
    : detail.gainedMask && !detail.lostMask
      ? accessCopy("firstGrant", locale)
      : "";
  const metadataView = kind === "CREDENTIAL" || (!kind && [
    ...(detail.before?.policyEffective?.paths ?? []),
    ...(detail.after?.policyEffective?.paths ?? []),
  ].some((path) => path.permissions?.includes("ViewMetadata")));
  const permissions = (mask) => {
    const names = [
      [1, metadataView ? "ViewMetadata" : "View"],
      [2, "Reveal"], [4, "Edit"], [8, "ManageAccess"],
      [16, "Create"], [32, "Manage"],
    ].filter(([bit]) => mask & bit).map(([, name]) => accessCopy(name, locale));
    return names.length ? names.join(", ") : accessCopy("none", locale);
  };
  return `${accessCopy("gained", locale)}: ${permissions(detail.gainedMask)}; ${accessCopy("lost", locale)}: ${permissions(detail.lostMask)}.${suffix ? ` ${suffix}` : ""}`;
}

const reasons = {
  POLICY_DENIED: [
    "У участника нет разрешения на доступ",
    "The member does not have access permission",
  ],
  DEVICE_NOT_ADMITTED: ["Устройство не допущено", "Device is not admitted"],
  KEY_UNAVAILABLE: ["Это устройство не может открыть данные ресурса", "This device cannot open the resource data"],
  NO_DEVICE_CONTENT_PERMISSION: [
    "Нет прав на содержимое для устройства",
    "No device content permission",
  ],
};
export function accessReasonCopy(reason, locale = "ru") {
  return (reasons[reason] ?? [
    "Причина недоступности не определена",
    "Availability reason is unknown",
  ])[locale === "en" ? 1 : 0];
}
