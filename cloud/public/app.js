import { createIndexedDBVaultRepository, createLocalVaultController } from "./vault-local.js";
import { createAuthenticatedVaultClient, synchronizeVault } from "./vault-sync.js";
import {
  createIndexedDBTeamDeviceRepository,
  ensureTeamDeviceIdentity,
  teamDevicePublicKeyFingerprint,
} from "./team-vault-crypto.js";
import {
  createIndexedDBTeamVaultRepository,
  createTeamVaultController,
  provisionTeamVaultWrappers,
  rotateTeamVault,
  synchronizeTeamVault,
} from "./team-vault-sync.js";

const verificationPrefix = "#verify-email?";
const passwordResetPrefix = "#reset-password?";
const teamInvitationPrefix = "#accept-team-invitation?";

function consumeTokenFragment(prefix, locationValue, historyValue) {
  const hash = String(locationValue.hash ?? "");
  if (!hash.startsWith(prefix)) return { present: false, token: null };
  historyValue.replaceState(null, "", `${locationValue.pathname}${locationValue.search}`);
  const token = new URLSearchParams(hash.slice(prefix.length)).get("token");
  return {
    present: true,
    token: token && token.length <= 256 ? token : null,
  };
}

export function consumeVerificationFragment(locationValue, historyValue) {
  return consumeTokenFragment(verificationPrefix, locationValue, historyValue);
}

export function consumePasswordResetFragment(locationValue, historyValue) {
  return consumeTokenFragment(passwordResetPrefix, locationValue, historyValue);
}

export function consumeTeamInvitationFragment(locationValue, historyValue) {
  return consumeTokenFragment(teamInvitationPrefix, locationValue, historyValue);
}

export async function submitEmailVerification(token, fetchValue = fetch) {
  const response = await fetchValue("/v1/auth/verify-email", {
    method: "POST",
    headers: { Accept: "application/json", "Content-Type": "application/json" },
    body: JSON.stringify({ token }),
    cache: "no-store",
    credentials: "omit",
    referrerPolicy: "no-referrer",
  });
  if (!response.ok) throw new Error("invalid_verification_token");
  const result = await response.json();
  if (result?.verified !== true) throw new Error("invalid_verification_token");
}

export async function submitPasswordReset(token, password, fetchValue = fetch) {
  const response = await fetchValue("/v1/auth/reset-password", {
    method: "POST",
    headers: { Accept: "application/json", "Content-Type": "application/json" },
    body: JSON.stringify({ token, password }),
    cache: "no-store",
    credentials: "omit",
    referrerPolicy: "no-referrer",
  });
  if (!response.ok) throw new Error("password_reset_failed");
  const result = await response.json();
  if (result?.reset !== true) throw new Error("password_reset_failed");
}

export function localVaultRecordData(type, { title, target, secret }) {
  const normalizedTitle = String(title ?? "").trim();
  const normalizedTarget = String(target ?? "").trim();
  const normalizedSecret = String(secret ?? "");
  if (!normalizedTitle || normalizedTitle.length > 120 || normalizedTarget.length > 2048 || normalizedSecret.length > 32_768) {
    throw new Error("invalid_local_record");
  }
  if (type === "host" && normalizedTarget) return { title: normalizedTitle, address: normalizedTarget };
  if (type === "credential" && normalizedTarget && normalizedSecret) {
    return { title: normalizedTitle, username: normalizedTarget, secret: normalizedSecret };
  }
  if (type === "snippet" && normalizedSecret) return { title: normalizedTitle, body: normalizedSecret };
  if (type === "forwarding" && normalizedTarget) {
    return { title: normalizedTitle, destination: normalizedTarget, configuration: normalizedSecret };
  }
  throw new Error("invalid_local_record");
}

export function teamHostRecordData({ title, target, folder, tags, description, baseData = null }) {
  const data = localVaultRecordData("host", { title, target, secret: "" });
  const normalizedFolder = String(folder ?? "").trim();
  const normalizedDescription = String(description ?? "").trim();
  const normalizedTags = [...new Set(String(tags ?? "").split(",").map((value) => value.trim()).filter(Boolean))];
  if (normalizedFolder.length > 120 || normalizedDescription.length > 2048
    || normalizedTags.some((value) => value.length > 64) || normalizedTags.length > 24) {
    throw new Error("invalid_team_host_organization");
  }
  if (normalizedFolder) data.folder = normalizedFolder;
  if (normalizedTags.length) data.tags = normalizedTags;
  if (normalizedDescription) data.description = normalizedDescription;
  if (baseData?.profile) {
    if (String(baseData.title ?? "") !== data.title || String(baseData.address ?? "") !== data.address) {
      throw new Error("advanced_team_host_requires_native_editor");
    }
    for (const key of ["username", "connectionType", "profile"]) data[key] = baseData[key];
  }
  return data;
}

export function localVaultRecordSummary(record) {
  const data = record?.data ?? {};
  let summary = "";
  if (record?.type === "host") summary = String(data.address ?? "");
  if (record?.type === "credential") summary = `${String(data.username ?? "")} · секрет скрыт`;
  if (record?.type === "snippet") summary = String(data.body ?? "");
  if (record?.type === "forwarding") summary = String(data.destination ?? "");
  return summary.length > 240 ? `${summary.slice(0, 237)}…` : summary;
}

export function localVaultConflictSideSummary(entity) {
  if (entity?.kind === "tombstone") return `Удалено · ${String(entity.value?.deletedAt ?? "")}`;
  if (entity?.kind !== "record") throw new Error("invalid_vault_conflict");
  const title = String(entity.value?.data?.title ?? "Без названия");
  const boundedTitle = title.length > 120 ? `${title.slice(0, 117)}…` : title;
  return `${boundedTitle} · ${String(entity.value?.type ?? "record")} · ${String(entity.value?.modifiedAt ?? "")}`;
}

export function teamVaultRecoveryMode({
  outcomeStatus = null,
  wrapperProvisioningFailed = false,
  errorCode = null,
} = {}) {
  const code = String(errorCode ?? "");
  if (code === "team_vault_rotation_required" || outcomeStatus === "conflict") return "none";
  if (code === "team_vault_key_unavailable") return "access";
  if (code) return "synchronize";
  if (wrapperProvisioningFailed) return "wrappers";
  return "none";
}

function setText(element, value) {
  if (element) element.textContent = value;
}

export async function initializeLocalVault({
  documentValue = document,
  repository = createIndexedDBVaultRepository(),
  confirmValue = (message) => globalThis.confirm(message),
} = {}) {
  const section = documentValue.querySelector("#local-vault");
  if (!section) return null;
  const setup = documentValue.querySelector("#local-vault-setup");
  const unlock = documentValue.querySelector("#local-vault-unlock");
  const workspace = documentValue.querySelector("#local-vault-workspace");
  const message = documentValue.querySelector("#local-vault-message");
  const records = documentValue.querySelector("#local-vault-records");
  const setupForm = documentValue.querySelector("#local-vault-setup-form");
  const unlockForm = documentValue.querySelector("#local-vault-unlock-form");
  const recordForm = documentValue.querySelector("#local-vault-record-form");
  const lockButton = documentValue.querySelector("#local-vault-lock");
  const type = documentValue.querySelector("#local-record-type");
  const title = documentValue.querySelector("#local-record-title");
  const target = documentValue.querySelector("#local-record-target");
  const secret = documentValue.querySelector("#local-record-secret");
  const targetLabel = documentValue.querySelector("#local-record-target-label");
  const secretLabel = documentValue.querySelector("#local-record-secret-label");
  const recoveryPanel = documentValue.querySelector("#cloud-vault-recovery");
  const recoveryForm = documentValue.querySelector("#cloud-vault-recovery-form");
  const conflictPanel = documentValue.querySelector("#local-vault-conflicts");
  const conflictForm = documentValue.querySelector("#local-vault-conflicts-form");
  const conflictList = documentValue.querySelector("#local-vault-conflicts-list");
  const hostDetail = documentValue.querySelector("#host-detail-dialog");
  const hostDetailTitle = documentValue.querySelector("#host-detail-title");
  const hostDetailAddress = documentValue.querySelector("#host-detail-address");
  const hostDetailModified = documentValue.querySelector("#host-detail-modified");
  const hostDetailFolder = documentValue.querySelector("#host-detail-folder");
  const hostDetailTags = documentValue.querySelector("#host-detail-tags");
  const hostDetailDescription = documentValue.querySelector("#host-detail-description");
  const hostDetailEdit = documentValue.querySelector("#host-detail-edit");
  const filterButtons = [...documentValue.querySelectorAll("#personal-vault-filters [data-record-filter]")];
  const controller = createLocalVaultController({ repository });
  let conflictResetListener = () => {};
  let activeRecordFilter = "all";

  function clearConflictUI() {
    conflictPanel.hidden = true;
    conflictForm.reset();
    conflictList.replaceChildren();
    for (const control of recordForm.querySelectorAll("input, select, textarea, button")) control.disabled = false;
    for (const button of records.querySelectorAll("button")) button.disabled = false;
    conflictResetListener();
  }

  function setConflictMode(active) {
    for (const control of recordForm.querySelectorAll("input, select, textarea, button")) control.disabled = active;
    for (const button of records.querySelectorAll("button")) button.disabled = active;
  }

  function hideRecovery() {
    recoveryPanel.hidden = true;
    recoveryForm.reset();
  }

  function mode(value) {
    setup.hidden = value !== "empty";
    unlock.hidden = value !== "locked";
    workspace.hidden = value !== "unlocked";
  }

  function updateLabels() {
    const labels = {
      host: ["Адрес", "Дополнительные данные не требуются"],
      credential: ["Имя пользователя", "Секрет"],
      snippet: ["Не используется", "Текст Snippet"],
      forwarding: ["Назначение", "Параметры"],
    };
    const [targetText, secretText] = labels[type.value] ?? labels.host;
    setText(targetLabel, targetText);
    setText(secretLabel, secretText);
    target.required = type.value !== "snippet";
    secret.required = type.value === "credential" || type.value === "snippet";
  }

  function render() {
    const current = controller.document();
    const counts = { host: 0, credential: 0, snippet: 0, forwarding: 0 };
    for (const record of current.records) {
      if (Object.hasOwn(counts, record.type)) counts[record.type] += 1;
    }
    for (const [recordType, count] of Object.entries(counts)) {
      setText(documentValue.querySelector(`#workspace-${recordType}-count`), String(count));
    }
    const visibleRecords = activeRecordFilter === "all"
      ? current.records
      : current.records.filter((record) => record.type === activeRecordFilter);
    records.replaceChildren();
    if (visibleRecords.length === 0) {
      const empty = documentValue.createElement("p");
      empty.className = "vault-empty";
      empty.textContent = current.records.length === 0
        ? "Personal Vault пока пуст. Данные появятся после первой синхронизации с Mac или ручного добавления."
        : "Записей этого типа пока нет.";
      records.append(empty);
      return;
    }
    for (const record of visibleRecords) {
      const card = documentValue.createElement("article");
      const heading = documentValue.createElement("h4");
      const summary = documentValue.createElement("p");
      const metadata = documentValue.createElement("small");
      const remove = documentValue.createElement("button");
      heading.textContent = String(record.data.title ?? "Без названия");
      summary.textContent = localVaultRecordSummary(record);
      metadata.textContent = `${record.type} · ${record.modifiedAt}`;
      remove.type = "button";
      remove.className = "danger";
      remove.textContent = "Удалить";
      remove.addEventListener("click", async () => {
        if (!confirmValue(`Удалить «${heading.textContent}»?`)) return;
        remove.disabled = true;
        try {
          await controller.delete(record.id);
          clearConflictUI();
          setText(message, "Запись удалена. Tombstone сохранён в зашифрованном Vault.");
          render();
        } catch {
          setText(message, "Не удалось сохранить удаление.");
          remove.disabled = false;
        }
      });
      if (record.type === "host") {
        card.classList.add("resource-card", "resource-card-clickable");
        card.tabIndex = 0;
        card.setAttribute("role", "button");
        card.setAttribute("aria-label", `Открыть Host ${heading.textContent}`);
        const openHost = () => {
          setText(hostDetailTitle, String(record.data.title ?? "Host"));
          setText(hostDetailAddress, String(record.data.address ?? "—"));
          setText(hostDetailModified, String(record.modifiedAt ?? "—"));
          setText(hostDetailFolder, "Личный Vault");
          setText(hostDetailTags, "—");
          setText(hostDetailDescription, "—");
          hostDetailEdit.hidden = true;
          hostDetail?.showModal();
        };
        card.addEventListener("click", (event) => {
          if (event.target === remove) return;
          openHost();
        });
        card.addEventListener("keydown", (event) => {
          if (event.key !== "Enter" && event.key !== " ") return;
          event.preventDefault();
          openHost();
        });
      }
      card.append(heading, summary, metadata, remove);
      records.append(card);
    }
  }

  setupForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const passphrase = setupForm.elements.passphrase.value;
    const confirmation = setupForm.elements.confirmation.value;
    if (passphrase !== confirmation) {
      setText(message, "Recovery-фразы не совпадают.");
      return;
    }
    const button = setupForm.querySelector("button");
    button.disabled = true;
    try {
      await controller.create(passphrase);
      setupForm.reset();
      hideRecovery();
      clearConflictUI();
      mode("unlocked");
      setText(message, "Локальный Vault создан и разблокирован только в памяти этой вкладки.");
      render();
    } catch {
      setText(message, "Не удалось создать Vault. Проверьте recovery-фразу и доступ к локальному хранилищу.");
      button.disabled = false;
    }
  });

  unlockForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = unlockForm.querySelector("button");
    button.disabled = true;
    try {
      await controller.unlock(unlockForm.elements.passphrase.value);
      unlockForm.reset();
      button.disabled = false;
      mode("unlocked");
      clearConflictUI();
      setText(message, "Vault расшифрован локально. Ключ существует только в памяти вкладки.");
      render();
    } catch {
      setText(message, "Не удалось разблокировать Vault. Recovery-фраза неверна или данные повреждены.");
      button.disabled = false;
    }
  });

  recordForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = recordForm.querySelector("button");
    button.disabled = true;
    try {
      await controller.upsert({
        type: type.value,
        data: localVaultRecordData(type.value, { title: title.value, target: target.value, secret: secret.value }),
      });
      recordForm.reset();
      clearConflictUI();
      updateLabels();
      setText(message, "Запись локально зашифрована и сохранена.");
      render();
    } catch {
      setText(message, "Не удалось сохранить запись. Заполните обязательные поля.");
    } finally {
      button.disabled = false;
    }
  });

  type.addEventListener("change", updateLabels);
  for (const button of filterButtons) {
    button.addEventListener("click", () => {
      activeRecordFilter = button.dataset.recordFilter || "all";
      for (const candidate of filterButtons) {
        candidate.classList.toggle("active", candidate === button);
      }
      if (!workspace.hidden) render();
    });
  }
  lockButton.addEventListener("click", () => {
    controller.lock();
    hideRecovery();
    clearConflictUI();
    mode("locked");
    records.replaceChildren();
    setText(message, "Vault заблокирован; ключ удалён из состояния страницы.");
  });

  updateLabels();
  try {
    mode(await controller.status());
    setText(message, "Данные зашифрованы локально; браузер разблокирует Vault только на этом устройстве.");
  } catch {
    setup.hidden = true;
    unlock.hidden = true;
    workspace.hidden = true;
    setText(message, "Локальное защищённое хранилище недоступно в этом браузере.");
  }
  return {
    controller,
    mode,
    render,
    clearConflictUI,
    setConflictMode,
    setFilter(value) {
      activeRecordFilter = ["all", "host", "credential", "snippet", "forwarding"].includes(value) ? value : "all";
      for (const button of filterButtons) {
        button.classList.toggle("active", button.dataset.recordFilter === activeRecordFilter);
      }
      if (!workspace.hidden) render();
    },
    setConflictResetListener(listener) {
      conflictResetListener = typeof listener === "function" ? listener : () => {};
    },
    showRecovery() {
      setup.hidden = true;
      unlock.hidden = true;
      workspace.hidden = true;
      recoveryPanel.hidden = false;
      recoveryForm.elements.passphrase.focus();
    },
    async hideRecoveryAndRestoreMode() {
      hideRecovery();
      mode(await controller.status());
    },
  };
}

