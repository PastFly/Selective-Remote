import { createIndexedDBVaultRepository, createLocalVaultController } from "./vault-local.js";
import { createAuthenticatedVaultClient, synchronizeVault } from "./vault-sync.js";
import { newestVaultConflictChoice } from "./vault-model.js";
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

export function localVaultRecordData(type, { title, target, secret }, baseData = null) {
  const normalizedTitle = String(title ?? "").trim();
  const normalizedTarget = String(target ?? "").trim();
  const normalizedSecret = String(secret ?? "");
  if (!normalizedTitle || normalizedTitle.length > 120 || normalizedTarget.length > 2048 || normalizedSecret.length > 32_768) {
    throw new Error("invalid_local_record");
  }
  const preserved = baseData && typeof baseData === "object" ? { ...baseData } : {};
  if (type === "host" && normalizedTarget) return { ...preserved, title: normalizedTitle, address: normalizedTarget };
  if (type === "credential" && normalizedTarget && normalizedSecret) {
    return { ...preserved, title: normalizedTitle, username: normalizedTarget, secret: normalizedSecret };
  }
  if (type === "snippet" && normalizedSecret) return { ...preserved, title: normalizedTitle, body: normalizedSecret };
  if (type === "forwarding" && normalizedTarget) {
    return { ...preserved, title: normalizedTitle, destination: normalizedTarget, configuration: normalizedSecret };
  }
  throw new Error("invalid_local_record");
}

export function localVaultRecordFormValues(record) {
  const data = record?.data ?? {};
  if (record?.type === "host") return { title: data.title ?? "", target: data.address ?? "", secret: "" };
  if (record?.type === "credential") return { title: data.title ?? "", target: data.username ?? "", secret: data.secret ?? "" };
  if (record?.type === "snippet") return { title: data.title ?? "", target: "", secret: data.body ?? "" };
  if (record?.type === "forwarding") return { title: data.title ?? "", target: data.destination ?? "", secret: data.configuration ?? "" };
  throw new Error("invalid_local_record");
}

export function formatVaultTimestamp(value, { locales, timeZone } = {}) {
  const date = new Date(String(value ?? ""));
  if (Number.isNaN(date.getTime())) return "—";
  return new Intl.DateTimeFormat(locales, {
    dateStyle: "medium", timeStyle: "medium", ...(timeZone ? { timeZone } : {}),
  }).format(date);
}

export function sortLocalVaultRecords(records, mode = "modified-desc") {
  const values = [...records];
  const title = (record) => String(record?.data?.title ?? "");
  if (mode === "title-asc") return values.sort((a, b) => title(a).localeCompare(title(b)));
  if (mode === "type-asc") return values.sort((a, b) => String(a.type).localeCompare(String(b.type)) || title(a).localeCompare(title(b)));
  return values.sort((a, b) => String(b.modifiedAt ?? "").localeCompare(String(a.modifiedAt ?? "")));
}

