import { actionsFor, effectiveAccess, grantPreview, presetFor, revokePreview } from './access-model.mjs';

const resources = [
  { id: "host-prod", type: "host", title: "production-01.example", folder: "Production / ssh", vault: "Production", icon: "▣" },
  { id: "host-stage", type: "host", title: "staging-02.example", folder: "Staging / ssh", vault: "Operations", icon: "▣" },
  { id: "cred-ops", type: "credential", title: "ops-readonly", folder: "Production / ssh", vault: "Production", icon: "◈" },
  { id: "snippet-health", type: "snippet", title: "Inspect health", folder: "Production / checks", vault: "Production", icon: "⌘" },
  { id: "folder-prod", type: "folder", title: "Production / ssh", folder: "Production", vault: "Production", icon: "▤" },
  { id: "forward-stage", type: "forwarding", title: "staging tunnel", folder: "Staging / ssh", vault: "Operations", icon: "⇄" },
];
const generatedResources = Array.from({ length: 494 }, (_, index) => {
  const number = String(index + 1).padStart(3, "0");
  const type = ["host", "credential", "snippet", "forwarding"][index % 4];
  return { id: `sample-${number}`, type, title: `sample-${type}-${number}`, folder: "Demo / scale", vault: "Scale Demo", icon: { host: "▣", credential: "◈", snippet: "⌘", forwarding: "⇄" }[type] };
});
const people = [
  { id: "member-alex", name: "Alex Morgan", role: "owner", initials: "AM" },
  { id: "member-mira", name: "Mira Chen", role: "admin", initials: "MC" },
  { id: "member-sam", name: "Sam Rivera", role: "viewer", initials: "SR" },
  { id: "member-nia", name: "Nia Patel", role: "viewer", initials: "NP" },
  { id: "member-jo", name: "Jo Kim", role: "viewer", initials: "JK" },
];
const generatedPeople = Array.from({ length: 95 }, (_, index) => ({
  id: `sample-member-${String(index + 6).padStart(3, "0")}`,
  name: `Demo Member ${String(index + 6).padStart(3, "0")}`,
  role: "viewer", initials: "DM",
}));
const initialGroups = [
  { id: "group-support", name: "Support L2", memberIds: ["member-alex", "member-sam"] },
  { id: "group-devops", name: "DevOps", memberIds: ["member-alex", "member-mira"] },
];
const copy = {
  ru: {
    concept: "ИНТЕРАКТИВНАЯ КОНЦЕПЦИЯ · 0.33", title: "Доступ без догадок", intro: "Кому, к чему и почему открыт доступ. Демонстрация интерфейса до изменения сервера и шифрования.", demo: "Демо · права не применяются", mac: "Mac workspace", cloud: "Cloud admin", light: "Light", graphite: "Graphite", team: "Northstar Demo", sidebar: "РАБОЧЕЕ ПРОСТРАНСТВО", hosts: "Хосты", credentials: "Учётные данные", snippets: "Сниппеты", folders: "Папки", forwarding: "Forwarding", cloudNav: "Cloud", notifications: "Уведомления", status: "Состояние синхронизации", macTitle: "Быстрый доступ к ресурсам", macIntro: "Откройте контекстное меню ресурса или кнопку «Поделиться». Колокольчик остаётся в верхней области.", search: "Поиск ресурсов", share: "Поделиться…", effective: "Кто имеет доступ?", view: "Просмотр", connect: "Подключение", operate: "Работа", edit: "Изменение", manage: "Управление", custom: "Настроить права…", noResults: "Нет совпадений", vault: "Vault", folder: "Папка", resource: "Ресурс", resources: "Ресурсы", members: "Участники", groups: "Группы", accessManager: "Access Manager", activity: "Активность", overview: "Обзор", selected: "Выбрано", recipient: "Кому", preset: "Набор прав", expiry: "Срок действия", forever: "Бессрочно", sevenDays: "7 дней", thirtyDays: "30 дней", preview: "Предпросмотр", applyDemo: "Применить в демо", cancel: "Отмена", close: "Закрыть", editGrant: "Настроить", grantPreview: "Что изменится", demoOnly: "Изменение останется только в памяти этого прототипа.", useWithoutReveal: "Использовать без раскрытия", useLimit: "Требует нового защищённого механизма. Текущий клиент расшифровывает Team Vault целиком; скрытое поле не защищает секрет от изменённого клиента.", reveal: "Показать секрет", revealNote: "Концепция отдельного права. В текущем Vault это ещё не обеспечивается.", direct: "Прямой доступ", inherited: "Через группу и папку", why: "Почему доступ есть", allPaths: "Показаны все пути; отзыв одного не убирает другой.", noGrant: "Для этого выбора нет демонстрационных назначений.", currentRole: "Текущая роль Team", teamBoundary: "Сейчас доступ к зашифрованному Vault зависит от роли Team, устройства и wrapper. Разрешений на отдельные записи ещё нет.", cloudTitle: "Центр управления доступом", cloudIntro: "Административный обзор участников, групп и ресурсов. Все изменения демонстрационные.", perspective: "Перспектива", peopleView: "Пользователи / группы", resourceView: "Ресурсы", permissions: "Разрешения", yes: "Да", no: "Нет", via: "Получено через", addGroup: "Создать демо-группу", groupName: "Название группы", groupAdded: "Группа создана в демо", grants: "Назначения", bulk: "Массовое действие", bulkGrant: "Выдать доступ", bulkRevoke: "Отозвать доступ", bulkHint: "Выберите несколько ресурсов и просмотрите результат перед применением.", bulkEmpty: "Выберите хотя бы один ресурс.", changed: "Демонстрационное назначение сохранено", revoked: "Демонстрационные назначения отозваны", owner: "Владелец", admin: "Администратор", viewer: "Просмотр", unsupported: "Пока недоступно", conceptual: "Концепция, не текущие возможности приложения", selectedResources: "Выбранные ресурсы", currentAccess: "Текущий доступ", grantTo: "Доступ для", auditNote: "После будущей реализации изменения будут записываться в существующий Team Audit без секретов.", noSecret: "Секреты не показаны", refresh: "Обновление страницы сбросит демонстрацию", pathDirect: "Прямое назначение", pathFolder: "Группа Support L2 → Vault Production → Production / ssh", removeDemo: "Убрать демо-назначение", role: "Роль", available: "Доступно", accessPaths: "Пути доступа", cloudDisclaimer: "Демо не отправляет запросы в Cloud и не изменяет реальный доступ.", macDisclaimer: "Нажатие «Поделиться» показывает дизайн взаимодействия, а не создаёт реальную ссылку или право.",
  },
  en: {
    concept: "INTERACTIVE CONCEPT · 0.33", title: "Access you can explain", intro: "Who can do what, with which resource, and why. Interface demo before server or crypto changes.", demo: "Demo · permissions are not applied", mac: "Mac workspace", cloud: "Cloud admin", light: "Light", graphite: "Graphite", team: "Northstar Demo", sidebar: "WORKSPACE", hosts: "Hosts", credentials: "Credentials", snippets: "Snippets", folders: "Folders", forwarding: "Forwarding", cloudNav: "Cloud", notifications: "Notifications", status: "Sync status", macTitle: "Quick resource access", macIntro: "Open a resource context menu or its Share button. The bell stays in the upper area.", search: "Search resources", share: "Share…", effective: "Who has access?", view: "View", connect: "Connect", operate: "Operate", edit: "Edit", manage: "Manage", custom: "Customize permissions…", noResults: "No matches", vault: "Vault", folder: "Folder", resource: "Resource", resources: "Resources", members: "Members", groups: "Groups", accessManager: "Access Manager", activity: "Activity", overview: "Overview", selected: "Selected", recipient: "Recipient", preset: "Permission preset", expiry: "Expiration", forever: "No expiration", sevenDays: "7 days", thirtyDays: "30 days", preview: "Preview", applyDemo: "Apply in demo", cancel: "Cancel", close: "Close", editGrant: "Customize", grantPreview: "What will change", demoOnly: "This change stays in this prototype's memory only.", useWithoutReveal: "Use without reveal", useLimit: "Needs a new protected flow. The current client decrypts the whole Team Vault; a hidden field cannot protect a secret from a modified client.", reveal: "Reveal secret", revealNote: "A separate permission concept. The current Vault cannot enforce it yet.", direct: "Direct access", inherited: "Via group and folder", why: "Why access exists", allPaths: "All paths are shown; removing one may leave another.", noGrant: "No demo grants for this selection.", currentRole: "Current Team role", teamBoundary: "Today encrypted Vault access depends on Team role, device admission and wrapper. There are no record-level permissions yet.", cloudTitle: "Access Manager", cloudIntro: "Administrative view of members, groups and resources. All changes are demo only.", perspective: "Perspective", peopleView: "People / groups", resourceView: "Resources", permissions: "Permissions", yes: "Yes", no: "No", via: "Via", addGroup: "Create demo group", groupName: "Group name", groupAdded: "Group created in demo", grants: "Grants", bulk: "Bulk action", bulkGrant: "Grant access", bulkRevoke: "Revoke access", bulkHint: "Select resources and preview the result before applying.", bulkEmpty: "Select at least one resource.", changed: "Demo grant saved", revoked: "Demo grants revoked", owner: "Owner", admin: "Admin", viewer: "Viewer", unsupported: "Unavailable", conceptual: "Concept, not current app behavior", selectedResources: "Selected resources", currentAccess: "Current access", grantTo: "Access for", auditNote: "A future implementation would record changes in existing Team Audit without secrets.", noSecret: "No secrets shown", refresh: "Refreshing resets the demo", pathDirect: "Direct grant", pathFolder: "Support L2 group → Production Vault → Production / ssh", removeDemo: "Remove demo grant", role: "Role", available: "Available", accessPaths: "Access paths", cloudDisclaimer: "This demo makes no Cloud requests and changes no real access.", macDisclaimer: "Share shows the interaction design; it creates no real link or permission.",
  },
};
Object.assign(copy.ru, {
  viewMetadata: "Просмотр метаданных", run: "Запуск", manageAccess: "Управление доступом",
  groupMember: "Участник группы", fromFolder: "Наследуется от папки", noMatchingGrant: "Для этого получателя нет прямых назначений на выбранных ресурсах.",
  revokeOnly: "Будут удалены только назначения выбранному получателю на выбранных ресурсах.",
  before: "До", after: "После", remainingPaths: "Оставшиеся пути", customHint: "Выберите разрешения для демонстрационного назначения.",
  groupMembership: "Состав группы", noMembers: "Участников пока нет", noAccess: "Нет доступа по демонстрационной модели",
  scale: "Масштаб демо", filterCloud: "Поиск в Cloud", previousPage: "Назад", nextPage: "Далее", page: "Страница",
});
Object.assign(copy.en, {
  viewMetadata: "View metadata", run: "Run", manageAccess: "Manage access",
  groupMember: "Group member", fromFolder: "Inherited from folder", noMatchingGrant: "No direct grants for this recipient on the selected resources.",
  revokeOnly: "Only grants to the selected recipient on the selected resources will be removed.",
  before: "Before", after: "After", remainingPaths: "Remaining paths", customHint: "Select permissions for this demo grant.",
  groupMembership: "Group membership", noMembers: "No members yet", noAccess: "No access in the demo model",
  scale: "Demo scale", filterCloud: "Search Cloud", previousPage: "Previous", nextPage: "Next", page: "Page",
});
const state = {
  locale: "ru", theme: "graphite", surface: "mac", macSection: "hosts", cloudSection: "manager", perspective: "people",
  query: "", selectedResource: "host-prod", selectedPrincipal: "member-alex", dialog: null, preset: "connect", recipient: "group-support", expiry: "forever", preview: false, customMode: false, customActions: new Set(),
  context: null, toast: "", volume: 6, cloudQuery: "", cloudPage: 0, groups: [...initialGroups], grants: [
    { id: "demo-folder-support", resourceId: "folder-prod", recipient: "group-support", actions: ["View"], expiry: "forever" },
    { id: "demo-host-alex", resourceId: "host-prod", recipient: "member-alex", actions: ["Connect"], expiry: "forever" },
  ], bulkSelected: new Set(), bulkMode: "grant", groupDraft: "",
};
const T = (key) => copy[state.locale][key] ?? key;
const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
const demoResources = () => [...resources, ...generatedResources].slice(0, state.volume);
const demoPeople = () => state.volume === 6 ? people : [...people, ...generatedPeople];
const resource = (id) => demoResources().find((item) => item.id === id) ?? resources[0];
const principal = (id) => [...demoPeople().map((p) => ({ ...p, type: "member" })), ...state.groups.map((g) => ({ ...g, type: "group" }))].find((item) => item.id === id);
const principalName = (id) => principal(id)?.name ?? id;
const typeName = (type) => T({ host: "hosts", credential: "credentials", snippet: "snippets", folder: "folders", forwarding: "forwarding" }[type] ?? type);
const model = () => ({ resources: demoResources(), groups: state.groups, grants: state.grants });
const activeActions = (item, preset = state.preset) => state.customMode ? [...state.customActions].filter((action) => actionsFor(item.type).includes(action)) : presetFor(item.type, preset);
const actionLabel = (action) => T({ "View": "view", "View metadata": "viewMetadata", "Connect": "connect", "Run": "run", "Reveal": "reveal", "Edit": "edit", "Manage Access": "manageAccess" }[action] ?? action);
function cloudPage(items) {
  const filtered = items.filter((item) => (item.title ?? item.name).toLowerCase().includes(state.cloudQuery.toLowerCase()));
  const pages = Math.max(1, Math.ceil(filtered.length / 25));
  const page = Math.min(state.cloudPage, pages - 1);
  return { items: filtered.slice(page * 25, page * 25 + 25), page, pages, total: filtered.length };
}
function cloudPager(result) {
  return `<div class="pager"><span>${esc(T("page"))} ${result.page + 1}/${result.pages} · ${result.total}</span><button type="button" class="button small" data-action="cloud-page" data-value="previous" ${result.page === 0 ? "disabled" : ""}>${esc(T("previousPage"))}</button><button type="button" class="button small" data-action="cloud-page" data-value="next" ${result.page + 1 >= result.pages ? "disabled" : ""}>${esc(T("nextPage"))}</button></div>`;
}

