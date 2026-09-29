import { teamDevicePublicKeyFingerprint } from "./team-vault-crypto.js";
import { createBrowserDeviceTrustFlow } from "./device-trust-flow.js";

export function createBrowserDeviceTrustPanel({ container, documentValue, client,
  repository, identityRepository = null, endpoint, accountID, identity,
  onUpdated = () => {}, onRekeyCommitted = () => {} }) {
  const flow = createBrowserDeviceTrustFlow({ client, repository, identityRepository,
    endpoint, accountID, identity });
  const pending = new Map();
  const english = () => documentValue.documentElement?.lang?.startsWith("en");
  const label = (ru, en) => english() ? en : ru;
  const element = (tag, text, className) => {
    const node = documentValue.createElement(tag);
    node.textContent = text;
    if (className) node.className = className;
    return node;
  };
  const action = (text, run, className = "secondary") => {
    const button = element("button", text, className);
    button.type = "button";
    button.addEventListener("click", async () => {
      button.disabled = true;
      try { await run(); await refresh(); onUpdated(); }
      catch (error) {
        const message = element("p", label("Действие не выполнено. Проверьте данные на обоих устройствах и обновите страницу.",
          "Action failed. Check both devices and refresh."), "device-trust-error");
        message.setAttribute("role", "alert");
        container.prepend(message);
      } finally { button.disabled = false; }
    });
    return button;
  };
  const field = (placeholder, autocomplete = "off") => {
    const input = documentValue.createElement("input");
    input.type = "text";
    input.placeholder = placeholder;
    input.autocomplete = autocomplete;
    input.spellcheck = false;
    return input;
  };

  async function refresh() {
    const current = await flow.status();
    if (current.rekeyCommitted) onRekeyCommitted();
    const fragment = documentValue.createDocumentFragment();
    const heading = element("h3", label("Доверие устройств", "Device trust"));
    fragment.append(heading);
    const fingerprint = await teamDevicePublicKeyFingerprint(flow.currentIdentity().publicKey);
    fragment.append(element("p", `${label("Отпечаток этого устройства", "This device fingerprint")}: ${fingerprint}`,
      "device-trust-fingerprint"));
    if (current.state === "FIRST_DEVICE" || current.state === "PUBLISH_PENDING") {
      fragment.append(element("p", label(
        "Это первое доверенное устройство аккаунта. Локальный корень доверия подтвердит следующие устройства. При потере всех устройств с этим корнем потребуется отдельное восстановление и смена ключей.",
        "This is the first trusted account device. Its local root will approve future devices. Losing every root holder requires a separate recovery and rekey.")));
      const consent = documentValue.createElement("label");
      const checkbox = documentValue.createElement("input");
      checkbox.type = "checkbox";
      consent.append(checkbox, ` ${label("Я понимаю последствия потери корня доверия", "I understand the root-loss consequence")}`);
      const button = action(current.state === "PUBLISH_PENDING"
        ? label("Повторить публикацию", "Retry publication")
        : label("Создать корень доверия", "Create trust root"), () => flow.bootstrap());
      button.disabled = true;
      checkbox.addEventListener("change", () => { button.disabled = !checkbox.checked; });
      fragment.append(consent, button);
    } else if (current.state === "PAIRING_REQUIRED") {
      fragment.append(element("p", label(
        "Попросите существующее доверенное устройство передать отпечаток корня и код контрольной точки напрямую. Данные Cloud без этого сравнения не подтверждают личность устройства.",
        "Get the root fingerprint and checkpoint code directly from an existing trusted device. Cloud data alone cannot establish trust.")));
      const root = field(label("Отпечаток корня", "Root fingerprint"));
      const checkpoint = field(label("Код контрольной точки", "Checkpoint code"));
      fragment.append(root, checkpoint,
        action(label("Сравнить и привязать", "Compare and pair"), () => flow.pair({
          trustedFingerprint: root.value, trustedCheckpointDigest: checkpoint.value })));
    } else if (current.state === "LOCAL_PIN_MISSING") {
      fragment.append(element("p", label(
        "Локальная отметка доверия отсутствует. Публикация остановлена. Требуется восстановление через проверенное устройство.",
        "The local trust pin is missing. Publication is stopped. Recovery through a trusted device is required.")));
    } else {
      fragment.append(element("p", `${label("Корень", "Root")}: ${current.pin.rootFingerprint}`,
        "device-trust-fingerprint"));
      fragment.append(element("p", `${label("Контрольная точка", "Checkpoint")}: ${current.pin.checkpointDigest}`,
        "device-trust-fingerprint"));
      if (current.state === "CERTIFIED") {
        fragment.append(element("p", label("Это устройство криптографически подтверждено.",
          "This device has a verified certificate.")));
      } else if (current.state === "REVOKED") {
        fragment.append(element("p", label("Подпись этого устройства больше не активна.",
          "This device certificate is no longer active.")));
      }
      const requests = await client.deviceTrustRequests();
      const own = requests.find((item) => item.deviceID === identity.deviceID
        && ["pending", "challenged", "answered"].includes(item.status));
      if (current.state === "PAIRED" && !own) {
        fragment.append(action(label("Запросить подтверждение", "Request approval"),
          () => flow.requestApproval()));
      }
      if (own) {
        fragment.append(element("p", `${label("Заявка", "Request")}: ${own.status}`));
        if (own.keyVersion > 1) {
          fragment.append(element("p", `${label("Новый отпечаток", "New fingerprint")}: ${
            await teamDevicePublicKeyFingerprint(own.publicKey)}`, "device-trust-fingerprint"));
        }
        if (own.status === "challenged" && own.challengeState === "offered") {
          fragment.append(action(label("Ответить на проверку ключа", "Answer key challenge"),
            () => flow.answerRequestChallenge(own)));
        }
      }
      if (!own && identityRepository && ["CERTIFIED", "CUSTODIAN"].includes(current.state)) {
        fragment.append(action(label("Запросить замену ключа", "Request key replacement"), async () => {
          if (!globalThis.confirm(label(
            "Старый ключ будет отозван после нового подтверждения. Потребуется ротация затронутых Team Vaults. Продолжить?",
            "The old key will be revoked after approval. Affected Team Vaults need rotation. Continue?"))) return;
          await flow.requestRekey();
        }));
      }
      if (current.state === "CUSTODIAN") {
        fragment.append(element("p", label(
          "Сравнивайте отпечаток на новом устройстве напрямую. Подтверждение начнётся только после точного ввода.",
          "Compare the fingerprint directly on the new device. Exact entry is required before approval.")));
        for (const request of requests.filter((item) =>
          (item.deviceID !== identity.deviceID || item.keyVersion > 1)
          && ["pending", "challenged", "answered"].includes(item.status))) {
          const card = element("article", "", "device-trust-request");
          const shown = await teamDevicePublicKeyFingerprint(request.publicKey);
          card.append(element("strong", `${request.name || request.deviceID} · ${request.platform}`),
            element("p", `${label("Создано", "Created")}: ${request.createdAt}`),
            element("p", `${label("Отпечаток", "Fingerprint")}: ${shown}`,
              "device-trust-fingerprint"));
          if (request.status === "pending" || !request.challengeState) {
            const comparison = field(label("Введите отпечаток с нового устройства", "Enter fingerprint from new device"));
            card.append(comparison, action(label("Проверить устройство", "Verify device"), async () => {
              const started = await flow.startApproval(request, comparison.value);
              pending.set(request.requestID, started);
            }));
          } else if (pending.has(request.requestID)) {
            card.append(action(label("Проверить ответ и подтвердить", "Verify answer and approve"), async () => {
              await flow.finishApproval(pending.get(request.requestID));
              pending.delete(request.requestID);
            }));
          } else {
            card.append(element("p", label(
              "Проверка началась в другом окне. Дождитесь истечения challenge и начните заново.",
              "Challenge started in another window. Wait for expiry and restart.")));
          }
          card.append(action(label("Отклонить", "Reject"),
            () => flow.reject(request.requestID), "danger"));
          fragment.append(card);
        }
        for (const entry of current.snapshot.checkpoint.payload.entries.filter(
          (item) => item.deviceID !== identity.deviceID)) {
          const card = element("article", "", "device-trust-request");
          card.append(element("strong", `${label("Подтверждённое устройство", "Certified device")}: ${entry.deviceID}`),
            action(label("Отозвать подпись и сессии", "Revoke certificate and sessions"), async () => {
              if (!globalThis.confirm(label(
                "Отозвать устройство? Его сессии завершатся, доступ к будущим ключам прекратится.",
                "Revoke device? Its sessions will end and future key access will stop."))) return;
              await flow.revokeDevice(entry.deviceID);
            }, "danger"));
          fragment.append(card);
        }
      }
    }
    container.replaceChildren(fragment);
    return current;
  }

  return { refresh };
}
