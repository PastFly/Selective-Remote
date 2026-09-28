import {
  createNotificationState, markNotificationRead, notificationCounts, notificationItems,
  reconcileNotifications, serializeNotificationState,
} from "./notification-projection.js";

const copy = {
  deviceApproval: {
    en: ["Device waiting for approval", "Review its key before approving.", "Review Device"],
    ru: ["Устройство ожидает одобрения", "Проверьте ключ перед одобрением.", "Проверить устройство"],
  },
  invitation: {
    en: ["Team invitation", "An invitation awaits your decision.", "Open Invitation"],
    ru: ["Приглашение в команду", "Приглашение ожидает вашего решения.", "Открыть приглашение"],
  },
  syncError: {
    en: ["Sync needs attention", "Changes are not confirmed on this device.", "Open Sync"],
    ru: ["Синхронизация требует внимания", "Изменения не подтверждены на этом устройстве.", "Открыть Sync"],
  },
  conflict: {
    en: ["Conflict needs review", "Choose a version in the existing resolver.", "Review Conflict"],
    ru: ["Конфликт требует проверки", "Выберите версию в существующем мастере.", "Проверить конфликт"],
  },
  failClosed: {
    en: ["Team Vault needs attention", "Team Vaults remain safely hidden.", "Review Team"],
    ru: ["Командному Vault требуется внимание", "Командные Vaults остаются безопасно скрытыми.", "Проверить команду"],
  },
  wrapperIssue: {
    en: ["Team key access needs attention", "Review device access in Team management.", "Review Access"],
    ru: ["Требуется доступ к ключу команды", "Проверьте доступ устройства в управлении командой.", "Проверить доступ"],
  },
};

export function notificationCopy(item, locale = "ru") {
  const [title, detail, action] = (copy[item.kind] ?? copy.syncError)[locale === "en" ? "en" : "ru"];
  return { title, detail, action };
}

export function visibleNotifications(items, filter = "all") {
  if (filter === "needsAction") return items.filter((item) => item.resolvedAt === null);
  if (filter === "sync") return items.filter((item) => ["syncError", "conflict", "failClosed", "wrapperIssue"].includes(item.kind));
  if (filter === "security") return items.filter((item) => ["deviceApproval", "failClosed", "wrapperIssue"].includes(item.kind));
  return items;
}

export function notificationBadge(count) {
  return count > 9 ? "9+" : count > 0 ? String(count) : "";
}

