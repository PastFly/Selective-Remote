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
  rotateTeamVault,
  synchronizeTeamVault,
} from "./team-vault-sync.js";

const verificationPrefix = "#verify-email?";
const passwordResetPrefix = "#reset-password?";

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
} = {}) {
  const section = documentValue.querySelector("#team-vault");
  if (!section || !client) return null;
  const sectionTitle = documentValue.querySelector("#team-vault-title");
  const message = documentValue.querySelector("#team-vault-message");
  const devices = documentValue.querySelector("#team-devices");
  const devicesRefresh = documentValue.querySelector("#team-devices-refresh");
  const createTeamForm = documentValue.querySelector("#team-create-form");
  const acceptInvitationForm = documentValue.querySelector("#team-invitation-accept-form");
  const onboarding = documentValue.querySelector("#team-onboarding");
  const teamSelect = documentValue.querySelector("#team-select");
  const teamRefresh = documentValue.querySelector("#team-refresh");
  const selectedPanel = documentValue.querySelector("#team-selected");
  const teamRole = documentValue.querySelector("#team-role");
  const members = documentValue.querySelector("#team-members");
  const membersView = documentValue.querySelector("#team-members-view");
  const inviteForm = documentValue.querySelector("#team-invite-form");
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
  const recordType = documentValue.querySelector("#team-record-type");
  const recordTitle = documentValue.querySelector("#team-record-title");
  const recordTarget = documentValue.querySelector("#team-record-target");
  const recordSecret = documentValue.querySelector("#team-record-secret");
  const recordTargetLabel = documentValue.querySelector("#team-record-target-label");
  const recordSecretLabel = documentValue.querySelector("#team-record-secret-label");
  const records = documentValue.querySelector("#team-vault-records");
  const conflictPanel = documentValue.querySelector("#team-vault-conflicts");
  const conflictForm = documentValue.querySelector("#team-vault-conflicts-form");
  const conflictList = documentValue.querySelector("#team-vault-conflicts-list");
  const conflictApply = documentValue.querySelector("#team-vault-conflicts-apply");
  let identity = null;
  let teams = [];
  let vaults = [];
  let teamMembers = [];
  let selectedTeam = null;
  let selectedVault = null;
  let controller = null;
  let activeConflicts = null;
  let activeView = "teams";

  function canManage() {
    return ["owner", "admin"].includes(selectedTeam?.role);
  }

  function canEdit() {
    return ["owner", "admin", "editor"].includes(selectedTeam?.role);
  }

  function updateTeamMessage() {
    if (!selectedTeam) return;
    if (activeView === "teams") {
      setText(message, `Team «${selectedTeam.name}» · участников: ${teamMembers.length}.`);
    } else if (activeView === "vaults") {
      setText(message, `Team «${selectedTeam.name}» · хранилищ: ${vaults.length}.`);
    } else {
      setText(message, selectedVault
        ? `Team «${selectedTeam.name}» · Vault «${selectedVault.name}».`
        : `Team «${selectedTeam.name}» · выберите Vault для просмотра хостов.`);
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
  }

  function renderRecords() {
    records.replaceChildren();
    if (!controller) return;
    const current = controller.document();
    const visibleRecords = current.records.filter((value) => activeView !== "hosts" || value.type === "host");
    if (visibleRecords.length === 0) {
      const empty = documentValue.createElement("p");
      empty.className = "vault-empty";
      empty.textContent = activeView === "hosts"
        ? "В выбранном Team Vault пока нет хостов."
        : "Shared Vault пока пуст.";
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
      remove.disabled = !canEdit();
      remove.addEventListener("click", async () => {
        remove.disabled = true;
        try {
          await controller.delete(record.id);
          clearConflicts();
          renderRecords();
          setText(workspaceStatus, "Удаление зашифровано локально. Выполните синхронизацию.");
        } catch {
          setText(workspaceStatus, "Не удалось сохранить удаление.");
          remove.disabled = !canEdit();
        }
      });
      card.append(heading, summary, metadata, remove);
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
          setText(message, "Ключ устройства одобрен. Owner/Admin может выдать недостающие wrappers из открытого Shared Vault.");
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
      name.textContent = member.displayName || member.email;
      detail.textContent = `${member.email} · epoch ${member.epoch}`;
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
        if (!confirmValue(`Отозвать доступ для ${member.email}? Все Shared Vaults будут заморожены до ротации ключей.`)) return;
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
      option.textContent = `${member.displayName || member.email} · ${member.role}`;
      transferOwnershipMember.append(option);
    }
    transferOwnershipForm.querySelector("button").disabled = transferOwnershipMember.options.length === 0;
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

  function lockCurrentVault() {
    controller?.lock();
    controller = null;
    selectedVault = null;
    workspace.hidden = true;
    rotateButton.hidden = true;
    rotateButton.disabled = true;
    grantWrappersButton.hidden = true;
    grantWrappersButton.disabled = true;
    records.replaceChildren();
    clearConflicts();
  }

  function setView(view) {
    activeView = ["teams", "vaults", "hosts"].includes(view) ? view : "teams";
    section.dataset.teamView = activeView;
    setText(sectionTitle, { teams: "Команды", vaults: "Командные хранилища", hosts: "Командные хосты" }[activeView]);
    onboarding.hidden = activeView !== "teams";
    membersView.hidden = activeView !== "teams";
    vaultDirectoryView.hidden = activeView === "teams";
    lifecyclePanel.hidden = activeView !== "teams" || selectedTeam?.role !== "owner";
    createVaultForm.hidden = activeView !== "vaults" || !canManage();
    workspace.hidden = activeView === "teams" || !controller;
    if (activeView === "hosts") recordType.value = "host";
    updateRecordLabels();
    if (controller) {
      clearConflicts();
      renderRecords();
      setWorkspaceControls(false);
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
    workspace.hidden = activeView === "teams";
    rotateButton.hidden = !vault.rotationRequired || !canManage();
    rotateButton.disabled = !vault.rotationRequired || !canManage();
    grantWrappersButton.hidden = vault.rotationRequired || !canManage();
    grantWrappersButton.disabled = true;
    workspaceTitle.textContent = `${selectedTeam.name} / ${vault.name}`;
    setText(workspaceStatus, "Загружаем зашифрованную Team-ревизию…");
    syncButton.disabled = true;
    try {
      const result = await synchronizeTeamVault({ client, controller, role: selectedTeam.role });
      renderRecords();
      setWorkspaceControls(false);
      syncButton.disabled = false;
      grantWrappersButton.disabled = grantWrappersButton.hidden;
      setText(workspaceStatus, {
        initialized: `Shared Vault создан и зашифрован для всех одобренных устройств · ревизия ${result.revision}.`,
        downloaded: `Team-ревизия ${result.revision} расшифрована локально.`,
        up_to_date: `Shared Vault синхронизирован · ревизия ${result.revision}.`,
      }[result.status] ?? "Shared Vault открыт.");
    } catch (error) {
      const code = String(error?.message ?? "");
      setWorkspaceControls(true);
      grantWrappersButton.disabled = true;
      rotateButton.hidden = code !== "team_vault_rotation_required" || !canManage();
      rotateButton.disabled = rotateButton.hidden;
      setText(workspaceStatus, code === "team_vault_rotation_required"
        ? "Запись заморожена: после отзыва участника или устройства требуется полная ротация ключа."
        : code === "team_vault_key_unavailable"
          ? "Для этого устройства нет wrapper ключа. Требуется одобрение существующим устройством."
          : "Shared Vault не открыт; локальные данные не изменены.");
    }
  }

  async function loadSelectedTeam() {
    selectedTeam = teams.find((team) => team.id === teamSelect.value) ?? null;
    lockCurrentVault();
    if (!selectedTeam) {
      selectedPanel.hidden = true;
      return;
    }
    selectedPanel.hidden = false;
    teamRole.textContent = `${selectedTeam.name} · ${selectedTeam.role}`;
    inviteForm.hidden = !canManage();
    createVaultForm.hidden = activeView !== "vaults" || !canManage();
    lifecyclePanel.hidden = activeView !== "teams" || selectedTeam.role !== "owner";
    renameTeamForm.elements.name.value = selectedTeam.name;
    archiveTeamForm.reset();
    transferOwnershipForm.reset();
    const [loadedMembers, sharedVaults] = await Promise.all([
      client.listTeamMembers(selectedTeam.id),
      client.listSharedVaults(selectedTeam.id),
    ]);
    teamMembers = loadedMembers;
    renderMembers(teamMembers);
    vaults = sharedVaults;
    populateVaults();
    updateTeamMessage();
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
      selectedPanel.hidden = true;
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
      await loadTeams();
      setText(message, "Приглашение принято.");
    } catch {
      acceptInvitationForm.elements.token.value = "";
      setText(message, "Приглашение недействительно, истекло или предназначено другому email.");
    } finally {
      button.disabled = false;
    }
  });

  inviteForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = inviteForm.querySelector("button");
    button.disabled = true;
    try {
      await client.inviteTeamMember({
        teamID: selectedTeam.id,
        email: inviteForm.elements.email.value,
        role: inviteForm.elements.role.value,
      });
      inviteForm.reset();
      setText(message, "Приглашение поставлено в защищённую очередь доставки на 48 часов.");
    } catch {
      setText(message, "Приглашение не создано. Проверьте SMTP, роль и полномочия.");
    } finally {
      button.disabled = false;
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
      await openSelectedVault();
      setText(message, "Shared Vault создан. Состояние криптографической инициализации показано ниже.");
    } catch {
      setText(message, "Shared Vault не создан или не инициализирован. Проверьте роль и одобрение устройства.");
    } finally {
      button.disabled = false;
    }
  });

  teamSelect.addEventListener("change", () => loadSelectedTeam().catch(() => setText(message, "Не удалось загрузить Team.")));
  teamRefresh.addEventListener("click", () => loadTeams(selectedTeam?.id).catch(() => setText(message, "Не удалось обновить Teams.")));
  devicesRefresh.addEventListener("click", () => loadDevices().catch(() => setText(message, "Не удалось обновить устройства.")));
  vaultOpen.addEventListener("click", () => openSelectedVault());
  rotateButton.addEventListener("click", async () => {
    if (!controller || !selectedVault || !canManage()) return;
    if (!confirmValue("Зашифровать полную текущую Team-ревизию новым ключом и выдать wrappers всем актуальным одобренным устройствам?")) return;
    rotateButton.disabled = true;
    syncButton.disabled = true;
    lockButton.disabled = true;
    grantWrappersButton.disabled = true;
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
        grantWrappersButton.hidden = !canManage();
        grantWrappersButton.disabled = grantWrappersButton.hidden;
        clearConflicts();
        renderRecords();
        setWorkspaceControls(false);
        setText(workspaceStatus, `Ротация завершена атомарно · ревизия ${result.revision} · поколение ключа ${result.keyGeneration}.`);
      }
    } catch {
      setText(workspaceStatus, "Ротация не подтверждена. Локальный snapshot не заменён; безопасно повторите операцию.");
    } finally {
      lockButton.disabled = false;
      syncButton.disabled = !controller || !rotateButton.hidden;
      rotateButton.disabled = rotateButton.hidden || !canManage() || Boolean(activeConflicts);
      grantWrappersButton.disabled = grantWrappersButton.hidden || Boolean(activeConflicts);
    }
  });
  grantWrappersButton.addEventListener("click", async () => {
    if (!controller || !selectedVault || !canManage() || selectedVault.rotationRequired) return;
    grantWrappersButton.disabled = true;
    try {
      const keyDevices = await client.listTeamKeyDevices(controller.scope);
      const missing = keyDevices.devices.filter((device) => !device.hasWrapper);
      const state = await controller.syncState();
      for (const recipient of missing) {
        const wrapper = await controller.prepareWrapper(recipient);
        await client.grantTeamVaultWrapper(
          controller.scope,
          { keyGeneration: state.keyGeneration, wrapper },
          `web:team:vault:grant:${globalThis.crypto.randomUUID()}`,
        );
      }
      setText(workspaceStatus, missing.length === 0
        ? "Все актуальные одобренные устройства уже имеют wrapper этой генерации."
        : `Выдано недостающих wrappers: ${missing.length}. Vault plaintext не покидал браузер.`);
    } catch {
      setText(workspaceStatus, "Не все wrappers подтверждены. Обновите состояние и безопасно повторите операцию.");
    } finally {
      grantWrappersButton.disabled = !controller || selectedVault?.rotationRequired || !canManage();
    }
  });
  recordType.addEventListener("change", updateRecordLabels);
  recordForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = recordForm.querySelector("button");
    button.disabled = true;
    try {
      await controller.upsert({
        type: recordType.value,
        data: localVaultRecordData(recordType.value, {
          title: recordTitle.value,
          target: recordTarget.value,
          secret: recordSecret.value,
        }),
      });
      recordForm.reset();
      updateRecordLabels();
      clearConflicts();
      rotateButton.disabled = !selectedVault?.rotationRequired || !canManage();
      renderRecords();
      setText(workspaceStatus, "Изменение зашифровано локально. Выполните синхронизацию.");
    } catch {
      setText(workspaceStatus, "Запись не сохранена. Проверьте поля и роль.");
    } finally {
      button.disabled = !canEdit();
    }
  });

  syncButton.addEventListener("click", async () => {
    syncButton.disabled = true;
    try {
      const result = await synchronizeTeamVault({ client, controller, role: selectedTeam.role });
      if (result.status === "conflict") renderConflicts(result);
      else {
        clearConflicts();
        renderRecords();
      }
      const messages = {
        initialized: `Shared Vault инициализирован · ревизия ${result.revision}.`,
        uploaded: `Зашифрованная Team-ревизия ${result.revision} загружена.`,
        uploaded_with_new_local_changes: `Ревизия ${result.revision} загружена; остались новые локальные изменения.`,
        downloaded: `Team-ревизия ${result.revision} загружена и объединена локально.`,
        up_to_date: `Shared Vault синхронизирован · ревизия ${result.revision}.`,
        remote_changed: `Team Vault изменился до ревизии ${result.remoteRevision}. Повторите синхронизацию.`,
        conflict: `Обнаружено конфликтов: ${result.conflicts.length}. Выберите версии явно.`,
      };
      setText(workspaceStatus, messages[result.status] ?? "Синхронизация завершена.");
    } catch (error) {
      setText(workspaceStatus, String(error?.message ?? "") === "team_vault_rotation_required"
        ? "Синхронизация заморожена до безопасной ротации ключа."
        : "Синхронизация не выполнена; локальная зашифрованная копия сохранена.");
    } finally {
      syncButton.disabled = !controller;
    }
  });

  lockButton.addEventListener("click", () => {
    controller?.lock();
    records.replaceChildren();
    clearConflicts();
    setWorkspaceControls(true);
    setText(workspaceStatus, "Ключ Shared Vault удалён из памяти. Нажмите синхронизацию для повторного локального unlock.");
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
        : "Конфликты разрешены локально. Синхронизируйте условную запись.");
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
      await Promise.all([loadDevices(), loadTeams()]);
    },
    deactivate() {
      identity = null;
      teams = [];
      vaults = [];
      teamMembers = [];
      selectedTeam = null;
      lockCurrentVault();
      teamSelect.replaceChildren();
      devices.replaceChildren();
      members.replaceChildren();
      selectedPanel.hidden = true;
    },
  };
}