export function initializeTeamWorkspace({
  documentValue = document,
  client,
  confirmValue = (message) => globalThis.confirm(message),
  initialInvitationToken = null,
  setIntervalValue = globalThis.setInterval,
  clearIntervalValue = globalThis.clearInterval,
  backgroundSyncIntervalMilliseconds = 15_000,
} = {}) {
  const section = documentValue.querySelector("#team-vault");
  if (!section || !client) return null;
  const sectionTitle = documentValue.querySelector("#team-vault-title");
  const message = documentValue.querySelector("#team-vault-message");
  const devices = documentValue.querySelector("#team-devices");
  const devicesRefresh = documentValue.querySelector("#team-devices-refresh");
  const createTeamForm = documentValue.querySelector("#team-create-form");
  const acceptInvitationForm = documentValue.querySelector("#team-invitation-accept-form");
  const pendingInvitations = documentValue.querySelector("#team-pending-invitations");
  const onboarding = documentValue.querySelector("#team-onboarding");
  const teamSelect = documentValue.querySelector("#team-select");
  const teamRefresh = documentValue.querySelector("#team-refresh");
  const selectedPanel = documentValue.querySelector("#team-selected");
  const teamRole = documentValue.querySelector("#team-role");
  const members = documentValue.querySelector("#team-members");
  const membersView = documentValue.querySelector("#team-members-view");
  const inviteForm = documentValue.querySelector("#team-invite-form");
  const inviteLinkCreate = documentValue.querySelector("#team-invite-link-create");
  const inviteLinkResult = documentValue.querySelector("#team-invite-link-result");
  const inviteLinkValue = documentValue.querySelector("#team-invite-link-value");
  const inviteLinkCopy = documentValue.querySelector("#team-invite-link-copy");
  const activeInvitations = documentValue.querySelector("#team-active-invitations");
  const lifecyclePanel = documentValue.querySelector("#team-lifecycle");
  const renameTeamForm = documentValue.querySelector("#team-rename-form");
  const transferOwnershipForm = documentValue.querySelector("#team-ownership-transfer-form");
  const transferOwnershipMember = documentValue.querySelector("#team-ownership-member");
  const archiveTeamForm = documentValue.querySelector("#team-archive-form");
  const createVaultForm = documentValue.querySelector("#team-vault-create-form");
  const vaultDirectoryView = documentValue.querySelector("#team-vault-directory-view");
  const vaultSelect = documentValue.querySelector("#team-vault-select");
  const vaultOpen = documentValue.querySelector("#team-vault-open");
  const workspace = documentValue.querySelector("#team-vault-workspace");
  const workspaceTitle = documentValue.querySelector("#team-vault-workspace-title");
  const workspaceStatus = documentValue.querySelector("#team-vault-workspace-status");
  const syncButton = documentValue.querySelector("#team-vault-sync");
  const rotateButton = documentValue.querySelector("#team-vault-rotate");
  const grantWrappersButton = documentValue.querySelector("#team-vault-grant-wrappers");
  const lockButton = documentValue.querySelector("#team-vault-lock");
  const recordForm = documentValue.querySelector("#team-vault-record-form");
  const recordEditor = documentValue.querySelector("#team-record-editor");
  const recordEditorSummary = documentValue.querySelector("#team-record-editor-summary");
  const recordType = documentValue.querySelector("#team-record-type");
  const recordTitle = documentValue.querySelector("#team-record-title");
  const recordTarget = documentValue.querySelector("#team-record-target");
  const recordSecret = documentValue.querySelector("#team-record-secret");
  const recordTargetLabel = documentValue.querySelector("#team-record-target-label");
  const recordSecretLabel = documentValue.querySelector("#team-record-secret-label");
  const records = documentValue.querySelector("#team-vault-records");
  const hostFields = documentValue.querySelector("#team-host-fields");
  const hostFolder = documentValue.querySelector("#team-host-folder");
  const hostFolderOptions = documentValue.querySelector("#team-host-folder-options");
  const hostTags = documentValue.querySelector("#team-host-tags");
  const hostDescription = documentValue.querySelector("#team-host-description");
  const hostBrowser = documentValue.querySelector("#team-host-browser");
  const hostSearch = documentValue.querySelector("#team-host-search");
  const hostFolderFilter = documentValue.querySelector("#team-host-folder-filter");
  const hostDetail = documentValue.querySelector("#host-detail-dialog");
  const hostDetailTitle = documentValue.querySelector("#host-detail-title");
  const hostDetailAddress = documentValue.querySelector("#host-detail-address");
  const hostDetailModified = documentValue.querySelector("#host-detail-modified");
  const hostDetailFolder = documentValue.querySelector("#host-detail-folder");
  const hostDetailTags = documentValue.querySelector("#host-detail-tags");
  const hostDetailDescription = documentValue.querySelector("#host-detail-description");
  const hostDetailCopy = documentValue.querySelector("#host-detail-copy");
  const hostDetailEdit = documentValue.querySelector("#host-detail-edit");
  const conflictPanel = documentValue.querySelector("#team-vault-conflicts");
  const conflictForm = documentValue.querySelector("#team-vault-conflicts-form");
  const conflictList = documentValue.querySelector("#team-vault-conflicts-list");
  const conflictApply = documentValue.querySelector("#team-vault-conflicts-apply");
  let identity = null;
  let teams = [];
  let vaults = [];
  let teamMembers = [];
  let teamInvitations = [];
  let accountInvitations = [];
  let selectedTeam = null;
  let selectedVault = null;
  let controller = null;
  let activeConflicts = null;
  let activeView = "teams";
  let backgroundSyncTimer = null;
  let vaultOperation = null;
  let editingHostID = null;
  let detailedHostID = null;

  if (initialInvitationToken) acceptInvitationForm.elements.token.value = initialInvitationToken;

  function canManage() {
    return ["owner", "admin"].includes(selectedTeam?.role);
  }

  function canEdit() {
    return ["owner", "admin", "editor"].includes(selectedTeam?.role);
  }

  function setRecoveryControls(mode = "none") {
    const retriesSynchronization = mode === "synchronize" || mode === "access";
    syncButton.hidden = !retriesSynchronization;
    syncButton.disabled = !retriesSynchronization || !controller;
    syncButton.textContent = mode === "access"
      ? "Проверить доступ снова"
      : "Повторить безопасную синхронизацию";
    grantWrappersButton.hidden = mode !== "wrappers";
    grantWrappersButton.disabled = mode !== "wrappers" || !controller || selectedVault?.rotationRequired;
  }

  function updateTeamMessage() {
    if (!selectedTeam) return;
    if (activeView === "teams") {
      setText(message, `Team «${selectedTeam.name}» · участников: ${teamMembers.length}.`);
    } else if (activeView === "members") {
      setText(message, `Команда «${selectedTeam.name}» · участники и приглашения.`);
    } else if (activeView === "management") {
      setText(message, `Команда «${selectedTeam.name}» · управление.`);
    } else if (activeView === "vaults") {
      setText(message, `Команда «${selectedTeam.name}» · папок: ${vaults.length}.`);
    } else {
      setText(message, selectedVault
        ? `Команда «${selectedTeam.name}» · папка «${selectedVault.name}».`
        : `Команда «${selectedTeam.name}» · выберите папку для просмотра хостов.`);
    }
  }

  function setWorkspaceControls(disabled) {
    for (const control of recordForm.querySelectorAll("input, select, textarea, button")) {
      control.disabled = disabled || !canEdit();
    }
    for (const button of records.querySelectorAll("button")) button.disabled = disabled || !canEdit();
    recordType.disabled = disabled || !canEdit() || activeView === "hosts";
  }

  function clearConflicts() {
    activeConflicts = null;
    conflictPanel.hidden = true;
    conflictForm.reset();
    conflictList.replaceChildren();
    conflictApply.disabled = true;
    setWorkspaceControls(false);
  }

  function updateRecordLabels() {
    const labels = {
      host: ["Адрес", "Дополнительные данные не требуются"],
      credential: ["Имя пользователя", "Секрет"],
      snippet: ["Не используется", "Текст Snippet"],
      forwarding: ["Назначение", "Параметры"],
    };
    const [targetText, secretText] = labels[recordType.value] ?? labels.host;
    setText(recordTargetLabel, targetText);
    setText(recordSecretLabel, secretText);
    recordTarget.required = recordType.value !== "snippet";
    recordSecret.required = ["credential", "snippet"].includes(recordType.value);
    hostFields.hidden = recordType.value !== "host";
    hostBrowser.hidden = activeView !== "hosts";
    setText(recordEditorSummary, editingHostID ? "Редактировать Host" : activeView === "hosts" ? "Добавить Host" : "Добавить запись");
  }

  function beginHostEdit(record) {
    editingHostID = record.id;
    recordType.value = "host";
    recordTitle.value = String(record.data.title ?? "");
    recordTarget.value = String(record.data.address ?? "");
    hostFolder.value = String(record.data.folder ?? "");
    hostTags.value = Array.isArray(record.data.tags) ? record.data.tags.join(", ") : "";
    hostDescription.value = String(record.data.description ?? "");
    const advanced = Boolean(record.data.profile);
    recordTitle.disabled = advanced;
    recordTarget.disabled = advanced;
    updateRecordLabels();
    recordEditor.open = true;
    recordEditor.scrollIntoView({ behavior: "smooth", block: "start" });
    recordTitle.focus();
    setText(workspaceStatus, advanced
      ? "Полный профиль создан в приложении: в браузере можно менять папку, теги и описание."
      : "Измените Host и сохраните зашифрованную запись.");
  }

  function hostFolderName(record) {
    return String(record?.data?.folder ?? "Без папки").trim() || "Без папки";
  }

  function updateHostFolders(hosts) {
    const selected = hostFolderFilter.value;
    const folders = [...new Set(hosts.map(hostFolderName))].sort((a, b) => a.localeCompare(b));
    hostFolderOptions.replaceChildren(...folders.filter((value) => value !== "Без папки").map((value) => {
      const option = documentValue.createElement("option"); option.value = value; return option;
    }));
    hostFolderFilter.replaceChildren();
    for (const value of ["all", ...folders]) {
      const option = documentValue.createElement("option");
      option.value = value;
      option.textContent = value === "all" ? "Все папки" : value;
      hostFolderFilter.append(option);
    }
    hostFolderFilter.value = folders.includes(selected) || selected === "all" ? selected : "all";
  }

  function renderRecords() {
    records.replaceChildren();
    if (!controller) return;
    const current = controller.document();
    const hosts = current.records.filter((value) => value.type === "host");
    updateHostFolders(hosts);
    const query = hostSearch.value.trim().toLocaleLowerCase();
    const folder = hostFolderFilter.value;
    const visibleRecords = current.records.filter((value) => {
      if (activeView !== "hosts") return true;
      if (value.type !== "host" || (folder !== "all" && hostFolderName(value) !== folder)) return false;
      const data = value.data ?? {};
      return !query || [data.title, data.address, data.folder, data.description, ...(Array.isArray(data.tags) ? data.tags : [])]
        .some((part) => String(part ?? "").toLocaleLowerCase().includes(query));
    });
    if (visibleRecords.length === 0) {
      const empty = documentValue.createElement("p");
      empty.className = "vault-empty";
      empty.textContent = activeView === "hosts"
        ? "В выбранном Team Vault пока нет хостов."
        : "Папка команды пока пуста.";
      records.append(empty);
      return;
    }
    let renderedFolder = null;
    for (const record of visibleRecords.sort((a, b) => activeView === "hosts" ? hostFolderName(a).localeCompare(hostFolderName(b)) : 0)) {
      const folderName = hostFolderName(record);
      if (activeView === "hosts" && folderName !== renderedFolder) {
        const folderHeading = documentValue.createElement("h3");
        folderHeading.className = "team-host-folder-heading";
        folderHeading.textContent = folderName;
        records.append(folderHeading);
        renderedFolder = folderName;
      }
      const card = documentValue.createElement("article");
      const heading = documentValue.createElement("h4");
      const summary = documentValue.createElement("p");
      const metadata = documentValue.createElement("small");
      const edit = documentValue.createElement("button");
      const remove = documentValue.createElement("button");
      heading.textContent = String(record.data.title ?? "Без названия");
      summary.textContent = localVaultRecordSummary(record);
      const tags = Array.isArray(record.data.tags) ? record.data.tags.map((value) => `#${value}`).join(" ") : "";
      metadata.textContent = `${tags ? `${tags} · ` : ""}${record.modifiedAt}`;
      remove.type = "button";
      remove.className = "danger";
      remove.textContent = "Удалить";
      remove.disabled = !canEdit();
      edit.type = "button";
      edit.className = "secondary record-edit";
      edit.textContent = "Изменить";
      edit.disabled = !canEdit();
      edit.addEventListener("click", (event) => { event.stopPropagation(); beginHostEdit(record); });
      remove.addEventListener("click", async () => {
        remove.disabled = true;
        try {
          await controller.delete(record.id);
          clearConflicts();
          renderRecords();
          setText(workspaceStatus, "Удаление зашифровано локально и будет синхронизировано автоматически.");
        } catch {
          setText(workspaceStatus, "Не удалось сохранить удаление.");
          remove.disabled = !canEdit();
        }
      });
      if (record.type === "host") {
        card.classList.add("resource-card", "resource-card-clickable");
        card.tabIndex = 0;
        card.setAttribute("role", "button");
        const openHost = () => {
          detailedHostID = record.id;
          setText(hostDetailTitle, String(record.data.title ?? "Host"));
          setText(hostDetailAddress, String(record.data.address ?? "—"));
          setText(hostDetailModified, String(record.modifiedAt ?? "—"));
          setText(hostDetailFolder, hostFolderName(record));
          setText(hostDetailTags, Array.isArray(record.data.tags) && record.data.tags.length ? record.data.tags.join(", ") : "—");
          setText(hostDetailDescription, String(record.data.description ?? "—"));
          hostDetailCopy.hidden = false;
          hostDetailEdit.hidden = !canEdit();
          hostDetail?.showModal();
        };
        card.addEventListener("click", (event) => { if (event.target !== remove && event.target !== edit) openHost(); });
        card.addEventListener("keydown", (event) => {
          if (event.key !== "Enter" && event.key !== " ") return;
          event.preventDefault(); openHost();
        });
      }
      const actions = documentValue.createElement("div");
      actions.className = "record-actions";
      if (record.type === "host") actions.append(edit);
      actions.append(remove);
      card.append(heading, summary, metadata, actions);
      records.append(card);
    }
  }

  function renderConflicts(result) {
    activeConflicts = { revision: result.revision, ids: result.conflicts.map((conflict) => conflict.id) };
    conflictForm.reset();
    conflictList.replaceChildren();
    result.conflicts.forEach((conflict, index) => {
      const fieldset = documentValue.createElement("fieldset");
      const legend = documentValue.createElement("legend");
      legend.textContent = `Конфликт ${index + 1}`;
      fieldset.append(legend);
      for (const [choice, prefix] of [["local", "Оставить локальную"], ["remote", "Принять Team-версию"]]) {
        const label = documentValue.createElement("label");
        const input = documentValue.createElement("input");
        input.type = "radio";
        input.name = `team-conflict-${index}`;
        input.value = choice;
        input.required = true;
        label.append(input, ` ${prefix}: ${localVaultConflictSideSummary(conflict[choice])}`);
        fieldset.append(label);
      }
      conflictList.append(fieldset);
    });
    conflictApply.disabled = true;
    setWorkspaceControls(true);
    conflictPanel.hidden = false;
  }

  async function loadDevices() {
    const values = await client.listDevices();
    devices.replaceChildren();
    for (const device of values) {
      const card = documentValue.createElement("article");
      const name = documentValue.createElement("strong");
      const detail = documentValue.createElement("small");
      const fingerprint = documentValue.createElement("p");
      const approve = documentValue.createElement("button");
      const revoke = documentValue.createElement("button");
      const current = device.id === client.deviceID();
      const approved = device.keyApprovedAt !== null;
      name.textContent = `${device.name || "Без названия"}${current ? " · текущее" : ""}`;
      detail.textContent = `${device.platform || "unknown"} ${device.appVersion || ""} · ${device.revokedAt ? "отозвано" : approved ? "ключ одобрен" : device.keyRegistered ? "ожидает одобрения" : "без Team-ключа"}`;
      fingerprint.className = "team-device-fingerprint";
      fingerprint.textContent = device.publicKey
        ? `SHA-256: ${await teamDevicePublicKeyFingerprint(device.publicKey)}`
        : "SHA-256: ключ не зарегистрирован";
      approve.type = "button";
      approve.textContent = "Одобрить ключ";
      approve.disabled = current || Boolean(device.revokedAt) || approved || !device.publicKey;
      approve.addEventListener("click", async () => {
        if (!confirmValue(`Сравните отпечаток на новом устройстве:\n${fingerprint.textContent}\n\nОдобрить этот ключ?`)) return;
        approve.disabled = true;
        try {
          await client.approveDeviceKey({
            deviceID: device.id,
            publicKey: device.publicKey,
            idempotencyKey: `web:device:approve:${globalThis.crypto.randomUUID()}`,
          });
          await loadDevices();
          setText(message, "Ключ устройства одобрен. Любой активный участник с текущим Team Vault key автоматически выдаст недостающий wrapper.");
        } catch {
          setText(message, "Ключ не одобрен: требуется уже одобренное текущее устройство и совпадающий отпечаток.");
          approve.disabled = false;
        }
      });
      revoke.type = "button";
      revoke.className = "danger";
      revoke.textContent = "Отозвать";
      revoke.disabled = current || Boolean(device.revokedAt);
      revoke.addEventListener("click", async () => {
        if (!confirmValue(`Отозвать устройство «${device.name || device.id}»? Его сессии завершатся, а затронутые Shared Vaults будут заморожены до ротации.`)) return;
        revoke.disabled = true;
        try {
          await client.revokeDevice(device.id);
          lockCurrentVault();
          await Promise.all([loadDevices(), loadTeams(selectedTeam?.id)]);
          setText(message, "Устройство отозвано. Завершите ротацию отмеченных Shared Vaults.");
        } catch {
          setText(message, "Устройство не отозвано: операция разрешена только с одобренного текущего устройства.");
          revoke.disabled = false;
        }
      });
      card.append(name, detail, fingerprint, approve, revoke);
      devices.append(card);
    }
  }

  function renderMembers(values) {
    members.replaceChildren();
    for (const member of values) {
      const card = documentValue.createElement("article");
      const name = documentValue.createElement("strong");
      const detail = documentValue.createElement("small");
      const role = documentValue.createElement("select");
      const save = documentValue.createElement("button");
      const revoke = documentValue.createElement("button");
      name.textContent = member.displayName || `@${member.username}`;
      detail.textContent = `@${member.username} · epoch ${member.epoch}`;
      const editableByActor = selectedTeam.role === "owner"
        || (selectedTeam.role === "admin" && ["editor", "viewer"].includes(member.role));
      const self = member.id === selectedTeam.membershipID;
      for (const value of ["owner", "admin", "editor", "viewer"]) {
        const option = documentValue.createElement("option");
        option.value = value;
        option.textContent = value;
        option.selected = member.role === value;
        option.disabled = selectedTeam.role !== "owner" && !["editor", "viewer"].includes(value);
        role.append(option);
      }
      role.disabled = !editableByActor || self;
      save.type = "button";
      save.textContent = "Изменить роль";
      save.disabled = !editableByActor || self;
      save.addEventListener("click", async () => {
        save.disabled = true;
        try {
          await client.updateTeamMemberRole({ teamID: selectedTeam.id, membershipID: member.id, role: role.value });
          await loadSelectedTeam();
          setText(message, "Роль участника обновлена.");
        } catch {
          setText(message, "Роль не изменена: проверьте полномочия и правило последнего Owner.");
          save.disabled = !editableByActor || self;
        }
      });
      revoke.type = "button";
      revoke.className = "danger";
      revoke.textContent = "Отозвать доступ";
      revoke.disabled = !editableByActor || self;
      revoke.addEventListener("click", async () => {
        if (!confirmValue(`Отозвать доступ для @${member.username}? Все Shared Vaults будут заморожены до ротации ключей.`)) return;
        revoke.disabled = true;
        try {
          const result = await client.revokeTeamMember({ teamID: selectedTeam.id, membershipID: member.id });
          await loadSelectedTeam();
          lockCurrentVault();
          setText(message, `Доступ отозван. Vaults для обязательной ротации: ${result.rotationRequiredVaults}.`);
        } catch {
          setText(message, "Доступ не отозван: проверьте полномочия и правило последнего Owner.");
          revoke.disabled = !editableByActor || self;
        }
      });
      card.append(name, detail, role, save, revoke);
      members.append(card);
    }
    transferOwnershipMember.replaceChildren();
    for (const member of values.filter((value) => value.id !== selectedTeam.membershipID)) {
      const option = documentValue.createElement("option");
      option.value = member.id;
      option.textContent = `${member.displayName || `@${member.username}`} · ${member.role}`;
      transferOwnershipMember.append(option);
    }
    transferOwnershipForm.querySelector("button").disabled = transferOwnershipMember.options.length === 0;
  }

  function invitationTarget(invitation) {
    if (invitation.type === "username") return `@${invitation.targetUsername}`;
    if (invitation.type === "link") return "Одноразовая ссылка";
    return "Прежнее email-приглашение";
  }

  function renderPendingInvitations() {
    pendingInvitations.replaceChildren();
    if (accountInvitations.length === 0) {
      const empty = documentValue.createElement("p");
      empty.className = "vault-empty";
      empty.textContent = "Новых приглашений нет.";
      pendingInvitations.append(empty);
      return;
    }
    for (const invitation of accountInvitations) {
      const card = documentValue.createElement("article");
      const title = documentValue.createElement("strong");
      const detail = documentValue.createElement("small");
      const accept = documentValue.createElement("button");
      title.textContent = invitation.teamName || "Team";
      detail.textContent = `Роль: ${invitation.role} · до ${invitation.expiresAt}`;
      accept.type = "button";
      accept.textContent = "Принять";
      accept.addEventListener("click", async () => {
        accept.disabled = true;
        try {
          await client.acceptTeamInvitation({ invitationID: invitation.id });
          await Promise.all([loadPendingInvitations(), loadTeams(invitation.teamID)]);
          setText(message, `Приглашение в Team «${invitation.teamName || "Team"}» принято.`);
        } catch {
          setText(message, "Приглашение уже отозвано, использовано или истекло.");
          await loadPendingInvitations().catch(() => {});
        }
      });
      card.append(title, detail, accept);
      pendingInvitations.append(card);
    }
  }

  function renderTeamInvitations() {
    activeInvitations.replaceChildren();
    if (!canManage() || teamInvitations.length === 0) {
      const empty = documentValue.createElement("p");
      empty.className = "vault-empty";
      empty.textContent = canManage() ? "Активных приглашений нет." : "";
      activeInvitations.append(empty);
      return;
    }
    for (const invitation of teamInvitations) {
      const card = documentValue.createElement("article");
      const title = documentValue.createElement("strong");
      const detail = documentValue.createElement("small");
      const cancel = documentValue.createElement("button");
      title.textContent = invitationTarget(invitation);
      detail.textContent = `Роль: ${invitation.role} · до ${invitation.expiresAt}`;
      cancel.type = "button";
      cancel.className = "danger";
      cancel.textContent = "Отозвать";
      cancel.addEventListener("click", async () => {
        if (!confirmValue(`Отозвать приглашение «${invitationTarget(invitation)}»?`)) return;
        cancel.disabled = true;
        try {
          await client.cancelTeamInvitation({
            teamID: invitation.teamID,
            invitationID: invitation.id,
          });
          if (invitation.type === "link") {
            inviteLinkResult.hidden = true;
            inviteLinkValue.value = "";
          }
          await loadSelectedTeam();
          setText(message, "Приглашение отозвано.");
        } catch {
          setText(message, "Приглашение не отозвано. Обновите список и повторите попытку.");
          cancel.disabled = false;
        }
      });
      card.append(title, detail, cancel);
      activeInvitations.append(card);
    }
  }

  async function loadPendingInvitations() {
    accountInvitations = await client.listPendingTeamInvitations();
    renderPendingInvitations();
  }

  function populateVaults() {
    vaultSelect.replaceChildren();
    for (const vault of vaults) {
      const option = documentValue.createElement("option");
      option.value = vault.id;
      option.textContent = `${vault.name}${vault.rotationRequired ? " · требуется ротация" : ""}`;
      vaultSelect.append(option);
    }
    vaultOpen.disabled = vaults.length === 0;
  }

  function stopBackgroundSync() {
    if (backgroundSyncTimer === null) return;
    clearIntervalValue(backgroundSyncTimer);
    backgroundSyncTimer = null;
  }

  function startBackgroundSync() {
    stopBackgroundSync();
    if (!controller || selectedVault?.rotationRequired
      || !Number.isFinite(backgroundSyncIntervalMilliseconds)
      || backgroundSyncIntervalMilliseconds <= 0) {
      return;
    }
    backgroundSyncTimer = setIntervalValue(() => {
      void runBackgroundTeamVaultSync();
    }, backgroundSyncIntervalMilliseconds);
    backgroundSyncTimer?.unref?.();
  }

  async function exclusiveVaultOperation(operation) {
    if (vaultOperation) return null;
    const pending = Promise.resolve().then(operation);
    vaultOperation = pending;
    try {
      return await pending;
    } finally {
      if (vaultOperation === pending) vaultOperation = null;
    }
  }

  async function synchronizeAndProvision(
    activeController = controller,
    activeTeam = selectedTeam,
    activeVault = selectedVault,
  ) {
    if (!activeController || !activeTeam || !activeVault) return null;
    return exclusiveVaultOperation(async () => {
      const result = await synchronizeTeamVault({
        client,
        controller: activeController,
        role: activeTeam.role,
      });
      if (controller !== activeController || selectedTeam?.id !== activeTeam.id
        || selectedVault?.id !== activeVault.id) {
        return null;
      }
      let wrapperProvisioning = null;
      let wrapperProvisioningFailed = false;
      if (!["conflict", "remote_changed"].includes(result.status) && !activeVault.rotationRequired) {
        try {
          wrapperProvisioning = await provisionTeamVaultWrappers({
            client,
            controller: activeController,
          });
        } catch {
          wrapperProvisioningFailed = true;
        }
      }
      if (!["conflict", "remote_changed"].includes(result.status)) {
        const state = await activeController.syncState();
        selectedVault = {
          ...selectedVault,
          revision: result.revision ?? selectedVault.revision,
          keyGeneration: state.keyGeneration,
        };
        vaults = vaults.map((value) => value.id === selectedVault.id ? selectedVault : value);
        populateVaults();
        vaultSelect.value = selectedVault.id;
      }
      return { result, wrapperProvisioning, wrapperProvisioningFailed };
    });
  }

  function applySynchronizationOutcome(outcome, { background = false } = {}) {
    if (!outcome) return;
    const { result, wrapperProvisioning, wrapperProvisioningFailed } = outcome;
    if (result.status === "conflict") {
      renderConflicts(result);
    } else if (result.status === "remote_changed") {
      clearConflicts();
      setWorkspaceControls(true);
    } else {
      clearConflicts();
      renderRecords();
    }
    setRecoveryControls(teamVaultRecoveryMode({
      outcomeStatus: result.status,
      wrapperProvisioningFailed,
    }));
    if (background && result.status === "up_to_date"
      && !wrapperProvisioningFailed && (wrapperProvisioning?.granted ?? 0) === 0) {
      return;
    }
    const messages = {
      initialized: `Shared Vault инициализирован · ревизия ${result.revision}.`,
      uploaded: `Зашифрованная Team-ревизия ${result.revision} загружена.`,
      uploaded_with_new_local_changes: `Ревизия ${result.revision} загружена; новые локальные изменения останутся для следующего цикла.`,
      downloaded: `Team-ревизия ${result.revision} загружена и объединена локально.`,
      up_to_date: `Shared Vault синхронизирован · ревизия ${result.revision}.`,
      remote_changed: `Team Vault изменился до ревизии ${result.remoteRevision}. Следующий цикл повторит синхронизацию.`,
      conflict: `Обнаружено конфликтов: ${result.conflicts.length}. Выберите версии явно.`,
    };
    let status = messages[result.status] ?? "Синхронизация завершена.";
    if (wrapperProvisioningFailed) {
      status += " Автоматическая выдача wrappers не подтверждена и будет безопасно повторена.";
    } else if ((wrapperProvisioning?.granted ?? 0) > 0) {
      status += ` Автоматически выдано недостающих wrappers: ${wrapperProvisioning.granted}.`;
    }
    setText(workspaceStatus, status);
  }

  async function runBackgroundTeamVaultSync() {
    if (documentValue.visibilityState === "hidden" || activeConflicts || vaultOperation
      || !controller || !selectedTeam || !selectedVault || selectedVault.rotationRequired) {
      return;
    }
    try {
      applySynchronizationOutcome(await synchronizeAndProvision(), { background: true });
    } catch (error) {
      const code = String(error?.message ?? "");
      if (code === "team_vault_rotation_required") {
        selectedVault = { ...selectedVault, rotationRequired: true };
        vaults = vaults.map((value) => value.id === selectedVault.id ? selectedVault : value);
        populateVaults();
        vaultSelect.value = selectedVault.id;
        rotateButton.hidden = !canManage();
        rotateButton.disabled = rotateButton.hidden;
        setRecoveryControls("none");
        stopBackgroundSync();
        setText(workspaceStatus, "Фоновая запись заморожена до безопасной ротации ключа.");
      } else if (code === "team_vault_key_unavailable") {
        setRecoveryControls(teamVaultRecoveryMode({ errorCode: code }));
        setText(workspaceStatus, "Ожидаем, пока устройство с текущим Team Vault key автоматически выдаст wrapper этому браузеру.");
      } else {
        setRecoveryControls(teamVaultRecoveryMode({ errorCode: code || "team_vault_sync_failed" }));
        setText(workspaceStatus, "Автоматическая синхронизация временно остановилась; локальная зашифрованная копия сохранена.");
      }
    }
  }

  function lockCurrentVault() {
    stopBackgroundSync();
    controller?.lock();
    controller = null;
    selectedVault = null;
    workspace.hidden = true;
    rotateButton.hidden = true;
    rotateButton.disabled = true;
    setRecoveryControls("none");
    records.replaceChildren();
    clearConflicts();
  }

  function setView(view) {
    activeView = ["teams", "members", "vaults", "hosts", "management"].includes(view) ? view : "teams";
    section.dataset.teamView = activeView;
    setText(sectionTitle, {
      teams: "Команды", members: "Участники команд", vaults: "Папки команд",
      hosts: "Хосты команд", management: "Управление командой",
    }[activeView]);
    onboarding.hidden = activeView !== "teams";
    membersView.hidden = activeView !== "members";
    vaultDirectoryView.hidden = !["vaults", "hosts"].includes(activeView);
    lifecyclePanel.hidden = activeView !== "management" || selectedTeam?.role !== "owner";
    createVaultForm.hidden = activeView !== "vaults" || !canManage();
    workspace.hidden = activeView !== "hosts" || !controller;
    if (activeView === "hosts") recordType.value = "host";
    updateRecordLabels();
    if (controller) {
      clearConflicts();
      renderRecords();
      setWorkspaceControls(false);
    } else if (activeView === "hosts" && vaults.length > 0) {
      void openSelectedVault();
    }
    updateTeamMessage();
  }

  async function openSelectedVault() {
    const vault = vaults.find((value) => value.id === vaultSelect.value);
    if (!vault || !identity) return;
    lockCurrentVault();
    selectedVault = vault;
    const scope = { type: "team", teamID: selectedTeam.id, vaultID: vault.id };
    controller = createTeamVaultController({
      repository: createIndexedDBTeamVaultRepository(scope),
      identity,
      scope,
    });
    workspace.hidden = activeView !== "hosts";
    rotateButton.hidden = !vault.rotationRequired || !canManage();
    rotateButton.disabled = !vault.rotationRequired || !canManage();
    setRecoveryControls("none");
    workspaceTitle.textContent = `${selectedTeam.name} / ${vault.name}`;
    setText(workspaceStatus, "Загружаем зашифрованную Team-ревизию…");
    try {
      const outcome = await synchronizeAndProvision();
      applySynchronizationOutcome(outcome);
    } catch (error) {
      const code = String(error?.message ?? "");
      setWorkspaceControls(true);
      rotateButton.hidden = code !== "team_vault_rotation_required" || !canManage();
      rotateButton.disabled = rotateButton.hidden;
      setRecoveryControls(teamVaultRecoveryMode({ errorCode: code }));
      setText(workspaceStatus, code === "team_vault_rotation_required"
        ? "Запись заморожена: после отзыва участника или устройства требуется полная ротация ключа."
        : code === "team_vault_key_unavailable"
          ? "Для этого устройства пока нет wrapper ключа. Ожидаем автоматическую выдачу от любого активного участника с текущим ключом."
          : "Shared Vault не открыт; локальные данные не изменены. Доступно безопасное повторение.");
    } finally {
      startBackgroundSync();
    }
  }

  async function loadSelectedTeam() {
    selectedTeam = teams.find((team) => team.id === teamSelect.value) ?? null;
    lockCurrentVault();
    if (!selectedTeam) {
      teamInvitations = [];
      renderTeamInvitations();
      selectedPanel.hidden = true;
      return;
    }
    selectedPanel.hidden = false;
    teamRole.textContent = `${selectedTeam.name} · ${selectedTeam.role}`;
    inviteForm.hidden = !canManage();
    const adminInviteOption = [...inviteForm.elements.role.options]
      .find((option) => option.value === "admin");
    if (adminInviteOption) adminInviteOption.disabled = selectedTeam.role !== "owner";
    if (selectedTeam.role !== "owner" && inviteForm.elements.role.value === "admin") {
      inviteForm.elements.role.value = "viewer";
    }
    createVaultForm.hidden = activeView !== "vaults" || !canManage();
    lifecyclePanel.hidden = activeView !== "management" || selectedTeam.role !== "owner";
    renameTeamForm.elements.name.value = selectedTeam.name;
    archiveTeamForm.reset();
    transferOwnershipForm.reset();
    const [loadedMembers, sharedVaults, loadedInvitations] = await Promise.all([
      client.listTeamMembers(selectedTeam.id),
      client.listSharedVaults(selectedTeam.id),
      canManage() ? client.listTeamInvitations(selectedTeam.id) : Promise.resolve([]),
    ]);
    teamMembers = loadedMembers;
    renderMembers(teamMembers);
    vaults = sharedVaults;
    teamInvitations = loadedInvitations;
    renderTeamInvitations();
    populateVaults();
    updateTeamMessage();
    if (activeView === "hosts" && vaults.length > 0) await openSelectedVault();
  }

  async function loadTeams(preferredID = null) {
    teams = await client.listTeams();
    teamSelect.replaceChildren();
    for (const team of teams) {
      const option = documentValue.createElement("option");
      option.value = team.id;
      option.textContent = `${team.name} · ${team.role}`;
      teamSelect.append(option);
    }
    if (preferredID && teams.some((team) => team.id === preferredID)) teamSelect.value = preferredID;
    if (teams.length > 0) await loadSelectedTeam();
    else {
      selectedTeam = null;
      teamInvitations = [];
      selectedPanel.hidden = true;
      renderTeamInvitations();
      setText(message, "Команд пока нет. Создайте Team или примите приглашение.");
    }
  }

  createTeamForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = createTeamForm.querySelector("button");
    button.disabled = true;
    try {
      const team = await client.createTeam({ name: createTeamForm.elements.name.value });
      createTeamForm.reset();
      await loadTeams(team.id);
      setText(message, "Team создан. Вы назначены Owner.");
    } catch {
      setText(message, "Team не создан. Проверьте название и повторите попытку.");
    } finally {
      button.disabled = false;
    }
  });

  acceptInvitationForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = acceptInvitationForm.querySelector("button");
    button.disabled = true;
    try {
      await client.acceptTeamInvitation({ token: acceptInvitationForm.elements.token.value });
      acceptInvitationForm.reset();
      await Promise.all([loadPendingInvitations(), loadTeams()]);
      setText(message, "Приглашение принято.");
    } catch {
      acceptInvitationForm.elements.token.value = "";
      setText(message, "Одноразовая ссылка недействительна, уже использована, отозвана или истекла.");
    } finally {
      button.disabled = false;
    }
  });

  inviteForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!selectedTeam || !canManage()) return;
    const button = inviteForm.querySelector("button");
    button.disabled = true;
    try {
      await client.inviteTeamMember({
        teamID: selectedTeam.id,
        username: inviteForm.elements.username.value,
        type: "username",
        role: inviteForm.elements.role.value,
      });
      inviteForm.reset();
      inviteLinkResult.hidden = true;
      inviteLinkValue.value = "";
      await loadSelectedTeam();
      setText(message, "Приглашение по @username создано на 48 часов.");
    } catch {
      setText(message, "Приглашение не создано. Проверьте @username, роль и полномочия.");
    } finally {
      button.disabled = false;
    }
  });

  inviteLinkCreate.addEventListener("click", async () => {
    if (!selectedTeam || !canManage()) return;
    inviteLinkCreate.disabled = true;
    try {
      const invitation = await client.inviteTeamMember({
        teamID: selectedTeam.id,
        type: "link",
        role: inviteForm.elements.role.value,
      });
      if (!invitation.acceptanceURL) throw new Error("team_invitation_failed");
      inviteLinkValue.value = invitation.acceptanceURL;
      inviteLinkResult.hidden = false;
      await loadSelectedTeam();
      setText(message, "Одноразовая ссылка создана на 48 часов. Передайте её только нужному участнику.");
    } catch {
      inviteLinkResult.hidden = true;
      inviteLinkValue.value = "";
      setText(message, "Одноразовая ссылка не создана. Проверьте роль и полномочия.");
    } finally {
      inviteLinkCreate.disabled = false;
    }
  });

  inviteLinkCopy.addEventListener("click", async () => {
    if (!inviteLinkValue.value) return;
    try {
      await documentValue.defaultView.navigator.clipboard.writeText(inviteLinkValue.value);
      setText(message, "Одноразовая ссылка скопирована.");
    } catch {
      inviteLinkValue.select();
      setText(message, "Не удалось скопировать автоматически. Скопируйте выделенную ссылку вручную.");
    }
  });

  renameTeamForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (selectedTeam?.role !== "owner") return;
    const button = renameTeamForm.querySelector("button");
    button.disabled = true;
    try {
      const team = await client.renameTeam({ teamID: selectedTeam.id, name: renameTeamForm.elements.name.value });
      await loadTeams(team.id);
      setText(message, "Название Team обновлено.");
    } catch {
      setText(message, "Team не переименована: проверьте название и полномочия Owner.");
    } finally {
      button.disabled = false;
    }
  });

  transferOwnershipForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (selectedTeam?.role !== "owner") return;
    const currentTeamID = selectedTeam.id;
    const button = transferOwnershipForm.querySelector("button");
    button.disabled = true;
    try {
      if (!confirmValue("Передать роль Owner выбранному участнику и продолжить как Admin?")) return;
      await client.transferTeamOwnership({
        teamID: currentTeamID,
        membershipID: transferOwnershipForm.elements.membershipID.value,
        password: transferOwnershipForm.elements.password.value,
      });
      lockCurrentVault();
      await loadTeams(currentTeamID);
      setText(message, "Владение передано. Ваша роль изменена на Admin.");
    } catch {
      setText(message, "Владение не передано: проверьте пароль, участника и полномочия Owner.");
    } finally {
      transferOwnershipForm.elements.password.value = "";
      button.disabled = transferOwnershipMember.options.length === 0;
    }
  });

  archiveTeamForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (selectedTeam?.role !== "owner") return;
    const archivedTeam = selectedTeam;
    const archivedVaults = [...vaults];
    const button = archiveTeamForm.querySelector("button");
    let remotelyArchived = false;
    button.disabled = true;
    try {
      if (!confirmValue(`Архивировать Team «${archivedTeam.name}» и немедленно закрыть к ней доступ?`)) return;
      await client.archiveTeam({
        teamID: archivedTeam.id,
        expectedName: archiveTeamForm.elements.expectedName.value,
        password: archiveTeamForm.elements.password.value,
      });
      remotelyArchived = true;
      lockCurrentVault();
      const removals = await Promise.allSettled(archivedVaults.map((vault) => (
        createIndexedDBTeamVaultRepository({ type: "team", teamID: archivedTeam.id, vaultID: vault.id }).remove()
      )));
      await loadTeams();
      const failed = removals.filter((result) => result.status === "rejected").length;
      setText(message, failed === 0
        ? "Team архивирована; локальные зашифрованные снимки удалены."
        : `Team архивирована, но ${failed} локальных зашифрованных снимков не удалось удалить.`);
    } catch {
      setText(message, remotelyArchived
        ? "Team архивирована, но локальную очистку или обновление списка не удалось завершить."
        : "Team не архивирована: точное название, пароль или полномочия Owner не подтверждены.");
    } finally {
      archiveTeamForm.elements.password.value = "";
      button.disabled = false;
    }
  });

  createVaultForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = createVaultForm.querySelector("button");
    button.disabled = true;
    try {
      const vault = await client.createSharedVault({ teamID: selectedTeam.id, name: createVaultForm.elements.name.value });
      createVaultForm.reset();
      await loadSelectedTeam();
      vaultSelect.value = vault.id;
      setText(message, "Папка команды создана. Перейдите в «Хосты команд», чтобы добавить или открыть Host.");
    } catch {
      setText(message, "Shared Vault не создан или не инициализирован. Проверьте роль и одобрение устройства.");
    } finally {
      button.disabled = false;
    }
  });

  teamSelect.addEventListener("change", () => {
    inviteLinkResult.hidden = true;
    inviteLinkValue.value = "";
    loadSelectedTeam().catch(() => setText(message, "Не удалось загрузить Team."));
  });
  teamRefresh.addEventListener("click", () => loadTeams(selectedTeam?.id).catch(() => setText(message, "Не удалось обновить Teams.")));
  devicesRefresh.addEventListener("click", () => loadDevices().catch(() => setText(message, "Не удалось обновить устройства.")));
  vaultOpen.addEventListener("click", () => {
    if (activeView === "vaults") {
      documentValue.querySelector('[data-workspace-target="team-vault"][data-team-view="hosts"]')?.click();
      return;
    }
    void openSelectedVault();
  });
  rotateButton.addEventListener("click", async () => {
    if (!controller || !selectedVault || !canManage() || vaultOperation) return;
    if (!confirmValue("Зашифровать полную текущую Team-ревизию новым ключом и выдать wrappers всем актуальным авторизованным устройствам?")) return;
    stopBackgroundSync();
    rotateButton.disabled = true;
    lockButton.disabled = true;
    setRecoveryControls("none");
    setWorkspaceControls(true);
    try {
      const result = await rotateTeamVault({ client, controller, role: selectedTeam.role });
      if (result.status === "conflict") {
        renderConflicts(result);
        setText(workspaceStatus, `Перед ротацией разрешите конфликтов: ${result.conflicts.length}. Секреты не отображаются.`);
      } else if (result.status === "remote_changed") {
        setText(workspaceStatus, `Другая ротация или запись уже изменила Vault до ревизии ${result.remoteRevision}. Повторно откройте Vault.`);
      } else {
        selectedVault = { ...selectedVault, rotationRequired: false, revision: result.revision, keyGeneration: result.keyGeneration };
        vaults = vaults.map((value) => value.id === selectedVault.id ? selectedVault : value);
        populateVaults();
        vaultSelect.value = selectedVault.id;
        rotateButton.hidden = true;
        setRecoveryControls("none");
        clearConflicts();
        renderRecords();
        setWorkspaceControls(false);
        setText(workspaceStatus, `Ротация завершена атомарно · ревизия ${result.revision} · поколение ключа ${result.keyGeneration}.`);
      }
    } catch {
      setText(workspaceStatus, "Ротация не подтверждена. Локальный snapshot не заменён; безопасно повторите операцию.");
    } finally {
      lockButton.disabled = false;
      rotateButton.disabled = rotateButton.hidden || !canManage() || Boolean(activeConflicts);
      setRecoveryControls("none");
      startBackgroundSync();
    }
  });
  grantWrappersButton.addEventListener("click", async () => {
    if (!controller || !selectedVault || selectedVault.rotationRequired) return;
    setRecoveryControls("none");
    try {
      const result = await exclusiveVaultOperation(() => provisionTeamVaultWrappers({
        client,
        controller,
      }));
      if (!result) return;
      setText(workspaceStatus, result.granted === 0
        ? "Все актуальные авторизованные устройства уже имеют wrapper этой генерации."
        : `Автоматически выдано недостающих wrappers: ${result.granted}. Vault plaintext не покидал браузер.`);
    } catch {
      setRecoveryControls("wrappers");
      setText(workspaceStatus, "Не все wrappers подтверждены. Автоматический цикл безопасно повторит выдачу.");
    }
  });
  recordType.addEventListener("change", updateRecordLabels);
  hostSearch.addEventListener("input", renderRecords);
  hostFolderFilter.addEventListener("change", renderRecords);
  hostDetailCopy.addEventListener("click", async () => {
    try {
      await documentValue.defaultView.navigator.clipboard.writeText(hostDetailAddress.textContent);
      setText(workspaceStatus, "Адрес Host скопирован без передачи в Cloud.");
    } catch { setText(workspaceStatus, "Браузер не разрешил доступ к буферу обмена."); }
  });
  hostDetailEdit.addEventListener("click", () => {
    const record = controller?.document().records.find((value) => value.id === detailedHostID && value.type === "host");
    hostDetail.close();
    if (record) beginHostEdit(record);
  });
  recordForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = recordForm.querySelector("button");
    button.disabled = true;
    try {
      const existingHost = editingHostID
        ? controller.document().records.find((value) => value.id === editingHostID && value.type === "host")
        : null;
      await controller.upsert({
        ...(editingHostID ? { id: editingHostID } : {}),
        type: recordType.value,
        data: recordType.value === "host"
          ? teamHostRecordData({
              title: recordTitle.value, target: recordTarget.value, folder: hostFolder.value,
              tags: hostTags.value, description: hostDescription.value, baseData: existingHost?.data,
            })
          : localVaultRecordData(recordType.value, {
              title: recordTitle.value, target: recordTarget.value, secret: recordSecret.value,
            }),
      });
      recordForm.reset();
      editingHostID = null;
      recordTitle.disabled = false;
      recordTarget.disabled = false;
      recordEditor.open = false;
      updateRecordLabels();
      clearConflicts();
      rotateButton.disabled = !selectedVault?.rotationRequired || !canManage();
      renderRecords();
      setText(workspaceStatus, "Изменение зашифровано локально и будет синхронизировано автоматически.");
    } catch {
      setText(workspaceStatus, "Запись не сохранена. Проверьте поля и роль.");
    } finally {
      button.disabled = !canEdit();
    }
  });

  syncButton.addEventListener("click", async () => {
    setRecoveryControls("none");
    try {
      applySynchronizationOutcome(await synchronizeAndProvision());
    } catch (error) {
      const code = String(error?.message ?? "");
      setRecoveryControls(teamVaultRecoveryMode({ errorCode: code }));
      setText(workspaceStatus, code === "team_vault_rotation_required"
        ? "Синхронизация заморожена до безопасной ротации ключа."
        : code === "team_vault_key_unavailable"
          ? "Wrapper ещё недоступен. Любой активный участник с текущим ключом выдаст его автоматически."
          : "Синхронизация не выполнена; локальная зашифрованная копия сохранена.");
    } finally {
      startBackgroundSync();
    }
  });

  lockButton.addEventListener("click", () => {
    stopBackgroundSync();
    controller?.lock();
    records.replaceChildren();
    clearConflicts();
    setWorkspaceControls(true);
    setRecoveryControls("none");
    setText(workspaceStatus, "Ключ Shared Vault удалён из памяти. Откройте выбранный Vault снова для локального unlock.");
  });

  conflictForm.addEventListener("change", () => {
    conflictApply.disabled = !activeConflicts || activeConflicts.ids.some((_id, index) => (
      !conflictForm.querySelector(`input[name="team-conflict-${index}"]:checked`)
    ));
  });
  conflictForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!activeConflicts) return;
    try {
      await controller.resolveConflicts({
        revision: activeConflicts.revision,
        resolutions: activeConflicts.ids.map((id, index) => ({
          id,
          choice: conflictForm.querySelector(`input[name="team-conflict-${index}"]:checked`)?.value,
        })),
      });
      clearConflicts();
      rotateButton.disabled = !selectedVault?.rotationRequired || !canManage();
      renderRecords();
      setText(workspaceStatus, selectedVault?.rotationRequired
        ? "Конфликты разрешены локально. Повторите безопасную ротацию."
        : "Конфликты разрешены локально. Условная запись будет синхронизирована автоматически.");
    } catch {
      clearConflicts();
      setText(workspaceStatus, "Набор конфликтов устарел. Запустите синхронизацию ещё раз.");
    }
  });

  updateRecordLabels();
  setView("teams");
  return {
    setView,
    async activate(nextIdentity) {
      identity = nextIdentity;
      await Promise.all([loadDevices(), loadPendingInvitations(), loadTeams()]);
    },
    deactivate() {
      identity = null;
      teams = [];
      vaults = [];
      teamMembers = [];
      teamInvitations = [];
      accountInvitations = [];
      selectedTeam = null;
      lockCurrentVault();
      teamSelect.replaceChildren();
      devices.replaceChildren();
      members.replaceChildren();
      activeInvitations.replaceChildren();
      pendingInvitations.replaceChildren();
      acceptInvitationForm.reset();
      inviteLinkResult.hidden = true;
      inviteLinkValue.value = "";
      selectedPanel.hidden = true;
    },
  };
}

