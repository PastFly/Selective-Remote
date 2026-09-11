import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  accountVaultPassphrase,
  initializeAppearance,
  localVaultConflictSideSummary,
  localVaultRecordData,
  localVaultRecordSummary,
  parseTeamHostConnection,
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

test("appearance defaults to graphite and synchronizes every visible selector", () => {
  const listeners = [];
  const controls = [{ value: "" }, { value: "" }].map((control) => ({
    ...control,
    addEventListener(_name, listener) { listeners.push([this, listener]); },
  }));
  const documentValue = {
    documentElement: { dataset: {} },
    querySelectorAll: () => controls,
  };
  const appearance = initializeAppearance({ documentValue });
  assert.equal(appearance.theme(), "graphite");
  assert.equal(documentValue.documentElement.dataset.theme, "graphite");
  assert.deepEqual(controls.map(({ value }) => value), ["graphite", "graphite"]);
  controls[1].value = "light";
  listeners[1][1]();
  assert.equal(appearance.theme(), "light");
  assert.deepEqual(controls.map(({ value }) => value), ["light", "light"]);
  appearance.apply("unknown");
  assert.equal(appearance.theme(), "graphite");
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
  const [html, styles, application, synchronization, teamSynchronization, server] = await Promise.all([
    readFile(new URL("../public/index.html", import.meta.url), "utf8"),
    readFile(new URL("../public/styles.css", import.meta.url), "utf8"),
    readFile(new URL("../public/app.js", import.meta.url), "utf8"),
    readFile(new URL("../public/vault-sync.js", import.meta.url), "utf8"),
    readFile(new URL("../public/team-vault-sync.js", import.meta.url), "utf8"),
    readFile(new URL("../src/server.mjs", import.meta.url), "utf8"),
  ]);

  assert.match(html, /id="cloud-account"[^>]*hidden/u);
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
  assert.match(html, /id="cloud-vault-recovery-form"/u);
  assert.match(html, /id="cloud-vault-recovery-account-password"[^>]*name="accountPassword"[^>]*autocomplete="current-password"/u);
  assert.match(html, /recovery-фразу один раз/iu);
  assert.match(html, /Сразу после обычного входа поле можно оставить пустым/u);
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
  assert.match(html, /data-workspace-target="team-vault" data-team-view="teams">Команды/u);
  assert.match(html, /data-workspace-target="team-vault" data-team-view="members">Участники команд/u);
  assert.match(html, /data-workspace-target="team-vault" data-team-view="vaults">Папки команд/u);
  assert.match(html, /data-workspace-target="team-vault" data-team-view="hosts">Хосты команд/u);
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
  assert.match(html, /https:\/\/yoomoney\.ru\/to\/4100119600001192/u);
  assert.match(html, /https:\/\/boosty\.to\/pastfly/u);
  assert.match(html, /https:\/\/github\.com\/PastFly\/Selective-Remote/u);
  assert.match(html, /id="account-delete-form"/u);
  assert.match(html, /id="account-username-form"/u);
  assert.match(html, /id="account-password-form"/u);
  assert.match(html, /autocomplete="current-password"/u);
  assert.match(html, /data-record-filter="host"/u);
  assert.match(html, /data-record-filter="credential"/u);
  assert.match(html, /data-record-filter="snippet"/u);
  assert.match(html, /data-record-filter="forwarding"/u);
  assert.match(html, /защищённой синхронизации Personal Vault с Mac/u);
  assert.doesNotMatch(html, /ещё не выполняет этот импорт автоматически/u);
  assert.match(styles, /\[hidden\]\s*\{\s*display:\s*none\s*!important;\s*\}/u);
  assert.match(styles, /\.workspace-layout/u);
  assert.match(styles, /:root\[data-theme="light"\] \.access,[\s\S]*\.resource-detail,[\s\S]*\.vault-conflicts\s*\{\s*background:#fff/u);
  assert.match(styles, /:root\[data-theme="light"\] \.resource-card-clickable:hover/u);
  assert.match(styles, /@keyframes reveal-up/u);
  assert.match(styles, /prefers-reduced-motion:reduce[^}]*[\s\S]*animation:none!important/u);
  assert.match(styles, /\.team-members article\s*\{[^}]*grid-template-columns:minmax\(180px,1fr\) minmax\(110px,auto\)/u);
  assert.match(application, /initializePortalNavigation/u);
  assert.match(application, /teamUI\?\.setView\(teamView \|\| "teams"\)/u);
  assert.match(application, /Team «\$\{selectedTeam\.name\}» · участников: \$\{teamMembers\.length\}/u);
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
  assert.match(application, /sidebarFooter\.append\(workspaceTheme\)/u);
  assert.match(application, /sidebarFooter\.append\(signedInAccount\)/u);
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
  assert.match(server, /\^\\\/app\(\?:\\\/\[\^\/\]\+\)\?\$/u);
  assert.match(application, /createAuthenticatedVaultClient/u);
  assert.match(application, /synchronizeVault/u);
  assert.match(application, /unlockAndSyncPersonalVault\(password\)/u);
  assert.match(application, /backgroundPersonalVaultSync/u);
  assert.match(application, /15_000/u);
  assert.match(application, /vault\.lock\(\)/u);
  assert.match(application, /let migrationPassphrase = accountVaultMigrationPassphrase/u);
  assert.match(application, /if \(!accountPassword\) throw new Error\("account_password_required"\)/u);
  assert.match(application, /email: currentUser\.email,[\s\S]*password: accountPassword/u);
  assert.match(application, /vault\.rewrap\(migrationPassphrase\)/u);
  assert.match(application, /Recovery-фраза не проверялась/u);
  assert.match(application, /переведена на автоматическую разблокировку паролем аккаунта/u);
  assert.match(application, /Personal Vault открыт паролем аккаунта/u);
  assert.match(application, /Legacy Personal Vault будет автоматически переведён/u);
  assert.match(application, /vaultUI\.mode\("waiting"\)/u);
  assert.doesNotMatch(application, /vaultUI\.showRecovery\(\)/u);
  assert.match(application, /ensureTeamDeviceIdentity/u);
  assert.match(application, /synchronizeTeamVault/u);
  assert.match(application, /provisionTeamVaultWrappers/u);
  assert.match(application, /backgroundSyncIntervalMilliseconds = 15_000/u);
  assert.match(application, /documentValue\.visibilityState === "hidden"/u);
  assert.match(application, /runBackgroundTeamVaultSync/u);
  assert.match(application, /teamVaultRecoveryMode/u);
  assert.match(application, /setRecoveryControls/u);
  assert.doesNotMatch(application, /Owner\/Admin может выдать недостающие wrappers/u);
  assert.match(teamSynchronization, /export async function provisionTeamVaultWrappers/u);
  assert.match(application, /rotateTeamVault/u);
  assert.match(application, /teamDevicePublicKeyFingerprint/u);
  assert.match(application, /client\.approveDeviceKey/u);
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