export async function initializeCloudAccount({
  documentValue = document,
  vaultUI,
  fetchValue = fetch,
  metadata = null,
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
  const teamWorkspace = initializeTeamWorkspace({ documentValue, client });
  const teamDeviceRepository = createIndexedDBTeamDeviceRepository();
  let activeConflicts = null;
  vaultUI.setConflictResetListener(() => {
    activeConflicts = null;
    conflictApply.disabled = true;
  });

  function setAccountMessage(value, tone = null) {
    setText(message, value);
    message.classList.toggle("error", tone === "error");
    message.classList.toggle("success", tone === "success");
  }

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
      recoveryForm.reset();
      await vaultUI.hideRecoveryAndRestoreMode();
      vaultUI.mode("unlocked");
      vaultUI.render();
      setText(vaultMessage, `Зашифрованная ревизия ${result.revision} восстановлена и расшифрована только в этой вкладке.`);
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
  const teamTitles = { teams: "Команды", vaults: "Team Vaults", hosts: "Team Hosts" };
  let sessionActive = false;

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
    selectWorkspacePanel("workspace-overview");
    setPath("/app", replace);
  }

  for (const button of documentValue.querySelectorAll("[data-open-auth]")) {
    button.addEventListener("click", () => showAuthentication(button.dataset.openAuth || "login"));
  }
  authBack.addEventListener("click", () => showLanding());
  for (const button of workspaceButtons) {
    button.addEventListener("click", () => selectWorkspacePanel(
      button.dataset.workspaceTarget,
      button.dataset.recordFilter || null,
      button.dataset.teamView || null,
    ));
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
  if (initialPath === "/login" || initialPath === "/app") {
    showAuthentication("login", { replace: initialPath === "/app" });
  } else {
    showLanding({ replace: initialPath !== "/" });
  }
  documentValue.defaultView?.addEventListener("popstate", () => {
    if (sessionActive && locationValue.pathname === "/app") showWorkspace({ replace: true });
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
