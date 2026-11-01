import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { readFile } from "node:fs/promises";
import { runInNewContext } from "node:vm";
import test from "node:test";
import {
  captureTeamWorkspaceContext,
  maintainAccessibleTeamVaultWrappers,
  preprovisionTeamInvitationWrappers,
  sessionRetiredByError,
  teamWorkspaceContextMatches,
  teamSyncTargetMatches,
  teamVaultEditTargetMatches,
  teamVaultRecordOperations,
  teamRecordEditorMatches,
  teamHostConnectionData,
  teamHostRecordData,
} from "../public/app.js";
import { createAuthenticatedVaultClient } from "../public/vault-sync.js";

const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");

function deferred() {
  let resolve;
  const promise = new Promise((complete) => { resolve = complete; });
  return { promise, resolve };
}

function fixture() {
  let generation = "1", session = { id: "synthetic-account" };
  const identity = { deviceID: "synthetic-device" };
  const client = { session: () => session,
    deviceID: () => identity.deviceID, sessionGeneration: () => generation };
  const effects = [];
  const firstController = { syncState: async () => ({ keyGeneration: 1 }), status: async () => "unlocked",
    lock() { effects.push("controller locked"); } };
  const firstTeam = { id: "team-a", role: "owner" };
  const firstVault = { id: "vault-a", rotationRequired: false, revision: 1 };
  const context = {
    client, identity, controller: firstController, selectedTeam: firstTeam, selectedVault: firstVault,
    teamActivationEpoch: 1, teamVaultLockEpoch: 0, teamVaultManuallyLocked: false,
    selectedTeamRequestGeneration: 1, inviteOperationGeneration: 0,
    publicationClient: null, publicationSelection: 0, publicationAccessDriver: null, publicationAccessTeamID: null,
    transientTeamControllers: new Set(), recordSavePending: false, recordSaveOperation: null,
    inviteForm: null, recordForm: null,
    sessionRetiredByError, onSessionRetired: () => effects.push("session retired"),
    teamSyncTargetMatches, workspace: { dataset: {} }, recordCreate: {}, recordEditor: null,
    documentValue: {}, vaults: [firstVault], vaultSelect: {}, workspaceStatus: {},
    records: { replaceChildren() { effects.push("records cleared"); } },
    lockButton: {}, rotateButton: {}, activeConflicts: null, vaultOperation: null,
    canManage: () => true, publishSyncObservation: () => effects.push("observation"),
    exclusiveVaultOperation: async (operation) => operation(),
    setRecoveryControls: () => effects.push("recovery"), setWorkspaceControls: () => effects.push("controls"),
    stopBackgroundSync: () => effects.push("stop"), startBackgroundSync: () => effects.push("start"),
    lockTransientTeamControllers() {},
    createTrackedTeamVaultController() {},
    resetRecordEditor: () => effects.push("editor reset"),
    resetSnippetBrowser: ({ lock } = {}) => effects.push(lock ? "snippet browser locked" : "snippet browser reset"),
    populateVaults: () => effects.push("vaults"), clearConflicts: () => effects.push("clear"),
    renderRecords: () => effects.push("render"), renderConflicts: () => effects.push("conflicts"),
    setText: () => effects.push("text"),
  };
  context.captureWorkspaceContext = () => captureTeamWorkspaceContext({
    client, identity, activationEpoch: context.teamActivationEpoch,
  });
  context.workspaceContextCurrent = (captured) => teamWorkspaceContextMatches(captured, {
    client, identity, activationEpoch: context.teamActivationEpoch,
  });
  return { context, effects, firstController, firstTeam, firstVault,
    replaceSession() { generation = "2"; },
    retireSession() { session = null; generation = "2"; },
    replaceSelection() {
      context.controller = { name: "other controller" };
      context.selectedTeam = { id: "team-b", role: "owner" };
      context.selectedVault = { id: "vault-b", revision: 11, rotationRequired: true };
      context.vaults = [context.selectedVault];
    },
  };
}