export function accountVaultPassphrase(password) {
  const normalized = String(password ?? "").normalize("NFC");
  if (new TextEncoder().encode(normalized).length < 12) throw new Error("invalid_account_password");
  return `selective-remote:account-password:v1:${normalized}`;
}

export async function initializeCloudAccount({
  documentValue = document,
  vaultUI,
  fetchValue = fetch,
  metadata = null,
  initialTeamInvitationToken = null,
  onSessionChange = () => {},
} = {}) {
  const vault = vaultUI?.controller;
  const section = documentValue.querySelector("#cloud-account");
  if (!section || !vault) return null;
  const form = documentValue.querySelector("#cloud-login-form");
  const registrationForm = documentValue.querySelector("#cloud-registration-form");
  const recoveryFormAccount = documentValue.querySelector("#cloud-recovery-form");
  const loginTab = documentValue.querySelector("#cloud-login-tab");
  const registrationTab = documentValue.querySelector("#cloud-register-tab");
  const tabs = documentValue.querySelector(".auth-tabs");
  const registrationSuccess = documentValue.querySelector("#cloud-registration-success");
  const registrationSuccessMessage = documentValue.querySelector("#cloud-registration-success-message");
  const registrationDone = documentValue.querySelector("#cloud-registration-done");
  const showRecovery = documentValue.querySelector("#cloud-show-recovery");
  const hideRecovery = documentValue.querySelector("#cloud-hide-recovery");
  const signedIn = documentValue.querySelector("#cloud-signed-in");
  const accountName = documentValue.querySelector("#cloud-account-name");
  const message = documentValue.querySelector("#cloud-account-message");
  const logoutButton = documentValue.querySelector("#cloud-logout");
  const deleteAccountForm = documentValue.querySelector("#account-delete-form");
  const deleteAccountMessage = documentValue.querySelector("#account-delete-message");
  const syncButton = documentValue.querySelector("#cloud-vault-sync");
  const vaultMessage = documentValue.querySelector("#local-vault-message");
  const recoveryForm = documentValue.querySelector("#cloud-vault-recovery-form");
  const recoveryCancel = documentValue.querySelector("#cloud-vault-recovery-cancel");
  const conflictPanel = documentValue.querySelector("#local-vault-conflicts");
  const conflictForm = documentValue.querySelector("#local-vault-conflicts-form");
  const conflictList = documentValue.querySelector("#local-vault-conflicts-list");
  const conflictApply = documentValue.querySelector("#local-vault-conflicts-apply");
  const client = createAuthenticatedVaultClient({ fetchValue });
  const teamWorkspace = initializeTeamWorkspace({ documentValue, client, initialInvitationToken: initialTeamInvitationToken });
  const teamDeviceRepository = createIndexedDBTeamDeviceRepository();
  let activeConflicts = null;
  let backgroundSyncing = false;
  let accountVaultMigrationPassphrase = null;
  vaultUI.setConflictResetListener(() => {
    activeConflicts = null;
    conflictApply.disabled = true;
  });

  function setAccountMessage(value, tone = null) {
    setText(message, value);
    message.classList.toggle("error", tone === "error");
    message.classList.toggle("success", tone === "success");
  }

  async function unlockAndSyncPersonalVault(password) {
    const passphrase = accountVaultPassphrase(password);
    let status = await vault.status();
    if (status === "locked") {
      await vault.unlock(passphrase);
      status = "unlocked";
    }
    let result = await synchronizeVault({ client, vault, recoveryPassphrase: passphrase });
    if (status === "empty" && result.status === "empty") {
      await vault.create(passphrase);
      result = await synchronizeVault({ client, vault });
    }
    vaultUI.mode("unlocked");
    vaultUI.render();
    return result;
  }

  async function backgroundPersonalVaultSync() {
    if (backgroundSyncing || !client.session() || await vault.status() !== "unlocked") return;
    backgroundSyncing = true;
    try {
      const result = await synchronizeVault({ client, vault });
      if (result.status === "conflict") renderConflicts(result);
      else if (result.status !== "remote_changed") hideConflicts();
      vaultUI.render();
    } catch {
      // Manual sync keeps the actionable error path; background failures never discard local state.
    } finally {
      backgroundSyncing = false;
    }
  }

  const personalVaultTimer = globalThis.setInterval(
    () => { void backgroundPersonalVaultSync(); },
    15_000
  );
  personalVaultTimer?.unref?.();

  function setAuthMode(mode) {
    const registrationAvailable = metadata?.registrationEnabled === true;
    form.hidden = mode !== "login";
    registrationForm.hidden = mode !== "registration";
    recoveryFormAccount.hidden = mode !== "recovery";
    registrationSuccess.hidden = true;
    loginTab.setAttribute("aria-selected", String(mode === "login"));
    registrationTab.setAttribute("aria-selected", String(mode === "registration"));
    for (const control of registrationForm.querySelectorAll("input, button")) {
      control.disabled = mode === "registration" && !registrationAvailable;
    }
    if (mode === "registration") {
      setAccountMessage(registrationAvailable
        ? "Создайте пароль Selective Remote — на почту придёт только одноразовая ссылка подтверждения."
        : "Регистрация временно закрыта. Уже подтверждённые аккаунты могут войти.", registrationAvailable ? null : "error");
    } else if (mode === "recovery") {
      setAccountMessage("Мы отправим одноразовую ссылку для смены пароля, если аккаунт существует.");
    } else {
      setAccountMessage("Сессионный токен хранится только в памяти этой вкладки.");
    }
  }

  function hideConflicts() {
    activeConflicts = null;
    vaultUI.clearConflictUI();
    conflictApply.disabled = true;
  }

  function renderConflicts(result) {
    activeConflicts = { revision: result.revision, ids: result.conflicts.map((conflict) => conflict.id) };
    conflictForm.reset();
    conflictList.replaceChildren();
    conflictApply.disabled = true;
    result.conflicts.forEach((conflict, index) => {
      const fieldset = documentValue.createElement("fieldset");
      const legend = documentValue.createElement("legend");
      legend.textContent = `Конфликт ${index + 1}`;
      fieldset.append(legend);
      for (const [choice, prefix] of [["local", "Оставить локальную"], ["remote", "Принять Cloud-версию"]]) {
        const label = documentValue.createElement("label");
        const input = documentValue.createElement("input");
        input.type = "radio";
        input.name = `conflict-${index}`;
        input.value = choice;
        input.required = true;
        label.append(input, ` ${prefix}: ${localVaultConflictSideSummary(conflict[choice])}`);
        fieldset.append(label);
      }
      conflictList.append(fieldset);
    });
    vaultUI.setConflictMode(true);
    conflictPanel.hidden = false;
  }

  function updateConflictApplyState() {
    if (!activeConflicts) {
      conflictApply.disabled = true;
      return;
    }
    conflictApply.disabled = activeConflicts.ids.some((_id, index) => (
      !conflictForm.querySelector(`input[name="conflict-${index}"]:checked`)
    ));
  }

  function showSession(user) {
    tabs.hidden = Boolean(user);
    form.hidden = Boolean(user);
    registrationForm.hidden = true;
    recoveryFormAccount.hidden = true;
    registrationSuccess.hidden = true;
    signedIn.hidden = !user;
    syncButton.disabled = !user;
    setText(accountName, user ? `${user.displayName || user.email} · ${user.email}` : "");
    onSessionChange(user);
  }

  loginTab.addEventListener("click", () => setAuthMode("login"));
  registrationTab.addEventListener("click", () => setAuthMode("registration"));
  showRecovery.addEventListener("click", () => setAuthMode("recovery"));
  hideRecovery.addEventListener("click", () => setAuthMode("login"));
  registrationDone.addEventListener("click", () => setAuthMode("login"));

  registrationForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (metadata?.registrationEnabled !== true) {
      setAccountMessage("Регистрация временно закрыта. Обновите страницу после открытия регистрационного окна.", "error");
      return;
    }
    const button = registrationForm.querySelector('button[type="submit"]');
    const password = registrationForm.elements.password.value;
    if (password !== registrationForm.elements.confirmation.value) {
      setAccountMessage("Пароли не совпадают.", "error");
      return;
    }
    button.disabled = true;
    try {
      const deviceID = await vault.deviceID();
      let identity = null;
      try { identity = await ensureTeamDeviceIdentity({ repository: teamDeviceRepository, deviceID }); } catch {}
      await client.register({
        displayName: registrationForm.elements.displayName.value,
        username: registrationForm.elements.username.value,
        email: registrationForm.elements.email.value,
        password,
        deviceID,
        publicKey: identity?.publicKey ?? null,
      });
      const email = registrationForm.elements.email.value.trim();
      registrationForm.reset();
      registrationForm.hidden = true;
      registrationSuccess.hidden = false;
      setText(registrationSuccessMessage, `Одноразовая ссылка отправлена на ${email}. Подтвердите адрес, затем войдите с созданным паролем.`);
      setAccountMessage("Аккаунт создан. Пароль не отправлялся по почте и не был сохранён в браузере.", "success");
    } catch (error) {
      const code = String(error?.message ?? "");
      const messages = {
        registration_disabled: "Регистрационное окно уже закрыто. Обновите страницу позже.",
        rate_limited: "Слишком много попыток. Повторите позже.",
        smtp_not_configured: "Почтовый сервис временно не настроен.",
      };
      setAccountMessage(messages[code] ?? "Не удалось создать аккаунт. Проверьте поля и повторите попытку.", "error");
    } finally {
      registrationForm.elements.password.value = "";
      registrationForm.elements.confirmation.value = "";
      button.disabled = false;
    }
  });

  recoveryFormAccount.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = recoveryFormAccount.querySelector('button[type="submit"]');
    button.disabled = true;
    try {
      await client.requestPasswordReset(recoveryFormAccount.elements.email.value);
      recoveryFormAccount.reset();
      setAccountMessage("Если аккаунт существует, ссылка для смены пароля уже отправлена.", "success");
    } catch {
      setAccountMessage("Не удалось запросить восстановление. Повторите позже.", "error");
    } finally {
      button.disabled = false;
    }
  });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = form.querySelector("button");
    button.disabled = true;
    try {
      const password = form.elements.password.value;
      accountVaultMigrationPassphrase = accountVaultPassphrase(password);
      const deviceID = await vault.deviceID();
      let identity = null;
      try {
        identity = await ensureTeamDeviceIdentity({ repository: teamDeviceRepository, deviceID });
      } catch {
        // Team keys are optional for personal-Vault login and fail independently.
      }
      const user = await client.login({
        email: form.elements.email.value,
        password,
        deviceID,
        publicKey: identity?.publicKey ?? null,
      });
      let personalVaultReady = false;
      try {
        await unlockAndSyncPersonalVault(password);
        personalVaultReady = true;
        accountVaultMigrationPassphrase = null;
      } catch {
        // Vaults created before account-password enrollment retain Recovery fallback.
      }
      if (identity) {
        try {
          await client.bootstrapDeviceKey({
            password,
            publicKey: identity.publicKey,
            idempotencyKey: `web:device:bootstrap:${globalThis.crypto.randomUUID()}`,
          });
        } catch {
          // Existing accounts with an approved device must use device-to-device approval.
        }
      }
      form.elements.password.value = "";
      showSession(user);
      if (!identity) {
        setText(message, "Вход выполнен. Team-ключ недоступен в этом браузере; личный Vault продолжает работать.");
      } else {
        try {
          await teamWorkspace?.activate(identity);
          setText(message, "Вход выполнен. Сессионный токен хранится только в памяти этой вкладки.");
        } catch {
          setText(message, "Вход выполнен. Team-раздел временно недоступен; личный Vault и сессия продолжают работать.");
        }
      }
      setText(
        vaultMessage,
        personalVaultReady
          ? "Personal Vault открыт паролем аккаунта и синхронизируется автоматически."
          : "Для ранее созданного Personal Vault один раз введите Recovery-фразу; новые входы используют пароль аккаунта."
      );
    } catch (error) {
      const code = String(error?.message ?? "");
      const messages = {
        invalid_credentials: "Неверная электронная почта или пароль.",
        email_not_verified: "Сначала подтвердите почту по ссылке из письма.",
        rate_limited: "Слишком много попыток входа. Повторите позже.",
      };
      setAccountMessage(messages[code] ?? "Не удалось войти. Проверьте соединение и повторите попытку.", "error");
    } finally {
      button.disabled = false;
    }
  });

  logoutButton.addEventListener("click", async () => {
    logoutButton.disabled = true;
    try {
      await client.logout();
    } finally {
      vault.lock();
      showSession(null);
      teamWorkspace?.deactivate();
      hideConflicts();
      await vaultUI.hideRecoveryAndRestoreMode();
      logoutButton.disabled = false;
      setText(message, "Сессия завершена, токен удалён из памяти вкладки.");
    }
  });

  deleteAccountForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const currentUser = client.session();
    const email = deleteAccountForm.elements.email.value.trim().toLowerCase();
    const button = deleteAccountForm.querySelector('button[type="submit"]');
    if (!currentUser || email !== currentUser.email.toLowerCase()) {
      setText(deleteAccountMessage, "Email должен точно совпадать с адресом текущего аккаунта.");
      return;
    }
    if (!globalThis.confirm(`Безвозвратно удалить аккаунт ${currentUser.email}?`)) return;
    button.disabled = true;
    try {
      await client.deleteAccount({ email, password: deleteAccountForm.elements.password.value });
      deleteAccountForm.reset();
      teamWorkspace?.deactivate();
      hideConflicts();
      vault.lock();
      await vaultUI.hideRecoveryAndRestoreMode();
      showSession(null);
      setAccountMessage("Аккаунт удалён. Все Cloud-сессии завершены.", "success");
    } catch (error) {
      const messages = {
        invalid_credentials: "Текущий пароль неверен.",
        account_email_mismatch: "Email не совпадает с адресом аккаунта.",
        account_owns_teams: "Сначала передайте владение активной Team или архивируйте её.",
      };
      setText(deleteAccountMessage, messages[String(error?.message ?? "")] ?? "Аккаунт не удалён. Повторите попытку позже.");
    } finally {
      deleteAccountForm.elements.password.value = "";
      button.disabled = false;
    }
  });

  syncButton.addEventListener("click", async () => {
    syncButton.disabled = true;
    try {
      const result = await synchronizeVault({ client, vault });
      const messages = {
        empty: "Сначала создайте локальный Vault.",
        uploaded: `Зашифрованная ревизия ${result.revision} загружена.`,
        uploaded_with_new_local_changes: `Ревизия ${result.revision} загружена; появились новые локальные изменения — синхронизируйте ещё раз.`,
        downloaded: `Зашифрованная ревизия ${result.revision} загружена и объединена локально.`,
        up_to_date: `Vault уже синхронизирован на ревизии ${result.revision}.`,
        remote_changed: `Удалённый Vault изменился до ревизии ${result.remoteRevision}. Повторите синхронизацию для безопасного merge.`,
        conflict: `Обнаружено конфликтов: ${result.conflicts.length}. Upload остановлен; требуется явное разрешение конфликтов.`,
      };
      if (result.status === "conflict") renderConflicts(result);
      else hideConflicts();
      setText(vaultMessage, messages[result.status] ?? "Синхронизация завершена.");
    } catch (error) {
      const code = String(error?.message ?? "");
      if (code === "local_vault_locked") setText(vaultMessage, "Сначала разблокируйте локальный Vault.");
      else if (code === "authentication_required") {
        showSession(null);
        setText(vaultMessage, "Сессия истекла. Войдите снова.");
      } else if (code === "recovery_passphrase_required") {
        hideConflicts();
        vaultUI.showRecovery();
        setText(vaultMessage, "На сервере есть зашифрованный Vault. Введите recovery-фразу для локального импорта.");
      } else {
        setText(vaultMessage, "Синхронизация не выполнена; локальные данные не потеряны.");
      }
    } finally {
      syncButton.disabled = !client.session();
    }
  });

  recoveryForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = recoveryForm.querySelector('button[type="submit"]');
    const passphrase = recoveryForm.elements.passphrase.value;
    button.disabled = true;
    try {
      const result = await synchronizeVault({ client, vault, recoveryPassphrase: passphrase });
      if (accountVaultMigrationPassphrase) {
        await vault.rewrap(accountVaultMigrationPassphrase);
        await synchronizeVault({ client, vault });
        accountVaultMigrationPassphrase = null;
      }
      recoveryForm.reset();
      await vaultUI.hideRecoveryAndRestoreMode();
      vaultUI.mode("unlocked");
      vaultUI.render();
      setText(vaultMessage, `Зашифрованная ревизия ${result.revision} восстановлена и переведена на автоматическую разблокировку паролем аккаунта.`);
    } catch (error) {
      recoveryForm.elements.passphrase.value = "";
      if (String(error?.message ?? "") === "authentication_required") {
        showSession(null);
        await vaultUI.hideRecoveryAndRestoreMode();
        setText(vaultMessage, "Сессия истекла. Войдите снова.");
      } else {
        setText(vaultMessage, "Не удалось восстановить Vault. Recovery-фраза неверна или зашифрованные данные повреждены.");
      }
    } finally {
      button.disabled = false;
    }
  });

  recoveryCancel.addEventListener("click", async () => {
    await vaultUI.hideRecoveryAndRestoreMode();
    setText(vaultMessage, "Восстановление отменено; удалённый Vault не изменён.");
  });

  conflictForm.addEventListener("change", updateConflictApplyState);
  conflictForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!activeConflicts) return;
    conflictApply.disabled = true;
    try {
      const resolutions = activeConflicts.ids.map((id, index) => ({
        id,
        choice: conflictForm.querySelector(`input[name="conflict-${index}"]:checked`)?.value,
      }));
      const result = await vault.resolveConflicts({ revision: activeConflicts.revision, resolutions });
      hideConflicts();
      vaultUI.render();
      setText(vaultMessage, `${result.conflictsResolved} конфликт(а) разрешено локально. Синхронизируйте ещё раз для условной загрузки.`);
    } catch {
      setText(vaultMessage, "Набор конфликтов устарел или выбран не полностью. Запустите синхронизацию ещё раз.");
      hideConflicts();
    } finally {
      syncButton.disabled = !client.session();
    }
  });

  showSession(null);
  setAuthMode("login");
  return { client, showAuth: setAuthMode, teamWorkspace };
}

