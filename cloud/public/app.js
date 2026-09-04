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
  const controller = createLocalVaultController({ repository });

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
    mode("locked");
    records.replaceChildren();
    setText(message, "Vault заблокирован; ключ удалён из состояния страницы.");
  });

  updateLabels();
  try {
    mode(await controller.status());
    setText(message, "Данные остаются на этом устройстве в зашифрованном виде; синхронизация ещё не подключена.");
  } catch {
    setup.hidden = true;
    unlock.hidden = true;
    workspace.hidden = true;
    setText(message, "Локальное защищённое хранилище недоступно в этом браузере.");
  }
  return controller;
}

export async function initializeCloudAccount({
  documentValue = document,
  vault,
  fetchValue = fetch,
} = {}) {
  const section = documentValue.querySelector("#cloud-account");
  if (!section || !vault) return null;
  const form = documentValue.querySelector("#cloud-login-form");
  const signedIn = documentValue.querySelector("#cloud-signed-in");
  const accountName = documentValue.querySelector("#cloud-account-name");
  const message = documentValue.querySelector("#cloud-account-message");
  const logoutButton = documentValue.querySelector("#cloud-logout");
  const syncButton = documentValue.querySelector("#cloud-vault-sync");
  const vaultMessage = documentValue.querySelector("#local-vault-message");
  const client = createAuthenticatedVaultClient({ fetchValue });

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
      setText(vaultMessage, messages[result.status] ?? "Синхронизация завершена.");
    } catch (error) {
      const code = String(error?.message ?? "");
      if (code === "local_vault_locked") setText(vaultMessage, "Сначала разблокируйте локальный Vault.");
      else if (code === "authentication_required") {
        showSession(null);
        setText(vaultMessage, "Сессия истекла. Войдите снова.");
      } else if (code === "recovery_passphrase_required") {
        setText(vaultMessage, "На сервере есть Vault. Импорт в чистый браузер требует recovery-фразу и будет добавлен отдельным шагом.");
      } else {
        setText(vaultMessage, "Синхронизация не выполнена; локальные данные не потеряны.");
      }
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
  const vault = await initializeLocalVault({ documentValue });
  await initializeCloudAccount({ documentValue, vault, fetchValue });
  await updateServiceStatus(documentValue, fetchValue);
}

if (typeof document !== "undefined") await initializePortal();