function segment(name, entries, selected) {
  return `<div class="segmented" role="group" aria-label="${esc(name)}">${entries.map(([value, label]) => `<button type="button" data-action="${esc(name)}" data-value="${esc(value)}" aria-pressed="${selected === value}">${esc(label)}</button>`).join("")}</div>`;
}
function shell(content) {
  return `<header class="topbar"><div class="brand"><div class="brandmark" aria-hidden="true">↗</div><div><strong>Selective Remote</strong><small>${esc(T("conceptual"))}</small></div></div><div class="switches">${segment("surface", [["mac", T("mac")], ["cloud", T("cloud")]], state.surface)}${segment("locale", [["ru", "RU"], ["en", "EN"]], state.locale)}${segment("theme", [["graphite", T("graphite")], ["light", T("light")]], state.theme)}</div></header><main class="page"><div class="intro"><div><div class="eyebrow">${esc(T("concept"))}</div><h1>${esc(T("title"))}</h1><p>${esc(T("intro"))}</p></div><div class="concept-pill">◌ ${esc(T("demo"))}</div></div>${content}<p class="bottom-note">${esc(T("refresh"))} · ${esc(T("noSecret"))}</p></main>${state.dialog ? renderDialog() : ""}${state.context ? renderContext() : ""}${state.toast ? `<div class="toast" role="status">${esc(state.toast)}</div>` : ""}`;
}
function navButton(section, icon, label, active, kind) { return `<button type="button" data-action="${kind}" data-value="${section}" class="${active ? "active" : ""}"><span aria-hidden="true">${icon}</span><span>${esc(label)}</span></button>`; }
function side(sections, selected, kind, title) {
  return `<aside class="sidebar"><div class="sidebar-head"><span class="brandmark" style="width:24px;height:24px;border-radius:7px;font-size:14px" aria-hidden="true">↗</span><strong>${esc(T("team"))}</strong><button class="icon-button" type="button" aria-label="${esc(T("notifications"))}" title="${esc(T("notifications"))}">🔔</button></div><div class="nav-label">${esc(title)}</div><nav class="nav-list" aria-label="${esc(title)}">${sections.map(([key, icon, label]) => navButton(key, icon, label, selected === key, kind)).join("")}</nav><div class="sidebar-foot">${esc(T("teamBoundary"))}</div></aside><nav class="mobile-tabs" aria-label="${esc(title)}">${sections.map(([key,,label]) => `<button type="button" data-action="${kind}" data-value="${key}" class="${selected === key ? "active" : ""}">${esc(label)}</button>`).join("")}</nav>`;
}
function resourceRow(item, active = false, selectable = false) {
  const selected = state.bulkSelected.has(item.id);
  return `<div class="resource-row ${active ? "active" : ""}" data-resource="${item.id}" tabindex="0"><div class="resource-icon" aria-hidden="true">${item.icon}</div><div class="resource-meta"><strong>${esc(item.title)}</strong><small>${esc(typeName(item.type))} · ${esc(item.vault)} ${esc(T("vault"))} · ${esc(item.folder)}</small></div>${selectable ? `<input type="checkbox" data-action="bulk-select" data-value="${item.id}" aria-label="${esc(T("selected"))} ${esc(item.title)}" ${selected ? "checked" : ""}>` : `<span class="tag">${esc(T("conceptual"))}</span><div class="resource-actions"><button type="button" class="button small ghost" data-action="effective" data-value="${item.id}">${esc(T("effective"))}</button><button type="button" class="button small" data-action="share" data-value="${item.id}">${esc(T("share"))}</button></div>`}</div>`;
}
function renderMac() {
  const sections = [["hosts", "▣", T("hosts")], ["credentials", "◈", T("credentials")], ["snippets", "⌘", T("snippets")], ["folders", "▤", T("folders")]];
  const type = ({ hosts: "host", credentials: "credential", snippets: "snippet", folders: "folder" })[state.macSection];
  const filtered = resources.filter((item) => item.type === type && `${item.title} ${item.folder}`.toLowerCase().includes(state.query.toLowerCase()));
  return shell(`<div class="workspace">${side(sections, state.macSection, "mac-section", T("sidebar"))}<section class="content"><div class="content-header"><div><div class="eyebrow">MAC · ${esc(T("team"))}</div><h2>${esc(T(state.macSection))}</h2><p>${esc(T("macIntro"))}</p></div><div class="header-actions"><button class="button" type="button" data-action="effective" data-value="${state.selectedResource}">${esc(T("effective"))}</button></div></div><div class="notice mint"><strong>${esc(T("demo"))}</strong><p>${esc(T("macDisclaimer"))}</p></div><div class="toolbar"><div class="left"><input class="filter" type="search" data-action="search" aria-label="${esc(T("search"))}" placeholder="${esc(T("search"))}" value="${esc(state.query)}"></div><div class="right"><span class="tag good">${esc(T("status"))} · ✓</span></div></div><div class="section-title">${esc(T("resources"))} · ${filtered.length}</div><div class="resource-list">${filtered.length ? filtered.map((item) => resourceRow(item, item.id === state.selectedResource)).join("") : `<div class="pane">${esc(T("noResults"))}</div>`}</div><p class="bottom-note">${esc(T("auditNote"))}</p></section></div>`);
}
function principalRow(item) { return `<div class="list-row ${state.selectedPrincipal === item.id ? "active" : ""}" data-action="select-principal" data-value="${item.id}" role="button" tabindex="0"><div class="avatar">${esc(item.initials ?? "◫")}</div><div class="grow"><strong>${esc(item.name)}</strong><small>${item.type === "group" ? `${item.memberIds.length} ${esc(T("members"))}` : esc(T(item.role))}</small></div><span aria-hidden="true">›</span></div>`; }
function principalEffective(item, principalId) {
  const access = effectiveAccess(model(), item.id, principalId);
  const permissionGrid = `<div class="permission-grid">${actionsFor(item.type).map((action) => `<div class="permission-item"><span>${esc(actionLabel(action))}</span><span class="${access.actions.includes(action) ? "yes" : "no"}">${esc(T(access.actions.includes(action) ? "yes" : "no"))}</span></div>`).join("")}</div>`;
  const paths = access.paths.map((path) => {
    const origin = resource(path.inheritedFrom ?? item.id);
    const group = state.groups.find((entry) => entry.id === path.origin);
    const viaGroup = group && principalId !== group.id ? `${T("groupMember")}: ${group.name} → ` : "";
    const route = path.inheritedFrom ? `${T("fromFolder")}: ${origin.title} → ` : `${T("direct")}: `;
    return `<div class="path"><strong>${esc(principalName(path.origin))}</strong><span class="step">${esc(viaGroup + route + item.title)}</span><span class="step">${esc(path.actions.map(actionLabel).join(" · "))}</span><button class="button small danger" type="button" data-action="remove-grant" data-value="${esc(path.grantId)}">${esc(T("removeDemo"))}</button></div>`;
  }).join("");
  return `${permissionGrid}<div class="section-title">${esc(T("accessPaths"))}</div>${paths || `<p class="muted">${esc(T("noAccess"))}</p>`}`;
}
function effectiveSummary(item, selectedId = state.selectedPrincipal) {
  const header = `<div class="detail-title"><div class="resource-icon">${item.icon}</div><div><h3>${esc(item.title)}</h3><small class="muted">${esc(item.vault)} ${esc(T("vault"))} · ${esc(typeName(item.type))}</small></div></div>`;
  const principals = selectedId ? [principal(selectedId)].filter(Boolean) : [...demoPeople(), ...state.groups].filter((entry) => state.volume === 6 || effectiveAccess(model(), item.id, entry.id).paths.length);
  return `${header}${principals.map((entry) => `<section class="effective-person"><h4>${esc(entry.name)}</h4>${principalEffective(item, entry.id)}</section>`).join("")}<p class="hint">${esc(T("allPaths"))}</p>`;
}
function managerView() {
  const principals = [...demoPeople().map((item) => ({ ...item, type: "member" })), ...state.groups.map((item) => ({ ...item, type: "group", initials: "◫" }))];
  const selected = resource(state.selectedResource);
  if (state.perspective === "people") {
    const page = cloudPage(principals);
    const resourceChoices = demoResources().slice(0, 20);
    return `<div class="two-column"><div class="pane"><h3>${esc(T("peopleView"))}</h3><div class="list">${page.items.map(principalRow).join("")}</div>${cloudPager(page)}</div><div class="pane"><div class="toolbar"><div class="left"><h3>${esc(T("currentAccess"))}: ${esc(principalName(state.selectedPrincipal))}</h3></div><div class="right"><button type="button" class="button small" data-action="share" data-value="${selected.id}">${esc(T("share"))}</button></div></div>${effectiveSummary(selected, state.selectedPrincipal)}<div class="section-title">${esc(T("resources"))}</div>${resourceChoices.map((item) => `<button type="button" class="button small ${item.id === selected.id ? "selected" : ""}" data-action="select-resource" data-value="${item.id}" style="margin:0 5px 6px 0">${esc(item.title)}</button>`).join("")}</div></div>`;
  }
  const page = cloudPage(demoResources());
  return `<div class="two-column"><div class="pane"><h3>${esc(T("resources"))}</h3><div class="list">${page.items.map((item) => `<div class="list-row ${item.id === selected.id ? "active" : ""}" data-action="select-resource" data-value="${item.id}" role="button" tabindex="0"><div class="resource-icon">${item.icon}</div><div class="grow"><strong>${esc(item.title)}</strong><small>${esc(item.vault)} · ${esc(typeName(item.type))}</small></div><span aria-hidden="true">›</span></div>`).join("")}</div>${cloudPager(page)}</div><div class="pane"><div class="toolbar"><h3>${esc(T("effective"))}</h3><button type="button" class="button small" data-action="share" data-value="${selected.id}">${esc(T("share"))}</button></div>${effectiveSummary(selected, null)}</div></div>`;
}
function membersView() { const page = cloudPage(demoPeople()); return `<div class="two-column"><div class="pane"><h3>${esc(T("members"))}</h3><div class="list">${page.items.map((item) => principalRow({ ...item, type: "member" })).join("")}</div>${cloudPager(page)}</div><div class="pane"><h3>${esc(T("currentRole"))}</h3><p>${esc(T("teamBoundary"))}</p><div class="section-title">${esc(T("why"))}</div><div class="path"><strong>${esc(principalName(state.selectedPrincipal))}</strong><span class="step">${esc(T("team"))} → Team ${esc(T("role"))}</span><span class="step">${esc(T("vault"))} → device + wrapper</span></div><button type="button" class="button" data-action="cloud-section" data-value="manager">${esc(T("accessManager"))}</button></div></div>`; }
function groupsView() { const selected = state.groups.find((item) => item.id === state.selectedPrincipal) ?? state.groups[0]; return `<div class="two-column"><div class="pane"><div class="toolbar"><h3>${esc(T("groups"))}</h3><button type="button" class="button small" data-action="new-group">+ ${esc(T("addGroup"))}</button></div><div class="list">${state.groups.map((item) => principalRow({ ...item, type: "group", initials: "◫" })).join("")}</div></div><div class="pane"><h3>${esc(selected.name)}</h3><p>${esc(T("conceptual"))}</p><div class="section-title">${esc(T("groupMembership"))}</div><div class="list">${selected.memberIds.length ? selected.memberIds.map((id) => `<div class="path">${esc(principalName(id))}</div>`).join("") : `<p class="muted">${esc(T("noMembers"))}</p>`}</div>${effectiveSummary(resource(state.selectedResource), selected.id)}<button type="button" class="button" data-action="cloud-section" data-value="manager">${esc(T("effective"))}</button></div></div>`; }
function resourcesView() { const page = cloudPage(demoResources()); return `<div class="toolbar"><div class="left"><span class="tag">${esc(T("selected"))}: ${state.bulkSelected.size}</span></div><div class="right"><button type="button" class="button" data-action="bulk-open" data-value="grant">${esc(T("bulkGrant"))}</button><button type="button" class="button danger" data-action="bulk-open" data-value="revoke">${esc(T("bulkRevoke"))}</button></div></div><div class="notice mint"><strong>${esc(T("bulk"))}</strong><p>${esc(T("bulkHint"))}</p></div><div class="resource-list">${page.items.map((item) => resourceRow(item, false, true)).join("")}</div>${cloudPager(page)}`; }
function renderCloud() {
  const sections = [["manager", "◫", T("accessManager")], ["members", "♙", T("members")], ["groups", "▦", T("groups")], ["resources", "▣", T("resources")]];
  const body = state.cloudSection === "manager" ? managerView() : state.cloudSection === "members" ? membersView() : state.cloudSection === "groups" ? groupsView() : resourcesView();
  return shell(`<div class="workspace">${side(sections, state.cloudSection, "cloud-section", T("cloudNav"))}<section class="content"><div class="content-header"><div><div class="eyebrow">CLOUD · ${esc(T("team"))}</div><h2>${state.cloudSection === "manager" ? esc(T("accessManager")) : esc(T(state.cloudSection))}</h2><p>${esc(T("cloudIntro"))}</p></div><div class="header-actions">${state.cloudSection === "manager" ? segment("perspective", [["people", T("peopleView")], ["resources", T("resourceView")]], state.perspective) : ""}</div></div><div class="notice"><strong>${esc(T("demo"))}</strong><p>${esc(T("cloudDisclaimer"))}</p></div><div class="toolbar"><label>${esc(T("scale"))} ${segment("volume", [["6", "6"], ["100", "100"], ["500", "500"]], String(state.volume))}</label><input class="filter" type="search" data-action="cloud-search" aria-label="${esc(T("filterCloud"))}" placeholder="${esc(T("filterCloud"))}" value="${esc(state.cloudQuery)}"></div>${body}<p class="bottom-note">${esc(T("auditNote"))}</p></section></div>`);
}
function renderContext() { const item = resource(state.context.id); return `<div class="context-menu" role="menu" style="left:${state.context.x}px;top:${state.context.y}px"><button role="menuitem" type="button" data-action="share" data-value="${item.id}">${esc(T("share"))}</button><button role="menuitem" type="button" data-action="effective" data-value="${item.id}">${esc(T("effective"))}</button></div>`; }
function recipients() { return [...demoPeople().map((p) => ({ id: p.id, name: p.name })), ...state.groups.map((g) => ({ id: g.id, name: `${T("groups")}: ${g.name}` }))]; }
function selectField(label, action, value, options) { return `<div class="field"><label for="${action}">${esc(label)}</label><select id="${action}" data-action="${action}">${options.map(([id, name]) => `<option value="${esc(id)}" ${value === id ? "selected" : ""}>${esc(name)}</option>`).join("")}</select></div>`; }
function presetOptions(chosen) {
  if (new Set(chosen.map((item) => item.type)).size > 1) return [["view", T("view")], ["manage", T("manage")]];
  const type = chosen[0].type;
  if (type === "folder") return [["view", T("view")], ["manage", T("manage")]];
  return [["view", T("view")], ["connect", T(type === "credential" ? "reveal" : type === "host" ? "connect" : "run")], ["edit", T("edit")], ["manage", T("manage")]];
}
function renderShareBody(item, bulk = false) {
  const chosen = bulk ? [...state.bulkSelected].map(resource) : [item];
  const sameType = new Set(chosen.map((entry) => entry.type)).size === 1;
  const presets = presetOptions(chosen);
  const selectedPreset = presets.some(([key]) => key === state.preset) ? state.preset : presets[0][0];
  const custom = state.customMode && sameType;
  const customControls = custom ? `<div class="field"><label>${esc(T("customHint"))}</label>${actionsFor(chosen[0].type).map((action) => `<label class="checkbox-line"><input type="checkbox" data-action="custom-action" data-value="${esc(action)}" ${state.customActions.has(action) ? "checked" : ""}> ${esc(actionLabel(action))}</label>`).join("")}</div>` : "";
  const actionById = Object.fromEntries(chosen.map((entry) => [entry.id, custom ? activeActions(entry) : presetFor(entry.type, selectedPreset)]));
  const rows = grantPreview(model(), chosen.map((entry) => entry.id), state.recipient, actionById).impacts.map((impact) =>
    `<li><strong>${esc(principalName(impact.principalId))} → ${esc(resource(impact.resourceId).title)}</strong> · ${esc(T("before"))}: ${esc(impact.before.map(actionLabel).join(" · ") || "—")} → ${esc(T("after"))}: ${esc(impact.after.map(actionLabel).join(" · ") || "—")}</li>`
  ).join("");
  return `${selectField(T("recipient"), "recipient", state.recipient, recipients().map((p) => [p.id, p.name]))}<div class="field"><label>${esc(T("preset"))}</label><div class="presets">${presets.map(([key, label]) => `<button type="button" data-action="preset" data-value="${key}" class="${!custom && selectedPreset === key ? "active" : ""}">${esc(label)}</button>`).join("")}</div>${sameType ? `<button type="button" class="button small ghost" data-action="custom" style="justify-self:start;margin-top:6px">${esc(T("custom"))}</button>` : ""}</div>${customControls}${chosen.some((entry) => entry.type === "credential") ? `<div class="notice"><strong>${esc(T("unsupported"))}: ${esc(T("useWithoutReveal"))}</strong><p>${esc(T("useLimit"))}</p><label class="checkbox-line"><input type="checkbox" disabled> ${esc(T("useWithoutReveal"))}</label><p class="hint">${esc(T("revealNote"))}</p></div>` : ""}${selectField(T("expiry"), "expiry", state.expiry, [["forever", T("forever")], ["7d", T("sevenDays")], ["30d", T("thirtyDays")]])}<div class="preview"><strong>${esc(T("grantPreview"))}: ${esc(principalName(state.recipient))}</strong><ul>${rows}</ul>${state.preview ? `<p class="hint">✓ ${esc(T("demoOnly"))} ${esc(T("auditNote"))}</p>` : ""}</div>`;
}
function renderRevokeBody() {
  const ids = [...state.bulkSelected];
  const result = revokePreview(model(), ids, state.recipient, state.revokeGrantId);
  return `${selectField(T("recipient"), "recipient", state.recipient, recipients().map((p) => [p.id, p.name]))}<div class="notice"><strong>${esc(T("revokeOnly"))}</strong><p>${esc(T("allPaths"))}</p></div><div class="preview"><strong>${esc(T("grantPreview"))}: ${esc(principalName(state.recipient))}</strong>${result.removedGrantIds.length ? `<ul>${result.impacts.map((impact) => `<li><strong>${esc(principalName(impact.principalId))} → ${esc(resource(impact.resourceId).title)}</strong> · ${esc(T("before"))}: ${esc(impact.before.map(actionLabel).join(" · ") || "—")} → ${esc(T("after"))}: ${esc(impact.after.map(actionLabel).join(" · ") || "—")}<br>${esc(T("remainingPaths"))}: ${impact.remainingPathIds.length}</li>`).join("")}</ul>` : `<p>${esc(T("noMatchingGrant"))}</p>`}</div>`;
}
function renderDialog() {
  const item = resource(state.selectedResource);
  const kind = state.dialog;
  const isBulk = kind === "bulk";
  let title = kind === "effective" ? T("effective") : kind === "group" ? T("addGroup") : isBulk ? T(state.bulkMode === "revoke" ? "bulkRevoke" : "bulkGrant") : T("share");
  let body = kind === "effective" ? `${effectiveSummary(item, null)}<div class="notice"><strong>${esc(T("conceptual"))}</strong><p>${esc(T("teamBoundary"))}</p></div>` : kind === "group" ? `<div class="field"><label for="group-name">${esc(T("groupName"))}</label><input id="group-name" maxlength="48" data-action="group-draft" value="${esc(state.groupDraft)}" placeholder="Support L1"></div><p class="hint">${esc(T("demoOnly"))}</p>` : isBulk && state.bulkMode === "revoke" ? renderRevokeBody() : renderShareBody(item, isBulk);
  const canRevoke = isBulk && state.bulkMode === "revoke" && revokePreview(model(), [...state.bulkSelected], state.recipient, state.revokeGrantId).removedGrantIds.length > 0;
  const canGrant = !state.customMode || state.customActions.size > 0;
  const primary = kind === "effective" ? "" : kind === "group" ? `<button type="button" class="button primary" data-action="group-add">${esc(T("addGroup"))}</button>` : isBulk && state.bulkMode === "revoke" ? `<button type="button" class="button danger" data-action="bulk-apply" ${canRevoke ? "" : "disabled"}>${esc(T("bulkRevoke"))}</button>` : `<button type="button" class="button ${state.preview ? "primary" : ""}" data-action="${state.preview ? "apply-grant" : "preview-grant"}" ${canGrant ? "" : "disabled"}>${esc(T(state.preview ? "applyDemo" : "preview"))}</button>`;
  return `<div class="scrim" data-action="scrim"><section class="dialog" role="dialog" aria-modal="true" aria-label="${esc(title)}"><div class="dialog-head"><div class="eyebrow">${esc(T("concept"))}</div><h2>${esc(title)}${kind === "share" || kind === "effective" ? ` · ${esc(item.title)}` : ""}</h2><p>${esc(T("demoOnly"))}</p></div><div class="dialog-body">${body}</div><div class="dialog-foot"><button type="button" class="button" data-action="close-dialog">${esc(T(kind === "effective" ? "close" : "cancel"))}</button>${primary}</div></section></div>`;
}
function render() {
  document.documentElement.lang = state.locale;
  document.body.dataset.theme = state.theme;
  document.getElementById("app").innerHTML = state.surface === "mac" ? renderMac() : renderCloud();
}
function notify(message) { state.toast = message; render(); window.setTimeout(() => { if (state.toast === message) { state.toast = ""; render(); } }, 3500); }
function openDialog(kind, id = state.selectedResource) { state.selectedResource = id; state.dialog = kind; state.context = null; state.preview = false; state.customMode = false; state.customActions = new Set(); render(); window.requestAnimationFrame(() => document.querySelector(".dialog button, .dialog select, .dialog input")?.focus()); }
function handleAction(action, value, target) {
  if (["surface", "locale", "theme", "perspective"].includes(action)) { state[action] = value; state.context = null; state.cloudPage = 0; if (action === "surface" && value === "mac") state.volume = 6; render(); return; }
  if (action === "volume") { state.volume = Number(value); state.cloudPage = 0; state.cloudQuery = ""; state.bulkSelected.clear(); render(); return; }
  if (action === "cloud-page") { state.cloudPage = Math.max(0, state.cloudPage + (value === "next" ? 1 : -1)); render(); return; }
  if (action === "mac-section") { state.macSection = value; state.query = ""; state.selectedResource = resources.find((r) => r.type === ({ hosts: "host", credentials: "credential", snippets: "snippet", folders: "folder" })[value])?.id ?? state.selectedResource; render(); return; }
  if (action === "cloud-section") { state.cloudSection = value; state.cloudPage = 0; state.cloudQuery = ""; render(); return; }
  if (action === "select-resource") { state.selectedResource = value; render(); return; }
  if (action === "select-principal") { state.selectedPrincipal = value; render(); return; }
  if (action === "share" || action === "effective") { openDialog(action, value); return; }
  if (action === "close-dialog" || action === "scrim") { if (action === "scrim" && target.closest(".dialog")) return; state.dialog = null; state.context = null; render(); return; }
  if (action === "preset") { state.preset = value; state.customMode = false; state.preview = false; render(); return; }
  if (action === "custom") { state.customMode = !state.customMode; state.customActions = new Set(); state.preview = false; render(); return; }
  if (action === "custom-action") { if (target.checked) state.customActions.add(value); else state.customActions.delete(value); state.preview = false; render(); return; }
  if (action === "preview-grant") { state.preview = true; render(); return; }
  if (action === "apply-grant") { const ids = state.dialog === "bulk" ? [...state.bulkSelected] : [state.selectedResource]; for (const id of ids) { const item = resource(id); const actions = state.customMode ? activeActions(item) : presetFor(item.type, presetOptions(ids.map(resource)).some(([key]) => key === state.preset) ? state.preset : "view"); if (actions.length) state.grants.push({ id: `grant-${Date.now()}-${Math.random()}`, resourceId: id, recipient: state.recipient, actions, expiry: state.expiry }); } state.dialog = null; notify(T("changed")); return; }
  if (action === "remove-grant") { const grant = state.grants.find((entry) => entry.id === value); if (!grant) return; state.bulkSelected = new Set([grant.resourceId]); state.recipient = grant.recipient; state.revokeGrantId = grant.id; state.bulkMode = "revoke"; openDialog("bulk", grant.resourceId); return; }
  if (action === "bulk-select") { if (target.checked) state.bulkSelected.add(value); else state.bulkSelected.delete(value); render(); return; }
  if (action === "bulk-open") { if (!state.bulkSelected.size) { notify(T("bulkEmpty")); return; } state.bulkMode = value; state.revokeGrantId = null; openDialog("bulk"); return; }
  if (action === "bulk-apply") { const result = revokePreview(model(), [...state.bulkSelected], state.recipient, state.revokeGrantId); if (!result.removedGrantIds.length) return; state.grants = result.remainingGrants; state.revokeGrantId = null; state.dialog = null; notify(T("revoked")); return; }
  if (action === "new-group") { state.groupDraft = ""; openDialog("group"); return; }
  if (action === "group-add") { const name = state.groupDraft.trim().slice(0, 48); if (!name) { document.getElementById("group-name")?.focus(); return; } const id = `group-demo-${Date.now()}`; state.groups.push({ id, name, memberIds: [] }); state.selectedPrincipal = id; state.dialog = null; notify(T("groupAdded")); }
}
document.addEventListener("click", (event) => {
  const target = event.target.closest("[data-action]");
  if (!target) { if (state.context) { state.context = null; render(); } return; }
  const action = target.dataset.action;
  if (["search", "cloud-search", "recipient", "expiry", "group-draft", "bulk-select", "custom-action"].includes(action)) return;
  event.preventDefault(); event.stopPropagation(); handleAction(action, target.dataset.value, target);
});
document.addEventListener("change", (event) => {
  const { action, value } = event.target.dataset;
  if (action === "recipient") { state.recipient = event.target.value; state.preview = false; render(); }
  else if (action === "expiry") { state.expiry = event.target.value; state.preview = false; render(); }
  else if (action === "bulk-select") handleAction(action, value, event.target);
  else if (action === "custom-action") handleAction(action, value, event.target);
});
document.addEventListener("input", (event) => {
  const action = event.target.dataset.action;
  if (action === "search") { state.query = event.target.value; const pos = event.target.selectionStart; render(); const input = document.querySelector('[data-action="search"]'); input?.focus(); input?.setSelectionRange(pos, pos); }
  if (action === "cloud-search") { state.cloudQuery = event.target.value; state.cloudPage = 0; const pos = event.target.selectionStart; render(); const input = document.querySelector('[data-action="cloud-search"]'); input?.focus(); input?.setSelectionRange(pos, pos); }
  if (action === "group-draft") state.groupDraft = event.target.value;
});
document.addEventListener("contextmenu", (event) => {
  const row = event.target.closest("[data-resource]");
  if (!row || state.surface !== "mac") return;
  event.preventDefault(); state.selectedResource = row.dataset.resource;
  state.context = { id: row.dataset.resource, x: Math.min(event.clientX, innerWidth - 220), y: Math.min(event.clientY, innerHeight - 96) };
  render();
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") { if (state.dialog || state.context) { state.dialog = null; state.context = null; render(); } return; }
  if ((event.key === "Enter" || event.key === " ") && event.target.matches('[role="button"][data-action]')) { event.preventDefault(); handleAction(event.target.dataset.action, event.target.dataset.value, event.target); }
  if ((event.key === "Enter" || event.key === " ") && event.target.matches("[data-resource]")) { event.preventDefault(); openDialog("effective", event.target.dataset.resource); }
});
render();
