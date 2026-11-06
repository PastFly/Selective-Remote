import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createIndexedDBVaultRepository, createLocalVaultController } from "../public/vault-local.js";
import { IDBFactory } from "./approved-idb-fixture.mjs";
import { encryptVaultPayload } from "../public/vault-crypto.js";
import { capturePersonalVaultSession, synchronizeVault } from "../public/vault-sync.js";
import * as application from "../public/app.js";

test("writer compatibility errors tell Personal and Team users to update without clearing data", async () => {
  const message = application.vaultStorageCompatibilityMessage("vault_client_upgrade_required");
  assert.match(message, /Обновите/u);
  assert.match(message, /Не очищайте данные браузера/u);
  assert.equal(application.teamVaultSynchronizationErrorMessage("vault_client_upgrade_required"), message);
  const i18n = await readFile(new URL("../public/i18n.js", import.meta.url), "utf8");
  assert.match(i18n, /Update the app or Cloud server before synchronizing/u);
});

test("temporarily stopped writes tell Personal and Team users to keep local copies", async () => {
  const message = application.vaultStorageCompatibilityMessage("vault_write_temporarily_unavailable");
  assert.match(message, /временно недоступна/u);
  assert.match(message, /Сохраните локальные копии/u);
  assert.equal(application.teamVaultSynchronizationErrorMessage("vault_write_temporarily_unavailable"), message);
  assert.equal(application.vaultStorageCompatibilityMessage("unrelated_server_failure"), null);
  const i18n = await readFile(new URL("../public/i18n.js", import.meta.url), "utf8");
  assert.match(i18n, /Writing to Cloud is temporarily unavailable.*Keep your local copies/u);
});
import {
  accountVaultPassphrase,
  appearancePreference,
  bootstrapPersonalVault,
  completeInteractivePersonalVaultLogin,
  finishPortalBootstrap,
  filterWorkspaceCommands,
  formatVaultSynchronizationSummary,
  formatVaultTimestamp,
  refreshVaultSynchronizationMessage,
  initializeAppearance,
  initializeHeroPreview,
  localVaultConflictSideSummary,
  localVaultRecordData,
  localVaultRecordFormValues,
  localVaultRecordSummary,
  maintainAccessibleTeamVaultWrappers,
  preprovisionTeamInvitationWrappers,
  recordFormFieldVisibility,
  setVaultSynchronizationMessage,
  resolveRestoredPersonalVaultState,
  parseTeamHostConnection,
  personalVaultStatePresentation,
  personalHostEditorValues,
  personalHostFolderName,
  personalHostRecordData,
  teamHostOrganizationValues,
  teamArchiveErrorMessage,
  teamRoleLabel,
  sortLocalVaultRecords,
  shouldFocusCommandPaletteSearch,
  teamHostConnectionData,
  teamHostRecordData,
  teamVaultRecoveryMode,
  vaultResourceDetail,
  workspaceCommands,
} from "../public/app.js";

test("unsupported Cloud sessions present an upgrade message in both languages", async () => {
  const message = application.cloudCompatibilityMessage("cloud_upgrade_required");
  assert.match(message, /Обновите Cloud/u);
  assert.match(message, /Сохранённые данные не изменены/u);
  assert.equal(application.cloudCompatibilityMessage("authentication_required"), null);
  const i18n = await readFile(new URL("../public/i18n.js", import.meta.url), "utf8");
  assert.ok(i18n.includes(JSON.stringify(message)));
  assert.match(i18n, /Update Cloud, then sign in again\. Your saved data has not been changed\./u);
});

test("Team role labels follow the active RU and EN locale", () => {
  assert.deepEqual(
    ["owner", "admin", "editor", "viewer"].map((role) => teamRoleLabel(role, "ru")),
    ["Владелец", "Администратор", "Редактор", "Просмотр"],
  );
  assert.deepEqual(
    ["owner", "admin", "editor", "viewer"].map((role) => teamRoleLabel(role, "en")),
    ["Owner", "Administrator", "Editor", "Viewer"],
  );
});

test("conflicting versions expose their differences only after an explicit reveal", () => {
  const nodes = [];
  const documentValue = { createElement(tag) {
    const node = { tag, hidden: false, textContent: "", attributes: {},
      setAttribute(key, value) { this.attributes[key] = value; },
      addEventListener(_name, listener) { this.activate = listener; } };
    nodes.push(node); return node;
  } };
  const parent = { children: [], append(...children) { this.children.push(...children); } };
  application.appendVaultConflictDetails({ documentValue, parent, choice: "local", entity: {
    kind: "record", value: { type: "credential", data: { title: "Same", password: "synthetic-secret" } },
  } });
  const [button, detail] = parent.children;
  assert.equal(detail.textContent, "");
  assert.equal(detail.hidden, true);
  assert.equal(button.attributes["aria-expanded"], "false");
  button.activate();
  assert.match(detail.textContent, /synthetic-secret/u);
  assert.equal(detail.hidden, false);
  assert.equal(button.attributes["aria-expanded"], "true");
  button.activate();
  assert.equal(detail.hidden, true);
  assert.equal(detail.textContent, "");
});


test("Team Host edit batches its credential update and duplicate cleanup", () => {
  assert.equal(typeof application.teamVaultRecordOperations, "function");
  const host = { id: "host", type: "host", data: { title: "Synthetic host" } };
  const credentials = ["first", "duplicate"].map(id => ({ id, type: "credential", data: { sourceID: "host", kind: "ssh" } }));
  const other = { id: "other", type: "credential", data: { sourceID: "other-host", kind: "ssh" } };
  const replacement = { id: "fresh", type: "credential", data: { sourceID: "host", kind: "ssh", secret: "synthetic" } };
  assert.deepEqual(application.teamVaultRecordOperations({
    records: [host, ...credentials, other], record: host, credential: { record: replacement },
  }), [
    { op: "upsert", record: host },
    { op: "upsert", record: { ...replacement, id: "first" } },
    { op: "delete", id: "duplicate" },
  ]);
  assert.deepEqual(application.teamVaultRecordOperations({
    records: [host, ...credentials, other], record: host, credential: { remove: true },
  }), [{ op: "upsert", record: host }, { op: "delete", id: "first" }, { op: "delete", id: "duplicate" }]);
});

test("Team editor detects changed record values and linked credentials without rejecting unrelated changes", () => {
  assert.equal(typeof application.captureTeamRecordEditorSnapshot, "function");
  assert.equal(typeof application.teamRecordEditorMatches, "function");
  const host = { id: "host", type: "host", version: { a: 1 }, data: { title: "Synthetic", address: "old.invalid" } };
  const credential = { id: "credential", type: "credential", version: { a: 1 }, data: { sourceID: "host", kind: "ssh", secret: "synthetic" } };
  const unrelated = { id: "other", type: "snippet", data: { title: "Before" } };
  const snapshot = application.captureTeamRecordEditorSnapshot([host, credential, unrelated], host);
  assert.equal(application.teamRecordEditorMatches(snapshot, [host, credential, { ...unrelated, data: { title: "After" } }]), true);
  assert.equal(application.teamRecordEditorMatches(snapshot, [{ ...host, data: { ...host.data, address: "new.invalid" } }, credential]), false);
  assert.equal(application.teamRecordEditorMatches(snapshot, [host, { ...credential, version: { a: 2 } }]), false);
  assert.equal(application.teamRecordEditorMatches(snapshot, [host]), false);
});

test("Team bulk deletion batches linked credentials exactly once and rejects missing selections", () => {
  assert.equal(typeof application.teamVaultDeleteOperations, "function");
  const records = [
    { id: "host", type: "host", data: {} },
    { id: "credential", type: "credential", data: { sourceID: "host", kind: "ssh" } },
    { id: "other", type: "snippet", data: {} },
  ];
  assert.deepEqual(application.teamVaultDeleteOperations(records, ["credential", "host", "other"]), [
    { op: "delete", id: "credential" }, { op: "delete", id: "host" }, { op: "delete", id: "other" },
  ]);
  assert.throws(() => application.teamVaultDeleteOperations(records, ["host", "missing"]), /record_changed/u);
});

test("a Team editing target requires the same active account and Vault", () => {
  assert.equal(typeof application.teamVaultEditTargetMatches, "function");
  const target = { controller: {}, teamID: "team", vaultID: "vault", sessionID: "account-a", sessionGeneration: "old" };
  assert.equal(application.teamVaultEditTargetMatches(target, { ...target }), true);
  assert.equal(application.teamVaultEditTargetMatches(target, { ...target, sessionID: "account-b" }), false);
  assert.equal(application.teamVaultEditTargetMatches(target, { ...target, sessionGeneration: "new" }), false);
  assert.equal(application.teamVaultEditTargetMatches(target, { ...target, vaultID: "other" }), false);
  assert.equal(application.teamVaultEditTargetMatches({ ...target, sessionID: null }, { ...target, sessionID: null }), false);
  assert.equal(application.teamVaultEditTargetMatches({ ...target, lockEpoch: 1 }, { ...target, lockEpoch: 2 }), false);
});

test("Personal Vault lock drops in-memory access before uncertain remembered-key cleanup finishes", async () => {
  assert.equal(typeof application.lockPersonalVault, "function");
  let release, locked = false, viewLocked = false;
  const cleanup = new Promise(resolve => { release = resolve; });
  const operation = application.lockPersonalVault({ controller: { lock() { locked = true; } },
    cleanup: () => cleanup, onLocked() { viewLocked = true; } });
  assert.equal(locked, true);
  assert.equal(viewLocked, true);
  release(false);
  assert.equal(await operation, false);
  assert.equal(await application.lockPersonalVault({ controller: { lock() { locked = true; } },
    cleanup() { throw new Error("synthetic_storage_failure"); } }), false);
});

test("logout reports server and local cleanup results even if Vault status is unavailable", async () => {
  assert.equal(typeof application.createBrowserLogoutRestoreView, "function");
  let current = true;
  const message = { textContent: "" };
  const restoreView = application.createBrowserLogoutRestoreView({ message, isCurrent: () => current });
  const vault = { lock() {}, async status() { throw new Error("synthetic_storage_failure"); },
    async forgetTrackedRememberedSession() { return false; } };
  await application.completeBrowserSessionLogout({ client: { logout: async () => {}, session: () => null }, vault,
    clearView() {}, restoreView });
  assert.match(message.textContent, /завершён на сервере/u);
  assert.match(message.textContent, /не удалось подтвердить удаление локального ключа/iu);
  const oldMessage = message.textContent;
  current = false;
  restoreView({ remoteRevoked: false, localCleanupConfirmed: false });
  assert.equal(message.textContent, oldMessage);
});

test("confirmed deletion of account A does not alter a newer session B", async () => {
  assert.equal(typeof application.completeBrowserAccountDeletion, "function");
  let session = { id: "a" }, generation = "a", release, locked = 0, cleaned = 0, cleared = 0;
  const held = new Promise(resolve => { release = resolve; });
  const client = { session: () => session, sessionGeneration: () => generation,
    async deleteAccount() { await held; return { deleted: true, sessionChanged: true }; } };
  const operation = application.completeBrowserAccountDeletion({ client,
    vault: { lock() { locked++; }, async forgetTrackedRememberedSession() { cleaned++; } },
    email: "synthetic@example.invalid", password: "synthetic",
    isBeforeCurrent: () => generation === "a", isViewCurrent: () => generation === "a",
    cancelPendingActivations() { cleaned++; }, clearView() { cleared++; } });
  session = { id: "b" }; generation = "b"; release();
  assert.deepEqual(await operation, { deleted: true, sessionChanged: true });
  assert.deepEqual({ session, locked, cleaned, cleared }, { session: { id: "b" }, locked: 0, cleaned: 0, cleared: 0 });
});

test("confirmed account deletion remains successful if local cleanup fails", async () => {
  assert.equal(typeof application.completeBrowserAccountDeletion, "function");
  let session = { id: "a" }, generation = "a", locked = 0, cleared = 0;
  const client = { session: () => session, sessionGeneration: () => generation,
    async deleteAccount() { session = null; generation = "retired"; return { deleted: true }; } };
  const result = await application.completeBrowserAccountDeletion({ client,
    vault: { lock() { locked++; }, async forgetTrackedRememberedSession() { throw new Error("synthetic_storage_failure"); } },
    email: "synthetic@example.invalid", password: "synthetic", isBeforeCurrent: () => generation === "a",
    isViewCurrent: () => true, cancelPendingActivations: () => true, clearView() { cleared++; } });
  assert.deepEqual(result, { deleted: true, localCleanupConfirmed: false, sessionChanged: false });
  assert.equal(locked, 1);
  assert.equal(cleared, 1);
});

test("account A cleanup finishing after a login to B does not restore A's view", async () => {
  let session = { id: "a" }, generation = "a", release, entered, locked = 0, cleared = 0;
  const held = new Promise(resolve => { release = resolve; }), started = new Promise(resolve => { entered = resolve; });
  const client = { session: () => session, sessionGeneration: () => generation,
    async deleteAccount() { session = null; generation = "retired"; return { deleted: true }; } };
  const operation = application.completeBrowserAccountDeletion({ client,
    vault: { lock() { locked++; }, async forgetTrackedRememberedSession() { entered(); await held; return false; } },
    email: "synthetic@example.invalid", password: "synthetic", isBeforeCurrent: () => generation === "a",
    isViewCurrent: () => generation !== "b", cancelPendingActivations: () => true, clearView() { cleared++; } });
  await started;
  session = { id: "b" }; generation = "b"; release();
  assert.deepEqual(await operation, { deleted: true, localCleanupConfirmed: false, sessionChanged: true });
  assert.equal(locked, 1);
  assert.equal(cleared, 1);
  assert.equal(session.id, "b");
});

test("a view cleanup failure does not misreport confirmed account deletion or key cleanup", async () => {
  let session = { id: "a" }, generation = "a";
  const client = { session: () => session, sessionGeneration: () => generation,
    async deleteAccount() { session = null; generation = "retired"; return { deleted: true }; } };
  const result = await application.completeBrowserAccountDeletion({ client,
    vault: { lock() {}, async forgetTrackedRememberedSession() { return true; } },
    email: "synthetic@example.invalid", password: "synthetic", isBeforeCurrent: () => generation === "a",
    isViewCurrent: () => true, cancelPendingActivations: () => true, clearView() { throw new Error("synthetic_ui_failure"); } });
  assert.equal(result.deleted, true);
  assert.equal(result.localCleanupConfirmed, true);
  assert.equal(result.viewCleared, false);
});

test("account deletion stops before requesting DELETE when the captured session changed", async () => {
  assert.equal(typeof application.completeBrowserAccountDeletion, "function");
  let requested = false;
  const result = await application.completeBrowserAccountDeletion({ client: { async deleteAccount() { requested = true; } },
    vault: {}, email: "synthetic@example.invalid", password: "synthetic", isBeforeCurrent: () => false });
  assert.deepEqual(result, { deleted: false, sessionChanged: true });
  assert.equal(requested, false);
});

for (const failed of [false, true]) test(`a late username update ${failed ? "error" : "success"} cannot alter the newer session's view`, async () => {
  assert.equal(typeof application.completeBrowserUsernameUpdate, "function");
  let generation = "a", release, applied = 0, errors = 0;
  const held = new Promise(resolve => { release = resolve; });
  const operation = application.completeBrowserUsernameUpdate({ client: { async updateUsername() {
    await held;
    if (failed) throw new Error("synthetic_username_failure");
    return { id: "a", username: "synthetic", sessionChanged: true };
  } }, username: "synthetic", password: "synthetic", isCurrent: () => generation === "a",
    onSuccess() { applied++; }, onError() { errors++; } });
  generation = "b"; release();
  await operation;
  assert.deepEqual({ applied, errors }, { applied: 0, errors: 0 });
});

for (const failed of [false, true]) test(`a late password update ${failed ? "error" : "success"} cannot alter the newer session's view`, async () => {
  assert.equal(typeof application.completeBrowserPasswordUpdate, "function");
  let generation = "a", release, applied = 0, errors = 0;
  const held = new Promise(resolve => { release = resolve; });
  const operation = application.completeBrowserPasswordUpdate({ client: { async changePassword() {
    await held;
    if (failed) throw new Error("synthetic_password_failure");
    return { changed: true };
  } }, currentPassword: "synthetic", newPassword: "synthetic-new", isCurrent: () => generation === "a",
    onSuccess() { applied++; }, onError() { errors++; } });
  generation = "b"; release();
  await operation;
  assert.deepEqual({ applied, errors }, { applied: 0, errors: 0 });
});