export function createNotificationCenter({ documentValue, onRoute }) {
  const root = documentValue.querySelector("#workspace-notification-details");
  const summary = documentValue.querySelector("#workspace-notification-summary");
  const badge = documentValue.querySelector("#workspace-notification-badge");
  const title = documentValue.querySelector("#workspace-notification-title");
  const unread = documentValue.querySelector("#workspace-notification-unread");
  const list = documentValue.querySelector("#workspace-notification-list");
  let storage;
  try { storage = documentValue.defaultView?.localStorage; }
  catch { storage = null; }
  if (!root || !summary || !badge || !list) return { sessionChanged() {}, observe() {}, render() {} };

  let state = null;
  let currentRecipient = null;
  let filter = "all";
  let storageKey = null;
  let lastPersistedAt = 0;
  const locale = () => documentValue.documentElement?.lang === "en" ? "en" : "ru";
  const now = () => new Date().toISOString();

  function persist(force = false) {
    if (!state || !storageKey || (!force && Date.now() - lastPersistedAt < 300_000)) return;
    try { storage?.setItem(storageKey, serializeNotificationState(state)); lastPersistedAt = Date.now(); }
    catch { /* Storage unavailable: current-session attention remains visible. */ }
  }

  function render() {
    const english = locale() === "en";
    const counts = state ? notificationCounts(state) : { attentionCount: 0, unreadCount: 0 };
    badge.textContent = notificationBadge(counts.attentionCount);
    badge.hidden = counts.attentionCount === 0;
    summary.setAttribute("aria-label", english
      ? `Notifications, ${counts.attentionCount} need attention`
      : `Уведомления: требуют внимания ${counts.attentionCount}`);
    if (title) title.textContent = english ? "Notifications" : "Уведомления";
    if (unread) unread.textContent = english
      ? `${counts.unreadCount} unread` : `Непрочитанных: ${counts.unreadCount}`;
    const filterNames = english
      ? { all: "All", needsAction: "Needs Action", sync: "Sync", security: "Security" }
      : { all: "Все", needsAction: "Требуют действия", sync: "Sync", security: "Безопасность" };
    for (const button of root.querySelectorAll("[data-notification-filter]")) {
      const value = button.dataset.notificationFilter;
      button.textContent = filterNames[value] ?? value;
      button.setAttribute("aria-pressed", String(filter === value));
    }
    list.replaceChildren();
    const items = visibleNotifications(state ? notificationItems(state) : [], filter).slice(0, 20);
    if (!items.length) {
      const empty = documentValue.createElement("p");
      empty.className = "notification-empty";
      empty.textContent = english ? "You're all caught up. No items need your attention."
        : "Всё в порядке. Нет событий, требующих вашего внимания.";
      list.append(empty);
      return;
    }
    for (const item of items) {
      const article = documentValue.createElement("article");
      article.className = "notification-card";
      article.dataset.read = String(item.readAt !== null);
      article.dataset.resolved = String(item.resolvedAt !== null);
      const heading = documentValue.createElement("strong");
      const detail = documentValue.createElement("p");
      const actions = documentValue.createElement("div");
      const route = documentValue.createElement("button");
      const read = documentValue.createElement("button");
      const labels = notificationCopy(item, locale());
      heading.textContent = labels.title;
      detail.textContent = labels.detail;
      route.type = "button"; route.textContent = labels.action;
      route.disabled = item.resolvedAt !== null;
      route.addEventListener("click", () => {
        state = markNotificationRead(state, item.id, now());
        persist(true); render(); root.open = false;
        onRoute?.(item);
      });
      actions.append(route);
      if (item.readAt === null && item.resolvedAt === null) {
        read.type = "button";
        read.className = "secondary";
        read.textContent = english ? "Mark read" : "Отметить прочитанным";
        read.addEventListener("click", () => {
          state = markNotificationRead(state, item.id, now());
          persist(true); render();
        });
        actions.append(read);
      }
      article.append(heading, detail, actions);
      list.append(article);
    }
  }

  for (const button of root.querySelectorAll("[data-notification-filter]")) {
    button.addEventListener("click", () => { filter = button.dataset.notificationFilter; render(); });
  }
  root.addEventListener("keydown", (event) => {
    if (event.key === "Escape") { root.open = false; summary.focus(); }
  });
  root.addEventListener("click", (event) => event.stopPropagation());
  documentValue.addEventListener("click", (event) => {
    if (root.open && !root.contains(event.target)) root.open = false;
  });

  return {
    sessionChanged(user) {
      root.open = false;
      if (!user?.id) { state = null; storageKey = null; currentRecipient = null; render(); return; }
      if (user.id === currentRecipient) { render(); return; }
      currentRecipient = user.id;
      storageKey = `selective-remote.notifications.v1:${user.id}`;
      let saved = null;
      try { saved = storage?.getItem(storageKey); } catch { /* unavailable */ }
      try { state = createNotificationState(user.id, saved); }
      catch { state = null; storageKey = null; }
      render();
    },
    observe(detail) {
      if (!state || !detail || detail.recipient !== currentRecipient) return;
      const before = JSON.stringify(state.items.map((item) => [item.id, item.readAt, item.resolvedAt]));
      state = reconcileNotifications(state, detail);
      const after = JSON.stringify(state.items.map((item) => [item.id, item.readAt, item.resolvedAt]));
      persist(before !== after);
      if (before !== after || root.open) render();
    },
    render,
  };
}
