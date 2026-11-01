import assert from "node:assert/strict";
import test from "node:test";
import { IDBFactory } from "fake-indexeddb";
import { initializeCloudAccount } from "../public/app.js";
import { createIndexedDBVaultRepository, createLocalVaultController } from "../public/vault-local.js";

const accountA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const accountB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const device = "11111111-1111-4111-8111-111111111111";

class Element {
  constructor() {
    this.handlers = {};
    this.classList = { toggle() {}, remove() {}, add() {} };
    this.elements = new Proxy({}, { get: (object, key) => object[key] ??= { value: "" } });
  }
  addEventListener(type, listener) { this.handlers[type] = listener; }
  setAttribute() {}
  querySelector() { return this.button ??= new Element(); }
  querySelectorAll() { return []; }
  replaceChildren() {}
  reset() {}
}

test("an obsolete manual sync cannot sign out the newer session presentation", async () => {
  globalThis.indexedDB = new IDBFactory();
  globalThis.BroadcastChannel = undefined;
  const nodes = new Map(), documentValue = {
    documentElement: { lang: "en" }, defaultView: {}, addEventListener() {}, querySelectorAll() { return []; },
    querySelector(selector) {
      if (selector === "#team-vault") return null;
      if (!nodes.has(selector)) nodes.set(selector, new Element());
      return nodes.get(selector);
    },
  };
  let release, entered;
  const held = new Promise(resolve => { release = resolve; });
  const started = new Promise(resolve => { entered = resolve; });
  const fetchValue = async (path, options = {}) => {
    if (path === "/v1/me") return Response.json({ error: "unauthorized" }, { status: 401 });
    if (path === "/v1/auth/login") {
      const email = JSON.parse(options.body).email, isA = email.startsWith("a");
      return Response.json({ token: (isA ? "a" : "b").repeat(43),
        user: { id: isA ? accountA : accountB, email, username: isA ? "a" : "b" }, deviceID: device });
    }
    if (path === "/v1/vault") {
      entered(); await held;
      return Response.json({ id: "99999999-9999-4999-8999-999999999999", revision: 0, envelopeVersion: 1,
        wrappedKey: null, ciphertext: null, nonce: null, authTag: null, contentHash: null, updatedAt: null });
    }
    throw Error("unexpected_test_request");
  };
  const vault = { status: async () => "unlocked" };
  const vaultUI = { controller: vault, repository: {}, setConflictResetListener() {}, setLockListener() {},
    clearConflictUI() {}, mode() {}, render() {} };
  const presentation = [];
  const app = await initializeCloudAccount({ documentValue, vaultUI, fetchValue,
    onSessionChange: user => presentation.push(user?.id ?? null) });
  await app.client.login({ email: "a@example.invalid", password: "synthetic password", deviceID: device });
  presentation.length = 0;
  const sync = nodes.get("#cloud-vault-sync").handlers.click({});
  await started;
  await app.client.login({ email: "b@example.invalid", password: "synthetic password", deviceID: device });
  release();
  await sync;
  assert.equal(app.client.session().id, accountB);
  assert.deepEqual(presentation, []);
});

test("startup does not announce a restored session after background invalidation", async () => {
  globalThis.indexedDB = new IDBFactory();
  globalThis.BroadcastChannel = undefined;
  globalThis.sessionStorage = { getItem: () => accountA, setItem() {}, removeItem() {} };
  const nodes = new Map(), documentValue = {
    documentElement: { lang: "en" }, defaultView: {}, addEventListener() {}, querySelectorAll() { return []; },
    querySelector(selector) {
      if (selector === "#team-vault") return null;
      if (!nodes.has(selector)) nodes.set(selector, new Element());
      return nodes.get(selector);
    },
  };
  const repository = createIndexedDBVaultRepository();
  const initial = createLocalVaultController({ repository: repository.forAccount(accountA) });
  await initial.create("synthetic password");
  await initial.rememberSession(accountA);
  const fetchValue = async path => {
    if (path === "/v1/me") return Response.json({ id: accountA, email: "a@example.invalid", username: "a", deviceID: device },
      { headers: { "X-Selective-Session-Binding": accountA } });
    if (path === "/v1/vault") return Response.json({ error: "browser_session_changed" }, { status: 409 });
    throw Error("unexpected_test_request");
  };
  const vaultUI = { controller: createLocalVaultController({ repository }), repository,
    setConflictResetListener() {}, setLockListener() {}, clearConflictUI() {},
    useController(next) { this.controller = next; }, mode() {}, render() {} };
  const app = await initializeCloudAccount({ documentValue, vaultUI, fetchValue });
  assert.equal(app.client.session(), null);
  assert.equal(await vaultUI.controller.status(), "locked");
  assert.doesNotMatch(nodes.get("#cloud-account-message").textContent, /Сессия восстановлена/u);
});