function decodePortableRecord(value) {
  const text = String(value ?? "");
  if (!text || text.length > 1_048_576) throw new Error("invalid_portable_record");
  const normalized = text.replace(/-/gu, "+").replace(/_/gu, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  const bytes = Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
  const decoded = JSON.parse(new TextDecoder().decode(bytes));
  if (!decoded || typeof decoded !== "object" || Array.isArray(decoded)) throw new Error("invalid_portable_record");
  return decoded;
}

function encodePortableRecord(value) {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/gu, "-").replace(/\//gu, "_").replace(/=+$/u, "");
}

export function personalHostEditorValues(record) {
  const data = record?.data ?? {};
  let profile = null;
  try { if (data.profile) profile = decodePortableRecord(data.profile); } catch { /* outer fields remain usable */ }
  const connectionType = String(profile?.connectionType ?? data.connectionType ?? "ssh");
  const address = connectionType === "serial"
    ? String(profile?.serialDevicePath ?? data.address ?? "")
    : String(profile?.host ?? data.address ?? "");
  return {
    title: String(profile?.friendlyName ?? data.title ?? ""),
    address,
    protocol: ["ssh", "rdp", "telnet", "serial"].includes(connectionType) ? connectionType : "ssh",
    port: Number(profile?.sshPort ?? data.port ?? (connectionType === "telnet" ? 23 : connectionType === "rdp" ? 3389 : 22)),
    username: String(profile?.username ?? data.username ?? ""),
    folder: String(profile?.group ?? data.folder ?? ""),
    tags: Array.isArray(profile?.tags ?? data.tags) ? (profile?.tags ?? data.tags).join(", ") : "",
    description: String(profile?.profileDescription ?? data.description ?? ""),
  };
}

export function personalHostRecordData({ title, address, protocol, port, username, folder, tags, description, baseData = null }) {
  const normalizedProtocol = String(protocol ?? "ssh");
  const normalizedPort = Number(port || (normalizedProtocol === "telnet" ? 23 : normalizedProtocol === "rdp" ? 3389 : 22));
  const normalizedUsername = String(username ?? "").trim();
  const normalizedFolder = String(folder ?? "").trim();
  const normalizedDescription = String(description ?? "").trim();
  const normalizedTags = [...new Set(String(tags ?? "").split(",").map((value) => value.trim()).filter(Boolean))];
  if (!["ssh", "rdp", "telnet", "serial"].includes(normalizedProtocol)
    || !Number.isSafeInteger(normalizedPort) || normalizedPort < 1 || normalizedPort > 65_535
    || normalizedUsername.length > 256 || normalizedFolder.length > 120 || normalizedDescription.length > 2_048
    || normalizedTags.length > 24 || normalizedTags.some((value) => value.length > 64)) {
    throw new Error("invalid_personal_host");
  }
  const data = localVaultRecordData("host", { title, target: address, secret: "" }, baseData);
  data.connectionType = normalizedProtocol;
  data.port = normalizedPort;
  data.username = normalizedUsername;
  if (normalizedFolder) data.folder = normalizedFolder; else delete data.folder;
  if (normalizedTags.length) data.tags = normalizedTags; else delete data.tags;
  if (normalizedDescription) data.description = normalizedDescription; else delete data.description;
  if (baseData?.profile) {
    const profile = decodePortableRecord(baseData.profile);
    profile.friendlyName = data.title;
    profile.connectionType = normalizedProtocol;
    profile.username = normalizedUsername;
    profile.group = normalizedFolder;
    profile.tags = normalizedTags;
    profile.profileDescription = normalizedDescription;
    if (normalizedProtocol === "serial") profile.serialDevicePath = data.address;
    else profile.host = data.address;
    if (normalizedProtocol === "ssh" || normalizedProtocol === "telnet") profile.sshPort = normalizedPort;
    data.profile = encodePortableRecord(profile);
  }
  return data;
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

export function teamHostConnectionData({ protocol, host, port, username }) {
  const normalizedProtocol = String(protocol ?? "").toLowerCase();
  const normalizedHost = String(host ?? "").trim();
  const normalizedUsername = String(username ?? "").trim();
  const defaultPort = normalizedProtocol === "ssh" ? 22 : 3389;
  const normalizedPort = Number(port || defaultPort);
  if (!["ssh", "rdp"].includes(normalizedProtocol)
    || !normalizedHost || normalizedHost.length > 2048 || /[\s/@]/u.test(normalizedHost)
    || !Number.isSafeInteger(normalizedPort) || normalizedPort < 1 || normalizedPort > 65_535
    || normalizedUsername.length > 256 || normalizedUsername.includes("\n")) {
    throw new Error("invalid_team_host_connection");
  }
  const encodedUser = normalizedUsername ? `${encodeURIComponent(normalizedUsername)}@` : "";
  const encodedHost = normalizedHost.includes(":") && !normalizedHost.startsWith("[")
    ? `[${normalizedHost}]` : normalizedHost;
  return {
    protocol: normalizedProtocol, host: normalizedHost, port: normalizedPort,
    username: normalizedUsername,
    target: `${normalizedProtocol}://${encodedUser}${encodedHost}:${normalizedPort}`,
  };
}

export function parseTeamHostConnection(data) {
  const address = String(data?.address ?? "").trim();
  const profileProtocol = String(data?.connectionType ?? "").toLowerCase();
  try {
    const parsed = new URL(address);
    if (["ssh:", "rdp:"].includes(parsed.protocol) && parsed.hostname) {
      return {
        protocol: parsed.protocol.slice(0, -1), host: parsed.hostname,
        port: Number(parsed.port || (parsed.protocol === "ssh:" ? 22 : 3389)),
        username: decodeURIComponent(parsed.username || ""),
      };
    }
  } catch { /* legacy address */ }
  return {
    protocol: ["ssh", "rdp"].includes(profileProtocol) ? profileProtocol : "rdp",
    host: address,
    port: profileProtocol === "ssh" ? 22 : 3389,
    username: String(data?.username ?? ""),
  };
}

export function localVaultRecordSummary(record) {
  const data = record?.data ?? {};
  let summary = "";
  if (record?.type === "host") summary = String(data.address ?? "");
  if (record?.type === "credential") summary = `${String(data.username ?? "")} · секрет скрыт`;
  if (record?.type === "snippet") summary = String(data.body ?? "");
  if (record?.type === "forwarding") summary = String(data.destination ?? "");
  if (record?.type === "sshKey") summary = "Приватный ключ защищён · содержимое скрыто";
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
  const waiting = documentValue.querySelector("#local-vault-waiting");
  const workspace = documentValue.querySelector("#local-vault-workspace");
  const actions = documentValue.querySelector("#local-vault-actions");
  const overviewNotice = documentValue.querySelector("#workspace-vault-notice");
  const message = documentValue.querySelector("#local-vault-message");
  const records = documentValue.querySelector("#local-vault-records");
  const recordForm = documentValue.querySelector("#local-vault-record-form");
  const search = documentValue.querySelector("#personal-vault-search");
  const sort = documentValue.querySelector("#personal-vault-sort");
  const folderFilter = documentValue.querySelector("#personal-vault-folder-filter");
  const createButton = documentValue.querySelector("#local-record-create");
  const saveButton = documentValue.querySelector("#local-record-save");
  const cancelButton = documentValue.querySelector("#local-record-cancel");
  const editorTitle = documentValue.querySelector("#local-record-editor-title");
  const editorHint = documentValue.querySelector("#local-record-editor-hint");
  const lockButton = documentValue.querySelector("#local-vault-lock");
  const type = documentValue.querySelector("#local-record-type");
  const title = documentValue.querySelector("#local-record-title");
  const target = documentValue.querySelector("#local-record-target");
  const secret = documentValue.querySelector("#local-record-secret");
  const targetLabel = documentValue.querySelector("#local-record-target-label");
  const secretLabel = documentValue.querySelector("#local-record-secret-label");
  const hostFields = documentValue.querySelector("#personal-host-fields");
  const hostProtocol = documentValue.querySelector("#local-host-protocol");
  const hostPort = documentValue.querySelector("#local-host-port");
  const hostUsername = documentValue.querySelector("#local-host-username");
  const hostFolder = documentValue.querySelector("#local-host-folder");
  const hostTags = documentValue.querySelector("#local-host-tags");
  const hostDescription = documentValue.querySelector("#local-host-description");
  const conflictPanel = documentValue.querySelector("#local-vault-conflicts");
  const conflictForm = documentValue.querySelector("#local-vault-conflicts-form");
  const conflictList = documentValue.querySelector("#local-vault-conflicts-list");
  const hostDetail = documentValue.querySelector("#host-detail-dialog");
  const hostDetailTitle = documentValue.querySelector("#host-detail-title");
  const hostDetailAddress = documentValue.querySelector("#host-detail-address");
  const hostDetailModified = documentValue.querySelector("#host-detail-modified");
  const hostDetailProtocol = documentValue.querySelector("#host-detail-protocol");
  const hostDetailPort = documentValue.querySelector("#host-detail-port");
  const hostDetailUsername = documentValue.querySelector("#host-detail-username");
  const hostDetailPasswordState = documentValue.querySelector("#host-detail-password-state");
  const hostDetailFolder = documentValue.querySelector("#host-detail-folder");
  const hostDetailTags = documentValue.querySelector("#host-detail-tags");
  const hostDetailDescription = documentValue.querySelector("#host-detail-description");
  const hostDetailEdit = documentValue.querySelector("#host-detail-edit");
  const hostDetailCopyPassword = documentValue.querySelector("#host-detail-copy-password");
  const hostDetailOpenSSH = documentValue.querySelector("#host-detail-open-ssh");
  const hostDetailOpenSFTP = documentValue.querySelector("#host-detail-open-sftp");
  if (hostDetail && hostDetail.parentElement !== documentValue.body) documentValue.body.append(hostDetail);
  const filterButtons = [...documentValue.querySelectorAll("#personal-vault-filters [data-record-filter]")];
  const controller = createLocalVaultController({ repository });
  let conflictResetListener = () => {};
  let filterChangeListener = () => {};
  let lockListener = async () => {};
  let activeRecordFilter = "all";
  let editingRecordID = null;

  function updateCreateButton() {
    const labels = {
      host: "Добавить Host",
      credential: "Добавить Credential",
      snippet: "Добавить Snippet",
      forwarding: "Добавить Forwarding",
    };
    setText(createButton, labels[activeRecordFilter] ?? "Добавить запись");
  }

  function resetEditor({ hide = true } = {}) {
    editingRecordID = null;
    recordForm.reset();
    recordForm.hidden = hide;
    type.disabled = false;
    saveButton.textContent = "Зашифровать и сохранить";
    cancelButton.textContent = "Отменить";
    cancelButton.hidden = hide;
    setText(editorTitle, "Новая запись");
    setText(editorHint, "Выберите тип и заполните поля. Всё шифруется в браузере.");
    updateLabels();
  }

  function beginCreate() {
    resetEditor({ hide: false });
    if (["host", "credential", "snippet", "forwarding"].includes(activeRecordFilter)) {
      type.value = activeRecordFilter;
      type.disabled = true;
    }
    cancelButton.textContent = "Отменить создание";
    updateLabels();
    setText(message, "Новая запись. Заполните поля и сохраните зашифрованную версию.");
    recordForm.scrollIntoView?.({ behavior: "smooth", block: "center" });
    title.focus?.();
  }

  function beginEdit(record) {
    const values = localVaultRecordFormValues(record);
    editingRecordID = record.id;
    recordForm.hidden = false;
    type.value = record.type;
    type.disabled = true;
    title.value = values.title;
    target.value = values.target;
    secret.value = values.secret;
    if (record.type === "host") {
      const host = personalHostEditorValues(record);
      title.value = host.title;
      target.value = host.address;
      hostProtocol.value = host.protocol;
      hostPort.value = String(host.port);
      hostUsername.value = host.username;
      hostFolder.value = host.folder;
      hostTags.value = host.tags;
      hostDescription.value = host.description;
    }
    saveButton.textContent = "Сохранить изменения";
    cancelButton.textContent = "Отменить изменение";
    cancelButton.hidden = false;
    setText(editorTitle, `Редактирование ${String(record.data?.title ?? "записи")}`);
    setText(editorHint, record.type === "host"
      ? "Основные поля и организация Host синхронизируются с приложением. Расширенные SSH/RDP-параметры сохраняются без изменений."
      : "Измените нужные поля и сохраните новую зашифрованную версию записи.");
    updateLabels();
    recordForm.scrollIntoView?.({ behavior: "smooth", block: "center" });
    title.focus?.();
    setText(message, `Редактирование: ${String(record.data?.title ?? "Без названия")}.`);
  }

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

  function mode(value) {
    workspace.hidden = value !== "unlocked";
    waiting.hidden = value === "unlocked";
    if (actions) actions.hidden = value !== "unlocked";
    if (overviewNotice) overviewNotice.hidden = value === "unlocked";
    if (value !== "unlocked") {
      for (const recordType of ["host", "credential", "snippet", "forwarding", "sshKey"]) {
        setText(documentValue.querySelector(`#workspace-${recordType}-count`), "—");
      }
    }
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
    const isHost = type.value === "host";
    hostFields.hidden = !isHost;
    secretLabel.hidden = isHost;
    secret.hidden = isHost;
    hostPort.disabled = !["ssh", "telnet"].includes(hostProtocol.value);
    if (hostProtocol.value === "rdp") hostPort.value = "3389";
    if (hostProtocol.value === "serial") hostPort.value = "1";
  }

  function render() {
    const current = controller.document();
    const counts = { host: 0, credential: 0, snippet: 0, forwarding: 0, sshKey: 0 };
    for (const record of current.records) {
      if (Object.hasOwn(counts, record.type)) counts[record.type] += 1;
    }
    for (const [recordType, count] of Object.entries(counts)) {
      setText(documentValue.querySelector(`#workspace-${recordType}-count`), String(count));
    }
    const hostFolderName = (record) => String(record?.data?.folder ?? "").trim() || "Без папки";
    const selectedFolder = String(folderFilter?.value ?? "all");
    const folders = [...new Set(current.records.filter((record) => record.type === "host").map(hostFolderName))]
      .sort((a, b) => a.localeCompare(b));
    if (folderFilter) {
      folderFilter.replaceChildren();
      for (const value of ["all", ...folders]) {
        const option = documentValue.createElement("option");
        option.value = value;
        option.textContent = value === "all" ? "Все папки" : value;
        folderFilter.append(option);
      }
      folderFilter.value = selectedFolder === "all" || folders.includes(selectedFolder) ? selectedFolder : "all";
    }
    const filteredRecords = (activeRecordFilter === "all"
      ? current.records
      : current.records.filter((record) => record.type === activeRecordFilter))
      .filter((record) => record.type !== "host" || folderFilter?.value === "all" || hostFolderName(record) === folderFilter?.value);
    const query = String(search?.value ?? "").trim().toLocaleLowerCase();
    const visibleRecords = sortLocalVaultRecords(filteredRecords.filter((record) => {
      if (!query) return true;
      const data = record.data ?? {};
      const searchable = [data.title, data.address, data.username, data.destination, data.folder,
        ...(Array.isArray(data.tags) ? data.tags : [])];
      return searchable.some((value) => String(value ?? "").toLocaleLowerCase().includes(query));
    }), sort?.value);
    if (activeRecordFilter === "host") {
      visibleRecords.sort((a, b) => hostFolderName(a).localeCompare(hostFolderName(b)));
    }
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
    let renderedFolder = null;
    for (const record of visibleRecords) {
      if (activeRecordFilter === "host" && hostFolderName(record) !== renderedFolder) {
        const folderHeading = documentValue.createElement("h3");
        folderHeading.className = "personal-vault-folder-heading";
        folderHeading.textContent = hostFolderName(record);
        records.append(folderHeading);
        renderedFolder = hostFolderName(record);
      }
      const card = documentValue.createElement("article");
      const heading = documentValue.createElement("h4");
      const summary = documentValue.createElement("p");
      const metadata = documentValue.createElement("small");
      const actions = documentValue.createElement("div");
      const edit = documentValue.createElement("button");
      const remove = documentValue.createElement("button");
      heading.textContent = String(record.data.title ?? "Без названия");
      summary.textContent = localVaultRecordSummary(record);
      metadata.textContent = `${record.type} · ${formatVaultTimestamp(record.modifiedAt)}`;
      actions.className = "record-actions";
      edit.type = "button";
      edit.className = "secondary record-edit";
      edit.textContent = "Изменить";
      edit.addEventListener("click", (event) => {
        event.stopPropagation();
        beginEdit(record);
      });
      remove.type = "button";
      remove.className = "danger";
      remove.textContent = "Удалить";
      remove.addEventListener("click", async () => {
        if (!confirmValue(`Удалить «${heading.textContent}»?`)) return;
        remove.disabled = true;
        try {
          await controller.delete(record.id);
          if (editingRecordID === record.id) resetEditor();
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
          setText(hostDetailModified, formatVaultTimestamp(record.modifiedAt));
          const connection = personalHostEditorValues(record);
          setText(hostDetailProtocol, connection.protocol.toUpperCase());
          setText(hostDetailPort, connection.protocol === "serial" ? "—" : String(connection.port));
          setText(hostDetailUsername, connection.username || "—");
          setText(hostDetailPasswordState, "Управляется приложением");
          setText(hostDetailFolder, String(record.data?.folder ?? "Личный Vault"));
          setText(hostDetailTags, Array.isArray(record.data?.tags) && record.data.tags.length ? record.data.tags.join(", ") : "—");
          setText(hostDetailDescription, String(record.data?.description ?? "—"));
          hostDetailEdit.hidden = false;
          hostDetailEdit.onclick = () => { hostDetail.close?.(); beginEdit(record); };
          hostDetailCopyPassword.hidden = true;
          hostDetailOpenSSH.hidden = true;
          hostDetailOpenSFTP.hidden = true;
          hostDetail?.showModal();
        };
        card.addEventListener("click", (event) => {
          if (event.target === remove || event.target === edit) return;
          openHost();
        });
        card.addEventListener("keydown", (event) => {
          if (event.key !== "Enter" && event.key !== " ") return;
          event.preventDefault();
          openHost();
        });
      }
      actions.append(edit, remove);
      card.append(heading, summary, metadata, actions);
      records.append(card);
    }
  }

  recordForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    saveButton.disabled = true;
    try {
      const existing = editingRecordID
        ? controller.document().records.find((record) => record.id === editingRecordID)
        : null;
      const data = type.value === "host"
        ? personalHostRecordData({
          title: title.value, address: target.value, protocol: hostProtocol.value,
          port: hostPort.value, username: hostUsername.value, folder: hostFolder.value,
          tags: hostTags.value, description: hostDescription.value, baseData: existing?.data,
        })
        : localVaultRecordData(
          type.value,
          { title: title.value, target: target.value, secret: secret.value },
          existing?.data,
        );
      await controller.upsert({
        ...(editingRecordID ? { id: editingRecordID } : {}),
        type: type.value,
        data,
      });
      const wasEditing = Boolean(editingRecordID);
      resetEditor();
      clearConflictUI();
      setText(message, wasEditing ? "Изменения зашифрованы и сохранены." : "Запись локально зашифрована и сохранена.");
      render();
    } catch {
      setText(message, "Не удалось сохранить запись. Заполните обязательные поля.");
    } finally {
      saveButton.disabled = false;
    }
  });

  type.addEventListener("change", updateLabels);
  createButton?.addEventListener("click", beginCreate);
  hostProtocol.addEventListener("change", () => {
    if (hostProtocol.value === "ssh") hostPort.value = "22";
    if (hostProtocol.value === "telnet") hostPort.value = "23";
    updateLabels();
  });
  cancelButton.addEventListener("click", () => {
    resetEditor();
    setText(message, "Изменение отменено.");
  });
  search?.addEventListener("input", render);
  sort?.addEventListener("change", render);
  folderFilter?.addEventListener("change", render);
  for (const button of filterButtons) {
    button.addEventListener("click", () => {
      resetEditor();
      activeRecordFilter = button.dataset.recordFilter || "all";
      updateCreateButton();
      for (const candidate of filterButtons) {
        candidate.classList.toggle("active", candidate === button);
      }
      if (!workspace.hidden) render();
      filterChangeListener(activeRecordFilter);
    });
  }
  lockButton.addEventListener("click", async () => {
    lockButton.disabled = true;
    try {
      await lockListener();
    } catch {
      setText(message, "Не удалось удалить ключ доверенного браузера. Vault оставлен открытым.");
      lockButton.disabled = false;
      return;
    }
    controller.lock();
    resetEditor();
    clearConflictUI();
    mode("waiting");
    records.replaceChildren();
    setText(message, "Vault заблокирован. Войдите в аккаунт снова, чтобы открыть его.");
    lockButton.disabled = false;
  });

  updateLabels();
  updateCreateButton();
  try {
    const status = await controller.status();
    mode(status === "unlocked" ? "unlocked" : "waiting");
    setText(message, status === "unlocked"
      ? "Данные расшифрованы локально только для этой вкладки."
      : "Войдите в аккаунт, чтобы открыть Personal Vault на этом устройстве.");
  } catch {
    waiting.hidden = true;
    workspace.hidden = true;
    setText(message, "Локальное защищённое хранилище недоступно в этом браузере.");
  }
  return {
    controller,
    mode,
    render,
    clearConflictUI,
    setConflictMode,
    closeEditor() {
      resetEditor();
    },
    setFilter(value) {
      resetEditor();
      activeRecordFilter = ["all", "host", "credential", "snippet", "forwarding", "sshKey"].includes(value) ? value : "all";
      updateCreateButton();
      for (const button of filterButtons) {
        button.classList.toggle("active", button.dataset.recordFilter === activeRecordFilter);
      }
      if (!workspace.hidden) render();
    },
    setConflictResetListener(listener) {
      conflictResetListener = typeof listener === "function" ? listener : () => {};
    },
    setFilterChangeListener(listener) {
      filterChangeListener = typeof listener === "function" ? listener : () => {};
    },
    setLockListener(listener) {
      lockListener = typeof listener === "function" ? listener : async () => {};
    },
    async restoreModeFromLocalStatus() {
      const status = await controller.status();
      mode(status === "unlocked" ? "unlocked" : "waiting");
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
  const inviteEmailSubmit = documentValue.querySelector("#team-invite-email-submit");
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
  const hostProtocol = documentValue.querySelector("#team-host-protocol");
  const hostPort = documentValue.querySelector("#team-host-port");
  const hostUsername = documentValue.querySelector("#team-host-username");
  const hostPassword = documentValue.querySelector("#team-host-password");
  const hostRemovePassword = documentValue.querySelector("#team-host-remove-password");
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
  const hostDetailProtocol = documentValue.querySelector("#host-detail-protocol");
  const hostDetailPort = documentValue.querySelector("#host-detail-port");
  const hostDetailUsername = documentValue.querySelector("#host-detail-username");
  const hostDetailPasswordState = documentValue.querySelector("#host-detail-password-state");
  const hostDetailModified = documentValue.querySelector("#host-detail-modified");
  const hostDetailFolder = documentValue.querySelector("#host-detail-folder");
  const hostDetailTags = documentValue.querySelector("#host-detail-tags");
  const hostDetailDescription = documentValue.querySelector("#host-detail-description");
  const hostDetailCopy = documentValue.querySelector("#host-detail-copy");
  const hostDetailEdit = documentValue.querySelector("#host-detail-edit");
  const hostDetailCopyPassword = documentValue.querySelector("#host-detail-copy-password");
  const hostDetailOpenSSH = documentValue.querySelector("#host-detail-open-ssh");
  const hostDetailOpenSFTP = documentValue.querySelector("#host-detail-open-sftp");
  const conflictPanel = documentValue.querySelector("#team-vault-conflicts");
  const conflictForm = documentValue.querySelector("#team-vault-conflicts-form");
  const conflictList = documentValue.querySelector("#team-vault-conflicts-list");
  const conflictApply = documentValue.querySelector("#team-vault-conflicts-apply");
  const overviewTeamCount = documentValue.querySelector("#workspace-team-count");
  const overviewInvitationCount = documentValue.querySelector("#workspace-team-invitation-count");
  const overviewStatus = documentValue.querySelector("#workspace-team-overview-status");
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

  function renderOverviewSummary() {
    setText(overviewTeamCount, identity ? String(teams.length) : "—");
    setText(overviewInvitationCount, identity ? String(accountInvitations.length) : "—");
    setText(overviewStatus, !identity
      ? "Войдите, чтобы открыть командное пространство."
      : teams.length > 0
        ? `Команд: ${teams.length}. Новых приглашений: ${accountInvitations.length}.`
        : accountInvitations.length > 0
          ? "У вас есть новое приглашение в команду."
          : "Создайте первую команду или примите приглашение.");
  }

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
    const connection = parseTeamHostConnection(record.data);
    editingHostID = record.id;
    recordType.value = "host";
    recordTitle.value = String(record.data.title ?? "");
    recordTarget.value = connection.host;
    hostProtocol.value = connection.protocol;
    hostPort.value = String(connection.port);
    hostUsername.value = connection.username;
    hostPassword.value = "";
    hostRemovePassword.checked = false;
    hostFolder.value = String(record.data.folder ?? "");
    hostTags.value = Array.isArray(record.data.tags) ? record.data.tags.join(", ") : "";
    hostDescription.value = String(record.data.description ?? "");
    const advanced = Boolean(record.data.profile);
    recordTitle.disabled = advanced;
    recordTarget.disabled = advanced;
    hostProtocol.disabled = advanced;
    hostPort.disabled = advanced;
    hostUsername.disabled = advanced;
    updateRecordLabels();
    recordEditor.open = true;
    recordEditor.scrollIntoView({ behavior: "smooth", block: "start" });
    recordTitle.focus();
    setText(workspaceStatus, advanced
      ? "Полный профиль создан в приложении: в браузере можно менять папку, теги и описание."
      : "Измените Host и сохраните зашифрованную запись.");
  }

  function hostCredentials(hostID) {
    return controller?.document().records.filter((value) => value.type === "credential"
      && value.data?.sourceID === hostID && ["ssh", "rdp"].includes(value.data?.kind)) ?? [];
  }

  function detailConnectionURL(protocol) {
    const record = controller?.document().records.find((value) => value.id === detailedHostID);
    if (!record) return null;
    return teamHostConnectionData({ ...parseTeamHostConnection(record.data), protocol }).target;
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
      metadata.textContent = `${tags ? `${tags} · ` : ""}${formatVaultTimestamp(record.modifiedAt)}`;
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
          for (const credential of hostCredentials(record.id)) await controller.delete(credential.id);
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
          const connection = parseTeamHostConnection(record.data);
          const credentials = hostCredentials(record.id);
          detailedHostID = record.id;
          setText(hostDetailTitle, String(record.data.title ?? "Host"));
          setText(hostDetailAddress, String(record.data.address ?? "—"));
          setText(hostDetailModified, formatVaultTimestamp(record.modifiedAt));
          setText(hostDetailProtocol, connection.protocol.toUpperCase());
          setText(hostDetailPort, String(connection.port));
          setText(hostDetailUsername, connection.username || "—");
          setText(hostDetailPasswordState, credentials.length ? "Сохранён в E2EE Team Vault" : "Не сохранён");
          setText(hostDetailFolder, hostFolderName(record));
          setText(hostDetailTags, Array.isArray(record.data.tags) && record.data.tags.length ? record.data.tags.join(", ") : "—");
          setText(hostDetailDescription, String(record.data.description ?? "—"));
          hostDetailCopy.hidden = false;
          hostDetailEdit.hidden = !canEdit();
          hostDetailCopyPassword.hidden = credentials.length === 0;
          hostDetailOpenSSH.hidden = connection.protocol !== "ssh";
          hostDetailOpenSFTP.hidden = connection.protocol !== "ssh";
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
    renderOverviewSummary();
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
    renderOverviewSummary();
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

  inviteEmailSubmit.addEventListener("click", async () => {
    if (!selectedTeam || !canManage()) return;
    const email = String(inviteForm.elements.email.value ?? "").trim();
    if (!email) { setText(message, "Укажите email участника."); return; }
    inviteEmailSubmit.disabled = true;
    try {
      await client.inviteTeamMember({ teamID: selectedTeam.id, email, type: "email", role: inviteForm.elements.role.value });
      inviteForm.elements.email.value = "";
      await loadSelectedTeam();
      setText(message, `Приглашение отправлено на ${email}. Оно действует 48 часов.`);
    } catch {
      setText(message, "Email-приглашение не отправлено. Проверьте адрес, роль и настройки почты.");
    } finally { inviteEmailSubmit.disabled = false; }
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
  hostProtocol.addEventListener("change", () => {
    hostPort.value = hostProtocol.value === "ssh" ? "22" : "3389";
  });
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
  hostDetailCopyPassword.addEventListener("click", async () => {
    const credential = hostCredentials(detailedHostID)[0];
    if (!credential) return;
    try {
      await documentValue.defaultView.navigator.clipboard.writeText(String(credential.data.secret ?? ""));
      setText(workspaceStatus, "Пароль Host скопирован локально. Cloud plaintext не получал.");
    } catch { setText(workspaceStatus, "Браузер не разрешил доступ к буферу обмена."); }
  });
  hostDetailOpenSSH.addEventListener("click", () => {
    const target = detailConnectionURL("ssh");
    if (target) documentValue.defaultView.location.href = target;
  });
  hostDetailOpenSFTP.addEventListener("click", () => {
    const target = detailConnectionURL("ssh");
    if (target) documentValue.defaultView.location.href = target.replace(/^ssh:/u, "sftp:");
  });
  recordForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = recordForm.querySelector("button");
    button.disabled = true;
    try {
      const existingHost = editingHostID
        ? controller.document().records.find((value) => value.id === editingHostID && value.type === "host")
        : null;
      const connection = recordType.value === "host" && !existingHost?.data?.profile
        ? teamHostConnectionData({
            protocol: hostProtocol.value, host: recordTarget.value,
            port: hostPort.value, username: hostUsername.value,
          })
        : null;
      const hostID = await controller.upsert({
        ...(editingHostID ? { id: editingHostID } : {}),
        type: recordType.value,
        data: recordType.value === "host"
          ? teamHostRecordData({
              title: recordTitle.value, target: connection?.target ?? recordTarget.value, folder: hostFolder.value,
              tags: hostTags.value, description: hostDescription.value, baseData: existingHost?.data,
            })
          : localVaultRecordData(recordType.value, {
              title: recordTitle.value, target: recordTarget.value, secret: recordSecret.value,
            }),
      });
      if (recordType.value === "host") {
        const credentials = hostCredentials(hostID);
        if (hostRemovePassword.checked) {
          for (const credential of credentials) await controller.delete(credential.id);
        } else if (hostPassword.value) {
          const connectionValue = connection ?? parseTeamHostConnection(existingHost?.data);
          const retained = credentials[0];
          await controller.upsert({
            ...(retained ? { id: retained.id } : {}), type: "credential",
            data: {
              title: `${recordTitle.value.trim()} · ${connectionValue.protocol}`,
              username: connectionValue.username, secret: hostPassword.value,
              kind: connectionValue.protocol, sourceID: hostID,
            },
          });
          for (const duplicate of credentials.slice(1)) await controller.delete(duplicate.id);
        }
      }
      recordForm.reset();
      editingHostID = null;
      recordTitle.disabled = false;
      recordTarget.disabled = false;
      hostProtocol.disabled = false;
      hostPort.disabled = false;
      hostUsername.disabled = false;
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
  renderOverviewSummary();
  setView("teams");
  return {
    setView,
    async activate(nextIdentity) {
      identity = nextIdentity;
      renderOverviewSummary();
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
      renderOverviewSummary();
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
  const usernameForm = documentValue.querySelector("#account-username-form");
  const usernameAvailability = documentValue.querySelector("#account-username-availability");
  const usernameMessage = documentValue.querySelector("#account-username-message");
  const passwordForm = documentValue.querySelector("#account-password-form");
  const passwordMessage = documentValue.querySelector("#account-password-message");
  const deleteAccountForm = documentValue.querySelector("#account-delete-form");
  const deleteAccountMessage = documentValue.querySelector("#account-delete-message");
  const syncButton = documentValue.querySelector("#cloud-vault-sync");
  const vaultMessage = documentValue.querySelector("#local-vault-message");
  const conflictPanel = documentValue.querySelector("#local-vault-conflicts");
  const conflictForm = documentValue.querySelector("#local-vault-conflicts-form");
  const conflictList = documentValue.querySelector("#local-vault-conflicts-list");
  const conflictApply = documentValue.querySelector("#local-vault-conflicts-apply");
  const client = createAuthenticatedVaultClient({ fetchValue });
  const teamWorkspace = initializeTeamWorkspace({ documentValue, client, initialInvitationToken: initialTeamInvitationToken });
  const teamDeviceRepository = createIndexedDBTeamDeviceRepository();
  let activeConflicts = null;
  let backgroundSyncing = false;
  const sessionTabID = globalThis.crypto?.randomUUID?.() ?? null;
  const sessionChannel = sessionTabID && typeof globalThis.BroadcastChannel === "function"
    ? new globalThis.BroadcastChannel("selective-remote.personal-vault.session.v1")
    : null;
  vaultUI.setConflictResetListener(() => {
    activeConflicts = null;
    conflictApply.disabled = true;
  });
  vaultUI.setLockListener(async () => {
    await vault.forgetRememberedSession();
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
      try {
        await vault.unlock(passphrase);
      } catch (unlockError) {
        const remote = await client.getVault();
        if (remote.revision === 0) throw unlockError;
        await vault.replaceLockedWithRemote(remote, passphrase);
        vaultUI.mode("unlocked");
        vaultUI.render();
        return { status: "downloaded", revision: remote.revision };
      }
      status = "unlocked";
    }
    let result = await synchronizePersonalVault({ recoveryPassphrase: passphrase });
    if (status === "empty" && result.status === "empty") {
      await vault.create(passphrase);
      result = await synchronizePersonalVault();
    }
    vaultUI.mode("unlocked");
    vaultUI.render();
    return result;
  }

  async function synchronizePersonalVault({ recoveryPassphrase = null } = {}) {
    let result = await synchronizeVault({ client, vault, recoveryPassphrase });
    if (result.status !== "conflict") return result;

    const conflictsResolved = result.conflicts.length;
    await vault.resolveConflicts({
      revision: result.revision,
      resolutions: result.conflicts.map((conflict) => ({
        id: conflict.id,
        choice: newestVaultConflictChoice(conflict),
      })),
    });
    result = await synchronizeVault({ client, vault });
    return { ...result, automaticallyResolved: conflictsResolved };
  }

  async function backgroundPersonalVaultSync() {
    if (backgroundSyncing || !client.session() || await vault.status() !== "unlocked") return;
    backgroundSyncing = true;
    try {
      let result = await synchronizePersonalVault();
      if (result.status === "remote_changed") result = await synchronizePersonalVault();
      if (result.status !== "remote_changed") hideConflicts();
      vaultUI.render();
      if (Number.isSafeInteger(result.revision)) {
        setText(vaultMessage, `Personal Vault синхронизирован · r${result.revision}.`);
      }
    } catch {
      setText(vaultMessage, "Автосинхронизация временно недоступна; локальные данные сохранены, повторим автоматически.");
    } finally {
      backgroundSyncing = false;
    }
  }

  async function requestUnlockedVaultFromOtherTab() {
    const user = client.session();
    if (!sessionChannel || !user || await vault.status() === "unlocked") return;
    try {
      sessionChannel.postMessage({
        version: 1,
        type: "request",
        requester: sessionTabID,
        userID: user.id,
      });
    } catch {
      // Browser session remains signed in; manual account sign-in can still unlock the Vault.
    }
  }

  sessionChannel?.addEventListener("message", (event) => {
    const value = event?.data;
    const user = client.session();
    if (!value || value.version !== 1 || !user || value.userID !== user.id) return;
    if (value.type === "request" && value.requester !== sessionTabID) {
      try {
        sessionChannel.postMessage({
          version: 1,
          type: "key",
          requester: value.requester,
          responder: sessionTabID,
          userID: user.id,
          key: vault.sessionKey(),
        });
      } catch {
        // This tab is locked or the browser cannot clone CryptoKey values.
      }
      return;
    }
    if (value.type !== "key" || value.requester !== sessionTabID || value.responder === sessionTabID) return;
    void (async () => {
      try {
        if (await vault.status() !== "locked") return;
        await vault.unlockWithSessionKey(value.key);
        try { await vault.rememberSession(user.id); } catch {}
        vaultUI.mode("unlocked");
        vaultUI.render();
        setText(vaultMessage, "Personal Vault разблокирован активной вкладкой и синхронизируется автоматически.");
        await backgroundPersonalVaultSync();
      } catch {
        // Only a key that decrypts this local encrypted snapshot is accepted.
      }
    })();
  });
  globalThis.addEventListener?.("pagehide", () => sessionChannel?.close(), { once: true });

  const personalVaultTimer = globalThis.setInterval(
    () => { void backgroundPersonalVaultSync(); },
    15_000
  );
  personalVaultTimer?.unref?.();
  documentValue.addEventListener?.("visibilitychange", () => {
    if (!documentValue.hidden) void backgroundPersonalVaultSync();
  });
  globalThis.addEventListener?.("online", () => { void backgroundPersonalVaultSync(); });

  function setAuthMode(mode) {
    const registrationAvailable = metadata?.registrationEnabled === true || Boolean(initialTeamInvitationToken);
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
        ? initialTeamInvitationToken
          ? "Создайте аккаунт по приглашению. После подтверждения email войдите и снова откройте ссылку приглашения."
          : "Создайте пароль Selective Remote — на почту придёт только одноразовая ссылка подтверждения."
        : "Регистрация временно закрыта. Уже подтверждённые аккаунты могут войти.", registrationAvailable ? null : "error");
    } else if (mode === "recovery") {
      setAccountMessage("Мы отправим одноразовую ссылку для смены пароля, если аккаунт существует.");
    } else {
      setAccountMessage("Сессия восстанавливается защищённой HttpOnly cookie; пароль в браузере не сохраняется.");
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
    setText(accountName, user ? `@${user.username}` : "");
    if (user && usernameForm) usernameForm.elements.username.value = user.username;
    onSessionChange(user);
  }

  function setSettingsMessage(element, value, tone = null) {
    setText(element, value);
    element.classList.toggle("error", tone === "error");
    element.classList.toggle("success", tone === "success");
  }

  loginTab.addEventListener("click", () => setAuthMode("login"));
  registrationTab.addEventListener("click", () => setAuthMode("registration"));
  showRecovery.addEventListener("click", () => setAuthMode("recovery"));
  hideRecovery.addEventListener("click", () => setAuthMode("login"));
  registrationDone.addEventListener("click", () => setAuthMode("login"));

  registrationForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (metadata?.registrationEnabled !== true && !initialTeamInvitationToken) {
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
        invitationToken: initialTeamInvitationToken,
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
        invalid_team_invitation: "Приглашение недействительно, уже использовано, отозвано или истекло.",
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
      let personalVaultReady = false;
      try {
        await unlockAndSyncPersonalVault(password);
        personalVaultReady = true;
        try { await vault.rememberSession(user.id); } catch {}
      } catch {
        vaultUI.mode("waiting");
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
          setText(message, "Вход выполнен. Сессия защищена HttpOnly cookie; пароль не сохранён.");
        } catch {
          setText(message, "Вход выполнен. Team-раздел временно недоступен; личный Vault и сессия продолжают работать.");
        }
      }
      setText(
        vaultMessage,
        personalVaultReady
          ? "Personal Vault открыт паролем аккаунта и синхронизируется автоматически."
          : "Personal Vault пока недоступен. Повторите вход или синхронизацию."
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
      try { await vault.forgetRememberedSession(); } catch {}
      vault.lock();
      showSession(null);
      teamWorkspace?.deactivate();
      hideConflicts();
      await vaultUI.restoreModeFromLocalStatus();
      logoutButton.disabled = false;
      setText(message, "Сессия завершена; cookie и ключ доверенного браузера удалены.");
    }
  });

  usernameForm.addEventListener("input", async () => {
    const username = usernameForm.elements.username.value.trim().toLowerCase();
    if (username.length < 3) return setSettingsMessage(usernameAvailability, "Минимум 3 символа.");
    if (username === client.session()?.username.toLowerCase()) {
      return setSettingsMessage(usernameAvailability, `@${username} — ваш текущий username.`);
    }
    try {
      const result = await client.usernameAvailability(username);
      setSettingsMessage(usernameAvailability, result.available ? `@${result.username} свободен` : `@${result.username} уже занят`, result.available ? "success" : "error");
    } catch {
      setSettingsMessage(usernameAvailability, "Допустимы латинские буквы, цифры, точка, дефис и подчёркивание.", "error");
    }
  });

  usernameForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const requestedUsername = usernameForm.elements.username.value.trim().toLowerCase();
    if (requestedUsername === client.session()?.username.toLowerCase()) {
      setSettingsMessage(usernameMessage, "Username уже установлен для этого аккаунта.");
      usernameForm.elements.password.value = "";
      return;
    }
    const button = usernameForm.querySelector('button[type="submit"]');
    button.disabled = true;
    try {
      const user = await client.updateUsername({ username: usernameForm.elements.username.value, password: usernameForm.elements.password.value });
      showSession(user);
      setSettingsMessage(usernameMessage, `Username изменён на @${user.username}.`, "success");
    } catch (error) {
      const messages = { username_exists: "Этот username уже занят.", invalid_username: "Проверьте формат username.", invalid_credentials: "Текущий пароль неверен." };
      setSettingsMessage(usernameMessage, messages[String(error?.message ?? "")] ?? "Не удалось изменить username.", "error");
    } finally {
      usernameForm.elements.password.value = "";
      button.disabled = false;
    }
  });

  passwordForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = passwordForm.querySelector('button[type="submit"]');
    if (passwordForm.elements.newPassword.value !== passwordForm.elements.confirmation.value) {
      return setSettingsMessage(passwordMessage, "Новые пароли не совпадают.", "error");
    }
    button.disabled = true;
    try {
      await client.changePassword({ currentPassword: passwordForm.elements.currentPassword.value, newPassword: passwordForm.elements.newPassword.value });
      passwordForm.reset();
      setSettingsMessage(passwordMessage, "Пароль изменён. Остальные сессии завершены.", "success");
    } catch (error) {
      const messages = { invalid_password: "Новый пароль должен содержать не менее 12 символов.", invalid_credentials: "Текущий пароль неверен." };
      setSettingsMessage(passwordMessage, messages[String(error?.message ?? "")] ?? "Не удалось изменить пароль.", "error");
    } finally {
      passwordForm.elements.currentPassword.value = "";
      passwordForm.elements.newPassword.value = "";
      passwordForm.elements.confirmation.value = "";
      button.disabled = false;
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
      try { await vault.forgetRememberedSession(); } catch {}
      vault.lock();
      await vaultUI.restoreModeFromLocalStatus();
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
      const result = await synchronizePersonalVault();
      const messages = {
        empty: "Сначала создайте локальный Vault.",
        uploaded: `Зашифрованная ревизия ${result.revision} загружена.`,
        uploaded_with_new_local_changes: `Ревизия ${result.revision} загружена; появились новые локальные изменения — синхронизируйте ещё раз.`,
        downloaded: `Зашифрованная ревизия ${result.revision} загружена и объединена локально.`,
        up_to_date: `Vault уже синхронизирован на ревизии ${result.revision}.`,
        remote_changed: `Удалённый Vault изменился до ревизии ${result.remoteRevision}. Повторите синхронизацию для безопасного merge.`,
      };
      hideConflicts();
      const automaticSuffix = result.automaticallyResolved
        ? ` Автоматически разрешено конфликтов: ${result.automaticallyResolved}.`
        : "";
      setText(vaultMessage, `${messages[result.status] ?? "Синхронизация завершена."}${automaticSuffix}`);
    } catch (error) {
      const code = String(error?.message ?? "");
      if (code === "local_vault_locked") setText(vaultMessage, "Сначала разблокируйте локальный Vault.");
      else if (code === "authentication_required") {
        showSession(null);
        setText(vaultMessage, "Сессия истекла. Войдите снова.");
      } else if (code === "recovery_passphrase_required") {
        hideConflicts();
        vaultUI.mode("waiting");
        setText(vaultMessage, "Personal Vault пока недоступен. Войдите в аккаунт ещё раз.");
      } else {
        setText(vaultMessage, "Синхронизация не выполнена; локальные данные не потеряны.");
      }
    } finally {
      syncButton.disabled = !client.session();
    }
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

  setAuthMode("login");
  try {
    const restoredUser = await client.restoreSession();
    showSession(restoredUser);
    let restoredVault = await vault.status() === "unlocked";
    if (!restoredVault) restoredVault = await vault.restoreRememberedSession(restoredUser.id);
    if (restoredVault) {
      vaultUI.mode("unlocked");
      vaultUI.render();
      setText(vaultMessage, "Personal Vault восстановлен на этом доверенном браузере. Синхронизируем изменения…");
      await backgroundPersonalVaultSync();
    } else {
      vaultUI.mode("waiting");
      setText(vaultMessage, "Personal Vault заблокирован. Ищем открытую вкладку этого аккаунта…");
      await requestUnlockedVaultFromOtherTab();
    }
    let identity = null;
    try {
      identity = await ensureTeamDeviceIdentity({ repository: teamDeviceRepository, deviceID: client.deviceID() });
      await teamWorkspace?.activate(identity);
    } catch {
      // A valid account session remains usable when this browser has no approved Team key.
    }
    setAccountMessage(identity
      ? "Сессия восстановлена. Team-раздел готов к работе."
      : "Сессия восстановлена. Для Team Vault может потребоваться одобрение устройства.", "success");
  } catch {
    showSession(null);
  }
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
    "workspace-about": "О проекте",
  };
  const resourceTitles = {
    host: "Хосты",
    snippet: "Сниппеты",
    credential: "Учётные данные",
    forwarding: "Forwarding",
    sshKey: "SSH-ключи",
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
    "/app/about": ["workspace-about", null, null],
  };
  let sessionActive = false;
  let requestedWorkspaceRoute = "/app";

  const workspaceHeader = documentValue.querySelector(".workspace-header");
  if (workspaceHeader) workspaceHeader.hidden = true;

  function setPath(path, replace = false) {
    if (locationValue.pathname === path) return;
    const method = replace ? "replaceState" : "pushState";
    historyValue[method]?.({}, "", path);
  }

  function selectWorkspacePanel(target, recordFilter = null, teamView = null) {
    const panelID = Object.hasOwn(titles, target) ? target : "workspace-overview";
    if (panelID !== "local-vault") vaultUI?.closeEditor();
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
    if (panelID === "local-vault") vaultUI?.setFilter(recordFilter || "all");
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

  vaultUI?.setFilterChangeListener((recordFilter) => {
    selectWorkspacePanel("local-vault", recordFilter, null);
    requestedWorkspaceRoute = routeForWorkspace("local-vault", recordFilter, null);
    setPath(requestedWorkspaceRoute);
  });

  function showLanding({ replace = false } = {}) {
    vaultUI?.closeEditor();
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
    vaultUI?.closeEditor();
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
  navigation?.sessionChanged(account?.client.session());
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
