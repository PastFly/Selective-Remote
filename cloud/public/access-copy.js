const copy = {
  title: ["Доступ и общий доступ", "Access & sharing"],
  members: ["Участники", "Members"],
  groups: ["Группы", "Groups"],
  resourceKind: ["Тип ресурсов", "Resource kind"],
  allKinds: ["Все типы", "All kinds"],
  resources: ["Ресурсы", "Resources"],
  vault: ["Vault", "Vault"],
  chooseVault: ["Выберите Vault", "Choose a Vault"],
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
  committed: ["Изменение сохранено сервером", "Change committed by server"],
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
  vaultScope: ["Весь Vault", "Whole Vault"],
  grant: ["Добавить доступ", "Grant access"],
  move: ["Переместить ресурс", "Move resource"],
  change: ["Изменить права", "Change permissions"],
  revoke: ["Отозвать эту выдачу", "Revoke this grant"],
  bulkRevoke: ["Отозвать выбранные выдачи", "Revoke selected grants"],
  grants: ["Прямые выдачи", "Direct grants"],
  who: ["Кому доступно", "Who has policy access"],
  paths: ["Все пути доступа", "All access paths"],
  direct: ["Прямой", "Direct"],
  inherited: ["Унаследован от контейнера", "Inherited from container"],
  policy: ["Права пользователя", "User policy"],
  device: ["Устройство участника", "Member device"],
  chooseDevice: ["Выберите конкретное устройство", "Choose an explicit device"],
  checkDevice: ["Проверить устройство", "Check device"],
  unknown: [
    "Доступ на устройстве не подтверждён",
    "Device usability unverified",
  ],
  yes: ["Доступ на устройстве подтверждён", "Device usability confirmed"],
  no: ["На устройстве недоступно", "Unavailable on device"],
  before: ["До", "Before"],
  after: ["После", "After"],
  gained: ["Добавленные права", "Gained permissions"],
  lost: ["Утраченные права", "Lost permissions"],
  affected: ["Затронутые выдачи", "Affected grants"],
  previewMore: ["Загрузить последствия дальше", "Load more consequences"],
  previewIncomplete: [
    "Сначала загрузите все последствия",
    "Load all consequences before confirming",
  ],
  limits: [
    "До 50 изменений, 20 получателей, 1000 пар участник/ресурс. Пакет применяется целиком.",
    "Up to 50 changes, 20 recipients, 1000 member/resource pairs. The batch applies atomically.",
  ],
  opaque: [
    "Названия видны только после разрешённой локальной расшифровки V2. Иначе показаны тип и ID.",
    "Labels appear only after authorized local V2 decryption. Otherwise type and ID are shown.",
  ],
  preparing: [
    "Подготовка V2: изменения политики не подтверждают доставку ключей или доступ на устройстве.",
    "V2 preparation: policy changes do not confirm key delivery or device usability.",
  ],
  legacy: [
    "V1: действует доступ ко всему Vault. Для отдельных ресурсов нужна подготовка V2.",
    "V1: whole Vault access applies. Resource access requires V2 preparation.",
  ],
  publication: [
    "READY/ACTIVE: опубликованное поколение неизменно. Изменения требуют нового криптографического опубликования.",
    "READY/ACTIVE: the published generation is immutable. Changes require a new cryptographic publication.",
  ],
  groupPublication: [
    "Изменения групп заблокированы текущим опубликованием в этой команде.",
    "Group changes are blocked by a current publication in this Team.",
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
    "Only View is inherited from a folder; folder management does not grant access management.",
  ],
  vaultConsequence: [
    "Выдача на весь Vault расширяет просмотр на вложенные ресурсы.",
    "A whole Vault grant extends View to contained resources.",
  ],
  preserved: [
    "Другие пути сохраняются: отзыв одной выдачи может оставить эффективный доступ.",
    "Other paths remain: revoking one grant may preserve effective access.",
  ],
  expired: [
    "Предпросмотр устарел. Обновите данные и проверьте последствия снова.",
    "Preview is stale. Refresh and preview again.",
  ],
  retry: ["Повторить", "Retry"],
};
const errors = {
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
    "Credential Edit требует Reveal.",
    "Credential Edit requires Reveal.",
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
    "Выберите допустимые права. Credential Edit требует Reveal.",
    "Choose valid permissions. Credential Edit requires Reveal.",
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
export function accessConsequence(detail, locale = "ru") {
  return `${accessCopy("gained", locale)}: ${detail.gainedMask}; ${accessCopy("lost", locale)}: ${detail.lostMask}. ${accessCopy("preserved", locale)}`;
}

const reasons = {
  POLICY_DENIED: [
    "Политика не предоставляет доступ",
    "Policy does not grant access",
  ],
  DEVICE_NOT_ADMITTED: ["Устройство не допущено", "Device is not admitted"],
  KEY_UNAVAILABLE: ["Ключ ресурса недоступен", "Resource key is unavailable"],
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