function installSynchronize(context) {
  const start = source.indexOf("  async function synchronizeAndProvision(");
  const end = source.indexOf("\n  function applySynchronizationOutcome", start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(source.slice(start, end) + "\nglobalThis.run = synchronizeAndProvision;", context);
}

function installRotation(context) {
  const start = source.indexOf('  rotateButton.addEventListener("click", async () => {');
  const end = source.indexOf('\n  grantWrappersButton.addEventListener', start);
  assert.ok(start >= 0 && end > start);
  context.rotateButton.addEventListener = (_name, callback) => { context.run = callback; };
  runInNewContext(source.slice(start, end), context);
}

function installTeamLock(context) {
  const start = source.indexOf('  lockButton.addEventListener("click", () => {', source.indexOf("export function initializeTeamWorkspace"));
  const end = source.indexOf('\n  conflictForm.addEventListener', start);
  assert.ok(start >= 0 && end > start);
  context.lockButton.addEventListener = (_name, callback) => { context.lock = callback; };
  runInNewContext(source.slice(start, end), context);
}

function installLockCurrentVault(context) {
  const start = source.indexOf("  function lockCurrentVault(");
  const end = source.indexOf("\n  function setView(", start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(source.slice(start, end) + "\nglobalThis.closeSelection = lockCurrentVault;", context);
}

function installBackgroundTimer(context) {
  const start = source.indexOf("  function stopBackgroundSync()");
  const end = source.indexOf("\n  async function exclusiveVaultOperation", start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(source.slice(start, end), context);
}

function installExclusiveOperation(context) {
  const start = source.indexOf("  async function exclusiveVaultOperation(");
  const end = source.indexOf("\n  async function maintainSelectedTeamVaults", start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(source.slice(start, end) + "\nglobalThis.runExclusive = exclusiveVaultOperation;", context);
}

function installTeamMaintenance(context) {
  const start = source.indexOf("  async function maintainSelectedTeamVaults()");
  const end = source.indexOf("\n  async function synchronizeAndProvision", start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(source.slice(start, end) + "\nglobalThis.runMaintenance = maintainSelectedTeamVaults;", context);
}

function installManualSync(context) {
  const start = source.indexOf('  syncButton.addEventListener("click", async () => {', source.indexOf("export function initializeTeamWorkspace"));
  const end = source.indexOf('\n  lockButton.addEventListener("click", () => {', start);
  assert.ok(start >= 0 && end > start);
  context.syncButton = { addEventListener(_name, callback) { context.runManualSync = callback; } };
  runInNewContext(source.slice(start, end), context);
}

function installOpenSelectedVault(context) {
  const start = source.indexOf("  async function openSelectedVault()");
  const end = source.indexOf("\n  async function loadSelectedTeam", start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(source.slice(start, end) + "\nglobalThis.openVault = openSelectedVault;", context);
}

function installTeamView(context) {
  const start = source.indexOf("  function setView(view, recordFilter");
  const end = source.indexOf("\n  async function openSelectedVault", start);
  assert.ok(start >= 0 && end > start);
  runInNewContext(source.slice(start, end) + "\nglobalThis.changeView = setView;", context);
}

test("Team session retirement locks Personal data and shows sign-in only for the retired session", () => {
  const start = source.indexOf("  function retireCurrentTeamSession(error, generation)");
  const end = source.indexOf("\n  const teamWorkspace =", start);
  assert.ok(start >= 0 && end > start);
  let generation = "2", session = null;
  const effects = [];
  const context = {
    client: { session: () => session, sessionGeneration: () => generation },
    sessionRetiredByError,
    retiredSessionGeneration: null,
    vault: { lock() { effects.push("vault locked"); } },
    hideConflicts() { effects.push("conflicts hidden"); },
    vaultUI: { mode(value) { effects.push(`mode:${value}`); } },
    showSession(value) { effects.push(`session:${value}`); },
    setAccountMessage(value) { effects.push(value); },
  };
  runInNewContext(source.slice(start, end) + "\nglobalThis.retire = retireCurrentTeamSession;", context);
  const error = Object.assign(new Error("authentication_required"), { invalidatedSessionEpoch: "1" });
  context.retire(error, "1");
  assert.deepEqual(effects.slice(0, 4), ["vault locked", "conflicts hidden", "mode:waiting", "session:null"]);
  assert.match(effects[4], /истекла/iu);
  effects.length = 0;
  session = { id: "new-account" };
  generation = "3";
  context.retire(error, "1");
  assert.deepEqual(effects, []);
});

test("a first 401 from background Team refresh closes the actual browser session", async () => {
  const deviceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  const accountID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  const response = (status, value) => new Response(JSON.stringify(value), {
    status, headers: { "Content-Type": "application/json" },
  });
  const client = createAuthenticatedVaultClient({ sessionStorageValue: null, fetchValue: async (path) => (
    path === "/v1/auth/login"
      ? response(200, { token: "t".repeat(43), deviceID, user: { id: accountID, email: "synthetic@example.invalid" } })
      : response(401, { error: "unauthorized" })
  ) });
  await client.login({ email: "synthetic@example.invalid", password: "synthetic-password", deviceID });
  const effects = [], context = { client, sessionRetiredByError, retiredSessionGeneration: null,
    vault: { lock() { effects.push("vault locked"); } },
    hideConflicts() { effects.push("conflicts hidden"); },
    vaultUI: { mode(value) { effects.push(`mode:${value}`); } },
    showSession(value) { effects.push(`session:${value}`); },
    setAccountMessage(value) { effects.push(value); } };
  const functionStart = source.indexOf("  function retireCurrentTeamSession(error, generation)");
  const functionEnd = source.indexOf("\n  const teamWorkspace =", functionStart);
  const listenerStart = source.indexOf("  client.subscribePublicationIdentity((cause) => {", functionEnd);
  const listenerEnd = source.indexOf("\n  const accountDevices", listenerStart);
  assert.ok(functionStart >= 0 && functionEnd > functionStart && listenerStart > functionEnd && listenerEnd > listenerStart);
  runInNewContext(source.slice(functionStart, functionEnd) + source.slice(listenerStart, listenerEnd), context);
  await assert.rejects(client.listPendingTeamInvitations(), /authentication_required/u);
  assert.equal(client.session(), null);
  assert.deepEqual(effects.slice(0, 4), ["vault locked", "conflicts hidden", "mode:waiting", "session:null"]);
  assert.equal(effects.filter((value) => value === "vault locked").length, 1);
});

test("an anonymous startup 401 does not announce an expired signed-in session", async () => {
  const client = createAuthenticatedVaultClient({ sessionStorageValue: null, fetchValue: async () => new Response(
    JSON.stringify({ error: "unauthorized" }), { status: 401, headers: { "Content-Type": "application/json" } },
  ) });
  const effects = [], context = { client, sessionRetiredByError, retiredSessionGeneration: null,
    vault: { lock() { effects.push("vault locked"); } }, vaultUI: { mode() { effects.push("mode"); } },
    hideConflicts() { effects.push("conflicts hidden"); },
    showSession() { effects.push("show session"); }, setAccountMessage() { effects.push("message"); } };
  const functionStart = source.indexOf("  function retireCurrentTeamSession(error, generation)");
  const functionEnd = source.indexOf("\n  const teamWorkspace =", functionStart);
  const listenerStart = source.indexOf("  client.subscribePublicationIdentity((cause) => {", functionEnd);
  const listenerEnd = source.indexOf("\n  const accountDevices", listenerStart);
  assert.ok(functionStart >= 0 && functionEnd > functionStart && listenerStart > functionEnd && listenerEnd > listenerStart);
  runInNewContext(source.slice(functionStart, functionEnd) + source.slice(listenerStart, listenerEnd), context);
  await assert.rejects(client.restoreSession(), /authentication_required/u);
  assert.deepEqual(effects, []);
});

function installInvitation(context) {
  const start = source.indexOf('  inviteForm.addEventListener("submit", async (event) => {');
  const end = source.indexOf('\n  inviteEmailSubmit.addEventListener', start);
  assert.ok(start >= 0 && end > start);
  const button = { disabled: false };
  context.inviteButton = button;
  context.inviteForm = {
    elements: { username: { value: "synthetic-user" }, role: { value: "editor" } },
    addEventListener(_name, callback) { context.run = callback; },
    querySelector() { return button; },
    reset() { context.effects.push("form reset"); },
  };
  context.inviteLinkResult = {};
  context.inviteLinkValue = {};
  context.message = {};
  context.effects = context._effects;
  context.loadSelectedTeam = async () => context.effects.push("team reload");
  runInNewContext(source.slice(start, end), context);
}

function installTeamRecordSave(context) {
  const start = source.indexOf('  recordForm.addEventListener("submit", async (event) => {', source.indexOf("export function initializeTeamWorkspace"));
  const end = source.indexOf("\n  recordCreate.addEventListener", start);
  assert.ok(start >= 0 && end > start);
  context.recordForm.addEventListener = (_name, callback) => { context.saveRecord = callback; };
  runInNewContext(source.slice(start, end), context);
}

test("closing a Team Vault stops sync and clears the unlocked editor and records", () => {
  const f = fixture();
  installLockCurrentVault(f.context);
  f.context.closeSelection();
  assert.equal(f.context.controller, null);
  assert.equal(f.context.selectedVault, null);
  assert.equal(f.context.workspace.hidden, true);
  assert.equal(f.context.recordCreate.hidden, true);
  assert.deepEqual(f.effects.slice(0, 4), ["stop", "editor reset", "snippet browser locked", "observation"]);
  assert.ok(f.effects.includes("controller locked"));
  assert.ok(f.effects.includes("records cleared"));
});

test("a stale Team operation cannot block or release a newer selection's operation", async () => {
  const f = fixture(), enteredA = deferred(), enteredB = deferred(), releaseA = deferred(), releaseB = deferred();
  f.context.vaultOperation = null;
  installExclusiveOperation(f.context);
  installLockCurrentVault(f.context);
  const first = f.context.runExclusive(async () => { enteredA.resolve(); await releaseA.promise; return "first"; });
  await enteredA.promise;
  f.context.closeSelection();
  f.replaceSelection();
  const second = f.context.runExclusive(async () => { enteredB.resolve(); await releaseB.promise; return "second"; });
  const secondStarted = await Promise.race([enteredB.promise.then(() => true), second.then(() => false)]);
  assert.equal(secondStarted, true);
  releaseA.resolve();
  assert.equal(await first, "first");
  assert.equal(await f.context.runExclusive(async () => "unexpected overlap"), null);
  releaseB.resolve();
  assert.equal(await second, "second");
  assert.equal(await f.context.runExclusive(async () => "available"), "available");
});

test("Team Lock stops an already running temporary rotation controller", async () => {
  const f = fixture(), entered = deferred(), resume = deferred();
  let locked = false, writes = 0;
  const temporary = { lock() { locked = true; } };
  f.context.selectedVault = { ...f.firstVault, rotationRequired: true };
  f.context.vaults = [f.context.selectedVault];
  f.context.backgroundMaintenanceOperation = null;
  f.context.client.accessClient = () => ({ getContext: async () => ({ formatState: "V1_ACTIVE" }) });
  f.context.client.listSharedVaults = async () => [];
  f.context.createTeamVaultController = () => temporary;
  f.context.maintainAccessibleTeamVaultWrappers = (options) => maintainAccessibleTeamVaultWrappers({
    ...options, repositoryFactory: () => ({}),
    controllerFactory: options.controllerFactory ?? (() => temporary),
    rotate: async () => {
      entered.resolve();
      await resume.promise;
      if (locked) throw new Error("team_vault_locked");
      writes++;
      return { status: "rotated" };
    },
  });
  installExclusiveOperation(f.context);
  installTeamMaintenance(f.context);
  installTeamLock(f.context);
  const pending = f.context.runMaintenance();
  await entered.promise;
  f.context.lock();
  const wasLockedAtClick = locked;
  resume.resolve();
  await pending;
  assert.equal(wasLockedAtClick, true);
  assert.equal(writes, 0);
});

test("an old manual sync cannot restart the background timer after Team Lock", async () => {
  const f = fixture(), pendingSync = deferred();
  let scheduled = 0;
  f.context.backgroundSyncTimer = null;
  f.context.backgroundSyncIntervalMilliseconds = 1000;
  f.context.setIntervalValue = () => { scheduled++; return { unref() {} }; };
  f.context.clearIntervalValue = () => {};
  f.context.runBackgroundTeamVaultSync = () => {};
  f.context.synchronizeAndProvision = () => pendingSync.promise;
  f.context.applySynchronizationOutcome = () => {};
  installBackgroundTimer(f.context);
  installManualSync(f.context);
  installTeamLock(f.context);
  const pending = f.context.runManualSync();
  f.context.lock();
  pendingSync.resolve(null);
  await pending;
  assert.equal(scheduled, 0);
});

test("an explicit Sync after Team Lock keeps the view locked until unlock completes", async () => {
  const f = fixture(), entered = deferred(), resume = deferred();
  f.context.teamVaultManuallyLocked = true;
  f.context.resolveTeamVaultFormat = async () => "V1_ACTIVE";
  f.context.synchronizeTeamVault = async () => {
    entered.resolve();
    await resume.promise;
    return { status: "up_to_date", revision: 1 };
  };
  f.context.provisionTeamVaultWrappers = async () => ({ granted: 0 });
  f.context.applySynchronizationOutcome = () => {};
  installSynchronize(f.context);
  installManualSync(f.context);
  const pending = f.context.runManualSync();
  await entered.promise;
  assert.equal(f.context.teamVaultManuallyLocked, true);
  resume.resolve();
  await pending;
  assert.equal(f.context.teamVaultManuallyLocked, false);
});

test("a failed explicit Sync leaves Team Vault locked and background sync stopped", async () => {
  const f = fixture();
  let scheduled = 0;
  f.context.teamVaultManuallyLocked = true;
  f.context.resolveTeamVaultFormat = async () => { throw new Error("network_unavailable"); };
  f.context.applySynchronizationOutcome = () => {};
  f.context.teamVaultRecoveryMode = () => "synchronize";
  f.context.teamVaultSynchronizationErrorMessage = () => "retry";
  f.context.backgroundSyncTimer = null;
  f.context.backgroundSyncIntervalMilliseconds = 1000;
  f.context.setIntervalValue = () => { scheduled++; return { unref() {} }; };
  f.context.clearIntervalValue = () => {};
  f.context.runBackgroundTeamVaultSync = () => {};
  installBackgroundTimer(f.context);
  installSynchronize(f.context);
  installManualSync(f.context);
  await f.context.runManualSync();
  assert.equal(f.context.teamVaultManuallyLocked, true);
  assert.equal(scheduled, 0);
});

test("changing Team resource filters while locked keeps records hidden and editing disabled", () => {
  const f = fixture();
  let renderCalls = 0, reopened = 0;
  Object.assign(f.context, {
    teamVaultManuallyLocked: true, activeView: "hosts", activeRecordFilter: "all", section: { dataset: {} },
    selectedRecordIDs: new Set(), sectionTitle: {}, onboarding: {}, membersView: {}, activityView: null,
    accessView: null, accessManager: null, vaultDirectoryView: {}, deviceAdmissionPolicyPanel: {},
    lifecyclePanel: {}, createVaultForm: {}, teamSummary: null, recordType: {},
    canEdit: () => true, updateRecordLabels() {}, updateTeamMessage() {},
    renderRecords() { renderCalls++; throw new Error("locked_controller_rendered"); },
    openSelectedVault() { reopened++; },
  });
  f.context.documentValue.querySelectorAll = () => [];
  installTeamView(f.context);
  assert.doesNotThrow(() => f.context.changeView("hosts", "snippet"));
  assert.equal(renderCalls, 0);
  assert.equal(reopened, 0);
  assert.equal(f.context.recordCreate.disabled, true);
});

for (const step of ["local cache", "format lookup"]) {
  test(`opening a Team Vault cannot resume after Lock during ${step}`, async () => {
    const f = fixture(), entered = deferred(), resume = deferred();
    let formatCalls = 0, controllerCreations = 0;
    f.context.vaultSelect.value = "vault-a";
    f.context.client.publicationIdentity = () => ({
      endpoint: "https://synthetic.invalid", accountID: "synthetic-account",
      deviceID: "synthetic-device", sessionEpoch: "1",
    });
    f.context.createIndexedDBPublicationRepository = () => ({
      async load() {
        if (step === "local cache") { entered.resolve(); await resume.promise; }
        return { payloadReceipt: null };
      },
    });
    f.context.resolveTeamVaultFormat = async () => {
      formatCalls++;
      if (step === "format lookup") { entered.resolve(); await resume.promise; }
      return "V1_ACTIVE";
    };
    f.context.createIndexedDBTeamVaultRepository = () => ({});
    f.context.createTeamVaultController = () => { controllerCreations++; return f.firstController; };
    f.context.deviceTrustRepository = null;
    f.context.activeView = "hosts";
    f.context.workspaceTitle = {};
    f.context.canEdit = () => true;
    f.context.synchronizeAndProvision = async () => null;
    f.context.applySynchronizationOutcome = () => {};
    installLockCurrentVault(f.context);
    installTeamLock(f.context);
    installOpenSelectedVault(f.context);
    const pending = f.context.openVault();
    await entered.promise;
    f.context.lock();
    resume.resolve();
    await pending;
    assert.equal(controllerCreations, 0);
    if (step === "local cache") assert.equal(formatCalls, 0);
  });
}

test("a current 401 while opening a Team Vault retires the visible session", async () => {
  const f = fixture();
  f.context.vaultSelect.value = "vault-a";
  f.context.client.publicationIdentity = () => f.context.client.session() ? ({
    endpoint: "https://synthetic.invalid", accountID: "synthetic-account",
    deviceID: "synthetic-device", sessionEpoch: "1",
  }) : null;
  f.context.createIndexedDBPublicationRepository = () => ({ async load() { return { payloadReceipt: null }; } });
  f.context.resolveTeamVaultFormat = async () => {
    f.retireSession();
    throw Object.assign(new Error("authentication_required"), { invalidatedSessionEpoch: "1" });
  };
  f.context.deviceTrustRepository = null;
  f.context.isPublicationOfflineError = () => false;
  f.context.isPublicationAccessLoss = () => false;
  f.context.publicationCopy = () => "format failed";
  installLockCurrentVault(f.context);
  installOpenSelectedVault(f.context);
  await f.context.openVault();
  assert.ok(f.effects.includes("session retired"));
});

for (const scenario of ["lock", "session"]) {
  test(`format lookup cannot resume Team sync after ${scenario}`, async () => {
    const f = fixture(), format = deferred();
    let started = 0;
    f.context.resolveTeamVaultFormat = () => format.promise;
    f.context.synchronizeTeamVault = async () => { started++; return { status: "up_to_date", revision: 1 }; };
    f.context.provisionTeamVaultWrappers = async () => ({ granted: 0 });
    installSynchronize(f.context);
    const pending = f.context.run();
    if (scenario === "lock") { installTeamLock(f.context); f.context.lock(); } else f.replaceSession();
    const effectsBeforeCompletion = f.effects.length;
    format.resolve("V1_ACTIVE");
    await pending;
    assert.equal(started, 0);
    assert.equal(f.effects.length, effectsBeforeCompletion);
  });
}

test("unchanged Team selection still synchronizes after the format lookup", async () => {
  const f = fixture();
  let started = 0;
  f.context.resolveTeamVaultFormat = async () => "V1_ACTIVE";
  f.context.synchronizeTeamVault = async () => { started++; return { status: "up_to_date", revision: 1 }; };
  f.context.provisionTeamVaultWrappers = async () => ({ granted: 0 });
  installSynchronize(f.context);
  const result = await f.context.run();
  assert.equal(started, 1);
  assert.equal(result.result.status, "up_to_date");
});

test("a current Team format 401 retires the visible session", async () => {
  const f = fixture();
  f.context.resolveTeamVaultFormat = async () => {
    f.retireSession();
    throw Object.assign(new Error("authentication_required"), { invalidatedSessionEpoch: "1" });
  };
  installSynchronize(f.context);
  await f.context.run();
  assert.deepEqual(f.effects, ["session retired"]);
});

test("a late Team 401 cannot retire a newer session", async () => {
  const f = fixture();
  f.context.resolveTeamVaultFormat = async () => {
    f.replaceSession();
    throw Object.assign(new Error("authentication_required"), { invalidatedSessionEpoch: "1" });
  };
  installSynchronize(f.context);
  await f.context.run();
  assert.deepEqual(f.effects, []);
});

for (const stage of ["sync", "wrapper"]) {
  test(`a current Team ${stage} 401 retires the visible session`, async () => {
    const f = fixture();
    f.context.resolveTeamVaultFormat = async () => "V1_ACTIVE";
    const retire = async () => {
      f.retireSession();
      throw Object.assign(new Error("authentication_required"), { invalidatedSessionEpoch: "1" });
    };
    f.context.synchronizeTeamVault = stage === "sync" ? retire : async () => ({ status: "up_to_date", revision: 1 });
    f.context.provisionTeamVaultWrappers = retire;
    installSynchronize(f.context);
    await f.context.run();
    assert.ok(f.effects.includes("session retired"));
  });
}

for (const scenario of ["selection", "session"]) {
  test(`Team rotation confirmation cannot authorize a newer ${scenario}`, async () => {
    const f = fixture(), confirmation = deferred();
    let rotated = 0;
    f.context.requestConfirmation = () => confirmation.promise;
    f.context.rotateTeamVault = async () => { rotated++; return { status: "rotated", revision: 2, keyGeneration: 2 }; };
    installRotation(f.context);
    const pending = f.context.run();
    if (scenario === "selection") f.replaceSelection(); else f.replaceSession();
    confirmation.resolve(true);
    await pending;
    assert.equal(rotated, 0);
    assert.deepEqual(f.effects, []);
  });
}

test("a late Team rotation result cannot repaint a different selection", async () => {
  const f = fixture(), rotation = deferred(), entered = deferred();
  f.context.requestConfirmation = async () => true;
  f.context.rotateTeamVault = () => { entered.resolve(); return rotation.promise; };
  installRotation(f.context);
  installLockCurrentVault(f.context);
  const pending = f.context.run();
  await Promise.race([entered.promise, pending.then(() => { throw new Error("rotation_did_not_start"); })]);
  assert.equal(f.context.lockButton.disabled, true);
  f.context.closeSelection();
  assert.equal(f.context.lockButton.disabled, false);
  f.replaceSelection();
  const effectsBeforeResult = f.effects.length;
  rotation.resolve({ status: "rotated", revision: 2, keyGeneration: 2 });
  await pending;
  assert.equal(f.context.selectedVault.id, "vault-b");
  assert.equal(f.context.selectedVault.revision, 11);
  assert.equal(f.context.selectedVault.rotationRequired, true);
  assert.equal(f.effects.length, effectsBeforeResult);
});

test("a current Team rotation 401 retires the session and restores Lock control", async () => {
  const f = fixture();
  f.context.requestConfirmation = async () => true;
  f.context.rotateTeamVault = async () => {
    f.retireSession();
    throw Object.assign(new Error("authentication_required"), { invalidatedSessionEpoch: "1" });
  };
  installRotation(f.context);
  installLockCurrentVault(f.context);
  f.context.onSessionRetired = () => { f.effects.push("session retired"); f.context.closeSelection(); };
  await f.context.run();
  assert.ok(f.effects.includes("session retired"));
  assert.equal(f.context.controller, null);
  assert.equal(f.context.lockButton.disabled, false);
});

for (const step of ["synchronize", "state", "wrapper"]) {
  test(`Team invitation cannot submit wrappers from an older session after ${step}`, async () => {
    let generation = "1", submitted = 0, locked = 0;
    const entered = deferred(), resume = deferred();
    const client = { session: () => ({ id: "synthetic-account" }), deviceID: () => "device-a",
      sessionGeneration: () => generation,
      async preprovisionTeamInvitationWrappers() { submitted++; return { ready: true, wrappers: 1 }; } };
    const pause = async (name, value) => {
      if (name === step) { entered.resolve(); await resume.promise; }
      return value;
    };
    const invitation = { id: "invite-a", preprovisioning: {
      membershipID: "member-b", membershipEpoch: 1, devices: [{ deviceID: "device-b" }],
      vaults: [{ vaultID: "vault-a", keyGeneration: 1 }],
    } };
    const pending = preprovisionTeamInvitationWrappers({
      client, identity: { deviceID: "device-a" }, team: { id: "team-a", role: "owner" }, invitation,
      repositoryFactory: () => ({}), controllerFactory: () => ({
        syncState: () => pause("state", { keyGeneration: 1 }),
        prepareWrapper: () => pause("wrapper", { deviceID: "device-b" }),
        lock() { locked++; },
      }),
      synchronize: () => pause("synchronize", { status: "up_to_date" }),
    });
    await entered.promise;
    generation = "2";
    resume.resolve();
    await assert.rejects(pending, /authentication_required/u);
    assert.equal(submitted, 0);
    assert.equal(locked, 1);
  });
}

test("a late invitation result does not prepare access for a newer session", async () => {
  const f = fixture(), request = deferred();
  f.context._effects = f.effects;
  let prepared = 0, cancelled = 0;
  f.context.client.inviteTeamMember = () => request.promise;
  f.context.client.cancelTeamInvitation = async () => { cancelled++; };
  f.context.preprovisionTeamInvitationWrappers = async () => { prepared++; return { ready: true }; };
  installInvitation(f.context);
  const pending = f.context.run({ preventDefault() {} });
  f.replaceSession();
  request.resolve({ id: "invite-a", preprovisioning: {} });
  await pending;
  assert.equal(prepared, 0);
  assert.equal(cancelled, 0);
  assert.deepEqual(f.effects, []);
});

test("a stale invitation preparation failure does not cancel in the newer session", async () => {
  const f = fixture(), preparation = deferred();
  f.context._effects = f.effects;
  let cancelled = 0, entered;
  const enteredPreparation = new Promise((resolve) => { entered = resolve; });
  f.context.client.inviteTeamMember = async () => ({ id: "invite-a", preprovisioning: {} });
  f.context.client.cancelTeamInvitation = async () => { cancelled++; };
  f.context.preprovisionTeamInvitationWrappers = () => { entered(); return preparation.promise; };
  installInvitation(f.context);
  const pending = f.context.run({ preventDefault() {} });
  await enteredPreparation;
  f.replaceSession();
  preparation.resolve({ ready: false });
  await pending;
  assert.equal(cancelled, 0);
  assert.deepEqual(f.effects, []);
});

test("a successful Team invitation reports success after its own refresh", async () => {
  const f = fixture();
  f.context._effects = f.effects;
  f.context.client.inviteTeamMember = async () => ({ id: "invite-a", preprovisioning: null });
  installInvitation(f.context);
  f.context.loadSelectedTeam = async () => {
    f.context.selectedTeamRequestGeneration++;
    f.context.teamVaultLockEpoch++;
    f.effects.push("team reload");
  };
  f.context.setText = (_target, value) => { f.effects.push(value); };
  await f.context.run({ preventDefault() {} });
  assert.ok(f.effects.includes("form reset"));
  assert.ok(f.effects.some((value) => /Приглашение по @username создано/u.test(value)));
});

test("a pending invitation in an old Team cannot block or enable a newer Team request", async () => {
  const f = fixture(), requestA = deferred(), requestB = deferred(), enteredA = deferred(), enteredB = deferred();
  f.context._effects = f.effects;
  f.context.client.inviteTeamMember = ({ teamID }) => {
    if (teamID === "team-a") { enteredA.resolve(); return requestA.promise; }
    enteredB.resolve(); return requestB.promise;
  };
  installInvitation(f.context);
  installLockCurrentVault(f.context);
  const first = f.context.run({ preventDefault() {} });
  await enteredA.promise;
  assert.equal(f.context.inviteButton.disabled, true);
  f.context.closeSelection();
  f.replaceSelection();
  assert.equal(f.context.inviteButton.disabled, false);
  const second = f.context.run({ preventDefault() {} });
  await enteredB.promise;
  assert.equal(f.context.inviteButton.disabled, true);
  requestA.resolve({ id: "invite-a", preprovisioning: null });
  await first;
  assert.equal(f.context.inviteButton.disabled, true);
  requestB.resolve({ id: "invite-b", preprovisioning: null });
  await second;
  assert.equal(f.context.inviteButton.disabled, false);
});

test("an old Team record save cannot block or release a newer Vault save", async () => {
  const f = fixture(), enteredA = deferred(), enteredB = deferred(), releaseA = deferred(), releaseB = deferred();
  const controllerA = { document: () => ({ records: [] }), lock() {},
    async applyBatch() { enteredA.resolve(); await releaseA.promise; } };
  const controllerB = { document: () => ({ records: [] }), lock() {},
    async applyBatch() { enteredB.resolve(); await releaseB.promise; } };
  const button = { disabled: false }, value = (text) => ({ value: text, disabled: false });
  Object.assign(f.context, { controller: controllerA, editingPublication: null, recordSavePending: false,
    recordSaveOperation: null, activeConflicts: null, canEdit: () => true, teamVaultEditTargetMatches,
    teamVaultRecordOperations, teamRecordEditorMatches, teamHostConnectionData, teamHostRecordData,
    recordType: value("host"), recordTitle: value("Synthetic"), recordTarget: value("synthetic.invalid"),
    hostProtocol: value("ssh"), hostPort: value("22"), hostUsername: value("test"), hostFolder: value(""),
    hostTags: value(""), hostDescription: value(""), hostRemovePassword: { checked: false }, hostPassword: value(""),
    editingRecordID: null, editingRecordSnapshot: null, draftRecordID: null, draftCredentialID: null,
    recordForm: { querySelector() { return button; } }, showTeamVaultRecordSaveError() {}, crypto: webcrypto });
  f.context.currentEditTarget = () => ({ controller: f.context.controller, teamID: f.context.selectedTeam?.id,
    vaultID: f.context.selectedVault?.id, sessionID: f.context.client.session()?.id,
    sessionGeneration: f.context.client.sessionGeneration() });
  installTeamRecordSave(f.context);
  installLockCurrentVault(f.context);
  const first = f.context.saveRecord({ preventDefault() {} });
  await enteredA.promise;
  f.context.closeSelection();
  f.replaceSelection();
  f.context.controller = controllerB;
  f.context.selectedVault.rotationRequired = false;
  const second = f.context.saveRecord({ preventDefault() {} });
  const secondStarted = await Promise.race([enteredB.promise.then(() => true), second.then(() => false)]);
  assert.equal(secondStarted, true);
  releaseA.resolve();
  await first;
  assert.equal(f.context.recordSavePending, true);
  assert.equal(button.disabled, true);
  releaseB.resolve();
  await second;
  assert.equal(f.context.recordSavePending, false);
});
