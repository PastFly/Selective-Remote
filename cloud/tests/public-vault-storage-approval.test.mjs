import assert from "node:assert/strict";
import test from "node:test";
import { IDBFactory } from "fake-indexeddb";
import { deferVaultStorageForPortal, initializePortal, initializePortalNavigation, prepareVaultStorageForPortal } from "../public/app.js";

function openOld(indexedDB) {
  const request = indexedDB.open("selective-remote-cloud", 1);
  request.onupgradeneeded = () => request.result.createObjectStore("local-vault");
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

test("portal waits for explicit approval before upgrading legacy browser storage", async () => {
  const indexedDB = new IDBFactory();
  (await openOld(indexedDB)).close();
  let entered, release;
  const asked = new Promise(resolve => { entered = resolve; });
  const confirmation = new Promise(resolve => { release = resolve; });
  const pending = prepareVaultStorageForPortal({ indexedDBValue: indexedDB, requestApproval: async () => {
    entered(); return confirmation;
  } });
  await asked;
  const old = await openOld(indexedDB);
  assert.equal(old.version, 1);
  old.close();
  release(true);
  await pending;
  await assert.rejects(openOld(indexedDB), error => error?.name === "VersionError");
});

test("declining the portal upgrade leaves old storage usable", async () => {
  const indexedDB = new IDBFactory();
  (await openOld(indexedDB)).close();
  await assert.rejects(prepareVaultStorageForPortal({ indexedDBValue: indexedDB,
    requestApproval: async () => false }), /vault_storage_upgrade_cancelled/u);
  const old = await openOld(indexedDB);
  assert.equal(old.version, 1);
  old.close();
});

test("approval is not reused if another tab already completed the upgrade", async () => {
  const indexedDB = new IDBFactory();
  (await openOld(indexedDB)).close();
  await prepareVaultStorageForPortal({ indexedDBValue: indexedDB, requestApproval: async () => {
    const request = indexedDB.open("selective-remote-cloud", 2);
    const db = await new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    db.close();
    return true;
  } });
  await new Promise((resolve, reject) => {
    const request = indexedDB.deleteDatabase("selective-remote-cloud");
    request.onsuccess = resolve;
    request.onerror = () => reject(request.error);
  });
  (await openOld(indexedDB)).close();
  let approvals = 0;
  await assert.rejects(prepareVaultStorageForPortal({ indexedDBValue: indexedDB,
    requestApproval: async () => { approvals++; return false; } }), /vault_storage_upgrade_cancelled/u);
  assert.equal(approvals, 1);
  const old = await openOld(indexedDB);
  assert.equal(old.version, 1);
  old.close();
});

test("blocked upgrade settles before asking for a fresh approval and retry", async () => {
  const indexedDB = new IDBFactory();
  const old = await openOld(indexedDB);
  let notifyBlocked;
  const blocked = new Promise(resolve => { notifyBlocked = resolve; });
  const prompts = [];
  const pending = prepareVaultStorageForPortal({ indexedDBValue: indexedDB,
    requestApproval: async ({ reason }) => { prompts.push(reason); return prompts.length === 1; },
    onBlocked: () => notifyBlocked(),
  });
  await blocked;
  assert.deepEqual(prompts, ["confirmation"]);
  old.close();
  await assert.rejects(pending, /vault_storage_upgrade_cancelled/u);
  assert.deepEqual(prompts, ["confirmation", "blocked"]);
  const oldAgain = await openOld(indexedDB);
  assert.equal(oldAgain.version, 1);
  oldAgain.close();
});

test("a user can leave a blocked upgrade for limited mode without authorizing a later upgrade", { timeout: 1000 }, async () => {
  const indexedDB = new IDBFactory();
  const old = await openOld(indexedDB);
  let cancel, notifyBlocked;
  const cancelled = new Promise(resolve => { cancel = resolve; });
  const blocked = new Promise(resolve => { notifyBlocked = resolve; });
  let approvals = 0;
  const pending = prepareVaultStorageForPortal({ indexedDBValue: indexedDB,
    requestApproval: async () => { approvals++; return true; },
    onBlocked: () => { notifyBlocked(); return cancelled; },
  });
  try {
    await blocked;
    cancel();
    await assert.rejects(pending, /vault_storage_upgrade_cancelled/u);
    assert.equal(approvals, 1);
  } finally { old.close(); }
  const reopened = await openOld(indexedDB);
  assert.equal(reopened.version, 1);
  reopened.close();
});

test("deferring upgrade keeps public Cloud controls and offers a retry", () => {
  const shell = { hidden: false }, notice = { hidden: true }, button = {};
  let reloads = 0;
  const elements = { ".shell": shell, "#vault-storage-deferred": notice, "#vault-storage-retry": button };
  deferVaultStorageForPortal({ documentValue: { querySelector: selector => elements[selector] },
    locationValue: { reload() { reloads++; } } });
  assert.equal(shell.hidden, false);
  assert.equal(notice.hidden, false);
  button.onclick();
  assert.equal(reloads, 1);
});

test("an invitation fragment is not consumed when storage preparation is deferred", async () => {
  const shell = { hidden: false }, notice = { hidden: true }, button = {}, detail = {};
  const status = { classList: { add() {}, remove() {} } };
  const elements = { ".shell": shell, "#vault-storage-deferred": notice,
    "#vault-storage-retry": button, "#vault-storage-deferred-detail": detail, "#service-status": status };
  const documentValue = { documentElement: { dataset: {} }, querySelector: selector => elements[selector] ?? null,
    querySelectorAll: () => [] };
  const locationValue = { hash: "#accept-team-invitation?token=synthetic", pathname: "/", search: "", reload() {} };
  let replacements = 0;
  await initializePortal({ documentValue, locationValue, historyValue: { replaceState() { replacements++; } },
    fetchValue: async () => new Response("{}", { status: 503 }) });
  assert.equal(replacements, 0);
  assert.equal(locationValue.hash, "#accept-team-invitation?token=synthetic");
  assert.equal(notice.hidden, false);
});

test("deferred invitation survives login and restored-session navigation", () => {
  const fragment = "#accept-team-invitation?token=synthetic";
  const locationValue = { pathname: "/", search: "", hash: fragment };
  const names = ["#site-brand", "#public-actions", "#public-hero", "#public-hero-copy", "#cloud-hero-preview",
    "#cloud-account", "#cloud-auth-back", "#public-grid", "#public-access", "#cloud-workspace"];
  const elements = Object.fromEntries(names.map(name => [name, {
    hidden: false, classList: { add() {}, remove() {} }, addEventListener() {}, focus() {},
  }]));
  const documentValue = { documentElement: {}, querySelector: selector => elements[selector] ?? null,
    querySelectorAll: () => [], addEventListener() {} };
  const historyValue = { pushState(_state, _unused, url) {
    const parsed = new URL(url, "https://synthetic.invalid");
    locationValue.pathname = parsed.pathname; locationValue.hash = parsed.hash;
  }, replaceState(_state, _unused, url) { this.pushState(_state, _unused, url); } };
  const view = initializePortalNavigation({ documentValue, locationValue, historyValue,
    deferredInvitationFragment: fragment });
  view.showAuthentication();
  assert.equal(locationValue.hash, fragment);
  view.sessionChanged({ id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" });
  assert.equal(locationValue.pathname, "/app");
  assert.equal(locationValue.hash, fragment);
});

test("email verification remains available without opening browser Vault storage", async () => {
  const panel = { hidden: true, classList: { add() {} } }, title = {}, message = {}, home = { hidden: true };
  const elements = { "#email-verification": panel, "#verification-title": title,
    "#verification-message": message, "#verification-home": home };
  const documentValue = { documentElement: { dataset: {} }, querySelector: selector => elements[selector] ?? null };
  const locationValue = { hash: "#verify-email?token=synthetic", pathname: "/", search: "" };
  const requests = [];
  await initializePortal({ documentValue, locationValue, historyValue: { replaceState() {} }, fetchValue: async path => {
    requests.push(path); return new Response(JSON.stringify({ verified: true }), { status: 200 });
  } });
  assert.deepEqual(requests, ["/v1/auth/verify-email"]);
  assert.equal(panel.hidden, false);
  assert.equal(home.hidden, false);
  assert.equal(title.textContent, "Email подтверждён");
  assert.equal(documentValue.documentElement.dataset.accountActionOnly, "true");
});

test("password reset remains usable without opening browser Vault storage", async () => {
  let submit;
  const panel = { hidden: true, classList: { add() {} } }, title = {}, message = {}, home = { hidden: true };
  const password = { value: "synthetic new password" }, confirmation = { value: password.value };
  const button = { disabled: false }, form = { hidden: false, querySelector: () => button,
    addEventListener(_name, handler) { submit = handler; } };
  const elements = { "#password-reset": panel, "#password-reset-form": form, "#password-reset-title": title,
    "#password-reset-message": message, "#new-password": password, "#confirm-password": confirmation,
    "#password-reset-home": home };
  const documentValue = { documentElement: { dataset: {} }, querySelector: selector => elements[selector] ?? null };
  const locationValue = { hash: "#reset-password?token=synthetic", pathname: "/", search: "" };
  const requests = [];
  await initializePortal({ documentValue, locationValue, historyValue: { replaceState() {} }, fetchValue: async path => {
    requests.push(path); return new Response(JSON.stringify({ reset: true }), { status: 200 });
  } });
  assert.deepEqual(requests, []);
  assert.equal(documentValue.documentElement.dataset.accountActionOnly, "true");
  await submit({ preventDefault() {} });
  assert.deepEqual(requests, ["/v1/auth/reset-password"]);
  assert.equal(home.hidden, false);
  assert.match(message.textContent, /ключи.*не изменены и не восстановлены/iu);
});