export function initializePortalNavigation({
  documentValue = document,
  locationValue = location,
  historyValue = history,
  vaultUI = null,
  teamUI = null,
  showAuthMode = () => {},
} = {}) {
  const brand = documentValue.querySelector("#site-brand");
  const publicActions = documentValue.querySelector("#public-actions");
  const hero = documentValue.querySelector("#public-hero");
  const heroCopy = documentValue.querySelector("#public-hero-copy");
  const heroPreview = documentValue.querySelector("#cloud-hero-preview");
  const auth = documentValue.querySelector("#cloud-account");
  const authBack = documentValue.querySelector("#cloud-auth-back");
  const publicGrid = documentValue.querySelector("#public-grid");
  const publicAccess = documentValue.querySelector("#public-access");
  const workspace = documentValue.querySelector("#cloud-workspace");
  const workspaceTitle = documentValue.querySelector("#workspace-title");
  const workspacePanels = [...documentValue.querySelectorAll(".workspace-panel")];
  const workspaceButtons = [...documentValue.querySelectorAll("[data-workspace-target]")];
  const sidebarButtons = [...documentValue.querySelectorAll(".workspace-sidebar [data-workspace-target]")];
  const titles = {
    "workspace-overview": "Обзор",
    "local-vault": "Personal Vault",
    "team-vault": "Команды",
    "workspace-devices": "Устройства",
    "workspace-settings": "Настройки",
  };
  const resourceTitles = {
    host: "Хосты",
    snippet: "Сниппеты",
    credential: "Учётные данные",
    forwarding: "Forwarding",
    all: "Personal Vault",
  };
  const teamTitles = {
    teams: "Команды", members: "Участники команд", vaults: "Папки команд",
    hosts: "Хосты команд", management: "Управление командой",
  };
  const workspaceRoutes = {
    "/app": ["workspace-overview", null, null],
    "/app/hosts": ["local-vault", "host", null],
    "/app/snippets": ["local-vault", "snippet", null],
    "/app/credentials": ["local-vault", "credential", null],
    "/app/forwarding": ["local-vault", "forwarding", null],
    "/app/personal-vault": ["local-vault", "all", null],
    "/app/teams": ["team-vault", null, "teams"],
    "/app/team-members": ["team-vault", null, "members"],
    "/app/team-folders": ["team-vault", null, "vaults"],
    "/app/team-hosts": ["team-vault", null, "hosts"],
    "/app/team-management": ["team-vault", null, "management"],
    "/app/devices": ["workspace-devices", null, null],
    "/app/settings": ["workspace-settings", null, null],
  };
  let sessionActive = false;
  let requestedWorkspaceRoute = "/app";

  function setPath(path, replace = false) {
    if (locationValue.pathname === path) return;
    const method = replace ? "replaceState" : "pushState";
    historyValue[method]?.({}, "", path);
  }

  function selectWorkspacePanel(target, recordFilter = null, teamView = null) {
    const panelID = Object.hasOwn(titles, target) ? target : "workspace-overview";
    for (const panel of workspacePanels) panel.hidden = panel.id !== panelID;
    for (const button of sidebarButtons) {
      const matchesPanel = button.dataset.workspaceTarget === panelID;
      const matchesFilter = panelID !== "local-vault"
        || (button.dataset.recordFilter || "all") === (recordFilter || "all");
      const matchesTeamView = panelID !== "team-vault"
        || (button.dataset.teamView || "teams") === (teamView || "teams");
      button.classList.toggle("active", matchesPanel && matchesFilter && matchesTeamView);
    }
    setText(workspaceTitle, panelID === "local-vault"
      ? resourceTitles[recordFilter || "all"]
      : panelID === "team-vault" ? teamTitles[teamView || "teams"] : titles[panelID]);
    if (recordFilter) vaultUI?.setFilter(recordFilter);
    if (panelID === "team-vault") teamUI?.setView(teamView || "teams");
  }

  function routeForWorkspace(target, recordFilter = null, teamView = null) {
    const normalizedFilter = target === "local-vault" ? recordFilter || "all" : null;
    const normalizedTeamView = target === "team-vault" ? teamView || "teams" : null;
    return Object.entries(workspaceRoutes).find(([, value]) => value[0] === target
      && value[1] === normalizedFilter && value[2] === normalizedTeamView)?.[0] ?? "/app";
  }

  function selectWorkspaceRoute(pathname) {
    const [target, recordFilter, teamView] = workspaceRoutes[pathname] ?? workspaceRoutes["/app"];
    selectWorkspacePanel(target, recordFilter, teamView);
  }

  function showLanding({ replace = false } = {}) {
    brand.hidden = false;
    publicActions.hidden = false;
    hero.hidden = false;
    hero.classList.remove("auth-active");
    heroCopy.hidden = false;
    heroPreview.hidden = false;
    auth.hidden = true;
    publicGrid.hidden = false;
    publicAccess.hidden = false;
    workspace.hidden = true;
    setPath("/", replace);
  }

  function showAuthentication(mode = "login", { replace = false } = {}) {
    brand.hidden = false;
    publicActions.hidden = true;
    hero.hidden = false;
    hero.classList.add("auth-active");
    heroCopy.hidden = true;
    heroPreview.hidden = true;
    auth.hidden = false;
    publicGrid.hidden = true;
    publicAccess.hidden = true;
    workspace.hidden = true;
    showAuthMode(mode);
    setPath("/login", replace);
    documentValue.querySelector(mode === "registration" ? "#cloud-registration-name" : "#cloud-email")?.focus();
  }

  function showWorkspace({ replace = false } = {}) {
    brand.hidden = true;
    hero.hidden = true;
    publicGrid.hidden = true;
    publicAccess.hidden = true;
    workspace.hidden = false;
    const route = Object.hasOwn(workspaceRoutes, locationValue.pathname)
      ? locationValue.pathname
      : requestedWorkspaceRoute;
    requestedWorkspaceRoute = route;
    selectWorkspaceRoute(route);
    setPath(route, replace);
  }

  for (const button of documentValue.querySelectorAll("[data-open-auth]")) {
    button.addEventListener("click", () => showAuthentication(button.dataset.openAuth || "login"));
  }
  authBack.addEventListener("click", () => showLanding());
  for (const button of workspaceButtons) {
    button.addEventListener("click", () => {
      const target = button.dataset.workspaceTarget;
      const recordFilter = button.dataset.recordFilter || null;
      const teamView = button.dataset.teamView || null;
      selectWorkspacePanel(target, recordFilter, teamView);
      requestedWorkspaceRoute = routeForWorkspace(target, recordFilter, teamView);
      setPath(requestedWorkspaceRoute);
      workspace.scrollIntoView?.({ block: "start" });
    });
  }

  const view = {
    sessionChanged(user) {
      if (user) {
        sessionActive = true;
        showWorkspace();
      } else if (sessionActive) {
        sessionActive = false;
        showAuthentication("login", { replace: true });
      }
    },
    showAuthentication,
    showLanding,
    showWorkspace,
    selectWorkspacePanel,
  };

  const initialPath = String(locationValue.pathname || "/");
  const requestedAuthMode = new URLSearchParams(locationValue.search).get("auth");
  if (requestedAuthMode === "login" || requestedAuthMode === "registration") {
    showAuthentication(requestedAuthMode, { replace: true });
    return view;
  }
  if (initialPath === "/login" || Object.hasOwn(workspaceRoutes, initialPath)) {
    if (Object.hasOwn(workspaceRoutes, initialPath)) requestedWorkspaceRoute = initialPath;
    showAuthentication("login", { replace: false });
  } else {
    showLanding({ replace: initialPath !== "/" });
  }
  documentValue.defaultView?.addEventListener("popstate", () => {
    if (sessionActive && Object.hasOwn(workspaceRoutes, locationValue.pathname)) showWorkspace({ replace: true });
    else if (locationValue.pathname === "/login") showAuthentication("login", { replace: true });
    else showLanding({ replace: true });
  });
  return view;
}