async function loginLifecycleFixture({ onVaultRequest, identity = null, onAccepted = async () => {}, legacyServer = false, onLoginResponse = async () => {} }) {
  const { createAuthenticatedVaultClient, loginWithDeviceConflictRetry } = await import("../public/vault-sync.js");
  const { runInNewContext } = await import("node:vm");
  const accountA = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", accountB = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const deviceID = "11111111-1111-4111-8111-111111111111", password = "synthetic testing password";
  const client = createAuthenticatedVaultClient({ sessionStorageValue: null, fetchValue: async (path, options) => {
    if (path === "/v1/auth/login") {
      const email = JSON.parse(options.body).email;
      const id = email.startsWith("b@") ? accountB : accountA;
      await onLoginResponse();
      return new Response(JSON.stringify({ token: "a".repeat(43), user: { id, email, username: "synthetic" }, deviceID }), {
        status: 200, headers: legacyServer ? {} : { "X-Selective-Session-Binding": deviceID },
      });
    }
    if (path === "/v1/vault") return onVaultRequest();
    throw new Error(`unexpected_synthetic_request:${path}`);
  } });
  let submit;
  const form = { elements: { email: { value: "a@example.invalid" }, password: { value: password } },
    querySelector: () => ({ disabled: false }), addEventListener(_event, listener) { submit = listener; } };
  const calls = { sessions: [], modes: [], accountMessages: [], text: [], locks: 0, personal: 0, team: 0,
    deactivations: 0, teamOwner: "previous-account", ownerWhenShown: [] };
  const accountDevices = { deviceID: async () => deviceID, remember: async (_email, id) => id,
    accepted: onAccepted, replaceAfterConflict: async () => null };
  const context = { form, client, accountDevices, loginWithDeviceConflictRetry, crypto: webcrypto, storageUnavailableCode: null,
    startupCompatibilityMessage: null,
    loginAttempt: 0, loginInputRevision: 0, completeInteractivePersonalVaultLogin: application.completeInteractivePersonalVaultLogin,
    ensureTeamDeviceIdentity: async () => identity, teamDeviceRepository: {},
    activateAccountVault: async () => ({ vault: { rememberSession: async () => true } }),
    unlockAndSyncPersonalVault: async () => { calls.personal++; return client.getVault(); },
    vaultUI: { mode(value) { calls.modes.push(value); } }, vault: { lock() { calls.locks++; } },
    showSession(user) { if (!user) context.teamWorkspace.deactivate(); calls.sessions.push(user); calls.ownerWhenShown.push(calls.teamOwner); },
    teamWorkspace: { async activate() { calls.team++; }, deactivate() { calls.deactivations++; calls.teamOwner = null; } },
    message: {}, vaultMessage: {}, setText(element, value) { element.textContent = value; calls.text.push(value); },
    setAccountMessage(value) { calls.accountMessages.push(value); },
    hideConflicts() {},
    cloudCompatibilityMessage: application.cloudCompatibilityMessage,
    vaultStorageCompatibilityMessage: application.vaultStorageCompatibilityMessage,
    personalVaultRecoveryMessage: application.personalVaultRecoveryMessage,
    personalVaultOwnershipError: () => false, personalVaultLegacyUnverifiedMessage: () => "legacy",
    personalVaultKeyMismatchMessage: () => "mismatch", sessionRetiredByError: application.sessionRetiredByError,
    retiredSessionGeneration: null };
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const retireStart = source.indexOf("  function retireCurrentTeamSession(error, generation)");
  const retireEnd = source.indexOf("\n  const teamWorkspace = ", retireStart);
  assert.ok(retireStart >= 0 && retireEnd > retireStart);
  runInNewContext(source.slice(retireStart, retireEnd), context);
  const start = source.indexOf('  form.addEventListener("submit", async (event) => {', source.indexOf("export async function initializeCloudAccount"));
  const end = source.indexOf("\n  let reauthenticationAttempt", start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(source.slice(start, end), context);
  return { client, calls, context, submit: () => submit({ preventDefault() {} }), accountB, deviceID, password };
}

test("login to a legacy server shows the upgrade requirement before touching the Vault", async () => {
  const fixture = await loginLifecycleFixture({ legacyServer: true, onVaultRequest: async () => { throw Error("unexpected_vault_request"); } });
  await fixture.submit();
  assert.equal(fixture.client.session(), null);
  assert.match(fixture.calls.accountMessages.at(-1), /Обновите Cloud/u);
  assert.deepEqual(fixture.calls.sessions, []);
  assert.equal(fixture.calls.team, 0);
  assert.equal(fixture.context.form.elements.password.value, "");
});

test("a delayed legacy-server rejection does not clear a newer password entry", async () => {
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const fixture = await loginLifecycleFixture({ legacyServer: true, onLoginResponse: async () => { entered(); await held; },
    onVaultRequest: async () => { throw Error("unexpected_vault_request"); } });
  const pending = fixture.submit();
  await started;
  fixture.context.form.elements.password.value = "newer synthetic entry";
  fixture.context.loginInputRevision += 1;
  release();
  await pending;
  assert.equal(fixture.context.form.elements.password.value, "newer synthetic entry");
  assert.equal(fixture.client.session(), null);
});

test("a 401 during Personal Vault login leaves the expired session signed out", async () => {
  const fixture = await loginLifecycleFixture({ onVaultRequest: async () => new Response(JSON.stringify({ error: "authentication_required" }), { status: 401 }) });
  await fixture.submit();
  assert.equal(fixture.client.session(), null);
  assert.deepEqual(fixture.calls.sessions, [null]);
  assert.equal(fixture.calls.locks, 1);
  assert.equal(fixture.calls.team, 0);
  assert.equal(fixture.calls.teamOwner, null);
  assert.ok(fixture.calls.deactivations >= 1);
  assert.match(fixture.calls.accountMessages.at(-1), /сессия cloud истекла/iu);
});

test("deferred storage rejects login locally with an actionable message", async () => {
  const fixture = await loginLifecycleFixture({ onVaultRequest: async () => { throw new Error("unexpected_request"); } });
  fixture.context.storageUnavailableCode = "vault_storage_upgrade_confirmation_required";
  await fixture.submit();
  assert.equal(fixture.client.session(), null);
  assert.equal(fixture.calls.personal, 0);
  assert.equal(fixture.calls.team, 0);
  assert.match(fixture.calls.accountMessages.at(-1), /хранилище Cloud не открыто/iu);
});

test("login explains when another tab blocks the safe storage upgrade", async () => {
  const fixture = await loginLifecycleFixture({ onVaultRequest: async () => { throw new Error("unexpected_vault_request"); } });
  fixture.context.accountDevices.deviceID = async () => { throw new Error("vault_storage_upgrade_blocked"); };
  await fixture.submit();
  assert.equal(fixture.client.session(), null);
  assert.equal(fixture.calls.personal, 0);
  assert.match(fixture.calls.accountMessages.at(-1), /вкладках.*закройте/iu);
  assert.match(fixture.calls.accountMessages.at(-1), /сохранённые данные не изменены/iu);
});

test("a late 401 from account A cannot repaint or lock account B", async () => {
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const fixture = await loginLifecycleFixture({ onVaultRequest: async () => {
    entered(); await held; return new Response(JSON.stringify({ error: "authentication_required" }), { status: 401 });
  } });
  const pending = fixture.submit();
  await started;
  await fixture.client.login({ email: "b@example.invalid", password: fixture.password, deviceID: fixture.deviceID });
  fixture.calls.teamOwner = "account-b";
  release();
  await pending;
  assert.equal(fixture.client.session().id, fixture.accountB);
  assert.deepEqual(fixture.calls.sessions, []);
  assert.deepEqual(fixture.calls.modes, []);
  assert.deepEqual(fixture.calls.accountMessages, []);
  assert.equal(fixture.calls.locks, 0);
  assert.equal(fixture.calls.team, 0);
  assert.equal(fixture.calls.teamOwner, "account-b");
});

test("a 401 during Team key bootstrap cannot restore an expired login", async () => {
  const fixture = await loginLifecycleFixture({ identity: { publicKey: null },
    onVaultRequest: async () => new Response(JSON.stringify({ error: "authentication_required" }), { status: 401 }) });
  fixture.context.unlockAndSyncPersonalVault = async () => ({});
  fixture.client.bootstrapDeviceKey = async () => fixture.client.getVault();
  await fixture.submit();
  assert.equal(fixture.client.session(), null);
  assert.deepEqual(fixture.calls.sessions, [null]);
  assert.equal(fixture.calls.locks, 1);
  assert.equal(fixture.calls.team, 0);
  assert.match(fixture.calls.accountMessages.at(-1), /сессия cloud истекла/iu);
});

test("a replaced session during device acceptance cannot continue the older login", async () => {
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const fixture = await loginLifecycleFixture({ onVaultRequest: async () => { throw new Error("unexpected_vault_request"); },
    onAccepted: async () => { entered(); await held; } });
  const pending = fixture.submit();
  await started;
  await fixture.client.login({ email: "b@example.invalid", password: fixture.password, deviceID: fixture.deviceID });
  release();
  await pending;
  assert.equal(fixture.client.session().id, fixture.accountB);
  assert.equal(fixture.calls.personal, 0);
  assert.deepEqual(fixture.calls.sessions, []);
  assert.equal(fixture.calls.team, 0);
});

test("a new login clears the prior Team view before showing the new account", async () => {
  const fixture = await loginLifecycleFixture({ onVaultRequest: async () => new Response("{}", { status: 500 }) });
  await fixture.submit();
  assert.equal(fixture.calls.sessions.length, 1);
  assert.equal(fixture.calls.sessions[0].email, "a@example.invalid");
  assert.deepEqual(fixture.calls.ownerWhenShown, [null]);
  assert.ok(fixture.calls.deactivations >= 1);
});

test("authentication loss belongs only to its exact retired session generation", () => {
  const error = Object.assign(new Error("authentication_required"), { invalidatedSessionEpoch: "5" });
  let generation = "6", session = null;
  const client = { session: () => session, sessionGeneration: () => generation };
  assert.equal(application.sessionRetiredByError(client, error, "5"), true);
  generation = "7";
  assert.equal(application.sessionRetiredByError(client, error, "5"), false);
  generation = "6"; session = { id: "new" };
  assert.equal(application.sessionRetiredByError(client, error, "5"), false);
});

test("session presentation clears the previous Team before displaying another account", async () => {
  const { runInNewContext } = await import("node:vm");
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf("  let sessionPresentationEpoch = ");
  const end = source.indexOf("\n  function setSettingsMessage", start);
  assert.ok(start >= 0 && end > start);
  let generation = "a", teamOwner = "initial", deactivations = 0;
  const observations = [];
  const context = { client: { sessionGeneration: () => generation },
    teamWorkspace: { deactivate() { deactivations++; teamOwner = null; } },
    tabs: {}, form: {}, registrationForm: {}, recoveryFormAccount: {}, registrationSuccess: {}, signedIn: {},
    syncButton: {}, accountName: {}, usernameForm: { elements: { username: {} } },
    setText(element, value) { element.textContent = value; }, onSessionChange(user) { observations.push({ user, teamOwner }); } };
  runInNewContext(`${source.slice(start, end)}\nthis.showCapturedSession = showSession;`, context);
  context.showCapturedSession({ id: "a", username: "synthetic-a" });
  teamOwner = "account-a"; generation = "b";
  context.showCapturedSession({ id: "b", username: "synthetic-b" });
  assert.equal(observations.at(-1).teamOwner, null);
  const count = deactivations;
  teamOwner = "account-b";
  context.showCapturedSession({ id: "b", username: "synthetic-b-renamed" });
  assert.equal(deactivations, count);
  assert.equal(observations.at(-1).teamOwner, "account-b");
});

async function startupLifecycleFixture({ requestVault, failRestore = false, onRestore = null, storageUnavailableCode = null, unsupportedServer = false }) {
  const { runInNewContext } = await import("node:vm");
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf('  setAuthMode("login");\n  let startupSession');
  const end = source.indexOf("\n  return {\n    client,", start);
  assert.ok(start >= 0 && end > start);
  let session = null, generation = "0";
  const calls = { sessions: [], modes: [], accountMessages: [], locks: 0 };
  const error = () => Object.assign(new Error("authentication_required"), { invalidatedSessionEpoch: "1" });
  const client = { session: () => session, sessionGeneration: () => generation,
    async restoreSession() {
      generation = "1";
      if (onRestore) await onRestore();
      if (unsupportedServer) throw new Error("cloud_upgrade_required");
      if (failRestore) { generation = "2"; throw error(); }
      session = { id: "a" }; return session;
    },
    async getVault() { return requestVault({ expire() { session = null; generation = "2"; return error(); } }); } };
  const context = { client, storageUnavailableCode, setAuthMode() {}, showSession(user) { calls.sessions.push(user?.id ?? null); },
    startupCompatibilityMessage: null,
    capturePersonalVaultSession() { const id = session.id, prior = generation;
      return { requireCurrent() { if (session?.id !== id || generation !== prior) throw new Error("authentication_required"); } }; },
    async activateAccountVault() { return { restored: false, legacyOwnershipUnverified: false }; },
    vault: { async status() { return "locked"; }, async restoreRememberedSession() { return false; }, lock() { calls.locks++; } },
    vaultUI: { mode(value) { calls.modes.push(value); }, render() {} }, vaultMessage: {}, setText() {},
    setAccountMessage(value) { calls.accountMessages.push(value); }, hideConflicts() {}, sessionRetiredByError: application.sessionRetiredByError,
    cloudCompatibilityMessage: application.cloudCompatibilityMessage,
    retiredSessionGeneration: null };
  const retireStart = source.indexOf("  function retireCurrentTeamSession(error, generation)");
  const retireEnd = source.indexOf("\n  const teamWorkspace = ", retireStart);
  assert.ok(retireStart >= 0 && retireEnd > retireStart);
  runInNewContext(source.slice(retireStart, retireEnd), context);
  const pending = runInNewContext(`(async () => {${source.slice(start, end)}\n})()`, context);
  return { pending, calls, client, context, source, replaceSession() { session = { id: "b" }; generation = "2"; } };
}

test("startup on a legacy server explains the upgrade and leaves the Vault closed", async () => {
  const fixture = await startupLifecycleFixture({ unsupportedServer: true, requestVault: async () => { throw Error("unexpected_vault_request"); } });
  await fixture.pending;
  assert.deepEqual(fixture.calls.sessions, [null]);
  assert.match(fixture.calls.accountMessages.at(-1), /Обновите Cloud/u);
  // Initial navigation calls setAuthMode after startup and must not erase the warning.
  const { runInNewContext } = await import("node:vm");
  Object.assign(fixture.context, { metadata: { registrationEnabled: false }, initialTeamInvitationToken: null,
    form: {}, registrationForm: { querySelectorAll: () => [] }, recoveryFormAccount: {}, registrationSuccess: {},
    loginTab: { setAttribute() {} }, registrationTab: { setAttribute() {} } });
  const start = fixture.source.indexOf("  function setAuthMode(mode)");
  const end = fixture.source.indexOf("\n  function hideConflicts", start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(fixture.source.slice(start, end) + "\nglobalThis.navigateToLogin = setAuthMode;", fixture.context);
  fixture.context.navigateToLogin("login");
  assert.match(fixture.calls.accountMessages.at(-1), /Обновите Cloud/u);
});

test("deferred storage does not restore a session or touch account Vault state", async () => {
  let restores = 0;
  const fixture = await startupLifecycleFixture({ requestVault: async () => { throw new Error("unexpected_request"); },
    onRestore: async () => { restores++; }, storageUnavailableCode: "vault_storage_upgrade_confirmation_required" });
  await fixture.pending;
  assert.equal(restores, 0);
  assert.equal(fixture.client.session(), null);
  assert.deepEqual(fixture.calls.sessions, [null]);
});

test("a current 401 during restored Personal Vault startup clears the signed-in view", async () => {
  const fixture = await startupLifecycleFixture({ requestVault: async ({ expire }) => { throw expire(); } });
  await fixture.pending;
  assert.equal(fixture.client.session(), null);
  assert.deepEqual(fixture.calls.sessions, ["a", null]);
  assert.equal(fixture.calls.locks, 1);
  assert.match(fixture.calls.accountMessages.at(-1), /сессия cloud истекла/iu);
});

test("a late startup 401 does not clear the newer signed-in session", async () => {
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const fixture = await startupLifecycleFixture({ requestVault: async () => {
    entered(); await held; throw new Error("authentication_required");
  } });
  await started;
  fixture.replaceSession(); release();
  await fixture.pending;
  assert.equal(fixture.client.session().id, "b");
  assert.deepEqual(fixture.calls.sessions, ["a"]);
  assert.equal(fixture.calls.locks, 0);
  assert.deepEqual(fixture.calls.accountMessages, []);
});

test("an ordinary signed-out startup does not report an expired restored session", async () => {
  const fixture = await startupLifecycleFixture({ failRestore: true, requestVault: async () => { throw new Error("unexpected_request"); } });
  await fixture.pending;
  assert.deepEqual(fixture.calls.sessions, [null]);
  assert.equal(fixture.calls.locks, 0);
  assert.deepEqual(fixture.calls.accountMessages, []);
});

test("a late failed session restore cannot show an error over a newer login", async () => {
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const fixture = await startupLifecycleFixture({ requestVault: async () => { throw new Error("unexpected_request"); },
    onRestore: async () => { entered(); await held; throw new Error("authentication_required"); } });
  await started;
  fixture.replaceSession(); release();
  await fixture.pending;
  assert.equal(fixture.client.session().id, "b");
  assert.deepEqual(fixture.calls.sessions, []);
  assert.deepEqual(fixture.calls.modes, []);
  assert.deepEqual(fixture.calls.accountMessages, []);
});

for (const failed of [false, true]) test(`an old Team list ${failed ? "error" : "response"} cannot replace the newer session's Team`, async () => {
  assert.equal(typeof application.captureTeamWorkspaceContext, "function");
  assert.equal(typeof application.teamWorkspaceContextMatches, "function");
  const { runInNewContext } = await import("node:vm");
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf("  async function loadTeams(");
  const end = source.indexOf("\n  createTeamForm.addEventListener", start);
  assert.ok(start >= 0 && end > start);
  let session = { id: "a" }, deviceID = "device-a", generation = "1", identity = { deviceID }, epoch = 1;
  let entered, release, locked = 0;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const client = { session: () => session, deviceID: () => deviceID, sessionGeneration: () => generation,
    async listTeams() {
      const account = session.id;
      if (account === "a") { entered(); await held; if (failed) throw new Error("synthetic_stale_failure"); }
      return [{ id: `team-${account}`, name: `Synthetic ${account}`, role: "owner" }];
    } };
  const select = { value: "", options: [], replaceChildren() { this.options = []; this.value = ""; },
    append(option) { this.options.push(option); if (!this.value) this.value = option.value; } };
  const context = { client, teams: [], selectedTeam: null, controller: null, teamListRequestGeneration: 0,
    teamSelect: select, teamInvitations: [], selectedPanel: {}, message: {}, documentValue: { createElement: () => ({}) },
    renderOverviewSummary() {}, renderTeamInvitations() {}, teamRoleLabel: () => "owner", setText() {},
    captureWorkspaceContext: () => application.captureTeamWorkspaceContext({ client, identity, activationEpoch: epoch }),
    workspaceContextCurrent: captured => application.teamWorkspaceContextMatches(captured, { client, identity, activationEpoch: epoch }),
    async loadSelectedTeam(captured) {
      if (!context.workspaceContextCurrent(captured)) return;
      context.controller?.lock();
      context.selectedTeam = context.teams.find(team => team.id === select.value);
    } };
  runInNewContext(`${source.slice(start, end)}\nthis.loadCapturedTeams = loadTeams;`, context);
  const old = context.loadCapturedTeams();
  await started;
  session = { id: "b" }; deviceID = "device-b"; generation = "2"; identity = { deviceID }; epoch++;
  await context.loadCapturedTeams();
  context.controller = { lock() { locked++; } };
  release();
  await old;
  assert.equal(context.selectedTeam.id, "team-b");
  assert.deepEqual(select.options.map(value => value.value), ["team-b"]);
  assert.equal(locked, 0);
});

for (const failed of [false, true]) test(`an old selected-Team ${failed ? "error" : "response"} cannot update a newer session of the same Team`, async () => {
  const { runInNewContext } = await import("node:vm");
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf("  async function loadSelectedTeam(");
  const end = source.indexOf("\n  async function loadTeams(", start);
  assert.ok(start >= 0 && end > start);
  let session = { id: "a" }, deviceID = "device-a", generation = "1", identity = { deviceID }, epoch = 1;
  let entered, release, backgroundStarted = 0;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const client = { session: () => session, deviceID: () => deviceID, sessionGeneration: () => generation,
    async listTeamMembersPage() { entered(); await held; if (failed) throw new Error("synthetic_stale_failure"); return { members: [], nextCursor: null, total: 0 }; },
    async listSharedVaults() { return [{ id: "vault-a" }]; }, async listTeamInvitations() { return []; },
    async getTeamDeviceAdmissionPolicy() { return {}; } };
  const element = () => ({ hidden: false, disabled: false, value: "", reset() {}, replaceChildren() {}, querySelector: () => element() });
  const shared = { id: "shared-team", role: "owner", name: "Synthetic" };
  const context = { client, teams: [shared], selectedTeam: null, selectedVault: null, memberRequestGeneration: 0, selectedTeamRequestGeneration: 0,
    accessManager: null, activeView: "teams", teamSelect: { value: shared.id }, lockCurrentVault() {},
    teamMembers: [], ownershipMembers: [], memberNextCursor: null, memberTotal: 0, renderMembers() {},
    teamInvitations: [], renderTeamInvitations() {}, selectedPanel: element(), deviceAdmissionPolicy: null,
    renderDeviceAdmissionPolicy() {}, deviceAdmissionPolicyPanel: element(), teamRole: element(), teamRoleLabel: () => "owner",
    inviteForm: { hidden: false, elements: { role: { value: "viewer", options: [{ value: "admin" }] } } },
    canManage: () => true, createVaultForm: element(), lifecyclePanel: element(), renameTeamForm: { elements: { name: element() } },
    archiveTeamForm: element(), archiveTeamMessage: element(), transferOwnershipForm: element(), transferOwnershipMember: element(),
    memberSearch: element(), memberRoleFilter: element(), vaults: [], populateVaults() {}, updateTeamMessage() {},
    startBackgroundSync() { backgroundStarted++; }, runBackgroundTeamVaultSync: async () => {}, setText() {},
    captureWorkspaceContext: () => application.captureTeamWorkspaceContext({ client, identity, activationEpoch: epoch }),
    workspaceContextCurrent: captured => application.teamWorkspaceContextMatches(captured, { client, identity, activationEpoch: epoch }) };
  runInNewContext(`${source.slice(start, end)}\nthis.loadCapturedTeam = loadSelectedTeam;`, context);
  const old = context.loadCapturedTeam();
  await started;
  session = { id: "b" }; deviceID = "device-b"; generation = "2"; identity = { deviceID }; epoch++;
  context.selectedTeam = { ...shared, name: "Synthetic B" };
  context.memberRequestGeneration++;
  context.vaults = [{ id: "vault-b" }];
  release();
  await old;
  assert.equal(context.selectedTeam.name, "Synthetic B");
  assert.equal(context.vaults[0].id, "vault-b");
  assert.equal(backgroundStarted, 0);
});

test("a member search does not cancel the current Team's vault-list load", async () => {
  const { runInNewContext } = await import("node:vm");
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf("  async function loadSelectedTeam("), end = source.indexOf("\n  async function loadTeams(", start);
  let entered, release, backgroundStarted = 0;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const identity = { deviceID: "device" }, client = { session: () => ({ id: "a" }), deviceID: () => "device", sessionGeneration: () => "1",
    async listTeamMembersPage() { entered(); await held; return { members: [], nextCursor: null, total: 0 }; },
    async listSharedVaults() { return [{ id: "vault-a" }]; }, async listTeamInvitations() { return []; },
    async getTeamDeviceAdmissionPolicy() { return {}; } };
  const element = () => ({ hidden: false, disabled: false, value: "", reset() {}, replaceChildren() {}, querySelector: () => element() });
  const team = { id: "team-a", role: "owner", name: "Synthetic" };
  const context = { client, teams: [team], selectedTeam: null, selectedVault: null, memberRequestGeneration: 0, selectedTeamRequestGeneration: 0,
    accessManager: null, activeView: "teams", teamSelect: { value: team.id }, lockCurrentVault() {},
    teamMembers: [], ownershipMembers: [], memberNextCursor: null, memberTotal: 0, renderMembers() {}, teamInvitations: [],
    renderTeamInvitations() {}, selectedPanel: element(), deviceAdmissionPolicy: null, renderDeviceAdmissionPolicy() {},
    deviceAdmissionPolicyPanel: element(), teamRole: element(), teamRoleLabel: () => "owner",
    inviteForm: { hidden: false, elements: { role: { value: "viewer", options: [{ value: "admin" }] } } }, canManage: () => true,
    createVaultForm: element(), lifecyclePanel: element(), renameTeamForm: { elements: { name: element() } }, archiveTeamForm: element(),
    archiveTeamMessage: element(), transferOwnershipForm: element(), transferOwnershipMember: element(), memberSearch: element(), memberRoleFilter: element(),
    vaults: [], populateVaults() {}, updateTeamMessage() {}, startBackgroundSync() { backgroundStarted++; }, runBackgroundTeamVaultSync: async () => {}, setText() {},
    captureWorkspaceContext: () => application.captureTeamWorkspaceContext({ client, identity, activationEpoch: 1 }),
    workspaceContextCurrent: captured => application.teamWorkspaceContextMatches(captured, { client, identity, activationEpoch: 1 }) };
  runInNewContext(`${source.slice(start, end)}\nthis.loadCapturedTeam = loadSelectedTeam;`, context);
  const pending = context.loadCapturedTeam();
  await started;
  context.memberRequestGeneration++;
  release();
  await pending;
  assert.equal(context.vaults[0]?.id, "vault-a");
  assert.equal(backgroundStarted, 1);
});

for (const kind of ["devices", "invitations"]) for (const failed of [false, true]) {
  test(`old Team ${kind} ${failed ? "error" : "response"} cannot repaint the newer session`, async () => {
    const { runInNewContext } = await import("node:vm");
    const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
    const startMarker = kind === "devices" ? "  async function loadDevices(" : "  async function loadPendingInvitations(";
    const endMarker = kind === "devices" ? "\n  function renderMembers(" : "\n  async function refreshWorkspaceActivity(";
    const start = source.indexOf(startMarker), end = source.indexOf(endMarker, start);
    assert.ok(start >= 0 && end > start);
    let generation = "1", identity = { deviceID: "same-device" }, epoch = 1, entered, release, paints = 0;
    const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
    const delayed = async () => { entered(); await held; if (failed) throw new Error("synthetic_stale_failure"); return []; };
    const client = { session: () => ({ id: "same-account" }), deviceID: () => "same-device", sessionGeneration: () => generation,
      listDevices: delayed, listPendingTeamInvitations: delayed };
    const context = { client, identity, notificationSourceSequence: 0, documentValue: {}, deviceTrustContainer: null,
      deviceTrustRepository: null, devices: { replaceChildren() { paints++; } }, deviceOrbit: null,
      accountInvitations: [{ id: "new" }], renderPendingInvitations() { paints++; }, renderOverviewSummary() { paints++; },
      activeInterfaceLocale: () => "ru",
      captureWorkspaceContext: () => application.captureTeamWorkspaceContext({ client, identity, activationEpoch: epoch }),
      workspaceContextCurrent: captured => application.teamWorkspaceContextMatches(captured, { client, identity, activationEpoch: epoch }) };
    runInNewContext(`${source.slice(start, end)}\nthis.loadCaptured = ${kind === "devices" ? "loadDevices" : "loadPendingInvitations"};`, context);
    const old = context.loadCaptured();
    await started;
    generation = "2"; identity = { deviceID: "same-device" }; context.identity = identity; epoch++;
    release();
    await old;
    assert.equal(paints, 0);
    if (kind === "invitations") assert.equal(context.accountInvitations[0].id, "new");
  });
}

test("a delayed old device-trust panel can only render into its detached container", async () => {
  const { runInNewContext } = await import("node:vm");
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf("  async function loadDevices("), end = source.indexOf("\n  function renderMembers(", start);
  let generation = "1", identity = { deviceID: "device" }, epoch = 1, entered, release, reloads = 0;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const client = { session: () => ({ id: "account" }), deviceID: () => "device", sessionGeneration: () => generation, async listDevices() { return []; } };
  const panel = { children: [], replaceChildren(...items) { this.children = items; } };
  const context = { client, identity, notificationSourceSequence: 0, documentValue: { createElement: () => ({ style: {} }) },
    deviceTrustContainer: panel, deviceTrustRepository: {}, teamIdentityRepository: {}, trustPanel: null,
    location: { origin: "https://synthetic.invalid", reload() { reloads++; } },
    devices: { replaceChildren() {} }, deviceOrbit: null, activeInterfaceLocale: () => "ru",
    captureWorkspaceContext: () => application.captureTeamWorkspaceContext({ client, identity, activationEpoch: epoch }),
    workspaceContextCurrent: captured => application.teamWorkspaceContextMatches(captured, { client, identity, activationEpoch: epoch }),
    createBrowserDeviceTrustPanel({ container, onRekeyCommitted }) { return { async refresh() {
      entered(); await held; container.value = "old"; onRekeyCommitted();
    } }; } };
  runInNewContext(`${source.slice(start, end)}\nthis.loadCaptured = loadDevices;`, context);
  const old = context.loadCaptured();
  await started;
  generation = "2"; identity = { deviceID: "device" }; context.identity = identity; epoch++;
  const current = { value: "new" };
  panel.replaceChildren(current);
  release();
  await old;
  assert.equal(panel.children[0], current);
  assert.equal(panel.children[0].value, "new");
  assert.equal(reloads, 0);
});

for (const stage of ["confirmation", "revoke", "selection", "maintenance", "vaults"]) {
  for (const failed of stage === "confirmation" ? [false] : [false, true]) {
    test(`Team revoke ${stage} ${failed ? "error" : "response"} cannot affect a replacement session`, async () => {
      const { runInNewContext } = await import("node:vm");
      const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
      const start = source.indexOf('      revoke.addEventListener("click", async () => {', source.indexOf("  function renderMembers("));
      const end = source.indexOf("\n      actions.className", start);
      assert.ok(start >= 0 && end > start);
      let entered, release, switched = false, callback, messagesAfterSwitch = 0, selectionsAfterSwitch = 0;
      const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
      const gate = async name => {
        if (name !== stage) return;
        entered(); await held;
        if (failed) throw new Error("synthetic_stale_failure");
      };
      const requests = [], revoke = { disabled: false, addEventListener(_type, handler) { callback = handler; } };
      const teamA = { id: "team-a" }, teamB = { id: "team-b" };
      const context = { revoke, member: { id: "member-a", username: "synthetic" }, selectedTeam: teamA,
        selectedTeamRequestGeneration: 1, activeSession: "a", ownershipMembers: ["a"], vaults: [{ id: "a" }],
        message: {}, editableByActor: true, self: false,
        captureWorkspaceContext() { return context.activeSession; }, workspaceContextCurrent: captured => captured === context.activeSession,
        async requestConfirmation() { await gate("confirmation"); return true; },
        client: { async revokeTeamMember(input) { requests.push(input); await gate("revoke"); return { rotationRequiredVaults: 1 }; },
          async listSharedVaults(id) { requests.push({ list: id }); await gate("vaults"); return [{ id: "a", rotationRequired: false }]; } },
        async loadSelectedTeam() { context.selectedTeamRequestGeneration++; if (switched) selectionsAfterSwitch++; await gate("selection"); },
        async maintainSelectedTeamVaults() { await gate("maintenance"); return { rotated: 1 }; },
        populateVaults() { if (switched) messagesAfterSwitch++; }, setText() { if (switched) messagesAfterSwitch++; } };
      runInNewContext(source.slice(start, end), context);
      const operation = callback();
      await started;
      switched = true; context.activeSession = "b"; context.selectedTeam = teamB; context.selectedTeamRequestGeneration++;
      context.ownershipMembers = ["b"]; context.vaults = [{ id: "b" }];
      release();
      await operation;
      assert.equal(context.selectedTeam, teamB);
      assert.deepEqual(context.ownershipMembers, ["b"]);
      assert.equal(context.vaults[0].id, "b");
      assert.equal(selectionsAfterSwitch, 0);
      assert.equal(messagesAfterSwitch, 0);
      assert.equal(requests.some(request => request.teamID === "team-b" || request.list === "team-b"), false);
    });
  }
}

for (const stage of ["format", "synchronize"]) test(`Team maintenance stops after its ${stage} result becomes stale`, async () => {
  let current = true, entered, release, controllers = 0, provisions = 0, locks = 0;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const gate = async name => { if (name === stage) { entered(); await held; } };
  const client = { accessClient() { return { async getContext() { await gate("format"); return { formatState: "V1_ACTIVE" }; } }; } };
  const operation = application.maintainAccessibleTeamVaultWrappers({ client, identity: {}, team: { id: "team-a", role: "owner" },
    vaults: [{ id: "vault-a", rotationRequired: false }], isCurrent: () => current,
    repositoryFactory: () => ({}), controllerFactory() { controllers++; return { lock() { locks++; } }; },
    async synchronize() { await gate("synchronize"); return { status: "up_to_date" }; },
    async provision() { provisions++; return { granted: 1 }; } });
  await started;
  current = false; release();
  await operation;
  assert.equal(provisions, 0);
  assert.equal(controllers, stage === "format" ? 0 : 1);
  assert.equal(locks, stage === "format" ? 0 : 1);
});

test("a previous Team maintenance promise is not reused by a newer session", async () => {
  const { runInNewContext } = await import("node:vm");
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf("  async function maintainSelectedTeamVaults("), end = source.indexOf("\n  async function synchronizeAndProvision(", start);
  assert.ok(start >= 0 && end > start);
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const calls = [];
  const teamA = { id: "shared-team", role: "owner", account: "a" }, teamB = { ...teamA, account: "b" };
  const context = { activeSession: "a", identity: {}, selectedTeam: teamA, selectedVault: null,
    selectedTeamRequestGeneration: 1, teamVaultLockEpoch: 0, teamVaultManuallyLocked: false,
    createTrackedTeamVaultController() {}, vaults: [{ id: "vault-a", rotationRequired: true }], vaultSelect: {},
    backgroundMaintenanceOperation: null, captureWorkspaceContext() { return context.activeSession; },
    workspaceContextCurrent: captured => captured === context.activeSession,
    async maintainAccessibleTeamVaultWrappers({ team }) {
      calls.push(`maintenance-${team.account}`);
      if (team.account === "a") { entered(); await held; }
      return { rotated: 1 };
    },
    client: { async listSharedVaults() { calls.push(`refresh-${context.activeSession}`); return [{ id: `vault-${context.activeSession}` }]; } },
    populateVaults() {} };
  runInNewContext(`${source.slice(start, end)}\nthis.maintainCaptured = maintainSelectedTeamVaults;`, context);
  const old = context.maintainCaptured();
  await started;
  context.activeSession = "b"; context.selectedTeam = teamB; context.selectedTeamRequestGeneration++;
  context.vaults = [{ id: "vault-b", rotationRequired: true }];
  await context.maintainCaptured();
  release();
  await old;
  assert.deepEqual(calls, ["maintenance-a", "maintenance-b", "refresh-b"]);
  assert.equal(context.vaults[0].id, "vault-b");
});

for (const outcome of ["success", "post-confirm-failure", "unconfirmed"]) {
  test(`current Team revoke reports ${outcome} without crossing accounts`, async () => {
    const { runInNewContext } = await import("node:vm");
    const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
    const start = source.indexOf('      revoke.addEventListener("click", async () => {', source.indexOf("  function renderMembers("));
    const end = source.indexOf("\n      actions.className", start);
    assert.ok(start >= 0 && end > start);
    let callback, lastMessage = "", loadedTeam = "";
    const revoke = { disabled: false, addEventListener(_type, handler) { callback = handler; } };
    const team = { id: "team-a" };
    const context = { revoke, member: { id: "member-a", username: "synthetic" }, selectedTeam: team,
      selectedTeamRequestGeneration: 1, ownershipMembers: ["old"], vaults: [], message: {}, editableByActor: true, self: false,
      captureWorkspaceContext: () => "a", workspaceContextCurrent: captured => captured === "a",
      requestConfirmation: async () => true,
      client: { async revokeTeamMember(input) {
        assert.equal(input.teamID, "team-a");
        if (outcome === "unconfirmed") throw new Error("synthetic_failure");
        return { rotationRequiredVaults: 1 };
      }, async listSharedVaults(id) { loadedTeam = id; return [{ id: "vault-a", rotationRequired: false }]; } },
      async loadSelectedTeam() { context.selectedTeamRequestGeneration++; },
      async maintainSelectedTeamVaults() { if (outcome === "post-confirm-failure") throw new Error("synthetic_failure"); return { rotated: 1 }; },
      populateVaults() {}, setText(_element, value) { lastMessage = value; } };
    runInNewContext(source.slice(start, end), context);
    await callback();
    if (outcome === "success") { assert.equal(loadedTeam, "team-a"); assert.match(lastMessage, /доступ отозван.*ключи обновлены/iu); }
    else if (outcome === "post-confirm-failure") assert.match(lastMessage, /доступ отозван.*не удалось подтвердить/iu);
    else assert.match(lastMessage, /не удалось подтвердить отзыв/iu);
  });
}

test("Team sync reports an up-to-date Vault without requiring conflict details", async () => {
  const { teamSyncOutcomeMessage } = await import("../public/app.js");
  assert.equal(typeof teamSyncOutcomeMessage, "function");
  assert.equal(teamSyncOutcomeMessage({ status: "up_to_date", revision: 5 }),
    "Shared Vault синхронизирован · ревизия 5.");
  assert.equal(teamSyncOutcomeMessage({ status: "downloaded", revision: 6 }),
    "Team-ревизия 6 загружена и объединена локально.");
  assert.equal(teamSyncOutcomeMessage({ status: "conflict", conflicts: [{}, {}] }),
    "Обнаружено конфликтов: 2. Выберите версии явно.");
});

test("Team admission failures distinguish committed devices from an unconfirmed result", async () => {
  const { teamDeviceAdmissionErrorMessage } = await import("../public/app.js");
  assert.equal(typeof teamDeviceAdmissionErrorMessage, "function");
  const committed = teamDeviceAdmissionErrorMessage(1);
  assert.match(committed, /Допущено устройств: 1/u);
  assert.match(committed, /синхронизац|ключ/u);
  assert.doesNotMatch(committed, /не допущены/u);
  const unknown = teamDeviceAdmissionErrorMessage(0);
  assert.match(unknown, /не удалось подтвердить/iu);
  assert.doesNotMatch(unknown, /не допущены/u);
});

test("Team archive failures provide specific actionable feedback", () => {
  assert.equal(
    teamArchiveErrorMessage(new Error("invalid_credentials")),
    "Текущий пароль неверен. Введите пароль текущего аккаунта и повторите.",
  );
  assert.equal(
    teamArchiveErrorMessage(new Error("team_name_mismatch")),
    "Название не совпадает. Введите точное название Team и повторите.",
  );
  assert.match(teamArchiveErrorMessage(new Error("team_archive_failed")), /Team не архивирована/u);
  assert.match(teamArchiveErrorMessage(new Error("local_cleanup_failed"), true), /Team архивирована/u);
});

test("Team locale rerender refreshes pending invitations and Team switches clear archive feedback", async () => {
  const application = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const localeRerender = application.match(/renderLocaleSensitive\(\) \{([\s\S]*?)\n    \},\n    async activate/u)?.[1] ?? "";
  assert.match(localeRerender, /renderPendingInvitations\(\)/u);

  const selectedTeamLoad = application.match(/async function loadSelectedTeam\([^\n]*\) \{([\s\S]*?)\n  async function loadTeams/u)?.[1] ?? "";
  assert.match(selectedTeamLoad, /archiveTeamForm\.reset\(\);\s*setText\(archiveTeamMessage, ""\)/u);
});

function memoryVaultRepository() {
  let snapshot = null;
  let sync = null;
  let deviceID = null;
  let sessionDeviceKey = null;
  let sessionUnlock = null;
  let ownership = null;
  return {
    async load() { return snapshot ? structuredClone(snapshot) : null; },
    async save(value) { snapshot = structuredClone(value); },
    async loadSync() { return sync ? structuredClone(sync) : null; },
    async saveSync(value) { sync = structuredClone(value); },
    async loadDeviceID() { return deviceID; },
    async saveDeviceID(value) { deviceID = value; },
    async loadSessionDeviceKey() { return sessionDeviceKey ? structuredClone(sessionDeviceKey) : null; },
    async saveSessionDeviceKey(value) { sessionDeviceKey = structuredClone(value); },
    async loadSessionUnlock() { return sessionUnlock ? structuredClone(sessionUnlock) : null; },
    async saveSessionUnlock(value) { sessionUnlock = structuredClone(value); },
    async deleteSessionUnlock() { sessionUnlock = null; },
    async loadOwnershipBinding() { return ownership ? structuredClone(ownership) : null; },
    async saveOwnershipBinding(value) { ownership = structuredClone(value); },
    rememberedSession() { return sessionUnlock ? structuredClone(sessionUnlock) : null; },
  };
}

function testVault(repository, ids) {
  let index = 0;
  return createLocalVaultController({
    repository,
    cryptoValue: webcrypto,
    randomUUID: () => ids[index++],
    now: () => "2026-09-21T00:00:00.000Z",
  });
}

test("restored authenticated sessions distinguish uninitialized, reauthentication-required, and unlocked Vaults", () => {
  assert.equal(resolveRestoredPersonalVaultState({ localStatus: "empty", remoteRevision: 0, restored: false }), "uninitialized");
  assert.equal(resolveRestoredPersonalVaultState({ localStatus: "locked", remoteRevision: 0, restored: false }), "reauthentication_required");
  assert.equal(resolveRestoredPersonalVaultState({ localStatus: "locked", remoteRevision: 3, restored: false }), "reauthentication_required");
  assert.equal(resolveRestoredPersonalVaultState({ localStatus: "unlocked", remoteRevision: 3, restored: true }), "unlocked");
  assert.throws(
    () => resolveRestoredPersonalVaultState({ localStatus: "empty", remoteRevision: -1, restored: false }),
    /invalid_personal_vault_state/u,
  );
});

test("interactive browser bootstrap creates exactly one encrypted r1 for an uninitialized account", async () => {
  const passphrase = accountVaultPassphrase("account B password is long enough");
  const vault = testVault(memoryVaultRepository(), ["11111111-1111-4111-8111-111111111111"]);
  let remote = { id: "99999999-9999-4999-8999-999999999999", revision: 0, envelope: null };
  let uploads = 0;
  const client = {
    session: () => ({ id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" }),
    async getVault() { return structuredClone(remote); },
    async putVault(_scope, envelope) {
      uploads += 1;
      assert.equal(envelope.baseRevision, 0);
      assert.equal(JSON.stringify(envelope).includes("account B password"), false);
      remote = { ...remote, revision: 1, envelope };
      return { conflict: false, revision: 1 };
    },
  };

  const result = await bootstrapPersonalVault({ vault, client, passphrase });

  assert.equal(result.status, "uploaded");
  assert.equal(result.revision, 1);
  assert.equal(uploads, 1);
  assert.equal(await vault.status(), "unlocked");
});

test("a new account can retry its own initial upload after a failed connection and reload", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const passphrase = accountVaultPassphrase("synthetic account password");
  const repository = memoryVaultRepository();
  let attempts = 0;
  const client = {
    session: () => ({ id: accountID }),
    async getVault() { return { id: "99999999-9999-4999-8999-999999999999", revision: 0, envelope: null }; },
    async putVault() {
      attempts += 1;
      if (attempts === 1) throw new Error("network_unavailable");
      return { conflict: false, revision: 1 };
    },
  };
  const first = testVault(repository, ["11111111-1111-4111-8111-111111111111"]);
  await assert.rejects(bootstrapPersonalVault({ vault: first, client, passphrase }), /network_unavailable/u);
  first.lock();
  const reloaded = testVault(repository, ["11111111-1111-4111-8111-111111111111"]);
  assert.deepEqual(await bootstrapPersonalVault({ vault: reloaded, client, passphrase }), { status: "uploaded", revision: 1 });
  assert.equal(attempts, 2);
});

test("fresh-account interactive login uses one credential flow, persists trusted unlock, and restores after reload", async () => {
  let credentialUses = 0;
  const password = {
    toString() {
      credentialUses += 1;
      return "account B password is long enough";
    },
  };
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = memoryVaultRepository();
  const vault = testVault(repository, ["11111111-1111-4111-8111-111111111111"]);
  let activeVault = vault;
  let remote = { id: "99999999-9999-4999-8999-999999999999", revision: 0, envelope: null };
  const client = {
    session: () => ({ id: accountID }),
    async getVault() { return structuredClone(remote); },
    async putVault(_scope, envelope) {
      remote = { ...remote, revision: 1, envelope };
      return { conflict: false, revision: 1 };
    },
  };
  const calls = [];

  const result = await completeInteractivePersonalVaultLogin({
    user: { id: accountID },
    password,
    activateAccountVault: async (_user, passphrase) => { calls.push(["activate", passphrase]); },
    unlockAndSyncPersonalVault: async (passphrase) => {
      calls.push(["unlock", passphrase]);
      return bootstrapPersonalVault({ vault: activeVault, client, passphrase });
    },
    rememberSession: async (id) => {
      calls.push(["remember", id]);
      return activeVault.rememberSession(id);
    },
  });

  assert.equal(credentialUses, 1);
  assert.deepEqual(calls.map(([name]) => name), ["activate", "unlock", "remember"]);
  assert.equal(calls[0][1], "selective-remote:account-password:v1:account B password is long enough");
  assert.equal(calls[1][1], calls[0][1]);
  assert.deepEqual(result, { result: { status: "uploaded", revision: 1 }, remembered: true });
  assert.equal(await activeVault.status(), "unlocked");
  assert.ok(repository.rememberedSession());

  activeVault = testVault(repository, ["22222222-2222-4222-8222-222222222222"]);
  assert.equal(await activeVault.restoreRememberedSession(accountID), true);
  assert.equal(await activeVault.status(), "unlocked");
  assert.equal(credentialUses, 1);
});

test("existing-account interactive login unlocks with the same one-time login credential flow", async () => {
  const password = "account B password is long enough";
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const source = testVault(memoryVaultRepository(), ["11111111-1111-4111-8111-111111111111"]);
  const passphrase = accountVaultPassphrase(password);
  await source.create(passphrase);
  const prepared = await source.prepareUpload(4);
  const repository = memoryVaultRepository();
  const target = testVault(repository, ["22222222-2222-4222-8222-222222222222"]);
  const client = {
    session: () => ({ id: accountID }),
    async getVault() { return { id: "99999999-9999-4999-8999-999999999999", revision: 5, envelope: prepared.envelope }; },
    async putVault() { throw new Error("unexpected_empty_vault_upload"); },
  };
  const result = await completeInteractivePersonalVaultLogin({
    user: { id: accountID },
    password,
    activateAccountVault: async () => {},
    unlockAndSyncPersonalVault: (derived) => bootstrapPersonalVault({ vault: target, client, passphrase: derived }),
    rememberSession: (id) => target.rememberSession(id),
  });

  assert.deepEqual(result, { result: { status: "downloaded", revision: 5 }, remembered: true });
  assert.equal(await target.status(), "unlocked");
  assert.ok(repository.rememberedSession());
});

test("interactive login stays unlocked but reports when trusted-browser persistence does not commit", async () => {
  const result = await completeInteractivePersonalVaultLogin({
    user: { id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" },
    password: "account B password is long enough",
    activateAccountVault: async () => {},
    unlockAndSyncPersonalVault: async () => ({ status: "downloaded", revision: 1 }),
    rememberSession: async () => false,
  });
  assert.deepEqual(result, { result: { status: "downloaded", revision: 1 }, remembered: false });

  const rejectedPersistence = await completeInteractivePersonalVaultLogin({
    user: { id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" },
    password: "account B password is long enough",
    activateAccountVault: async () => {},
    unlockAndSyncPersonalVault: async () => ({ status: "downloaded", revision: 1 }),
    rememberSession: async () => { throw new Error("local_vault_storage_failed"); },
  });
  assert.deepEqual(rejectedPersistence, { result: { status: "downloaded", revision: 1 }, remembered: false });
});

test("interactive login does not initialize or sync an unowned legacy local Vault", async () => {
  let synchronizationCalls = 0;
  let rememberCalls = 0;
  await assert.rejects(completeInteractivePersonalVaultLogin({
    user: { id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" },
    password: "synthetic account password",
    activateAccountVault: async () => ({ legacyOwnershipUnverified: true }),
    unlockAndSyncPersonalVault: async () => { synchronizationCalls += 1; },
    rememberSession: async () => { rememberCalls += 1; },
  }), /legacy_vault_owner_unverified/u);
  assert.equal(synchronizationCalls, 0);
  assert.equal(rememberCalls, 0);
});

test("an existing remote Vault is imported instead of being replaced with an empty r1", async () => {
  const passphrase = accountVaultPassphrase("account B password is long enough");
  const source = testVault(memoryVaultRepository(), ["11111111-1111-4111-8111-111111111111"]);
  await source.create(passphrase);
  await source.upsert({ type: "host", data: { title: "Remote", address: "remote.invalid" } });
  const prepared = await source.prepareUpload(4);
  const target = testVault(memoryVaultRepository(), ["22222222-2222-4222-8222-222222222222"]);
  const client = {
    session: () => ({ id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" }),
    async getVault() {
      return { id: "99999999-9999-4999-8999-999999999999", revision: 5, envelope: prepared.envelope };
    },
    async putVault() { throw new Error("unexpected_empty_vault_upload"); },
  };

  const result = await bootstrapPersonalVault({ vault: target, client, passphrase });

  assert.deepEqual(result, { status: "downloaded", revision: 5 });
  assert.equal(target.document().records[0].data.address, "remote.invalid");
});

test("failed local unlock cannot replace an inaccessible encrypted Vault during login", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const oldPassphrase = accountVaultPassphrase("old synthetic account password");
  const newPassphrase = accountVaultPassphrase("new synthetic account password");
  const repository = memoryVaultRepository();
  const local = testVault(repository, ["11111111-1111-4111-8111-111111111111", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]);
  await local.create(oldPassphrase);
  await local.upsert({ type: "host", data: { title: "Offline", address: "offline.invalid" } });
  local.lock();
  const before = await repository.load();

  const remote = testVault(memoryVaultRepository(), ["22222222-2222-4222-8222-222222222222"]);
  await remote.create(newPassphrase);
  const remoteEnvelope = (await remote.prepareUpload(4)).envelope;
  let uploads = 0;
  const client = {
    session: () => ({ id: accountID }),
    async getVault() { return { id: "99999999-9999-4999-8999-999999999999", revision: 5, envelope: remoteEnvelope }; },
    async putVault() { uploads++; throw new Error("unexpected_vault_upload"); },
  };
  await assert.rejects(bootstrapPersonalVault({ vault: local, client, passphrase: newPassphrase }), /local_vault_recovery_required/u);
  assert.deepEqual(await repository.load(), before);
  assert.equal(uploads, 0);
  await local.unlock(oldPassphrase);
  assert.equal(local.document().records[0].data.address, "offline.invalid");
});

test("a new login password does not replace an inaccessible remote Vault on an empty device", async () => {
  const oldPassphrase = accountVaultPassphrase("old synthetic account password");
  const newPassphrase = accountVaultPassphrase("new synthetic account password");
  const remote = testVault(memoryVaultRepository(), ["11111111-1111-4111-8111-111111111111"]);
  await remote.create(oldPassphrase);
  const original = (await remote.prepareUpload(4)).envelope;
  const serverEnvelope = structuredClone(original);
  const repository = memoryVaultRepository();
  const local = testVault(repository, ["22222222-2222-4222-8222-222222222222"]);
  let uploads = 0;
  const client = {
    session: () => ({ id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" }),
    async getVault() { return { id: "99999999-9999-4999-8999-999999999999", revision: 5, envelope: structuredClone(serverEnvelope) }; },
    async putVault() { uploads++; throw new Error("unexpected_vault_upload"); },
  };
  await assert.rejects(bootstrapPersonalVault({ vault: local, client, passphrase: newPassphrase }), /remote_vault_recovery_required/u);
  assert.equal(await repository.load(), null);
  assert.equal(uploads, 0);
  assert.deepEqual(serverEnvelope, original);
});

test("Personal Vault recovery messages distinguish stored local and Cloud copies", async () => {
  const local = application.personalVaultRecoveryMessage("local_vault_recovery_required");
  const remote = application.personalVaultRecoveryMessage("remote_vault_recovery_required");
  assert.equal(application.personalVaultRecoveryMessage("legacy_vault_unlock_failed"), local);
  assert.match(local, /локальный.*копия сохранена/iu);
  assert.match(remote, /Cloud.*не изменён/iu);
  assert.notEqual(local, remote);
  const { runInNewContext } = await import("node:vm");
  const source = await readFile(new URL("../public/i18n.js", import.meta.url), "utf8");
  const browser = { window: {}, document: { addEventListener() {} }, location: { search: "?lang=en" }, URLSearchParams,
    localStorage: { getItem() { return null; } }, navigator: { language: "en" } };
  runInNewContext(source, browser);
  assert.match(browser.window.SelectiveRemoteI18n.t(local), /encrypted copy is preserved/iu);
  assert.match(browser.window.SelectiveRemoteI18n.t(remote), /Cloud.*not been changed/iu);
  const integrity = application.personalVaultRecoveryMessage("remote_same_revision_changed");
  assert.match(integrity, /Cloud.*синхронизация остановлена/iu);
  assert.equal(application.personalVaultRecoveryMessage("vault_content_hash_mismatch"), integrity);
  assert.equal(application.personalVaultRecoveryMessage("vault_decryption_failed"), integrity);
  assert.match(browser.window.SelectiveRemoteI18n.t(integrity), /Cloud.*synchronization has stopped/iu);
});

test("corrupted encrypted local and remote copies are preserved and reported as recovery", async () => {
  const passphrase = accountVaultPassphrase("synthetic account password");
  const repository = memoryVaultRepository();
  const local = testVault(repository, ["11111111-1111-4111-8111-111111111111"]);
  await local.create(passphrase);
  const broken = await repository.load();
  broken.envelope.ciphertext = (broken.envelope.ciphertext[0] === "A" ? "B" : "A") + broken.envelope.ciphertext.slice(1);
  await repository.save(broken);
  local.lock();
  let uploads = 0;
  const client = {
    session: () => ({ id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" }),
    async getVault() { return { id: "99999999-9999-4999-8999-999999999999", revision: 1, envelope: structuredClone(broken.envelope) }; },
    async putVault() { uploads++; throw new Error("unexpected_vault_upload"); },
  };
  await assert.rejects(bootstrapPersonalVault({ vault: local, client, passphrase }), /local_vault_recovery_required/u);
  assert.deepEqual(await repository.load(), broken);

  const emptyRepository = memoryVaultRepository();
  const empty = testVault(emptyRepository, ["22222222-2222-4222-8222-222222222222"]);
  await assert.rejects(bootstrapPersonalVault({ vault: empty, client, passphrase }), /remote_vault_recovery_required/u);
  assert.equal(await emptyRepository.load(), null);
  assert.equal(uploads, 0);
});

test("duplicate record IDs in encrypted copies require recovery without replacing either copy", async () => {
  const passphrase = accountVaultPassphrase("synthetic account password");
  const repository = memoryVaultRepository();
  const local = testVault(repository, ["11111111-1111-4111-8111-111111111111"]);
  await local.create(passphrase);
  await local.upsert({ id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", type: "host", data: { title: "Test", address: "test.invalid" } });
  const broken = await repository.load();
  const payload = local.document();
  payload.records.push(structuredClone(payload.records[0]));
  broken.envelope = await encryptVaultPayload({ vaultKey: local.sessionKey(), payload,
    baseRevision: broken.revision - 1, wrappedKey: broken.envelope.wrappedKey, cryptoValue: webcrypto });
  await repository.save(broken);
  local.lock();
  let uploads = 0;
  const remoteEnvelope = { ...structuredClone(broken.envelope), baseRevision: 0 };
  const client = { session: () => ({ id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" }),
    async getVault() { return { id: "99999999-9999-4999-8999-999999999999", revision: 1, envelope: remoteEnvelope }; },
    async putVault() { uploads++; throw new Error("unexpected_vault_upload"); } };
  await assert.rejects(bootstrapPersonalVault({ vault: local, client, passphrase }), /local_vault_recovery_required/u);
  assert.deepEqual(await repository.load(), broken);
  const emptyRepository = memoryVaultRepository();
  const empty = testVault(emptyRepository, ["22222222-2222-4222-8222-222222222222"]);
  await assert.rejects(bootstrapPersonalVault({ vault: empty, client, passphrase }), /remote_vault_recovery_required/u);
  assert.equal(await emptyRepository.load(), null);
  assert.equal(uploads, 0);
});

test("an invalid newer Cloud document is reported without replacing an unlocked local copy", async () => {
  const passphrase = accountVaultPassphrase("synthetic account password");
  const repository = memoryVaultRepository();
  const local = testVault(repository, ["11111111-1111-4111-8111-111111111111"]);
  await local.create(passphrase);
  await local.upsert({ id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", type: "host", data: { title: "Test", address: "test.invalid" } });
  const initial = await local.prepareUpload(0);
  await local.markSynced({ serverRevision: 1, localRevision: initial.localRevision,
    serverContentHash: initial.envelope.contentHash });
  const before = await repository.load();
  const payload = local.document();
  payload.records.push(structuredClone(payload.records[0]));
  const envelope = await encryptVaultPayload({ vaultKey: local.sessionKey(), payload, baseRevision: 1,
    wrappedKey: initial.envelope.wrappedKey, cryptoValue: webcrypto });
  let uploads = 0;
  const client = { session: () => ({ id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" }),
    async getVault() { return { id: "99999999-9999-4999-8999-999999999999", revision: 2, envelope }; },
    async putVault() { uploads++; throw new Error("unexpected_vault_upload"); } };
  await assert.rejects(bootstrapPersonalVault({ vault: local, client, passphrase }), /remote_vault_recovery_required/u);
  assert.deepEqual(await repository.load(), before);
  assert.equal(uploads, 0);
});

test("unverified Cloud history still exposes the decrypted local copy without uploading", async () => {
  const { runInNewContext } = await import("node:vm");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const passphrase = accountVaultPassphrase("synthetic account password");
  const repository = memoryVaultRepository();
  const local = testVault(repository, ["11111111-1111-4111-8111-111111111111"]);
  await local.create(passphrase);
  const initial = await local.prepareUpload(0);
  await local.markSynced({ serverRevision: 1, localRevision: initial.localRevision });
  await local.upsert({ id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", type: "host", data: { title: "Offline", address: "offline.invalid" } });
  local.lock();
  let uploads = 0;
  const client = { session: () => ({ id: accountID }),
    async getVault() { return { id: "99999999-9999-4999-8999-999999999999", revision: 1, envelope: initial.envelope }; },
    async putVault() { uploads++; throw new Error("unexpected_vault_upload"); } };
  const modes = [], observations = [];
  const context = { vault: local, client, capturePersonalVaultSession, bootstrapPersonalVault,
    synchronizePersonalVault: ({ recoveryPassphrase, targetVault }) => synchronizeVault({ client, vault: targetVault, recoveryPassphrase }),
    vaultUI: { mode: value => modes.push(value), render() {} },
    documentValue: {}, publishSyncObservation: (_document, value) => observations.push(value) };
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf("  async function unlockAndSyncPersonalVault("), end = source.indexOf("\n  async function synchronizePersonalVault(", start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(source.slice(start, end), context);
  const result = await context.unlockAndSyncPersonalVault(passphrase, local);
  assert.equal(result.status, "local_only");
  assert.equal(result.issue, "remote_history_unverified");
  assert.equal(local.document().records[0].data.address, "offline.invalid");
  assert.deepEqual(modes, ["unlocked"]);
  assert.equal(uploads, 0);
});

test("damaged sync metadata does not hide an otherwise readable local Vault", async () => {
  const { runInNewContext } = await import("node:vm");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const passphrase = accountVaultPassphrase("synthetic account password"), repository = memoryVaultRepository();
  const local = testVault(repository, ["11111111-1111-4111-8111-111111111111"]);
  await local.create(passphrase);
  await local.upsert({ id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", type: "host", data: { title: "Offline", address: "offline.invalid" } });
  const initial = await local.prepareUpload(0), before = await repository.load();
  await repository.saveSync({ serverRevision: 1, localRevision: "invalid" });
  local.lock();
  let uploads = 0;
  const client = { session: () => ({ id: accountID }),
    async getVault() { return { id: "99999999-9999-4999-8999-999999999999", revision: 1, envelope: initial.envelope }; },
    async putVault() { uploads++; throw new Error("unexpected_vault_upload"); } };
  const modes = [], context = { vault: local, client, capturePersonalVaultSession, bootstrapPersonalVault,
    synchronizePersonalVault: ({ recoveryPassphrase, targetVault }) => synchronizeVault({ client, vault: targetVault, recoveryPassphrase }),
    vaultUI: { mode: value => modes.push(value), render() {} }, documentValue: {}, publishSyncObservation() {} };
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf("  async function unlockAndSyncPersonalVault("), end = source.indexOf("\n  async function synchronizePersonalVault(", start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(source.slice(start, end), context);
  const result = await context.unlockAndSyncPersonalVault(passphrase, local);
  assert.equal(result.status, "local_only");
  assert.equal(result.issue, "local_sync_recovery_required");
  assert.equal(local.document().records[0].data.address, "offline.invalid");
  assert.deepEqual(await repository.load(), before);
  assert.deepEqual(modes, ["unlocked"]);
  assert.equal(uploads, 0);
});

test("local-only recovery cannot display a Vault after the account session changes", async () => {
  const { runInNewContext } = await import("node:vm");
  const accountA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", accountB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  let account = accountA;
  const client = { session: () => ({ id: account }) };
  const vault = { status: async () => "unlocked" }, modes = [];
  const context = { vault, client, capturePersonalVaultSession,
    bootstrapPersonalVault: async () => { account = accountB; throw new Error("remote_history_unverified"); },
    vaultUI: { mode: value => modes.push(value), render() {} } };
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf("  async function unlockAndSyncPersonalVault("), end = source.indexOf("\n  async function synchronizePersonalVault(", start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(source.slice(start, end), context);
  await assert.rejects(context.unlockAndSyncPersonalVault("synthetic passphrase", vault), /authentication_required/u);
  assert.deepEqual(modes, []);
});

test("local-only login does not establish a remembered browser key", async () => {
  let rememberCalls = 0;
  const outcome = await completeInteractivePersonalVaultLogin({ user: { id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" },
    password: "synthetic account password", activateAccountVault: async () => ({ vault: {} }),
    unlockAndSyncPersonalVault: async () => ({ status: "local_only", issue: "remote_history_unverified" }),
    rememberSession: async () => { rememberCalls++; return true; } });
  assert.equal(outcome.result.status, "local_only");
  assert.equal(outcome.remembered, false);
  assert.equal(rememberCalls, 0);
});

for (const outcome of ["success", "failure"]) for (const replacement of ["account", "epoch", "conflicts"]) {
  test(`an old conflict resolution ${outcome} cannot change a replacement ${replacement} view`, async () => {
    const { runInNewContext } = await import("node:vm");
    const first = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", second = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    let account = first, epoch = "1", enter, release, submit;
    const started = new Promise(resolve => { enter = resolve; }), held = new Promise(resolve => { release = resolve; });
    const client = { session: () => ({ id: account }), publicationIdentity: () => ({ accountID: account,
      deviceID: "11111111-1111-4111-8111-111111111111", sessionEpoch: epoch }) };
    const originalConflict = { revision: 1, ids: ["cccccccc-cccc-4ccc-8ccc-cccccccccccc"] };
    const replacementConflict = { revision: 2, ids: ["dddddddd-dddd-4ddd-8ddd-dddddddddddd"] };
    const events = [], conflictForm = { addEventListener(name, callback) { if (name === "submit") submit = callback; },
      querySelector() { return { value: "local" }; } };
    const syncButton = { disabled: true }, conflictApply = { disabled: false };
    const context = { client, capturePersonalVaultSession, conflictForm, conflictApply, syncButton,
      activeConflicts: originalConflict,
      vault: { async resolveConflicts() { enter(); await held; if (outcome === "failure") throw new Error("stale");
        return { conflictsResolved: 1 }; } },
      hideConflicts() { events.push("hide"); context.activeConflicts = null; },
      vaultUI: { render() { events.push("render"); } }, vaultMessage: {},
      setText() { events.push("message"); }, updateConflictApplyState() {} };
    const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
    const start = source.indexOf('  conflictForm.addEventListener("change", updateConflictApplyState);');
    const end = source.indexOf('\n  setAuthMode("login");', start);
    assert.ok(start >= 0 && end > start);
    runInNewContext(source.slice(start, end), context);
    const pending = submit({ preventDefault() {} });
    await started;
    if (replacement === "account") { account = second; epoch = "2"; context.vault = {}; }
    if (replacement === "epoch") epoch = "2";
    context.activeConflicts = replacementConflict;
    syncButton.disabled = true;
    release();
    await pending;
    assert.equal(context.activeConflicts, replacementConflict);
    assert.equal(syncButton.disabled, true);
    assert.deepEqual(events, []);
  });
}

for (const outcome of ["success", "failure"]) {
  test(`an old Team conflict resolution ${outcome} cannot alter the replacement workspace`, async () => {
    const { runInNewContext } = await import("node:vm");
    let epoch = "1", enter, release, submit;
    const started = new Promise(resolve => { enter = resolve; }), held = new Promise(resolve => { release = resolve; });
    const originalConflict = { revision: 1, ids: ["cccccccc-cccc-4ccc-8ccc-cccccccccccc"] };
    const replacementConflict = { revision: 2, ids: ["dddddddd-dddd-4ddd-8ddd-dddddddddddd"] };
    const events = [], conflictForm = { addEventListener(name, callback) { if (name === "submit") submit = callback; },
      querySelector() { return { value: "local" }; } };
    const context = { conflictForm, conflictApply: {}, rotateButton: {}, activeConflicts: originalConflict,
      controller: { async resolveConflicts() { enter(); await held; if (outcome === "failure") throw new Error("stale"); } },
      captureWorkspaceContext: () => ({ epoch }), workspaceContextCurrent: captured => captured.epoch === epoch,
      clearConflicts() { events.push("clear"); context.activeConflicts = null; },
      renderRecords() { events.push("render"); }, selectedVault: {}, canManage: () => true,
      setText() { events.push("message"); }, workspaceStatus: {} };
    const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
    const start = source.indexOf('  conflictForm.addEventListener("change", () => {');
    const end = source.indexOf("\n  for (const button of smartFilterButtons)", start);
    assert.ok(start >= 0 && end > start);
    runInNewContext(source.slice(start, end), context);
    const pending = submit({ preventDefault() {} });
    await started;
    epoch = "2"; context.controller = {}; context.activeConflicts = replacementConflict;
    release();
    await pending;
    assert.equal(context.activeConflicts, replacementConflict);
    assert.deepEqual(events, []);
  });
}

test("Personal reauthentication deactivates the old Team workspace before changing session", async () => {
  const { runInNewContext } = await import("node:vm");
  let submit;
  const events = [], password = { value: "synthetic password", addEventListener() {} };
  const form = { elements: { password }, querySelector() { return { disabled: false }; },
    addEventListener(name, callback) { if (name === "submit") submit = callback; } };
  const client = { session: () => ({ id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", email: "a@example.invalid" }),
    sessionGeneration: () => "1", deviceID: () => "11111111-1111-4111-8111-111111111111",
    async login() { events.push("login"); throw new Error("synthetic_failure"); } };
  const context = { vaultReauthenticateForm: form, client, reauthenticationAttempt: 0, reauthenticationInputRevision: 0,
    teamDeviceRepository: {}, ensureTeamDeviceIdentity: async () => null,
    teamWorkspace: { deactivate() { events.push("deactivate"); } }, vaultUI: { mode() {} }, vaultMessage: {},
    setText() {}, vaultStorageCompatibilityMessage: () => null, personalVaultRecoveryMessage: () => null,
    personalVaultOwnershipError: () => false, sessionRetiredByError: () => false };
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf('  vaultReauthenticateForm?.addEventListener("submit", async (event) => {');
  const end = source.indexOf('\n  logoutButton.addEventListener', start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(source.slice(start, end), context);
  await submit({ preventDefault() {} });
  assert.deepEqual(events.slice(0, 2), ["deactivate", "login"]);
});

test("a corrupt Team Cloud revision during rotation produces the integrity warning", async () => {
  const { runInNewContext } = await import("node:vm");
  let click;
  const messages = [], context = { controller: {}, selectedVault: { id: "vault", rotationRequired: true },
    selectedTeam: { id: "team", role: "owner" }, canManage: () => true, vaultOperation: null,
    captureWorkspaceContext: () => ({ generation: "1" }), workspaceContextCurrent: () => true,
    teamVaultLockEpoch: 1, teamSyncTargetMatches: () => true, requestConfirmation: async () => true,
    stopBackgroundSync() {}, startBackgroundSync() {}, setRecoveryControls() {}, setWorkspaceControls() {},
    rotateButton: { hidden: false, addEventListener(_event, handler) { click = handler; } }, lockButton: {},
    client: {}, rotateTeamVault: async () => { throw new Error("team_vault_content_hash_mismatch"); },
    sessionRetiredByError: () => false, workspaceStatus: {}, setText(_element, value) { messages.push(value); },
    teamVaultSynchronizationErrorMessage: application.teamVaultSynchronizationErrorMessage, activeConflicts: null };
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf('  rotateButton.addEventListener("click", async () => {');
  const end = source.indexOf('\n  grantWrappersButton.addEventListener', start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(source.slice(start, end), context);
  await click();
  assert.equal(messages.at(-1), application.teamVaultSynchronizationErrorMessage("team_vault_content_hash_mismatch"));
});

test("loss of Team access during rotation clears the displayed Vault", async () => {
  const { runInNewContext } = await import("node:vm");
  let click, locks = 0, lockOptions;
  const context = { controller: {}, selectedVault: { id: "vault", rotationRequired: true },
    selectedTeam: { id: "team", role: "owner" }, canManage: () => true, vaultOperation: null,
    captureWorkspaceContext: () => ({ generation: "1" }), workspaceContextCurrent: () => true,
    teamVaultLockEpoch: 1, teamSyncTargetMatches: () => true, requestConfirmation: async () => true,
    stopBackgroundSync() {}, startBackgroundSync() {}, setRecoveryControls() {}, setWorkspaceControls() {},
    rotateButton: { hidden: false, addEventListener(_event, handler) { click = handler; } }, lockButton: {},
    client: {}, rotateTeamVault: async () => { throw new Error("team_vault_key_unavailable"); },
    sessionRetiredByError: () => false, workspaceStatus: {}, message: {}, setText() {},
    lockCurrentVault(options) { locks++; lockOptions = options; context.teamVaultLockEpoch++; },
    teamVaultSynchronizationErrorMessage: application.teamVaultSynchronizationErrorMessage, activeConflicts: null };
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf('  rotateButton.addEventListener("click", async () => {');
  const end = source.indexOf('\n  grantWrappersButton.addEventListener', start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(source.slice(start, end), context);
  await click();
  assert.equal(locks, 1);
  assert.equal(lockOptions?.preserveUnsavedEditor, true);
});

for (const preserveUnsavedEditor of [true, false]) {
  test(`locking Team Vault ${preserveUnsavedEditor ? 'preserves an open draft for copying' : 'normally clears the editor'}`, async () => {
    const { runInNewContext } = await import('node:vm');
    let value = 'synthetic unsaved edit', controllerLocks = 0, recordClears = 0, alerts = 0;
    const submit = { disabled: false }, cancel = { disabled: false }, input = { disabled: false };
    const workspace = { hidden: false, dataset: {} };
    const context = { teamVaultLockEpoch: 1, teamVaultManuallyLocked: false, inviteOperationGeneration: 1,
      inviteForm: { querySelector: () => null }, recordSavePending: false, recordSaveOperation: null,
      recordForm: { querySelector: () => submit, querySelectorAll: () => [input] },
      recordCancel: cancel, lockTransientTeamControllers() {}, stopBackgroundSync() {},
      vaultOperation: null, resetRecordEditor() { value = ''; }, resetSnippetBrowser() {}, publicationSelection: 0,
      publicationClient: null, publicationAccessDriver: null, publicationAccessTeamID: null,
      publishSyncObservation() {}, documentValue: {}, selectedVault: { id: 'synthetic' },
      client: { session: () => ({ id: 'synthetic' }) }, controller: { lock() { controllerLocks++; } },
      workspace, recordEditor: { open: true }, recordCreate: {}, lockButton: {}, rotateButton: {},
      setRecoveryControls() {}, records: { replaceChildren() { recordClears++; } },
      clearConflicts() { submit.disabled = false; input.disabled = true; cancel.disabled = true; }, workspaceStatus: {},
      showTeamVaultRecordSaveError({ error }) { assert.equal(error.message, 'team_vault_access_lost_draft'); alerts++; } };
    const source = await readFile(new URL('../public/app.js', import.meta.url), 'utf8');
    const start = source.indexOf('  function lockCurrentVault('), end = source.indexOf('\n  function setView(', start);
    assert.ok(start >= 0 && end > start);
    runInNewContext(source.slice(start, end), context);
    context.lockCurrentVault({ preserveUnsavedEditor });
    assert.equal(controllerLocks, 1);
    assert.equal(recordClears, 1);
    assert.equal(context.controller, null);
    assert.equal(value, preserveUnsavedEditor ? 'synthetic unsaved edit' : '');
    assert.equal(workspace.hidden, !preserveUnsavedEditor);
    assert.equal(workspace.dataset.draftRecovery, preserveUnsavedEditor ? 'true' : undefined);
    assert.equal(submit.disabled, preserveUnsavedEditor);
    if (preserveUnsavedEditor) {
      assert.equal(input.disabled, false);
      assert.equal(cancel.disabled, false);
    }
    assert.equal(alerts, preserveUnsavedEditor ? 1 : 0);
  });
}

test('closing a recovery-only Team draft clears its form and hides the workspace', async () => {
  const { runInNewContext } = await import('node:vm');
  let close, resets = 0;
  const workspace = { hidden: false, dataset: { draftRecovery: 'true' } };
  const context = { workspace, recordEditor: { addEventListener(name, handler) { if (name === 'close') close = handler; } },
    resetRecordEditor() { resets++; } };
  const source = await readFile(new URL('../public/app.js', import.meta.url), 'utf8');
  const start = source.indexOf('  recordEditor?.addEventListener("close", () => {');
  const end = source.indexOf('\n  syncButton.addEventListener', start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(source.slice(start, end), context);
  close();
  assert.equal(resets, 1);
  assert.equal(workspace.hidden, true);
  assert.equal(workspace.dataset.draftRecovery, undefined);
  close();
  assert.equal(resets, 1);
});

for (const status of [404, 503]) {
  test(`Team format check ${status} ${status === 404 ? "clears revoked access" : "does not discard local data on a temporary error"}`, async () => {
    const { runInNewContext } = await import("node:vm");
    let locks = 0, lockOptions;
    const controller = {}, team = { id: "team" }, vault = { id: "vault" };
    const error = Object.assign(new Error(status === 404 ? "team_not_found" : "access_request_failed"), { status });
    const context = { controller, selectedTeam: team, selectedVault: vault, teamVaultManuallyLocked: false,
      publicationClient: null, captureWorkspaceContext: () => ({ generation: "1" }), teamVaultLockEpoch: 1,
      workspaceContextCurrent: () => true, teamSyncTargetMatches: () => true,
      resolveTeamVaultFormat: async () => { throw error; }, client: {}, sessionRetiredByError: () => false,
      isPublicationAccessLoss: value => value.message === "team_not_found",
      lockCurrentVault(options) { locks++; lockOptions = options; }, setText() {}, message: {} };
    const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
    const start = source.indexOf("  async function synchronizeAndProvision("), end = source.indexOf("\n  function applySynchronizationOutcome", start);
    assert.ok(start >= 0 && end > start);
    runInNewContext(source.slice(start, end), context);
    if (status === 404) assert.equal(await context.synchronizeAndProvision(), null);
    else await assert.rejects(context.synchronizeAndProvision(), /access_request_failed/u);
    assert.equal(locks, status === 404 ? 1 : 0);
    assert.equal(lockOptions?.preserveUnsavedEditor, status === 404 ? true : undefined);
  });
}

for (const code of ["team_vault_key_unavailable", "team_vault_membership_changed", "team_vault_history_unverified", "team_vault_download_failed"]) {
  test(`Team sync ${code} ${code === "team_vault_download_failed" ? "keeps the existing view" : "clears an already displayed Vault"}`, async () => {
    const { runInNewContext } = await import("node:vm");
    let locks = 0;
    const controller = {}, team = { id: "team" }, vault = { id: "vault" };
    const context = { controller, selectedTeam: team, selectedVault: vault, teamVaultManuallyLocked: false,
      publicationClient: null, captureWorkspaceContext: () => ({ generation: "1", accountID: "a" }),
      teamVaultLockEpoch: 1, workspaceContextCurrent: () => true, teamSyncTargetMatches: () => true,
      resolveTeamVaultFormat: async () => "V1_ACTIVE", client: {}, sessionRetiredByError: () => false,
      isPublicationAccessLoss: () => false, publishSyncObservation() {}, documentValue: {},
      exclusiveVaultOperation: callback => callback(), synchronizeTeamVault: async () => { throw new Error(code); },
      lockCurrentVault() { locks++; }, setText() {}, message: {} };
    const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
    const start = source.indexOf("  async function synchronizeAndProvision("), end = source.indexOf("\n  function applySynchronizationOutcome", start);
    assert.ok(start >= 0 && end > start);
    runInNewContext(source.slice(start, end), context);
    if (code === "team_vault_download_failed") await assert.rejects(context.synchronizeAndProvision(), /team_vault_download_failed/u);
    else assert.equal(await context.synchronizeAndProvision(), null);
    assert.equal(locks, code === "team_vault_download_failed" ? 0 : 1);
  });
}

test("corrupt local metadata while unlocked is not misreported as Cloud corruption", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const passphrase = accountVaultPassphrase("synthetic account password");
  const indexedDB = new IDBFactory();
  const repository = createIndexedDBVaultRepository(indexedDB).forAccount(accountID);
  const local = testVault(repository, ["11111111-1111-4111-8111-111111111111"]);
  await local.create(passphrase);
  const initial = await local.prepareUpload(0);
  await local.markSynced({ serverRevision: 1, localRevision: initial.localRevision,
    serverContentHash: initial.envelope.contentHash });
  const request = indexedDB.open("selective-remote-cloud");
  const database = await new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
  });
  await new Promise((resolve, reject) => {
    const transaction = database.transaction("local-vault", "readwrite"), store = transaction.objectStore("local-vault");
    const key = `personal-account:v1:${accountID}:snapshot`, current = store.get(key);
    current.onsuccess = () => store.put({ ...current.result, revision: 0 }, key);
    transaction.oncomplete = resolve; transaction.onabort = () => reject(transaction.error);
  });
  database.close();
  let uploads = 0;
  const client = { session: () => ({ id: accountID }),
    async getVault() { return { id: "99999999-9999-4999-8999-999999999999", revision: 1, envelope: initial.envelope }; },
    async putVault() { uploads++; throw new Error("unexpected_vault_upload"); } };
  await assert.rejects(bootstrapPersonalVault({ vault: local, client, passphrase }), /local_vault_recovery_required/u);
  assert.equal(uploads, 0);
  assert.equal(local.document().records.length, 0);
});

for (const phase of ["unlock", "synchronize"]) {
  test(`a stale ${phase} error does not present recovery for a newer session`, async () => {
    const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
    const deviceID = "11111111-1111-4111-8111-111111111111";
    let epoch = "1", entered, release;
    const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
    const client = { session: () => ({ id: accountID }), publicationIdentity: () => ({ accountID, deviceID, sessionEpoch: epoch }) };
    const failure = async () => { entered(); await held; throw new Error("vault_content_hash_mismatch"); };
    const vault = { status: async () => phase === "unlock" ? "locked" : "empty", unlock: failure };
    const pending = bootstrapPersonalVault({ vault, client, passphrase: "synthetic passphrase", synchronize: failure });
    await started;
    epoch = "2";
    release();
    await assert.rejects(pending, error => error?.message === "authentication_required");
  });
}

test("bootstrap preserves the error that retired its current authenticated session", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const deviceID = "11111111-1111-4111-8111-111111111111";
  let epoch = 1, signedIn = true;
  const client = { session: () => signedIn ? { id: accountID } : null, sessionGeneration: () => String(epoch),
    publicationIdentity: () => signedIn ? { accountID, deviceID, sessionEpoch: String(epoch) } : null };
  const retired = Object.assign(new Error("authentication_required"), { invalidatedSessionEpoch: "1", retiredAuthenticatedSession: true });
  const synchronize = async () => { signedIn = false; epoch++; throw retired; };
  await assert.rejects(bootstrapPersonalVault({ vault: { status: async () => "empty" }, client,
    passphrase: "synthetic passphrase", synchronize }), error => error === retired);
});

test("locked Personal Vault copy does not promise key recovery after a password reset", async () => {
  const presentation = personalVaultStatePresentation("reauthentication_required");
  assert.match(presentation.description, /После сброса пароля доступ к данным может не восстановиться/u);
  const [application, i18n] = await Promise.all([
    readFile(new URL("../public/app.js", import.meta.url), "utf8"),
    readFile(new URL("../public/i18n.js", import.meta.url), "utf8"),
  ]);
  assert.match(application, /Сброс пароля не восстанавливает ключи/u);
  assert.match(i18n, /After a password reset, access to your data may not be restored/u);
  assert.match(i18n, /Resetting your password does not recover keys/u);
});

test("Personal Vault state copy distinguishes authentication from encryption in RU and EN", async () => {
  const [html, i18n] = await Promise.all([
    readFile(new URL("../public/index.html", import.meta.url), "utf8"),
    readFile(new URL("../public/i18n.js", import.meta.url), "utf8"),
  ]);
  assert.match(html, /id="local-vault-state-title"/u);
  assert.match(html, /id="local-vault-reauthenticate-form"/u);
  assert.match(html, /Подтвердить пароль и создать Vault/u);
  assert.deepEqual(personalVaultStatePresentation("uninitialized"), {
    title: "Personal Vault ещё не создан для этого аккаунта",
    description: "Подтвердите пароль аккаунта, чтобы создать первый зашифрованный Vault.",
    action: "Подтвердить пароль и создать Vault",
  });
  assert.deepEqual(personalVaultStatePresentation("reauthentication_required"), {
    title: "Требуется восстановление доступа к Personal Vault",
    description: "Сессия аккаунта активна, но ключ Personal Vault недоступен. Попробуйте подтвердить пароль или открыть другую вкладку, где Vault уже открыт. После сброса пароля доступ к данным может не восстановиться.",
    action: "Восстановить доступ",
  });
  assert.equal(personalVaultStatePresentation("unlocked"), null);
  assert.match(i18n, /Personal Vault has not been created for this account yet/u);
  assert.match(i18n, /Confirm password and create Vault/u);
  assert.match(i18n, /Confirm password and open Vault/u);
  assert.match(i18n, /Restore access to Personal Vault/u);
  assert.match(i18n, /the trusted-browser key could not be saved/u);
  assert.match(i18n, /Restoring Personal Vault/u);
  assert.match(i18n, /Personal Vault is temporarily unavailable/u);
});

test("browser password change rewraps Personal Vault before changing the authentication password", {
  todo: "password change rewrap is an approved follow-up outside this PR",
}, async () => {
  const application = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const handler = application.match(/passwordForm\.addEventListener\("submit"[\s\S]*?deleteAccountForm\.addEventListener/u)?.[0] ?? "";
  assert.match(handler, /vault\.rewrap/u);
});

test("account password is domain-separated before it unlocks Personal Vault", () => {
  assert.equal(
    accountVaultPassphrase("correct horse battery"),
    "selective-remote:account-password:v1:correct horse battery",
  );
  assert.throws(() => accountVaultPassphrase("too-short"), /invalid_account_password/u);
  assert.equal(
    accountVaultPassphrase("mot-de-passe-café"),
    accountVaultPassphrase("mot-de-passe-cafe\u0301"),
  );
});

test("appearance persists the selected theme and restores it after a full reload", () => {
  const listeners = [];
  const controls = [{ value: "" }, { value: "" }].map((control) => ({
    ...control,
    addEventListener(_name, listener) { listeners.push([this, listener]); },
  }));
  const documentValue = {
    cookie: "sr_theme=light",
    documentElement: { dataset: {} },
    querySelectorAll: () => controls,
  };
  const appearance = initializeAppearance({ documentValue });
  assert.equal(appearance.theme(), "light");
  assert.equal(documentValue.documentElement.dataset.theme, "light");
  assert.deepEqual(controls.map(({ value }) => value), ["light", "light"]);
  controls[1].value = "emerald";
  listeners[1][1]();
  assert.equal(appearance.theme(), "emerald");
  assert.deepEqual(controls.map(({ value }) => value), ["emerald", "emerald"]);
  assert.match(documentValue.cookie, /^sr_theme=emerald; Max-Age=31536000; Path=\/; SameSite=Lax$/u);
  appearance.apply("unknown");
  assert.equal(appearance.theme(), "graphite");
  assert.equal(appearancePreference("unrelated=1; sr_theme=light; another=2"), "light");
  assert.equal(appearancePreference("sr_theme=unknown"), "graphite");
});

test("command palette does not summon the software keyboard on touch-sized screens", () => {
  assert.equal(shouldFocusCommandPaletteSearch({ coarsePointer: true, viewportWidth: 390 }), false);
  assert.equal(shouldFocusCommandPaletteSearch({ coarsePointer: false, viewportWidth: 390 }), false);
  assert.equal(shouldFocusCommandPaletteSearch({ coarsePointer: false, viewportWidth: 1440 }), true);
  assert.equal(shouldFocusCommandPaletteSearch({ fromKeyboard: true, coarsePointer: true, viewportWidth: 390 }), true);
});

test("portal bootstrap reveals the resolved view and retires its loading screen", () => {
  const removed = [];
  const bootScreen = { hidden: false };
  finishPortalBootstrap({
    documentValue: {
      documentElement: { classList: { remove: (...names) => removed.push(...names) } },
      querySelector: (selector) => selector === "#app-boot-screen" ? bootScreen : null,
    },
  });
  assert.deepEqual(removed, ["app-booting"]);
  assert.equal(bootScreen.hidden, true);
});

test("hero preview opens cinematic product scenes and returns to its overview", () => {
  const makeElement = (dataset = {}) => {
    const classes = new Set();
    const listeners = new Map();
    return {
      dataset,
      hidden: false,
      attributes: new Map(),
      classList: {
        add: (...values) => values.forEach((value) => classes.add(value)),
        remove: (...values) => values.forEach((value) => classes.delete(value)),
        toggle: (value, force) => force ? classes.add(value) : classes.delete(value),
        contains: (value) => classes.has(value),
      },
      addEventListener: (name, listener) => listeners.set(name, listener),
      setAttribute(name, value) { this.attributes.set(name, value); },
      focus() { this.focused = true; },
      listeners,
    };
  };
  const scenes = ["hosts", "credentials", "snippets", "devices"];
  const overviewButtons = scenes.map((scene) => makeElement({ heroPreviewScene: scene }));
  const stageButtons = scenes.map((scene) => makeElement({ heroPreviewScene: scene }));
  const scopeButtons = ["personal", "team"].map((scope) => makeElement({ heroPreviewScope: scope }));
  const scopeLabels = scenes.map(() => makeElement());
  const panels = scenes.map((scene) => makeElement({ previewScenePanel: scene }));
  const sidebarItems = scenes.map(() => makeElement());
  const preview = makeElement();
  preview.querySelectorAll = () => sidebarItems;
  const overview = makeElement();
  const stage = makeElement();
  stage.hidden = true;
  const back = makeElement();
  const overviewTabs = makeElement();
  overviewTabs.querySelectorAll = () => overviewButtons;
  const stageTabs = makeElement();
  stageTabs.querySelectorAll = () => stageButtons;
  const documentValue = {
    activeElement: null,
    querySelector: (selector) => ({
      "#cloud-hero-preview": preview,
      "#hero-preview-overview": overview,
      "#hero-preview-stage": stage,
      "[data-hero-preview-back]": back,
      '[data-hero-preview-scene="hosts"]': overviewButtons[0],
    })[selector] ?? null,
    querySelectorAll: (selector) => ({
      "[data-hero-preview-scene]": [...overviewButtons, ...stageButtons],
      "[data-hero-preview-scope]": scopeButtons,
      "[data-preview-scope-label]": scopeLabels,
      "[data-preview-scene-panel]": panels,
      ".hero-preview-grid, .preview-scene-tabs": [overviewTabs, stageTabs],
    })[selector] ?? [],
  };
  const controller = initializeHeroPreview({ documentValue });
  overviewButtons[1].listeners.get("click")();
  assert.equal(controller.scene(), "credentials");
  assert.equal(preview.dataset.scene, "credentials");
  assert.equal(preview.classList.contains("preview-scene-active"), true);
  assert.equal(overview.hidden, true);
  assert.equal(stage.hidden, false);
  assert.deepEqual(panels.map(({ hidden }) => hidden), [true, false, true, true]);
  assert.equal(stageButtons[1].attributes.get("aria-selected"), "true");
  scopeButtons[1].listeners.get("click")();
  assert.equal(controller.scope(), "team");
  assert.equal(preview.dataset.scope, "team");
  assert.deepEqual(scopeLabels.map(({ textContent }) => textContent), scenes.map(() => "Team Vault"));
  back.listeners.get("click")();
  assert.equal(controller.scene(), null);
  assert.equal(overview.hidden, false);
  assert.equal(stage.hidden, true);
  assert.equal(overviewButtons[0].focused, true);
});

test("Vault form values map to the four versioned record types", () => {
  assert.deepEqual(
    localVaultRecordData("host", { title: " Production ", target: "host.invalid", secret: "" }),
    { title: "Production", address: "host.invalid" },
  );
  assert.deepEqual(
    localVaultRecordData("credential", { title: "Admin", target: "root", secret: "synthetic-secret" }),
    { title: "Admin", username: "root", secret: "synthetic-secret" },
  );
  assert.deepEqual(
    localVaultRecordData("snippet", { title: "Status", target: "", secret: "uptime" }),
    { title: "Status", body: "uptime" },
  );
  assert.deepEqual(
    localVaultRecordData("forwarding", { title: "Database", target: "db.invalid:5432", secret: "local 15432" }),
    { title: "Database", destination: "db.invalid:5432", configuration: "local 15432" },
  );
});

test("Vault form mapping rejects incomplete and oversized records", () => {
  assert.throws(
    () => localVaultRecordData("credential", { title: "Admin", target: "root", secret: "" }),
    /invalid_local_record/,
  );
  assert.throws(
    () => localVaultRecordData("unknown", { title: "Unknown", target: "value", secret: "value" }),
    /invalid_local_record/,
  );
  assert.throws(
    () => localVaultRecordData("host", { title: "x".repeat(121), target: "host.invalid", secret: "" }),
    /invalid_local_record/,
  );
});

test("Personal Vault editor preserves native fields and maps decrypted form values", () => {
  const base = { title: "Old", address: "old.invalid", folder: "Work", profile: "opaque" };
  assert.deepEqual(
    localVaultRecordData("host", { title: "New", target: "new.invalid", secret: "" }, base),
    { title: "New", address: "new.invalid", folder: "Work", profile: "opaque" },
  );
  assert.deepEqual(localVaultRecordFormValues({
    type: "forwarding",
    data: { title: "DB", destination: "db.invalid:5432", configuration: "local 15432" },
  }), { title: "DB", target: "db.invalid:5432", secret: "local 15432" });
  assert.deepEqual(
    localVaultRecordData(
      "credential",
      { title: "Deploy", target: "root", secret: "new-secret" },
      { title: "Old", username: "old", secret: "old-secret", folder: "Production", tags: ["linux"] },
    ),
    { title: "Deploy", username: "root", secret: "new-secret", folder: "Production", tags: ["linux"] },
  );
});

test("Personal Host editor updates organization and the embedded native profile together", () => {
  const profile = {
    id: "44444444-4444-4444-8444-444444444444", connectionType: "ssh",
    friendlyName: "Old", host: "old.invalid", username: "root", sshPort: 22,
    group: "Old", tags: ["legacy"], profileDescription: "Old description",
    sshProxyMode: "none",
  };
  const encoded = Buffer.from(JSON.stringify(profile)).toString("base64url");
  const baseData = { title: "Old", address: "old.invalid", connectionType: "ssh", profile: encoded };
  const data = personalHostRecordData({
    title: "Production", address: "prod.invalid", protocol: "ssh", port: "2222",
    username: "deployer", folder: "Work/Production", tags: "linux, prod, linux",
    description: "Primary endpoint", baseData,
  });
  const decoded = JSON.parse(Buffer.from(data.profile, "base64url").toString());
  assert.deepEqual(personalHostEditorValues({ type: "host", data }), {
    title: "Production", address: "prod.invalid", protocol: "ssh", port: 2222,
    username: "deployer", folder: "Work/Production", tags: "linux, prod",
    description: "Primary endpoint",
  });
  assert.equal(decoded.friendlyName, "Production");
  assert.equal(decoded.host, "prod.invalid");
  assert.equal(decoded.sshPort, 2222);
  assert.equal(decoded.group, "Work/Production");
  assert.equal(decoded.sshProxyMode, "none");
  assert.equal(personalHostFolderName({ type: "host", data: baseData }), "Old");
  assert.equal(personalHostFolderName({ type: "host", data: { title: "Ungrouped" } }), "Без папки");
});

test("Vault timestamps render in the viewer time zone instead of raw UTC", () => {
  const rendered = formatVaultTimestamp("2026-09-11T12:58:29.596Z", {
    locales: "ru-RU", timeZone: "Europe/Moscow",
  });
  assert.match(rendered, /15:58:29/u);
  assert.equal(formatVaultTimestamp("invalid", { locales: "ru-RU" }), "—");
  assert.match(formatVaultSynchronizationSummary(23, "2026-09-11T15:17:30.000Z", {
    locales: "ru-RU", timeZone: "Europe/Moscow",
  }), /Последняя синхронизация:.*18:17:30.*r23/u);
  assert.equal(formatVaultSynchronizationSummary(-1), "Последняя синхронизация: —");
});

test("RU and EN synchronization metadata use the active locale", () => {
  const at = "2026-09-11T15:17:30.000Z";
  assert.match(formatVaultSynchronizationSummary(23, at, { locale: "ru", timeZone: "UTC" }), /^Последняя синхронизация:/u);
  assert.match(formatVaultSynchronizationSummary(23, at, { locale: "en", timeZone: "UTC" }), /^Last synchronized:/u);
  assert.equal(formatVaultSynchronizationSummary(-1, at, { locale: "en" }), "Last synchronized: —");
});

test("a rendered synchronization timestamp switches locale without a new sync", () => {
  let summary = null;
  const documentValue = { documentElement: { lang: "ru" }, createElement: () => ({ dataset: {}, textContent: "" }) };
  const message = {
    textContent: "",
    append(_separator, node) { summary = node; },
    querySelector(selector) { return selector === "[data-vault-sync-summary]" ? summary : null; },
  };
  setVaultSynchronizationMessage(message, {
    documentValue, message: "Готово.", revision: 7, at: "2026-09-11T15:17:30.000Z", timeZone: "UTC",
  });
  assert.match(summary.textContent, /^Последняя синхронизация:/u);
  documentValue.documentElement.lang = "en";
  assert.equal(refreshVaultSynchronizationMessage(message, { locale: "en", timeZone: "UTC" }), true);
  assert.match(summary.textContent, /^Last synchronized: Sep/u);
});

test("record editor visibility hides the complete secret row for Hosts", () => {
  assert.deepEqual(recordFormFieldVisibility("host"), {
    target: true, secret: false, hostFields: true, snippetFolder: false,
  });
  assert.deepEqual(recordFormFieldVisibility("credential"), {
    target: true, secret: true, hostFields: false, snippetFolder: false,
  });
  assert.deepEqual(recordFormFieldVisibility("snippet"), {
    target: false, secret: true, hostFields: false, snippetFolder: true,
  });
});

test("Personal record edit populates its layout before the dialog becomes visible", async () => {
  const application = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = application.indexOf("function beginEdit(record)");
  const end = application.indexOf("function clearConflictUI()", start);
  const beginEdit = application.slice(start, end);

  assert.ok(start >= 0 && end > start);
  assert.ok(beginEdit.indexOf("updateLabels();") < beginEdit.indexOf("editorDialog?.showModal?.();"));
});

test("Quick Search has stable routes and bilingual aliases", () => {
  const commands = workspaceCommands("en");
  assert.equal(commands.find(({ id }) => id === "overview")?.route, "/app");
  assert.equal(commands.find(({ id }) => id === "devices")?.route, "/app/devices");
  assert.equal(filterWorkspaceCommands("Overview", "en")[0]?.id, "overview");
  assert.equal(filterWorkspaceCommands("Обзор", "en")[0]?.id, "overview");
  assert.equal(filterWorkspaceCommands("Devices", "ru")[0]?.id, "devices");
  assert.equal(filterWorkspaceCommands("Устройства", "ru")[0]?.id, "devices");
});

test("Quick Search labels follow RU and EN without changing command IDs", () => {
  const ru = workspaceCommands("ru");
  const en = workspaceCommands("en");
  assert.deepEqual(ru.map(({ id }) => id), en.map(({ id }) => id));
  assert.equal(ru.find(({ id }) => id === "teams")?.label, "Команды");
  assert.equal(en.find(({ id }) => id === "teams")?.label, "Teams");
});

test("record forms use explicit rows for Personal and Team create/edit fields", async () => {
  const html = await readFile(new URL("../public/index.html", import.meta.url), "utf8");
  for (const formID of ["local-vault-record-form", "team-vault-record-form"]) {
    const form = html.slice(html.indexOf(`id="${formID}"`), html.indexOf("</form>", html.indexOf(`id="${formID}"`)));
    assert.match(form, /class="record-field-row"/u);
    assert.match(form, /data-record-field="secret"/u);
    assert.match(form, /class="record-control-stack"/u);
  }
});

test("mobile More exposes all secondary destinations and preferences", async () => {
  const html = await readFile(new URL("../public/index.html", import.meta.url), "utf8");
  const dialog = html.slice(html.indexOf('id="workspace-mobile-account"'), html.indexOf("</dialog>", html.indexOf('id="workspace-mobile-account"')));
  assert.match(html, /id="workspace-mobile-account-open"[\s\S]*>Ещё</u);
  for (const target of ["workspace-devices", "workspace-settings", "workspace-about"]) {
    assert.match(dialog, new RegExp(`data-workspace-target="${target}"`, "u"));
  }
  assert.match(dialog, /data-locale-switch="mobile-account"/u);
  assert.match(dialog, /data-theme-select/u);
  assert.match(dialog, /id="workspace-mobile-logout"/u);
});

test("Light theme covers Devices cards and fixed mobile navigation", async () => {
  const styles = await readFile(new URL("../public/styles.css", import.meta.url), "utf8");
  assert.match(styles, /:root\[data-theme="light"\] \.device-vault-map \.team-devices article/u);
  assert.match(styles, /:root\[data-theme="light"\] \.workspace-mobile-nav/u);
});

test("Teams terminology and selector placeholder are consistent in English", async () => {
  const html = await readFile(new URL("../public/index.html", import.meta.url), "utf8");
  const i18n = await readFile(new URL("../public/i18n.js", import.meta.url), "utf8");
  assert.match(i18n, /"Команды": "Teams"/u);
  assert.match(i18n, /"Выберите команду": "Select a team"/u);
  assert.match(html, /<strong>Snippets<\/strong><small>Команды и скрипты<\/small>/u);
  assert.match(i18n, /"Команды и скрипты": "Commands and scripts"/u);
});

test("dialog navigation controls retain semantic buttons and accessible names", async () => {
  const html = await readFile(new URL("../public/index.html", import.meta.url), "utf8");
  assert.match(html, /<dialog class="mobile-account-dialog"[^>]*aria-labelledby="workspace-mobile-account-title"/u);
  assert.match(html, /data-workspace-target="workspace-devices"[^>]*>[^<]*<span[^>]*aria-hidden="true"/u);
  assert.match(html, /id="workspace-mobile-logout"/u);
});

test("Personal Vault catalog sorting is deterministic and does not mutate the document", () => {
  const records = [
    { id: "b", type: "host", modifiedAt: "2026-09-10T00:00:00Z", data: { title: "Beta" } },
    { id: "a", type: "credential", modifiedAt: "2026-09-11T00:00:00Z", data: { title: "Alpha" } },
  ];
  assert.deepEqual(sortLocalVaultRecords(records).map(({ id }) => id), ["a", "b"]);
  assert.deepEqual(sortLocalVaultRecords(records, "title-asc").map(({ id }) => id), ["a", "b"]);
  assert.deepEqual(records.map(({ id }) => id), ["b", "a"]);
});

test("Team Host organization stays inside the encrypted record", () => {
  assert.deepEqual(teamHostRecordData({
    title: " API ", target: "api.invalid", folder: " Production ",
    tags: "linux, api, linux", description: " Primary endpoint ",
  }), {
    title: "API", address: "api.invalid", folder: "Production",
    tags: ["linux", "api"], description: "Primary endpoint",
  });
  assert.throws(() => teamHostRecordData({
    title: "API", target: "api.invalid", folder: "x".repeat(121), tags: "", description: "",
  }), /invalid_team_host_organization/u);
  const advanced = {
    title: "Mac", address: "rdp.invalid", username: "operator",
    connectionType: "rdp", profile: "opaque-encrypted-profile",
  };
  assert.deepEqual(teamHostRecordData({
    title: "Mac", target: "rdp.invalid", folder: "Support",
    tags: "windows", description: "Shared desktop", baseData: advanced,
  }), { ...advanced, folder: "Support", tags: ["windows"], description: "Shared desktop" });
  assert.throws(() => teamHostRecordData({
    title: "Changed", target: "rdp.invalid", folder: "", tags: "", description: "", baseData: advanced,
  }), /advanced_team_host_requires_native_editor/u);
  const nativeProfile = Buffer.from(JSON.stringify({
    group: "ssh", tags: ["legacy"], profileDescription: "Created on macOS",
  })).toString("base64url");
  assert.deepEqual(teamHostOrganizationValues({ data: { profile: nativeProfile } }), {
    folder: "ssh", tags: ["legacy"], description: "Created on macOS",
  });
  assert.deepEqual(teamHostOrganizationValues({ data: {
    profile: nativeProfile, folder: "Browser", tags: ["new"], description: "Edited in browser",
  } }), { folder: "Browser", tags: ["new"], description: "Edited in browser" });
});

test("Team Host connection fields produce password-free interoperable URLs", () => {
  assert.deepEqual(teamHostConnectionData({
    protocol: "ssh", host: "bastion.example.invalid", port: "2222", username: "deployer",
  }), {
    protocol: "ssh", host: "bastion.example.invalid", port: 2222, username: "deployer",
    target: "ssh://deployer@bastion.example.invalid:2222",
  });
  assert.deepEqual(parseTeamHostConnection({ address: "rdp://operator@desktop.example.invalid:3390" }), {
    protocol: "rdp", host: "desktop.example.invalid", port: 3390, username: "operator",
  });
  assert.deepEqual(parseTeamHostConnection({ address: "legacy.example.invalid" }), {
    protocol: "rdp", host: "legacy.example.invalid", port: 3389, username: "",
  });
  assert.throws(() => teamHostConnectionData({
    protocol: "ssh", host: "bad host", port: 22, username: "root",
  }), /invalid_team_host_connection/u);
});

test("Team Vault routine automation exposes controls only for recoverable blockers", () => {
  assert.equal(teamVaultRecoveryMode(), "none");
  assert.equal(teamVaultRecoveryMode({ outcomeStatus: "up_to_date" }), "none");
  assert.equal(teamVaultRecoveryMode({ outcomeStatus: "remote_changed" }), "none");
  assert.equal(teamVaultRecoveryMode({ outcomeStatus: "conflict" }), "none");
  assert.equal(teamVaultRecoveryMode({ wrapperProvisioningFailed: true }), "wrappers");
  assert.equal(teamVaultRecoveryMode({ errorCode: "team_vault_key_unavailable" }), "access");
  assert.equal(teamVaultRecoveryMode({ errorCode: "network_unavailable" }), "synchronize");
  assert.equal(teamVaultRecoveryMode({ errorCode: "team_vault_rotation_required" }), "none");
});

test("a conflicting older browser copy is reported without promising automatic sync", () => {
  assert.equal(typeof application.teamVaultSynchronizationErrorMessage, "function");
  const message = application.teamVaultSynchronizationErrorMessage("team_vault_legacy_conflict");
  assert.match(message, /копи/u);
  assert.doesNotMatch(message, /продолжится автоматически/u);
});

test("a blocked storage upgrade explains how to keep data and retry in RU and EN", async () => {
  const message = application.vaultStorageCompatibilityMessage("vault_storage_upgrade_blocked");
  assert.match(message, /вкладках.*закройте/iu);
  assert.match(message, /сохранённые данные не изменены/iu);
  assert.equal(application.vaultStorageCompatibilityMessage("other_error"), null);
  assert.equal(application.teamVaultSynchronizationErrorMessage("vault_storage_upgrade_blocked"), message);

  const { runInNewContext } = await import("node:vm");
  const source = await readFile(new URL("../public/i18n.js", import.meta.url), "utf8");
  const browser = { window: {}, document: { addEventListener() {} },
    location: { search: "?lang=en" }, URLSearchParams,
    localStorage: { getItem() { return null; } }, navigator: { language: "en" } };
  runInNewContext(source, browser);
  const english = browser.window.SelectiveRemoteI18n.t(message);
  assert.match(english, /tabs.*close/iu);
  assert.match(english, /data.*preserved/iu);
});

test("a stale Team snapshot explains recovery without claiming two copies", () => {
  const message = application.teamVaultSynchronizationErrorMessage("team_vault_stale_snapshot");
  assert.match(message, /другой вкладке/iu);
  assert.match(message, /заблокир.*синхрониз/iu);
  assert.match(message, /несохранённ.*сбросят.*повторно/iu);
  assert.doesNotMatch(message, /две локальные копии|буфер обмена/iu);
  const state = application.reduceSyncPresentationState(application.createSyncPresentationState(), {
    scope: "team", type: "error", code: "team_vault_stale_snapshot",
  });
  assert.equal(state.team.issue, "team_vault_stale_snapshot");
});

test("a stale Team record save reports inside the editor without resetting its fields", () => {
  assert.equal(typeof application.showTeamVaultRecordSaveError, "function");
  let inline = null, resets = 0;
  const form = {
    draft: "synthetic draft",
    querySelector() { return inline; },
    prepend(element) { inline = element; },
    reset() { resets += 1; this.draft = ""; },
  };
  const documentValue = { createElement() { return {
    dataset: {}, textContent: "", setAttribute(name, value) { this[name] = value; },
  }; } };
  const status = { textContent: "" };
  application.showTeamVaultRecordSaveError({ documentValue, form, status, error: new Error("team_vault_stale_snapshot") });
  assert.equal(resets, 0);
  assert.equal(form.draft, "synthetic draft");
  assert.equal(inline.role, "alert");
  assert.match(inline.textContent, /сбросят.*повторно/iu);
  assert.equal(status.textContent, inline.textContent);
});

test("a Team draft after access loss warns about unconfirmed saving in Russian and English", async () => {
  let alert;
  const form = { querySelector: () => alert, prepend(element) { alert = element; } };
  const documentValue = { createElement: () => ({ dataset: {}, setAttribute(name, value) { this[name] = value; } }) };
  application.showTeamVaultRecordSaveError({ documentValue, form, status: {},
    error: new Error('team_vault_access_lost_draft'), beforeSave: true });
  assert.equal(alert.role, 'alert');
  assert.match(alert.textContent, /сохранение не подтверждено.*копирования/iu);
  const { runInNewContext } = await import('node:vm');
  const source = await readFile(new URL('../public/i18n.js', import.meta.url), 'utf8');
  const browser = { window: {}, document: { addEventListener() {} }, location: { search: '?lang=en' }, URLSearchParams,
    localStorage: { getItem() { return null; } }, navigator: { language: 'en' } };
  runInNewContext(source, browser);
  assert.match(browser.window.SelectiveRemoteI18n.t(alert.textContent), /saving was not confirmed.*only for copying/iu);
});

test("an invalid Team Host address is reported before saving without discarding the draft", async () => {
  const { runInNewContext } = await import("node:vm");
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf('  recordForm.addEventListener("submit", async (event) => {', source.indexOf("export function initializeTeamWorkspace"));
  const end = source.indexOf("\n  recordCreate.addEventListener", start);
  assert.ok(start >= 0 && end > start);
  let submit, inline = null, saves = 0, resets = 0;
  const button = { disabled: false }, value = (text) => ({ value: text, disabled: false });
  const recordForm = {
    addEventListener(_event, handler) { submit = handler; },
    querySelector(selector) { return selector === 'button[type="submit"]' ? button : inline; },
    prepend(element) { inline = element; },
  };
  const documentValue = { createElement() { return {
    dataset: {}, textContent: "", setAttribute(name, value) { this[name] = value; },
  }; } };
  const controller = { document: () => ({ records: [] }), async applyBatch() { saves++; } };
  const target = { controller, teamID: "synthetic-team", vaultID: "synthetic-vault",
    sessionID: "synthetic-account", sessionGeneration: "1" };
  const status = { textContent: "" };
  const context = { recordForm, controller, editingPublication: null, canEdit: () => true, activeConflicts: null,
    selectedVault: { rotationRequired: false }, recordSavePending: false, currentEditTarget: () => target,
    teamVaultEditTargetMatches: application.teamVaultEditTargetMatches,
    teamVaultRecordOperations: application.teamVaultRecordOperations, teamRecordEditorMatches: application.teamRecordEditorMatches,
    teamHostConnectionData: application.teamHostConnectionData, teamHostRecordData: application.teamHostRecordData,
    recordType: value("host"), recordTitle: value("Synthetic host"), recordTarget: value("bad host"),
    hostProtocol: value("ssh"), hostPort: value("22"), hostUsername: value("test"), hostFolder: value(""),
    hostTags: value(""), hostDescription: value(""), hostRemovePassword: { checked: false }, hostPassword: value(""),
    editingRecordID: null, editingRecordSnapshot: null, draftRecordID: null, draftCredentialID: null,
    resetRecordEditor() { resets++; }, clearConflicts() {}, rotateButton: {}, canManage: () => true, renderRecords() {},
    setText() {}, workspaceStatus: status, documentValue,
    showTeamVaultRecordSaveError: application.showTeamVaultRecordSaveError, crypto: webcrypto };
  runInNewContext(source.slice(start, end), context);
  await submit({ preventDefault() {} });
  assert.equal(saves, 0);
  assert.equal(resets, 0);
  assert.equal(context.recordTarget.value, "bad host");
  assert.match(inline.textContent, /проверьте.*адрес.*порт/iu);
  assert.doesNotMatch(inline.textContent, /могла сохраниться|закройте редактор/iu);
  assert.equal(status.textContent, inline.textContent);
});

test("a save-stage error never claims that an invalid Team record was not saved", () => {
  let inline = null;
  const form = { querySelector() { return inline; }, prepend(element) { inline = element; } };
  const documentValue = { createElement() { return {
    dataset: {}, textContent: "", setAttribute() {},
  }; } };
  application.showTeamVaultRecordSaveError({ documentValue, form, status: {},
    error: new Error("invalid_team_host_connection"), beforeSave: false });
  assert.match(inline.textContent, /могла сохраниться/iu);
  assert.doesNotMatch(inline.textContent, /запись не сохранена/iu);
});

test("Team input validation errors have English translations", async () => {
  const { runInNewContext } = await import("node:vm");
  const source = await readFile(new URL("../public/i18n.js", import.meta.url), "utf8");
  const browser = { window: {}, document: { addEventListener() {} },
    location: { search: "?lang=en" }, URLSearchParams,
    localStorage: { getItem() { return null; } }, navigator: { language: "en" } };
  runInNewContext(source, browser);
  for (const code of ["invalid_team_host_connection", "invalid_team_host_organization",
    "advanced_team_host_requires_native_editor", "invalid_local_record", "invalid_snippet_title",
    "invalid_snippet_body", "invalid_snippet_folder"]) {
    let inline = null;
    const form = { querySelector() { return inline; }, prepend(element) { inline = element; } };
    const documentValue = { createElement() { return { dataset: {}, textContent: "", setAttribute() {} }; } };
    application.showTeamVaultRecordSaveError({ documentValue, form, status: {}, error: new Error(code), beforeSave: true });
    const translated = browser.window.SelectiveRemoteI18n.t(inline.textContent);
    assert.notEqual(translated, inline.textContent, code);
    assert.match(translated, /not saved/u);
  }
});

test("a completed Team save cannot reset an editor from a newer session", async () => {
  const { runInNewContext } = await import("node:vm");
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf('  recordForm.addEventListener("submit", async (event) => {', source.indexOf("export function initializeTeamWorkspace"));
  const end = source.indexOf("\n  recordCreate.addEventListener", start);
  assert.ok(start >= 0 && end > start);
  let submit, enter, release, resets = 0, renders = 0;
  const started = new Promise((resolve) => { enter = resolve; });
  const held = new Promise((resolve) => { release = resolve; });
  const controller = { document: () => ({ records: [] }), async applyBatch() { enter(); await held; } };
  let target = { controller, teamID: "synthetic-team", vaultID: "synthetic-vault",
    sessionID: "synthetic-account", sessionGeneration: "1" };
  const button = { disabled: false }, value = (text) => ({ value: text, disabled: false });
  const recordForm = { addEventListener(_event, handler) { submit = handler; }, querySelector() { return button; } };
  const context = { recordForm, controller, editingPublication: null, canEdit: () => true, activeConflicts: null,
    selectedVault: { rotationRequired: false }, recordSavePending: false, currentEditTarget: () => target,
    teamVaultEditTargetMatches: application.teamVaultEditTargetMatches,
    teamVaultRecordOperations: application.teamVaultRecordOperations, teamRecordEditorMatches: application.teamRecordEditorMatches,
    teamHostConnectionData: application.teamHostConnectionData, teamHostRecordData: application.teamHostRecordData,
    recordType: value("host"), recordTitle: value("Old draft"), recordTarget: value("synthetic.invalid"),
    hostProtocol: value("ssh"), hostPort: value("22"), hostUsername: value("test"), hostFolder: value(""),
    hostTags: value(""), hostDescription: value(""), hostRemovePassword: { checked: false }, hostPassword: value(""),
    editingRecordID: null, editingRecordSnapshot: null, draftRecordID: null, draftCredentialID: null,
    resetRecordEditor() { resets++; }, clearConflicts() {}, rotateButton: {}, canManage: () => true,
    renderRecords() { renders++; }, setText() {}, workspaceStatus: {}, documentValue: {},
    showTeamVaultRecordSaveError() { throw new Error("unexpected_save_failure"); }, crypto: webcrypto };
  runInNewContext(source.slice(start, end), context);
  const pending = submit({ preventDefault() {} });
  await started;
  target = { ...target, sessionGeneration: "2" };
  context.recordTitle.value = "New draft";
  release();
  await pending;
  assert.equal(resets, 0);
  assert.equal(renders, 0);
  assert.equal(context.recordTitle.value, "New draft");
});

test("a changed Team record explains that reopening clears the unfinished editor", () => {
  const message = application.teamVaultSynchronizationErrorMessage("team_vault_editor_changed");
  assert.match(message, /запись.*credential.*изменились/iu);
  assert.match(message, /закройте редактор.*сбросятся.*повторно/iu);
  assert.doesNotMatch(message, /буфер обмена|две локальные копии/iu);
});

test("an unconfirmed Team save remains visible in the editor without claiming it failed", () => {
  let inline = null, resets = 0;
  const form = { draft: "synthetic draft", querySelector() { return inline; }, prepend(element) { inline = element; },
    reset() { resets += 1; this.draft = ""; } };
  const documentValue = { createElement() { return {
    dataset: {}, textContent: "", setAttribute(name, value) { this[name] = value; },
  }; } };
  application.showTeamVaultRecordSaveError({ documentValue, form, status: {}, error: new Error("storage_failed") });
  assert.equal(resets, 0);
  assert.equal(form.draft, "synthetic draft");
  assert.ok(inline);
  assert.equal(inline.role, "alert");
  assert.match(inline.textContent, /не удалось подтвердить.*могла сохраниться/iu);
  assert.doesNotMatch(inline.textContent, /запись не сохранена/iu);
});

test("a stale Team snapshot recovery warning is translated to English", async () => {
  const { runInNewContext } = await import("node:vm");
  const source = await readFile(new URL("../public/i18n.js", import.meta.url), "utf8");
  const browser = { window: {}, document: { addEventListener() {} },
    location: { search: "?lang=en" }, URLSearchParams,
    localStorage: { getItem() { return null; } }, navigator: { language: "en" } };
  runInNewContext(source, browser);
  const message = browser.window.SelectiveRemoteI18n.t(application.teamVaultSynchronizationErrorMessage("team_vault_stale_snapshot"));
  assert.match(message, /another tab.*Lock.*Synchronize/iu);
  assert.match(message, /unsaved fields.*cleared.*entered again/iu);
  assert.doesNotMatch(message, /clipboard|two local Team Vault copies/iu);
});

test("an overlapping Team operation asks the user to retry", () => {
  const message = application.teamVaultSynchronizationErrorMessage("team_vault_operation_in_progress");
  assert.match(message, /дождитесь.*повторите/iu);
  assert.doesNotMatch(message, /продолжится автоматически/u);
});

test("trusted browser automatically rotates and maintains accessible Team Vaults outside the active view", async () => {
  const scopes = [];
  const locked = [];
  const result = await maintainAccessibleTeamVaultWrappers({
    client: { accessClient: () => ({getContext: async () => ({formatState:"V1_ACTIVE"})}) },
    identity: { deviceID: "trusted-browser" },
    team: { id: "team-1", role: "owner" },
    vaults: [
      { id: "available", rotationRequired: false },
      { id: "unavailable", rotationRequired: false },
      { id: "rotating", rotationRequired: true },
    ],
    repositoryFactory(scope) {
      scopes.push(scope);
      return { scope };
    },
    controllerFactory({ scope }) {
      return { scope, lock() { locked.push(scope.vaultID); } };
    },
    async synchronize({ controller }) {
      if (controller.scope.vaultID === "unavailable") {
        throw new Error("team_vault_key_unavailable");
      }
      return { status: "up_to_date" };
    },
    async provision({ controller }) {
      assert.equal(controller.scope.vaultID, "available");
      return { granted: 2 };
    },
    async rotate({ controller }) {
      assert.equal(controller.scope.vaultID, "rotating");
      return { status: "rotated", revision: 3, keyGeneration: 2 };
    },
  });

  assert.deepEqual(result, {
    attempted: 3,
    synchronized: 1,
    rotated: 1,
    granted: 2,
    unavailable: 1,
    failed: 0,
  });
  assert.deepEqual(scopes.map(({ vaultID }) => vaultID), ["available", "unavailable", "rotating"]);
  assert.deepEqual(locked, ["available", "unavailable", "rotating"]);
});

test("username invitation preprovisioning wraps every snapshotted Vault and device locally", async () => {
  const locked = [];
  let uploaded;
  const invitation = {
    id: "invite-1",
    preprovisioning: {
      membershipID: "membership-2",
      membershipEpoch: 4,
      devices: [{ deviceID: "device-2", publicKey: { kty: "EC" } }],
      vaults: [
        { vaultID: "vault-1", keyGeneration: 2 },
        { vaultID: "vault-2", keyGeneration: 7 },
      ],
    },
  };
  const result = await preprovisionTeamInvitationWrappers({
    client: {
      session: () => ({ id: "account-1" }),
      deviceID: () => "device-1",
      sessionGeneration: () => "1",
      async preprovisionTeamInvitationWrappers(value) { uploaded = value; return { ready: true, wrappers: 2 }; },
    },
    identity: { deviceID: "device-1" },
    team: { id: "team-1", role: "owner" },
    invitation,
    repositoryFactory: (scope) => ({ scope }),
    controllerFactory({ scope }) {
      return {
        scope,
        async syncState() {
          return { keyGeneration: scope.vaultID === "vault-1" ? 2 : 7 };
        },
        async prepareWrapper(recipient) {
          return { recipient, vaultID: scope.vaultID };
        },
        lock() { locked.push(scope.vaultID); },
      };
    },
    async synchronize() { return { status: "up_to_date" }; },
  });

  assert.deepEqual(result, { ready: true, wrappers: 2 });
  assert.equal(uploaded.teamID, "team-1");
  assert.equal(uploaded.invitationID, "invite-1");
  assert.deepEqual(uploaded.wrappers.map(({ vaultID, wrapper }) => ({
    vaultID,
    membershipID: wrapper.recipient.membershipID,
    membershipEpoch: wrapper.recipient.membershipEpoch,
    deviceID: wrapper.recipient.deviceID,
  })), [
    { vaultID: "vault-1", membershipID: "membership-2", membershipEpoch: 4, deviceID: "device-2" },
    { vaultID: "vault-2", membershipID: "membership-2", membershipEpoch: 4, deviceID: "device-2" },
  ]);
  assert.deepEqual(locked, ["vault-1", "vault-2"]);
});

test("credential summaries never expose their secret", () => {
  const record = {
    type: "credential",
    data: { title: "Admin", username: "root", secret: "must-not-render" },
  };
  const summary = localVaultRecordSummary(record);

  assert.equal(summary, "root · секрет скрыт");
  assert.equal(summary.includes(record.data.secret), false);
});

test("resource details support safe Credential, Snippet, and Forwarding inspection", () => {
  const credential = vaultResourceDetail({
    type: "credential", modifiedAt: "2026-09-16T12:00:00Z",
    data: { title: "Production", username: "root", secret: "secret-value" },
  });
  assert.equal(credential.content, "••••••••");
  assert.equal(credential.copyValue, "secret-value");
  assert.equal(credential.target, "root");
  const snippet = vaultResourceDetail({ type: "snippet", data: { title: "Status", body: "uptime" } });
  assert.equal(snippet.content, "uptime");
  assert.equal(snippet.copyValue, "uptime");
  const forwarding = vaultResourceDetail({
    type: "forwarding", data: { title: "Database", destination: "db:5432", configuration: "local 15432" },
  });
  assert.equal(forwarding.target, "db:5432");
  assert.equal(forwarding.content, "local 15432");
});

test("conflict choices expose only bounded metadata and never record secrets or bodies", () => {
  const credential = {
    kind: "record",
    value: {
      type: "credential",
      modifiedAt: "2026-09-04T00:00:00.000Z",
      data: { title: "Administrator", username: "root", secret: "must-not-render" },
    },
  };
  const snippet = {
    kind: "record",
    value: {
      type: "snippet",
      modifiedAt: "2026-09-04T00:00:00.000Z",
      data: { title: "Status", body: "sensitive command body" },
    },
  };
  const rendered = `${localVaultConflictSideSummary(credential)} ${localVaultConflictSideSummary(snippet)}`;

  assert.match(rendered, /Administrator · credential/u);
  assert.match(rendered, /Status · snippet/u);
  assert.doesNotMatch(rendered, /must-not-render|sensitive command body|root/u);
  assert.match(
    localVaultConflictSideSummary({ kind: "tombstone", value: { deletedAt: "2026-09-04T00:00:00.000Z" } }),
    /Удалено/u,
  );
});

test("portal exposes separate public, authentication and workspace states", async () => {
  const [html, styles, application, appearanceBootstrap, synchronization, teamSynchronization, server] = await Promise.all([
    readFile(new URL("../public/index.html", import.meta.url), "utf8"),
    readFile(new URL("../public/styles.css", import.meta.url), "utf8"),
    readFile(new URL("../public/app.js", import.meta.url), "utf8"),
    readFile(new URL("../public/appearance-bootstrap.js", import.meta.url), "utf8"),
    readFile(new URL("../public/vault-sync.js", import.meta.url), "utf8"),
    readFile(new URL("../public/team-vault-sync.js", import.meta.url), "utf8"),
    readFile(new URL("../src/server.mjs", import.meta.url), "utf8"),
  ]);

  assert.match(html, /id="cloud-account"[^>]*hidden/u);
  assert.match(html, /<html lang="ru" class="app-booting">/u);
  assert.match(html, /id="app-boot-screen"[^>]*role="status"/u);
  assert.match(html, /Открываем защищённое пространство/u);
  assert.match(html, /<script src="\/appearance-bootstrap\.js\?v=162"><\/script>\s*<link rel="stylesheet" href="\/styles\.css\?v=197">/u);
  assert.match(html, /\/app\.js\?v=196/u);
  assert.match(appearanceBootstrap, /sr_theme=\(graphite\|emerald\|light\)/u);
  assert.match(appearanceBootstrap, /document\.documentElement\.dataset\.theme/u);
  assert.match(styles, /\.app-booting \.shell \{ visibility:hidden; \}/u);
  assert.match(styles, /\.app-booting \.app-boot-screen \{ display:grid; \}/u);
  assert.match(styles, /select:not\(\[multiple\]\) \{[^}]*appearance:none[^}]*background-image:linear-gradient/u);
  assert.match(styles, /select:not\(\[multiple\]\):focus-visible \{[^}]*border-color:var\(--accent\)/u);
  assert.match(styles, /select:not\(\[multiple\]\):disabled/u);
  assert.match(styles, /\.modern-select-menu \{[^}]*background:color-mix/u);
  assert.match(styles, /\.modern-select-option\[aria-selected="true"\]/u);
  assert.match(styles, /:root\[data-theme="light"\] \.modern-select-menu/u);
  assert.match(styles, /:root\[data-theme="light"\] \.workspace-main/u);
  assert.match(styles, /:root\[data-theme="light"\] \.account-settings-card input/u);
  assert.match(styles, /@keyframes modern-select-in-light/u);
  assert.match(styles, /@keyframes preview-float-light/u);
  assert.match(application, /export function finishPortalBootstrap/u);
  assert.match(application, /modern-select\.js\?v=193/u);
  assert.match(application, /save\.className = "team-member-action-button"/u);
  assert.match(application, /admitDevices\.className = "team-member-action-button"/u);
  assert.doesNotMatch(application, /Не используется/u);
  assert.match(application, /targetRow\.hidden = !visibility\.target;/u);
  assert.match(application, /secretRow\.hidden = !visibility\.secret;/u);
  assert.match(application, /recordTargetRow\.hidden = !visibility\.target;/u);
  assert.match(application, /recordSecretRow\.hidden = !visibility\.secret;/u);
  assert.match(application, /try \{\s*initializeAppearance\(\);\s*initializeModernSelects\(\);\s*await initializePortal\(\);\s*\} finally \{\s*finishPortalBootstrap\(\);/u);
  assert.match(html, /id="cloud-workspace"[^>]*hidden/u);
  assert.match(html, /data-open-auth="login"/u);
  assert.match(html, /data-open-auth="registration"/u);
  assert.equal((html.match(/data-open-auth="login"/gu) ?? []).length, 3);
  assert.equal((html.match(/data-open-auth="registration"/gu) ?? []).length, 3);
  assert.match(html, /<nav class="brand-actions"[\s\S]*data-open-auth="login"[\s\S]*data-open-auth="registration"[\s\S]*<\/nav>/u);
  assert.match(html, /class="hero-actions"[\s\S]*data-open-auth="registration"[\s\S]*data-open-auth="login"/u);
  assert.match(html, /class="hero-ambient"[^>]*aria-hidden="true"/u);
  assert.match(html, /href="https:\/\/github\.com\/PastFly\/Selective-Remote\/releases\/latest"[^>]*>[^<]*<span[^>]*>↓<\/span> Скачать для macOS/u);
  assert.match(html, /class="site-nav"[\s\S]*href="#public-grid">Возможности[\s\S]*href="#public-security">Безопасность[\s\S]*href="#public-team">Для команд[\s\S]*>GitHub ↗/u);
  assert.match(html, /id="service-status"[^>]*role="status"[\s\S]*<span>Проверка<\/span>/u);
  assert.equal((html.match(/data-hero-preview-scene=/gu) ?? []).length, 8);
  assert.match(html, /id="hero-preview-stage"[^>]*aria-live="polite"[^>]*hidden/u);
  assert.match(html, /data-preview-scene-panel="hosts"/u);
  assert.match(html, /data-preview-scene-panel="credentials"/u);
  assert.match(html, /data-preview-scene-panel="snippets"/u);
  assert.match(html, /data-preview-scene-panel="devices"/u);
  assert.equal((html.match(/data-hero-preview-scope=/gu) ?? []).length, 2);
  assert.match(html, /id="sync-journey-title"/u);
  assert.match(html, /Создали Host на Mac/u);
  assert.doesNotMatch(html, /selective-remote-(?:macos|cloud-browser)\.webp/u);
  assert.equal((html.match(/DEMO DATA/gu) ?? []).length, 2);
  assert.match(html, /class="product-mock product-mock-macos"/u);
  assert.match(html, /class="product-mock product-mock-browser"/u);
  assert.match(html, /class="product-mock-cloud-tools"/u);
  assert.match(html, /Синхронизировано сейчас/u);
  assert.match(html, /demo\.example/u);
  assert.match(html, /id="landing-features-title"/u);
  assert.match(html, /class="security-flow"[^>]*aria-label="Как работает защищённая синхронизация"/u);
  assert.match(html, /class="auth-security-note"/u);
  assert.doesNotMatch(html, /Войти через Google|Войти через Apple/u);
  assert.match(html, /id="cloud-login-form"/u);
  assert.match(html, /id="cloud-vault-sync"/u);
  assert.match(html, /id="cloud-logout"/u);
  assert.match(html, /id="local-vault-waiting"[^>]*hidden/u);
  assert.match(html, /id="local-vault-actions"[^>]*hidden/u);
  assert.match(html, /Personal Vault заблокирован/u);
  assert.doesNotMatch(html, /cloud-vault-recovery|local-vault-(?:setup|unlock)-form/u);
  assert.doesNotMatch(html, /Recovery-фраза|recovery-фраза/iu);
  assert.match(html, /id="local-vault-conflicts-form"/u);
  assert.match(html, /id="local-vault-conflicts-apply"[^>]*disabled/u);
  assert.match(html, /id="team-vault"[^>]*hidden/u);
  assert.match(html, /id="team-create-form"/u);
  assert.match(html, /id="team-invitation-accept-form"/u);
  assert.match(html, /id="team-pending-invitations"/u);
  assert.match(html, /id="team-invite-username"/u);
  assert.match(html, /id="team-invite-link-create"/u);
  assert.match(html, /id="team-active-invitations"/u);
  assert.match(html, /id="team-invite-email"/u);
  assert.match(html, /id="team-invite-email-submit"/u);
  assert.match(html, /id="team-select"/u);
  assert.match(html, /id="team-lifecycle"[^>]*hidden/u);
  assert.match(html, /id="team-rename-form"/u);
  assert.match(html, /id="team-ownership-transfer-form"/u);
  assert.match(html, /id="team-archive-form"/u);
  assert.match(html, /autocomplete="current-password"/u);
  assert.match(html, /id="team-devices"/u);
  assert.match(html, /id="team-vault-rotate"[^>]*hidden/u);
  assert.match(html, /Изменения синхронизируются автоматически/u);
  assert.match(html, /Дополнительные действия появятся только при устранимой ошибке доступа/u);
  assert.match(html, /id="team-vault-grant-wrappers"[^>]*hidden[^>]*>Повторить безопасную выдачу wrappers/u);
  assert.match(html, /id="team-vault-sync"[^>]*hidden[^>]*>Повторить безопасную синхронизацию/u);
  assert.equal((html.match(/aria-describedby="team-vault-workspace-status"/gu) ?? []).length, 2);
  assert.doesNotMatch(html, /Синхронизировать сейчас/u);
  assert.match(html, /id="team-vault-record-form"/u);
  assert.match(html, /id="team-vault-conflicts-form"/u);
  assert.match(html, /id="workspace-overview"/u);
  assert.match(html, /data-workspace-target="local-vault"/u);
  assert.match(html, /data-workspace-target="workspace-devices"/u);
  assert.match(html, /id="personal-vault-filters"[\s\S]*data-record-filter="host">Hosts/u);
  assert.match(html, /id="personal-vault-filters"[\s\S]*data-record-filter="snippet">Snippets/u);
  assert.match(html, /id="personal-vault-filters"[\s\S]*data-record-filter="credential">Credentials/u);
  assert.match(html, /data-workspace-target="team-vault">Команды/u);
  assert.equal((html.match(/class="workspace-mobile-nav"/gu) ?? []).length, 1);
  assert.ok(html.indexOf('class="workspace-mobile-nav"') > html.indexOf('id="team-vault"'));
  assert.match(styles, /\.brand-actions>button\[data-open-auth="login"\]\s*\{\s*display:inline-flex/u);
  assert.match(styles, /\.brand \.status span \{ display:inline; \}/u);
  assert.match(html, /id="team-view-tabs"/u);
  assert.match(html, /data-team-view="members">Участники/u);
  assert.match(html, /id="team-member-search"/u);
  assert.match(html, /id="team-member-role-filter"/u);
  assert.match(html, /id="team-member-more"/u);
  assert.match(html, /data-team-view="vaults">Vaults/u);
  assert.match(html, /data-team-view="hosts">Ресурсы/u);
  assert.match(html, /class="host-scope-switcher"/u);
  assert.match(html, />Личные<\/button>[\s\S]*data-team-view="hosts" data-preserve-record-filter data-preserve-scroll>Командные/u);
  assert.match(html, /id="team-resource-navigation"/u);
  assert.match(html, /id="team-resource-filters" aria-label="Типы командных ресурсов"/u);
  assert.match(html, /id="team-view-tabs"[\s\S]*id="team-resource-navigation"/u);
  assert.match(html, /data-team-record-filter="all"[^>]*>Все/u);
  assert.match(html, /data-team-record-filter="host"[^>]*>Hosts/u);
  assert.match(html, /data-team-record-filter="credential"[^>]*>Credentials/u);
  assert.match(html, /data-team-record-filter="snippet"[^>]*>Snippets/u);
  assert.match(html, /data-team-record-filter="forwarding"[^>]*>Forwarding/u);
  assert.match(html, /id="team-record-editor"/u);
  assert.match(html, /id="team-record-create"/u);
  assert.match(html, /id="team-record-cancel"/u);
  assert.match(html, /id="resource-detail-dialog"/u);
  assert.match(html, /id="resource-detail-copy"/u);
  assert.match(html, /class="device-vault-map"/u);
  assert.match(html, /id="host-detail-dialog"/u);
  assert.match(html, /id="host-detail-copy"/u);
  assert.match(html, /id="host-detail-edit"/u);
  assert.match(html, /id="host-detail-copy-password"/u);
  assert.match(html, /id="host-detail-open-ssh"/u);
  assert.match(html, /id="host-detail-open-sftp"/u);
  assert.match(html, /id="team-host-protocol"/u);
  assert.match(html, /id="team-host-port"/u);
  assert.match(html, /id="team-host-username"/u);
  assert.match(html, /id="team-host-password"[^>]*type="password"/u);
  assert.match(html, /data-workspace-target="workspace-settings"/u);
  assert.match(html, /data-workspace-target="workspace-about">О проекте/u);
  assert.match(html, /id="workspace-team-overview-title"/u);
  assert.match(html, /id="workspace-team-count"/u);
  assert.match(html, /id="workspace-team-invitation-count"/u);
  assert.match(html, /https:\/\/yoomoney\.ru\/to\/4100119600001192/u);
  assert.match(html, /https:\/\/boosty\.to\/pastfly/u);
  assert.match(html, /https:\/\/github\.com\/PastFly\/Selective-Remote/u);
  assert.match(html, /https:\/\/t\.me\/SelectiveRemoteApp/u);
  assert.match(styles, /\.workspace-about>\.vault-heading \{ margin-bottom:26px; \}/u);
  assert.match(html, /id="account-delete-form"/u);
  assert.match(html, /id="account-username-form"/u);
  assert.match(html, /id="account-password-form"/u);
  assert.match(html, /id="team-device-admission-policy"/u);
  assert.match(html, /id="team-device-admission-toggle"[^>]*role="switch"[^>]*checked/u);
  assert.match(html, /id="app-confirmation-dialog"/u);
  assert.match(html, /autocomplete="current-password"/u);
  assert.match(html, /data-record-filter="host"/u);
  assert.match(html, /data-record-filter="credential"/u);
  assert.match(html, /data-record-filter="snippet"/u);
  assert.match(html, /data-record-filter="forwarding"/u);
  assert.match(html, /id="personal-vault-search"/u);
  assert.match(html, /id="personal-vault-sort"/u);
  assert.match(html, /id="personal-vault-folder-filter"/u);
  assert.match(html, /id="local-record-create"/u);
  assert.match(html, /id="local-record-editor-dialog"/u);
  assert.match(html, /id="local-vault-record-form"/u);
  assert.match(html, /id="local-record-cancel"[^>]*hidden/u);
  assert.doesNotMatch(html, /data-record-filter="all">Personal Vault/u);
  assert.match(html, /data-workspace-target="team-vault">Команды/u);
  assert.match(html, /id="personal-host-fields"/u);
  assert.match(html, /id="local-host-protocol"/u);
  assert.match(html, /id="local-host-folder"/u);
  assert.match(html, /Откройте Vault, чтобы увидеть личные подключения/u);
  assert.doesNotMatch(html, /ещё не выполняет этот импорт автоматически/u);
  assert.match(styles, /\[hidden\]\s*\{\s*display:\s*none\s*!important;\s*\}/u);
  assert.match(styles, /\.workspace-layout/u);
  assert.match(html, /styles\.css\?v=197/u);
  assert.match(html, /app\.js\?v=196/u);
  assert.match(html, /data-nav-icon="⌁" data-workspace-target="local-vault" data-record-filter="all">Vault/u);
  assert.match(html, /data-stat-kind="credential"/u);
  assert.match(styles, /Cloud workspace v171/u);
  assert.match(styles, /#cloud-workspace \.vault-records article \{[^}]*grid-template-columns:minmax\(160px,1\.1fr\)/u);
  assert.match(styles, /@media \(max-width:700px\) \{[\s\S]*#cloud-workspace \.vault-records article \{ grid-template-columns:minmax\(0,1fr\)/u);
  assert.match(styles, /:root\[data-theme="light"\] \.access,[\s\S]*\.resource-detail,[\s\S]*\.vault-conflicts\s*\{\s*background:var\(--surface-raised\)/u);
  assert.match(styles, /--panel:#f6faf8; --surface-soft:#eef6f2; --surface-raised:#fbfdfc/u);
  assert.match(styles, /:root\[data-theme="light"\] \.app-boot-card \{[^}]*background:linear-gradient/u);
  assert.match(styles, /:root\[data-theme="light"\] \.workspace-main \{\s*background:transparent;\s*\}/u);
  assert.match(styles, /:root\[data-theme="light"\] :is\(\.local-vault,\.team-vault\)\.workspace-panel \{\s*background:transparent; box-shadow:none;\s*\}/u);
  assert.match(styles, /:root\[data-theme="light"\] \.workspace-stats button,[^}]*background:var\(--surface-raised\)/u);
  assert.match(styles, /:root\[data-theme="light"\] \.resource-card-clickable:hover/u);
  assert.match(styles, /@keyframes reveal-up/u);
  assert.match(styles, /@keyframes ribbon-drift/u);
  assert.match(styles, /@keyframes auth-card-arrive/u);
  assert.match(styles, /@keyframes preview-stage-enter/u);
  assert.match(styles, /@keyframes preview-credential-unlock/u);
  assert.match(styles, /@keyframes preview-orbit-spin/u);
  assert.match(styles, /@keyframes journey-signal/u);
  assert.match(styles, /\.product-gallery-grid/u);
  assert.match(styles, /\.product-gallery-grid \{ grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/u);
  assert.match(styles, /\.product-mock-body/u);
  assert.match(styles, /\.product-mock-cloud \{ display:grid; grid-template-rows:auto auto auto minmax\(0,1fr\) auto; height:calc\(100% - 32px\)/u);
  assert.match(styles, /\.preview-scope-switch/u);
  assert.match(styles, /\.hero-ribbon/u);
  assert.match(styles, /\.security-story/u);
  assert.match(styles, /prefers-reduced-motion:reduce[^}]*[\s\S]*animation:none!important/u);
  assert.match(styles, /\.team-members article\s*\{[^}]*grid-template-columns:36px minmax\(0,1fr\) auto auto/u);
  assert.match(styles, /\.team-member-directory,\.team-member-invitations \{ min-width:0; \}/u);
  assert.match(styles, /\.team-member-toolbar \{[^}]*grid-template-columns:minmax\(0,1fr\) minmax\(128px,168px\)/u);
  assert.match(styles, /\.team-active-invitations-panel \{ margin-top:28px; padding-top:22px/u);
  assert.match(styles, /@keyframes team-panel-enter/u);
  assert.match(html, /Добавить участника/u);
  assert.match(html, /Приглашение можно принять в течение 48 часов/u);
  assert.doesNotMatch(html, /Пригласить на 48 часов/u);
  assert.match(styles, /\.team-member-actions/u);
  assert.match(styles, /\.team-policy-card/u);
  assert.match(styles, /\.setting-switch/u);
  assert.match(styles, /\.app-confirmation::backdrop/u);
  assert.match(styles, /:focus-visible/u);
  assert.match(application, /initializePortalNavigation/u);
  assert.match(application, /initializeHeroPreview/u);
  assert.match(application, /BroadcastChannel\("selective-remote\.personal-vault\.session\.v1"\)/u);
  assert.match(application, /restoreRememberedSession\(restoredUser\.id\)/u);
  assert.match(application, /targetVault\.hasAccountOwnership\(user\.id\)/u);
  assert.match(application, /targetVault\.rememberSession\(user\.id\)/u);
  assert.doesNotMatch(application, /try \{ await vault\.rememberSession\(user\.id\); \} catch \{\}/u);
  assert.match(application, /vault\.forgetRememberedSession\(\)/u);
  assert.match(application, /visibilitychange/u);
  assert.doesNotMatch(html, /<div class="vault-toolbar">\s*<div><h3>Личный Vault/u);
  assert.match(application, /ваш текущий username/u);
  assert.match(application, /teamUI\?\.setView\(teamView \|\| "teams", activeTeamRecordFilter\)/u);
  assert.match(application, /Team «\$\{selectedTeam\.name\}» · участников: \$\{memberTotal\}/u);
  assert.match(application, /listTeamMembersPage/u);
  assert.match(application, /Команда «\$\{selectedTeam\.name\}» · папок: \$\{vaults\.length\}/u);
  assert.match(application, /createVaultForm\.hidden = activeView !== "vaults" \|\| !canManage\(\)/u);
  assert.match(application, /workspace\.hidden = activeView !== "hosts" \|\| !controller/u);
  assert.match(application, /activeView === "hosts" && vaults\.length > 0/u);
  assert.match(application, /data-team-view="hosts"/u);
  assert.match(styles, /#team-vault\[data-team-view="hosts"\] \.team-vault-directory-heading/u);
  assert.match(styles, /\.vault-records article\s*\{[^}]*grid-template-columns:minmax\(0,1fr\)/u);
  assert.match(styles, /\.record-actions\s*\{[^}]*grid-column:1;[^}]*flex-wrap:wrap/u);
  assert.match(styles, /@media \(max-width:560px\)[^}]*[\s\S]*\.record-actions\{display:grid;grid-template-columns:1fr 1fr\}/u);
  assert.match(application, /выберите папку для просмотра \$\{resourceNames\[activeRecordFilter\]\}/u);
  assert.match(application, /await openSelectedVault\(\)/u);
  assert.match(application, /value\.type !== activeRecordFilter/u);
  assert.match(application, /activeRecordFilter !== "host"\) return true/u);
  assert.match(html, /id="team-host-search"/u);
  assert.match(html, /id="team-host-folder-filter"/u);
  assert.match(application, /teamHostRecordData/u);
  assert.match(application, /В выбранном Team Vault пока нет \$\{emptyLabels\[activeRecordFilter\]\}/u);
  assert.match(application, /hostDetail\?\.showModal\(\)/u);
  assert.match(application, /documentValue\.body\.append\(hostDetail\)/u);
  assert.match(html, /class="workspace-security-status"/u);
  assert.match(html, /class="workspace-account"/u);
  assert.match(styles, /\.workspace-security-icon/u);
  assert.doesNotMatch(application, /sidebarFooter\.append/u);
  assert.match(application, /workspaceHeader\.hidden = false/u);
  assert.match(application, /beginRecordEdit/u);
  assert.match(application, /appendVaultFolderGroup/u);
  assert.match(application, /collapsedVaultFoldersState = new Map/u);
  assert.match(application, /showVaultResourceDetail/u);
  assert.doesNotMatch(application, /record-open/u);
  assert.equal((application.match(/actions\.append\(favorite, edit, remove\)/gu) ?? []).length, 2);
  assert.equal((application.match(/card\.classList\.add\("resource-card", "resource-card-clickable"/gu) ?? []).length, 2);
  assert.equal((application.match(/event\.target\.closest\?\.\("button, input, select, textarea, a, summary, label"\)/gu) ?? []).length, 2);
  assert.match(styles, /#cloud-workspace input\.record-select\s*\{[^}]*width:18px;[^}]*min-width:18px;[^}]*max-width:18px;[^}]*height:18px;[^}]*min-height:18px;[^}]*max-height:18px;[^}]*padding:0;/u);
  assert.ok(styles.indexOf("#cloud-workspace input.record-select") > styles.indexOf(".team-vault input"));
  assert.match(styles, /#cloud-workspace \.record-actions \{[^}]*position:relative;[^}]*z-index:3;/u);
  assert.match(application, /recordEditor\?\.showModal\?\.\(\)/u);
  assert.match(application, /event\.metaKey \|\| event\.ctrlKey/u);
  assert.match(application, /navigator\.clipboard\.writeText\(hostDetailAddress\.textContent\)/u);
  assert.match(application, /navigator\.clipboard\.writeText\(String\(credential\.data\.secret/u);
  assert.match(application, /target\.replace\(\/\^ssh:\/u, "sftp:"\)/u);
  assert.match(application, /sourceID: recordID/u);
  assert.match(application, /resourceTitles/u);
  assert.match(application, /client\.deleteAccount/u);
  assert.match(application, /account_owns_teams/u);
  assert.match(application, /URLSearchParams\(locationValue\.search\)/u);
  assert.match(application, /requestedAuthMode === "login" \|\| requestedAuthMode === "registration"/u);
  assert.match(application, /setPath\("\/login"/u);
  assert.match(application, /"\/app": \["workspace-overview", null, null, null\]/u);
  assert.match(application, /"\/app\/team-vault": \["team-vault", null, "hosts", "all"\]/u);
  assert.match(application, /"\/app\/team-hosts": \["team-vault", null, "hosts", "host"\]/u);
  assert.match(application, /"\/app\/team-snippets": \["team-vault", null, "hosts", "snippet"\]/u);
  assert.match(application, /"\/app\/team-credentials": \["team-vault", null, "hosts", "credential"\]/u);
  assert.match(application, /"\/app\/team-forwarding": \["team-vault", null, "hosts", "forwarding"\]/u);
  assert.match(application, /button\.closest\("#local-vault"\) \? activePersonalRecordFilter : activeTeamRecordFilter/u);
  assert.match(application, /let activePersonalRecordFilter = "all"/u);
  assert.match(application, /panelID === "local-vault" && recordFilter\) activePersonalRecordFilter = recordFilter/u);
  assert.match(application, /preserveRecordFilter && target === "local-vault" \? activeTeamRecordFilter/u);
  assert.match(application, /button\.dataset\.teamRecordFilter \|\|/u);
  assert.match(application, /teamResourceContext && button\.dataset\.workspaceTarget === "local-vault"/u);
  assert.match(application, /!button\.hasAttribute\("data-preserve-scroll"\)/u);
  assert.match(styles, /#team-vault\[data-team-view="hosts"\] \.team-section-tabs \{ display:none; \}/u);
  assert.match(styles, /#local-vault>\.vault-heading,#team-vault\[data-team-view="hosts"\]>\.vault-heading \{ min-height:78px; \}/u);
  assert.match(styles, /#team-vault\[data-team-view="hosts"\] \.team-resource-navigation \{ display:block; margin-top:28px; padding-top:28px; border-top:1px solid var\(--line\); \}/u);
  assert.doesNotMatch(styles, /\.team-resource-navigation \.host-scope-switcher \{/u);
  assert.doesNotMatch(styles, /\.team-resource-navigation \.record-filters button/u);
  assert.ok(styles.indexOf(".record-filters { display:flex") > styles.indexOf(".team-vault button:disabled"));
  assert.match(styles, /\.record-filters button \{[^}]*border-radius:999px[^}]*background:transparent[^}]*font-weight:400/u);
  assert.match(application, /activeRecordFilter !== "all" && value\.type !== activeRecordFilter/u);
  assert.match(application, /activeView === "hosts" && activeRecordFilter !== "all"/u);
  assert.match(application, /routeForWorkspace/u);
  assert.match(application, /setFilterChangeListener/u);
  assert.match(application, /renderOverviewSummary/u);
  assert.match(application, /formatVaultTimestamp\(record\.modifiedAt\)/u);
  assert.match(application, /english \? "Modified" : "Изменено"/u);
  assert.match(application, /setVaultSynchronizationMessage\(vaultMessage, \{ documentValue, revision: result\.revision \}\)/u);
  assert.match(application, /const hostFolderName = personalHostFolderName/u);
  assert.match(application, /localVaultRecordFormValues\(record\)/u);
  assert.match(application, /editingRecordID/u);
  assert.match(application, /closeEditor\(\)/u);
  assert.match(application, /editorDialog\?\.close\?\.\(\)/u);
  assert.match(application, /createButton\?\.addEventListener\("click", beginCreate\)/u);
  assert.match(application, /setFilter\(value\) \{\s*resetEditor\(\)/u);
  assert.match(application, /panelID !== "local-vault"\) vaultUI\?\.closeEditor\(\)/u);
  assert.match(application, /personalHostRecordData/u);
  assert.match(styles, /\.personal-vault-browser/u);
  assert.match(styles, /grid-template-columns:repeat\(3,minmax\(0,1fr\)\)/u);
  assert.match(styles, /\.team-host-browser \{ display:grid; grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/u);
  assert.match(styles, /\.record-form input\[type="checkbox"\] \{ width:auto/u);
  assert.match(styles, /\.team-section-tabs,\.host-scope-switcher/u);
  assert.ok(styles.includes('.brand-actions button:not([data-locale]):not(.secondary):not(.modern-select-trigger):not(.modern-select-option)'));
  assert.ok(styles.includes(':not([data-team-view]):not([data-record-filter])'));
  assert.ok(styles.includes(':not(.team-member-action-button)'));
  assert.match(styles, /:root\[data-theme="light"\] \.team-member-action-button \{[^}]*color:var\(--text-primary\)/u);
  assert.ok(styles.includes(':root[data-theme="light"] :is(input:not([type="checkbox"]):not([type="radio"]),textarea,select)'));
  assert.ok(styles.includes(':root[data-theme="light"] .team-section-tabs button:not(.active)'));
  assert.match(server, /\^\\\/app\(\?:\\\/\[\^\/\]\+\)\?\$/u);
  assert.match(application, /createAuthenticatedVaultClient/u);
  assert.match(application, /prepareAccountScopedVault/u);
  assert.match(application, /vaultUI\.repository\.forAccount\(user\.id\)/u);
  assert.match(application, /activateAccountVault\(restoredUser\)/u);
  assert.match(application, /synchronizeVault/u);
  assert.match(application, /completeInteractivePersonalVaultLogin/u);
  assert.match(application, /backgroundPersonalVaultSync/u);
  assert.match(application, /renderConflicts\(result\)/u);
  assert.match(application, /async function synchronizePersonalVault/u);
  assert.doesNotMatch(
    application.match(/syncButton\.addEventListener\("click"[\s\S]*?conflictForm\.addEventListener/u)?.[0] ?? "",
    /renderConflicts\(result\)/u,
  );
  assert.match(application, /15_000/u);
  assert.match(application, /vault\.lock\(\)/u);
  assert.doesNotMatch(application, /accountVaultMigrationPassphrase|account_password_required/u);
  assert.doesNotMatch(application, /cloud-vault-recovery-form|vaultUI\.showRecovery/u);
  assert.doesNotMatch(application, /vault\.replaceLockedWithRemote\(/u);
  assert.match(application, /Personal Vault открыт паролем аккаунта/u);
  assert.doesNotMatch(application, /Legacy Personal Vault|Recovery-фраза|секретная фраза/iu);
  assert.match(application, /vaultUI\.mode\("locked", \{ allowReauthentication: true \}\)/u);
  assert.match(html, /id="local-vault-reauthenticate-form"/u);
  assert.match(styles, /\.vault-bootstrap-form/u);
  assert.doesNotMatch(application, /vaultUI\.showRecovery\(\)/u);
  assert.match(application, /ensureTeamDeviceIdentity/u);
  assert.match(application, /synchronizeTeamVault/u);
  assert.match(application, /provisionTeamVaultWrappers/u);
  assert.match(application, /maintainAccessibleTeamVaultWrappers/u);
  assert.match(application, /rotationRequired[\s\S]*rotate\(\{ client, controller: maintenanceController, role: team\.role \}\)/u);
  assert.match(application, /Автоматически обновляем ключи командных папок перед приглашением/u);
  assert.match(application, /backgroundSyncIntervalMilliseconds = 15_000/u);
  assert.match(application, /workspaceRefreshIntervalMilliseconds = 10_000/u);
  assert.match(application, /refreshWorkspaceActivity/u);
  assert.match(application, /client\.listPendingTeamInvitations\(\)/u);
  assert.match(application, /client\.listTeams\(\)/u);
  assert.match(application, /Promise\.allSettled/u);
  assert.match(application, /client\.listTeamMembersPage\(activeTeam\.id/u);
  assert.match(application, /Данные команды обновлены/u);
  assert.match(application, /Синхронизация продолжится автоматически/u);
  assert.doesNotMatch(application, /Синхронизация не выполнена; локальная/u);
  assert.match(html, /app\.js\?v=196/u);
  assert.match(html, /styles\.css\?v=197/u);
  assert.doesNotMatch(application, /documentValue\.visibilityState === "hidden"/u);
  assert.match(application, /runBackgroundTeamVaultSync/u);
  assert.match(application, /void runBackgroundTeamVaultSync\(\)/u);
  assert.match(application, /teamVaultSynchronizationErrorMessage/u);
  assert.match(application, /Оставьте доверенный браузер или приложение участника/u);
  assert.match(application, /teamVaultRecoveryMode/u);
  assert.match(application, /setRecoveryControls/u);
  assert.doesNotMatch(application, /Owner\/Admin может выдать недостающие wrappers/u);
  assert.match(teamSynchronization, /export async function provisionTeamVaultWrappers/u);
  assert.match(application, /rotateTeamVault/u);
  assert.match(application, /teamDevicePublicKeyFingerprint/u);
  assert.match(application, /client\.approveDeviceKey/u);
  assert.match(application, /client\.listTeamMembershipDevices/u);
  assert.match(application, /client\.admitTeamMembershipDevice/u);
  assert.match(application, /client\.getTeamDeviceAdmissionPolicy/u);
  assert.match(application, /client\.updateTeamDeviceAdmissionPolicy/u);
  assert.match(application, /createConfirmationRequester/u);
  assert.match(application, /Доступ будет ограничен текущим членством в этой Team/u);
  assert.match(application, /client\.revokeDevice/u);
  assert.match(application, /client\.renameTeam/u);
  assert.match(application, /client\.transferTeamOwnership/u);
  assert.match(application, /client\.archiveTeam/u);
  assert.match(application, /createIndexedDBTeamVaultRepository[\s\S]*\.remove\(\)/u);
  assert.match(application, /resolveConflicts/u);
  assert.match(application, /recoveryPassphrase/u);
  assert.doesNotMatch(`${application}\n${teamSynchronization}`, /localStorage|sessionStorage/u);
  assert.doesNotMatch(synchronization, /localStorage/u);
  assert.match(synchronization, /unsupported_vault_scope/u);
  assert.match(synchronization, /credentials: "same-origin"/u);
  assert.match(teamSynchronization, /team_vault_rotation_required/u);
  assert.match(teamSynchronization, /prepareInitialization/u);
});
