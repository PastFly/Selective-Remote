import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  localVaultConflictSideSummary,
  localVaultRecordData,
  localVaultRecordSummary,
} from "../public/app.js";

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
  assert.match(html, /id="cloud-login-form"/u);
  assert.match(html, /id="cloud-vault-sync"/u);
  assert.match(html, /id="cloud-logout"/u);
  assert.match(html, /id="cloud-vault-recovery-form"/u);
  assert.match(html, /id="local-vault-conflicts-form"/u);
  assert.match(html, /id="local-vault-conflicts-apply"[^>]*disabled/u);
  assert.match(html, /id="team-vault"[^>]*hidden/u);
  assert.match(html, /id="team-create-form"/u);
  assert.match(html, /id="team-invitation-accept-form"/u);
  assert.match(html, /id="team-select"/u);
  assert.match(html, /id="team-lifecycle"[^>]*hidden/u);
  assert.match(html, /id="team-rename-form"/u);
  assert.match(html, /id="team-ownership-transfer-form"/u);
  assert.match(html, /id="team-archive-form"/u);
  assert.match(html, /autocomplete="current-password"/u);
  assert.match(html, /id="team-devices"/u);
  assert.match(html, /id="team-vault-rotate"[^>]*hidden/u);
  assert.match(html, /id="team-vault-record-form"/u);
  assert.match(html, /id="team-vault-conflicts-form"/u);
  assert.match(html, /id="workspace-overview"/u);
  assert.match(html, /data-workspace-target="local-vault"/u);
  assert.match(html, /data-workspace-target="workspace-devices"/u);
  assert.match(html, /data-workspace-target="local-vault" data-record-filter="host">Хосты/u);
  assert.match(html, /data-workspace-target="local-vault" data-record-filter="snippet">Сниппеты/u);
  assert.match(html, /data-workspace-target="local-vault" data-record-filter="credential">Учётные данные/u);
  assert.match(html, /data-workspace-target="team-vault">Команды и Team Vaults/u);
  assert.match(html, /id="host-detail-dialog"/u);
  assert.match(html, /data-workspace-target="workspace-settings"/u);
  assert.match(html, /id="account-delete-form"/u);
  assert.match(html, /autocomplete="current-password"/u);
  assert.match(html, /data-record-filter="host"/u);
  assert.match(html, /data-record-filter="credential"/u);
  assert.match(html, /data-record-filter="snippet"/u);
  assert.match(html, /data-record-filter="forwarding"/u);
  assert.match(html, /Текущая версия macOS-клиента ещё не выполняет этот импорт автоматически/u);
  assert.match(styles, /\[hidden\]\s*\{\s*display:\s*none\s*!important;\s*\}/u);
  assert.match(styles, /\.workspace-layout/u);
  assert.match(application, /initializePortalNavigation/u);
  assert.match(application, /hostDetail\?\.showModal\(\)/u);
  assert.match(application, /resourceTitles/u);
  assert.match(application, /client\.deleteAccount/u);
  assert.match(application, /account_owns_teams/u);
  assert.match(application, /URLSearchParams\(locationValue\.search\)/u);
  assert.match(application, /requestedAuthMode === "login" \|\| requestedAuthMode === "registration"/u);
  assert.match(application, /setPath\("\/login"/u);
  assert.match(application, /setPath\("\/app"/u);
  assert.match(server, /\["\/", "\/login", "\/app"\]\.includes\(pathname\)/u);
  assert.match(application, /createAuthenticatedVaultClient/u);
  assert.match(application, /synchronizeVault/u);
  assert.match(application, /ensureTeamDeviceIdentity/u);
  assert.match(application, /synchronizeTeamVault/u);
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
  assert.match(synchronization, /credentials: "omit"/u);
  assert.match(teamSynchronization, /team_vault_rotation_required/u);
  assert.match(teamSynchronization, /prepareInitialization/u);
});