async function updateServiceStatus(documentValue, fetchValue) {
  const status = documentValue.querySelector("#service-status");
  try {
    const response = await fetchValue("/v1/meta", {
      headers: { Accept: "application/json" },
      cache: "no-store",
    });
    if (!response.ok) throw new Error("unavailable");
    const meta = await response.json();
    status.textContent = `API v${meta.apiVersion} · сервис доступен`;
    status.classList.add("ok");
    return meta;
  } catch {
    status.textContent = "Сервис недоступен";
    return null;
  }
}

export async function initializePortal({
  documentValue = document,
  locationValue = location,
  historyValue = history,
  fetchValue = fetch,
} = {}) {
  const verification = consumeVerificationFragment(locationValue, historyValue);
  const passwordReset = consumePasswordResetFragment(locationValue, historyValue);
  const teamInvitation = consumeTeamInvitationFragment(locationValue, historyValue);
  if (verification.present) {
    const panel = documentValue.querySelector("#email-verification");
    const title = documentValue.querySelector("#verification-title");
    const message = documentValue.querySelector("#verification-message");
    const home = documentValue.querySelector("#verification-home");
    panel.hidden = false;
    try {
      if (!verification.token) throw new Error("invalid_verification_token");
      await submitEmailVerification(verification.token, fetchValue);
      panel.classList.add("success");
      title.textContent = "Email подтверждён";
      message.textContent = "Теперь можно вернуться в Selective Remote и войти в аккаунт.";
    } catch {
      panel.classList.add("error");
      title.textContent = "Ссылка недействительна";
      message.textContent = "Она могла истечь или уже была использована. Запросите новое письмо позже.";
    }
    home.hidden = false;
  }
  if (passwordReset.present) {
    const panel = documentValue.querySelector("#password-reset");
    const form = documentValue.querySelector("#password-reset-form");
    const title = documentValue.querySelector("#password-reset-title");
    const message = documentValue.querySelector("#password-reset-message");
    const password = documentValue.querySelector("#new-password");
    const confirmation = documentValue.querySelector("#confirm-password");
    const home = documentValue.querySelector("#password-reset-home");
    panel.hidden = false;
    if (!passwordReset.token) {
      panel.classList.add("error");
      title.textContent = "Ссылка недействительна";
      message.textContent = "Она могла истечь или уже была использована.";
      form.hidden = true;
      home.hidden = false;
    } else {
      form.addEventListener("submit", async (event) => {
        event.preventDefault();
        if (password.value !== confirmation.value) {
          message.textContent = "Пароли не совпадают.";
          return;
        }
        const button = form.querySelector("button");
        button.disabled = true;
        try {
          await submitPasswordReset(passwordReset.token, password.value, fetchValue);
          password.value = "";
          confirmation.value = "";
          form.hidden = true;
          panel.classList.add("success");
          title.textContent = "Пароль изменён";
          message.textContent = "Все прежние сессии отозваны. Теперь войдите с новым паролем.";
          home.hidden = false;
        } catch {
          panel.classList.add("error");
          message.textContent = "Не удалось изменить пароль. Ссылка могла истечь или уже была использована.";
          button.disabled = false;
        }
      });
    }
  }
  const metadata = await updateServiceStatus(documentValue, fetchValue);
  const vaultUI = await initializeLocalVault({ documentValue });
  let navigation = null;
  const account = await initializeCloudAccount({
    documentValue,
    vaultUI,
    fetchValue,
    metadata,
    initialTeamInvitationToken: teamInvitation.token,
    onSessionChange: (user) => navigation?.sessionChanged(user),
  });
  navigation = initializePortalNavigation({
    documentValue,
    locationValue,
    historyValue,
    vaultUI,
    teamUI: account?.teamWorkspace,
    showAuthMode: account?.showAuth,
  });
  if (teamInvitation.present) {
    navigation?.showAuthentication("login", { replace: true });
    const accountMessage = documentValue.querySelector("#cloud-account-message");
    if (accountMessage) accountMessage.textContent = teamInvitation.token
      ? "Войдите в аккаунт, затем примите одноразовое Team-приглашение в разделе «Команды»."
      : "Одноразовая ссылка приглашения недействительна.";
  }
}

export function initializeAppearance({ documentValue = document } = {}) {
  const allowed = new Set(["graphite", "emerald", "light"]);
  let selected = "graphite";
  const controls = [...documentValue.querySelectorAll("[data-theme-select]")];
  const apply = (theme) => {
    selected = allowed.has(theme) ? theme : "graphite";
    documentValue.documentElement.dataset.theme = selected;
    for (const control of controls) control.value = selected;
  };
  for (const control of controls) control.addEventListener("change", () => apply(control.value));
  apply(selected);
  return { theme: () => selected, apply };
}

if (typeof document !== "undefined") {
  initializeAppearance();
  await initializePortal();
}