test("an obsolete reauthentication cannot mark the newer session failed or retain its password", async () => {
  globalThis.indexedDB = new IDBFactory();
  globalThis.BroadcastChannel = undefined;
  const nodes = new Map(), documentValue = {
    documentElement: { lang: "en" }, defaultView: {}, addEventListener() {}, querySelectorAll() { return []; },
    querySelector(selector) {
      if (selector === "#team-vault") return null;
      if (!nodes.has(selector)) nodes.set(selector, new Element());
      return nodes.get(selector);
    },
  };
  let release, entered, requestsA = 0;
  const held = new Promise(resolve => { release = resolve; });
  const started = new Promise(resolve => { entered = resolve; });
  const fetchValue = async (path, options = {}) => {
    if (path === "/v1/me") return Response.json({ error: "unauthorized" }, { status: 401 });
    if (path === "/v1/auth/login") {
      const email = JSON.parse(options.body).email, isA = email.startsWith("a");
      if (isA && ++requestsA === 2) { entered(); await held; }
      return Response.json({ token: (isA ? "a" : "b").repeat(43),
        user: { id: isA ? accountA : accountB, email, username: isA ? "a" : "b" }, deviceID: device });
    }
    throw Error("unexpected_test_request");
  };
  const modes = [], vault = { status: async () => "locked", lock() {} };
  const vaultUI = { controller: vault, repository: {}, setConflictResetListener() {}, setLockListener() {},
    clearConflictUI() {}, mode(value) { modes.push(value); }, render() {} };
  const app = await initializeCloudAccount({ documentValue, vaultUI, fetchValue });
  await app.client.login({ email: "a@example.invalid", password: "synthetic password", deviceID: device });
  const form = nodes.get("#local-vault-reauthenticate-form");
  form.elements.password.value = "synthetic password";
  const pending = form.handlers.submit({ preventDefault() {} });
  await started;
  await app.client.login({ email: "b@example.invalid", password: "synthetic password", deviceID: device });
  release();
  await pending;
  assert.equal(app.client.session().id, accountB);
  assert.deepEqual(modes, ["restoring"]);
  assert.equal(form.elements.password.value, "");
  assert.equal(form.querySelector().disabled, false);
});

test("reauthentication returns to sign-in when its own session is invalidated", async () => {
  globalThis.indexedDB = new IDBFactory();
  globalThis.BroadcastChannel = undefined;
  globalThis.sessionStorage = { getItem: () => null, setItem() {}, removeItem() {} };
  const nodes = new Map(), documentValue = {
    documentElement: { lang: "en" }, defaultView: {}, addEventListener() {}, querySelectorAll() { return []; },
    querySelector(selector) {
      if (selector === "#team-vault") return null;
      if (!nodes.has(selector)) nodes.set(selector, new Element());
      return nodes.get(selector);
    },
  };
  const fetchValue = async path => {
    if (path === "/v1/me" || path === "/v1/vault") return Response.json({ error: "unauthorized" }, { status: 401 });
    if (path === "/v1/auth/login") return Response.json({ token: "a".repeat(43),
      user: { id: accountA, email: "a@example.invalid", username: "a" }, deviceID: device });
    throw Error("unexpected_test_request");
  };
  const repository = createIndexedDBVaultRepository(), changes = [];
  const vaultUI = { controller: createLocalVaultController({ repository }), repository,
    setConflictResetListener() {}, setLockListener() {}, clearConflictUI() {},
    useController(value) { this.controller = value; }, mode() {}, render() {} };
  const app = await initializeCloudAccount({ documentValue, vaultUI, fetchValue,
    onSessionChange: user => changes.push(user?.id ?? null) });
  await app.client.login({ email: "a@example.invalid", password: "synthetic password", deviceID: device });
  changes.length = 0;
  const form = nodes.get("#local-vault-reauthenticate-form");
  form.elements.password.value = "synthetic password";
  await form.handlers.submit({ preventDefault() {} });
  assert.equal(app.client.session(), null);
  assert.deepEqual(changes, [null]);
});
