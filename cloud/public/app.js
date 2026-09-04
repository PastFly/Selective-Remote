import { createIndexedDBVaultRepository, createLocalVaultController } from "./vault-local.js";
import { createAuthenticatedVaultClient, synchronizeVault } from "./vault-sync.js";

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
  const controller = createLocalVaultController({ repository });
  let conflictResetListener = () => {};

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
    records.replaceChildren();
    if (current.records.length === 0) {
      const empty = documentValue.createElement("p");
      empty.className = "vault-empty";
      empty.textContent = "Vault пока пуст.";
      records.append(empty);
      return;
    }
    for (const record of current.records) {
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
    setText(message, "Данные зашифрованы локально; после входа доступна ручная Cloud-синхронизация.");
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

export async function initializeCloudAccount({
  documentValue = document,
  vaultUI,
  fetchValue = fetch,
} = {}) {
  const vault = vaultUI?.controller;
  const section = documentValue.querySelector("#cloud-account");
  if (!section || !vault) return null;
  const form = documentValue.querySelector("#cloud-login-form");
  const signedIn = documentValue.querySelector("#cloud-signed-in");
  const accountName = documentValue.querySelector("#cloud-account-name");
  const message = documentValue.querySelector("#cloud-account-message");
  const logoutButton = documentValue.querySelector("#cloud-logout");
  const syncButton = documentValue.querySelector("#cloud-vault-sync");
  const vaultMessage = documentValue.querySelector("#local-vault-message");
  const recoveryForm = documentValue.querySelector("#cloud-vault-recovery-form");
  const recoveryCancel = documentValue.querySelector("#cloud-vault-recovery-cancel");
  const conflictPanel = documentValue.querySelector("#local-vault-conflicts");
  const conflictForm = documentValue.querySelector("#local-vault-conflicts-form");
  const conflictList = documentValue.querySelector("#local-vault-conflicts-list");
  const conflictApply = documentValue.querySelector("#local-vault-conflicts-apply");
  const client = createAuthenticatedVaultClient({ fetchValue });
  let activeConflicts = null;
  vaultUI.setConflictResetListener(() => {
    activeConflicts = null;
    conflictApply.disabled = true;
  });

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
    form.hidden = Boolean(user);
    signedIn.hidden = !user;
    syncButton.disabled = !user;
    setText(accountName, user ? `${user.displayName || user.email} · ${user.email}` : "");
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = form.querySelector("button");
    button.disabled = true;
    try {
      const user = await client.login({
        email: form.elements.email.value,
        password: form.elements.password.value,
        deviceID: await vault.deviceID(),
      });
      form.elements.password.value = "";
      showSession(user);
      setText(message, "Вход выполнен. Сессионный токен хранится только в памяти этой вкладки.");
    } catch {
      setText(message, "Не удалось войти. Проверьте email, пароль и подтверждение аккаунта.");
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
      hideConflicts();
      await vaultUI.hideRecoveryAndRestoreMode();
      logoutButton.disabled = false;
      setText(message, "Сессия завершена, токен удалён из памяти вкладки.");
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
  return client;
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
  } catch {
    status.textContent = "Сервис недоступен";
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
  const vaultUI = await initializeLocalVault({ documentValue });
  await initializeCloudAccount({ documentValue, vaultUI, fetchValue });
  await updateServiceStatus(documentValue, fetchValue);
}

if (typeof document !== "undefined") await initializePortal();
