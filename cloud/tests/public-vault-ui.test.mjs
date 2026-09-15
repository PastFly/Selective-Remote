import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  accountVaultPassphrase,
  appearancePreference,
  finishPortalBootstrap,
  formatVaultSynchronizationSummary,
  formatVaultTimestamp,
  initializeAppearance,
  localVaultConflictSideSummary,
  localVaultRecordData,
  localVaultRecordFormValues,
  localVaultRecordSummary,
  maintainAccessibleTeamVaultWrappers,
  preprovisionTeamInvitationWrappers,
  parseTeamHostConnection,
  personalHostEditorValues,
  personalHostFolderName,
  personalHostRecordData,
  sortLocalVaultRecords,
  teamHostConnectionData,
  teamHostRecordData,
  teamVaultRecoveryMode,
} from "../public/app.js";

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

test("trusted browser automatically rotates and maintains accessible Team Vaults outside the active view", async () => {
  const scopes = [];
  const locked = [];
  const result = await maintainAccessibleTeamVaultWrappers({
    client: {},
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
  assert.match(html, /<script src="\/appearance-bootstrap\.js\?v=155"><\/script>\s*<link rel="stylesheet" href="\/styles\.css\?v=155">/u);
  assert.match(html, /\/app\.js\?v=155/u);
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
  assert.match(application, /modern-select\.js\?v=155/u);
  assert.match(application, /save\.className = "team-member-action-button"/u);
  assert.match(application, /admitDevices\.className = "team-member-action-button"/u);
  assert.match(application, /try \{\s*initializeAppearance\(\);\s*initializeModernSelects\(\);\s*await initializePortal\(\);\s*\} finally \{\s*finishPortalBootstrap\(\);/u);
  assert.match(html, /id="cloud-workspace"[^>]*hidden/u);
  assert.match(html, /data-open-auth="login"/u);
  assert.match(html, /data-open-auth="registration"/u);
  assert.equal((html.match(/data-open-auth="login"/gu) ?? []).length, 1);
  assert.equal((html.match(/data-open-auth="registration"/gu) ?? []).length, 1);
  assert.match(html, /<nav class="brand-actions"[\s\S]*data-open-auth="login"[\s\S]*data-open-auth="registration"[\s\S]*<\/nav>/u);
  assert.doesNotMatch(html, /class="hero-actions"/u);
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
  assert.match(html, /data-workspace-target="local-vault" data-record-filter="host">Хосты/u);
  assert.match(html, /data-workspace-target="local-vault" data-record-filter="snippet">Сниппеты/u);
  assert.match(html, /data-workspace-target="local-vault" data-record-filter="credential">Учётные данные/u);
  assert.match(html, /data-workspace-target="team-vault">Команды/u);
  assert.match(html, /id="team-view-tabs"/u);
  assert.match(html, /data-team-view="members">Участники/u);
  assert.match(html, /id="team-member-search"/u);
  assert.match(html, /id="team-member-role-filter"/u);
  assert.match(html, /id="team-member-more"/u);
  assert.match(html, /data-team-view="vaults">Vaults/u);
  assert.match(html, /data-team-view="hosts">Хосты/u);
  assert.match(html, /class="host-scope-switcher"/u);
  assert.match(html, />Личные<\/button>[\s\S]*data-team-view="hosts">Командные/u);
  assert.match(html, /id="team-record-editor"/u);
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
  assert.match(html, /id="local-vault-record-form"[^>]*hidden/u);
  assert.match(html, /id="local-record-cancel"[^>]*hidden/u);
  assert.doesNotMatch(html, /data-record-filter="all">Personal Vault/u);
  assert.match(html, /class="workspace-nav-label">Команды/u);
  assert.match(html, /id="personal-host-fields"/u);
  assert.match(html, /id="local-host-protocol"/u);
  assert.match(html, /id="local-host-folder"/u);
  assert.match(html, /Откройте Vault, чтобы увидеть личные подключения/u);
  assert.doesNotMatch(html, /ещё не выполняет этот импорт автоматически/u);
  assert.match(styles, /\[hidden\]\s*\{\s*display:\s*none\s*!important;\s*\}/u);
  assert.match(styles, /\.workspace-layout/u);
  assert.match(styles, /:root\[data-theme="light"\] \.access,[\s\S]*\.resource-detail,[\s\S]*\.vault-conflicts\s*\{\s*background:var\(--surface-raised\)/u);
  assert.match(styles, /--panel:#f6faf8; --surface-soft:#eef6f2; --surface-raised:#fbfdfc/u);
  assert.match(styles, /:root\[data-theme="light"\] \.app-boot-card \{[^}]*background:linear-gradient/u);
  assert.match(styles, /:root\[data-theme="light"\] \.workspace-main \{[^}]*#edf5f1/u);
  assert.match(styles, /:root\[data-theme="light"\] \.workspace-stats button,[^}]*background:var\(--surface-raised\)/u);
  assert.match(styles, /:root\[data-theme="light"\] \.resource-card-clickable:hover/u);
  assert.match(styles, /@keyframes reveal-up/u);
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
  assert.match(application, /BroadcastChannel\("selective-remote\.personal-vault\.session\.v1"\)/u);
  assert.match(application, /restoreRememberedSession\(restoredUser\.id\)/u);
  assert.match(application, /vault\.rememberSession\(user\.id\)/u);
  assert.match(application, /vault\.forgetRememberedSession\(\)/u);
  assert.match(application, /visibilitychange/u);
  assert.doesNotMatch(html, /<div class="vault-toolbar">\s*<div><h3>Личный Vault/u);
  assert.match(application, /ваш текущий username/u);
  assert.match(application, /teamUI\?\.setView\(teamView \|\| "teams"\)/u);
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
  assert.match(application, /выберите папку для просмотра хостов/u);
  assert.match(application, /await openSelectedVault\(\)/u);
  assert.match(application, /value\.type !== "host" \|\| \(folder !== "all"/u);
  assert.match(html, /id="team-host-search"/u);
  assert.match(html, /id="team-host-folder-filter"/u);
  assert.match(application, /teamHostRecordData/u);
  assert.match(application, /В выбранном Team Vault пока нет хостов/u);
  assert.match(application, /hostDetail\?\.showModal\(\)/u);
  assert.match(application, /documentValue\.body\.append\(hostDetail\)/u);
  assert.match(html, /class="workspace-security-status"/u);
  assert.match(html, /class="workspace-account"/u);
  assert.match(styles, /\.workspace-security-icon/u);
  assert.doesNotMatch(application, /sidebarFooter\.append/u);
  assert.match(application, /workspaceHeader\.hidden = true/u);
  assert.match(application, /beginHostEdit/u);
  assert.match(application, /navigator\.clipboard\.writeText\(hostDetailAddress\.textContent\)/u);
  assert.match(application, /navigator\.clipboard\.writeText\(String\(credential\.data\.secret/u);
  assert.match(application, /target\.replace\(\/\^ssh:\/u, "sftp:"\)/u);
  assert.match(application, /sourceID: hostID/u);
  assert.match(application, /resourceTitles/u);
  assert.match(application, /client\.deleteAccount/u);
  assert.match(application, /account_owns_teams/u);
  assert.match(application, /URLSearchParams\(locationValue\.search\)/u);
  assert.match(application, /requestedAuthMode === "login" \|\| requestedAuthMode === "registration"/u);
  assert.match(application, /setPath\("\/login"/u);
  assert.match(application, /"\/app": \["workspace-overview", null, null\]/u);
  assert.match(application, /"\/app\/team-hosts": \["team-vault", null, "hosts"\]/u);
  assert.match(application, /routeForWorkspace/u);
  assert.match(application, /setFilterChangeListener/u);
  assert.match(application, /renderOverviewSummary/u);
  assert.match(application, /formatVaultTimestamp\(record\.modifiedAt\)/u);
  assert.match(application, /Изменено: \$\{formatVaultTimestamp\(record\.modifiedAt\)\}/u);
  assert.match(application, /formatVaultSynchronizationSummary\(result\.revision\)/u);
  assert.match(application, /const hostFolderName = personalHostFolderName/u);
  assert.match(application, /localVaultRecordFormValues\(record\)/u);
  assert.match(application, /editingRecordID/u);
  assert.match(application, /closeEditor\(\)/u);
  assert.match(application, /recordForm\.hidden = hide/u);
  assert.match(application, /createButton\?\.addEventListener\("click", beginCreate\)/u);
  assert.match(application, /setFilter\(value\) \{\s*resetEditor\(\)/u);
  assert.match(application, /panelID !== "local-vault"\) vaultUI\?\.closeEditor\(\)/u);
  assert.match(application, /personalHostRecordData/u);
  assert.match(styles, /\.personal-vault-browser/u);
  assert.match(styles, /grid-template-columns:repeat\(3,minmax\(0,1fr\)\)/u);
  assert.match(styles, /\.team-host-browser \{ display:grid; grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/u);
  assert.match(styles, /\.record-form input\[type="checkbox"\] \{ width:auto/u);
  assert.match(styles, /\.team-section-tabs,\.host-scope-switcher/u);
  assert.ok(styles.includes('.brand-actions button:not(.secondary):not(.modern-select-trigger):not(.modern-select-option)'));
  assert.ok(styles.includes(':not([data-team-view]):not([data-record-filter])'));
  assert.ok(styles.includes(':not(.team-member-action-button)'));
  assert.match(styles, /:root\[data-theme="light"\] \.team-member-action-button \{[^}]*color:var\(--ink\)/u);
  assert.ok(styles.includes(':root[data-theme="light"] :is(input:not([type="checkbox"]):not([type="radio"]),textarea,select)'));
  assert.ok(styles.includes(':root[data-theme="light"] .team-section-tabs button:not(.active)'));
  assert.match(server, /\^\\\/app\(\?:\\\/\[\^\/\]\+\)\?\$/u);
  assert.match(application, /createAuthenticatedVaultClient/u);
  assert.match(application, /synchronizeVault/u);
  assert.match(application, /unlockAndSyncPersonalVault\(password\)/u);
  assert.match(application, /backgroundPersonalVaultSync/u);
  assert.match(application, /newestVaultConflictChoice/u);
  assert.match(application, /async function synchronizePersonalVault/u);
  assert.match(application, /automaticallyResolved: conflictsResolved/u);
  assert.doesNotMatch(
    application.match(/syncButton\.addEventListener\("click"[\s\S]*?conflictForm\.addEventListener/u)?.[0] ?? "",
    /renderConflicts\(result\)/u,
  );
  assert.match(application, /15_000/u);
  assert.match(application, /vault\.lock\(\)/u);
  assert.doesNotMatch(application, /accountVaultMigrationPassphrase|account_password_required/u);
  assert.doesNotMatch(application, /cloud-vault-recovery-form|vaultUI\.showRecovery/u);
  assert.match(application, /replaceLockedWithRemote/u);
  assert.match(application, /Personal Vault открыт паролем аккаунта/u);
  assert.doesNotMatch(application, /Legacy Personal Vault|Recovery-фраза|секретная фраза/iu);
  assert.match(application, /vaultUI\.mode\("waiting"\)/u);
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
  assert.match(html, /app\.js\?v=155/u);
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
  assert.doesNotMatch(`${application}\n${synchronization}\n${teamSynchronization}`, /localStorage|sessionStorage/u);
  assert.match(synchronization, /unsupported_vault_scope/u);
  assert.match(synchronization, /credentials: "same-origin"/u);
  assert.match(teamSynchronization, /team_vault_rotation_required/u);
  assert.match(teamSynchronization, /prepareInitialization/u);
});
