import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { validateVaultDocument } from "../public/vault-model.js";

const sourceRoot = new URL("../../Sources/SelectiveRemote/", import.meta.url);

test("macOS Cloud foundation keeps sessions in device-only Keychain storage", async () => {
  const [client, store] = await Promise.all([
    readFile(new URL("CloudAPIClient.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudSessionStore.swift", sourceRoot), "utf8"),
  ]);
  assert.match(store, /local\.selectiveremote\.cloud\.session\.v1/);
  assert.match(store, /kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly/);
  assert.doesNotMatch(store, /UserDefaults/);
  assert.match(client, /Bearer.*Authorization/);
  assert.match(client, /http\.statusCode == 401[\s\S]*removeToken/);
  assert.match(client, /no-store.*Cache-Control/);
});

test("macOS Team crypto source pins the browser protocol labels and strict JWK shape", async () => {
  const [source, identity] = await Promise.all([
    readFile(new URL("CloudTeamCrypto.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudTeamDeviceIdentity.swift", sourceRoot), "utf8"),
  ]);
  assert.match(source, /selective-remote\/team-device-key\/v1/);
  assert.match(source, /selective-remote\/team-vault-wrapper\/v1/);
  assert.match(source, /selective-remote\/team-vault-wrapper-key\/v1/);
  assert.match(source, /selective-remote\/team-vault-payload\/v1/);
  assert.match(source, /actualKeys == \["crv", "ext", "key_ops", "kty", "x", "y"\]/);
  assert.match(source, /P256\.KeyAgreement\.PublicKey/);
  assert.match(source, /hkdfDerivedSymmetricKey/);
  assert.match(source, /AES\.GCM\.(seal|SealedBox)/);
  assert.match(identity, /local\.selectiveremote\.cloud\.team-device-key\.v1/);
  assert.match(identity, /kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly/);
  assert.match(identity, /savePrivateKeyIfAbsent/);
  assert.doesNotMatch(identity, /UserDefaults/);
});

test("macOS Team payload transport persists ciphertext-only offline snapshots", async () => {
  const [client, crypto, snapshots] = await Promise.all([
    readFile(new URL("CloudAPIClient.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudTeamCrypto.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudTeamVaultSnapshotStore.swift", sourceRoot), "utf8"),
  ]);
  assert.match(crypto, /static func encryptPayload/);
  assert.match(crypto, /static func decryptPayload/);
  assert.match(crypto, /payloadContentHashMismatch/);
  assert.match(client, /Idempotency-Key/);
  assert.match(client, /http\.statusCode == 200 \|\| http\.statusCode == 409/);
  assert.match(client, /key-devices/);
  assert.match(snapshots, /\.write\(to: url, options: \[\.atomic\]\)/);
  assert.match(snapshots, /posixPermissions: 0o600/);
  assert.doesNotMatch(snapshots, /\b(?:let|var)\s+(?:vaultKey|plaintext|password|token)\b/iu);
});

test("macOS Team Vault coordinator preserves causal dirty and conflict state", async () => {
  const coordinator = await readFile(
    new URL("CloudTeamVaultSyncCoordinator.swift", sourceRoot),
    "utf8",
  );
  assert.match(coordinator, /actor SelectiveRemoteTeamVaultSyncCoordinator/);
  assert.match(coordinator, /case rotationRequired/);
  assert.match(coordinator, /case remoteRevisionRollback/);
  assert.match(coordinator, /case remoteRevisionDivergence/);
  assert.match(coordinator, /localRevision > local\.syncedLocalRevision/);
  assert.match(coordinator, /return \.conflict\(\.init\(local: localVersion, remote: remoteVersion\)\)/);
  assert.match(coordinator, /macos:team-vault:/);
  assert.match(coordinator, /try snapshots\.save\(staged, endpoint: endpoint\)/);
  assert.match(coordinator, /write\.revision == expectedServerRevision/);
  assert.match(coordinator, /func resolveConflict\(/);
  assert.match(coordinator, /latestRemote == conflict\.remote/);
  assert.match(coordinator, /baseRevision: latestRemote\.revision/);
  assert.match(coordinator, /return try await push\(teamID: teamID, vaultID: vaultID, identity: identity\)/);
  assert.match(coordinator, /revalidated == current/);
  assert.match(coordinator, /func initialize\(/);
  assert.match(coordinator, /wrappers: wrappers/);
});

test("macOS automatically provisions and synchronizes Team Vaults while unlocked", async () => {
  const [client, coordinator, autoSync, app] = await Promise.all([
    readFile(new URL("CloudAPIClient.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudTeamVaultSyncCoordinator.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudTeamVaultAutoSync.swift", sourceRoot), "utf8"),
    readFile(new URL("SelectiveRemoteApp.swift", sourceRoot), "utf8"),
  ]);
  assert.match(client, /func grantSharedVaultWrapper\(/);
  assert.match(client, /\/wrappers/);
  assert.match(coordinator, /func provisionMissingWrappers\(/);
  assert.match(coordinator, /actor\.membershipID == remoteVersion\.wrapper\.membershipID/);
  assert.match(autoSync, /pollInterval: Duration = \.seconds\(15\)/);
  assert.match(autoSync, /case \.localChanges:/);
  assert.match(autoSync, /case \.conflict:/);
  assert.doesNotMatch(autoSync, /func initialize\(/);
  assert.match(app, /appLock\.isLocked/);
  assert.match(app, /teamVaultAutoSync\.stop\(\)/);
});

test("Host context menu opens a real encrypted Team Vault share flow", async () => {
  const [content, sharing, coordinator] = await Promise.all([
    readFile(new URL("ContentView.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudProfileShareView.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudTeamVaultSyncCoordinator.swift", sourceRoot), "utf8"),
  ]);
  assert.match(content, /Share with Team/);
  assert.match(content, /SelectiveRemoteCloudProfileShareView/);
  assert.match(sharing, /client\.teamKeyDevices/);
  assert.match(sharing, /coordinator\.initialize/);
  assert.match(sharing, /coordinator\.stage/);
  assert.match(sharing, /coordinator\.push/);
  assert.match(sharing, /without its saved password/);
  assert.match(coordinator, /enum SelectiveRemoteTeamVaultSyncError: LocalizedError, Equatable/);
  assert.match(coordinator, /case \.missingDeviceWrapper:[\s\S]*?не выдан ключ выбранного Team Vault/);
  assert.match(sharing, /catch SelectiveRemoteTeamVaultSyncError\.missingDeviceWrapper/);
  assert.match(sharing, /needsDeviceWrapper = true/);
  assert.match(sharing, /Открыть Team Vaults в браузере/);
});

test("macOS Team Vault record workflow mirrors the bounded browser causal model", async () => {
  const model = await readFile(new URL("CloudVaultRecordModel.swift", sourceRoot), "utf8");
  assert.match(model, /static let schemaVersion = 1/);
  assert.match(model, /case host[\s\S]*case credential[\s\S]*case snippet[\s\S]*case forwarding/);
  assert.match(model, /maximumBytes = 24 \* 1024 \* 1024/);
  assert.match(model, /maximumEntities = 10_000/);
  assert.match(model, /case left, right, equal, concurrent/);
  assert.match(model, /incompleteConflictResolutions/);
  assert.match(model, /func prepareRecordConflict\(/);
  assert.match(model, /func resolveRecordConflicts\(/);
  assert.match(model, /resolvedPayload: resolved\.encoded\(\)/);
});

test("macOS exposes a complete-choice conflict review without rendering secrets", async () => {
  const [review, settings] = await Promise.all([
    readFile(new URL("CloudVaultConflictReviewView.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudSettingsView.swift", sourceRoot), "utf8"),
  ]);
  assert.match(review, /Resolve and Sync/);
  assert.match(review, /choices\.count == conflicts\.count/);
  assert.match(review, /conflicts\.allSatisfy \{ choices\[\$0\.id\] != nil \}/);
  assert.match(review, /values\["title"\]/);
  assert.doesNotMatch(review, /values\["(?:secret|body|username)"\]/);
  assert.match(review, /must-not-render/);
  assert.match(settings, /Open Test Conflict/);
  assert.match(settings, /sends nothing to Cloud/);
});

test("macOS Cloud settings expose device-bound sign-in and native Team management", async () => {
  const [settings, accountViews, teamManagement, client, sessions] = await Promise.all([
    readFile(new URL("CloudSettingsView.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudAccountViews.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudTeamManagementView.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudAPIClient.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudSessionStore.swift", sourceRoot), "utf8"),
  ]);
  assert.match(accountViews, /SecureField/);
  assert.doesNotMatch(accountViews, /@AppStorage/);
  assert.match(accountViews, /Create New Account/);
  assert.match(accountViews, /Registration is currently disabled on this server/);
  assert.match(accountViews, /Confirm Password/);
  assert.match(accountViews, /Verify Your Email/);
  assert.match(settings, /identityManager\.identity/);
  assert.match(settings, /publicKey: identity\.publicKey/);
  assert.match(settings, /restoreStoredSession/);
  assert.match(settings, /client\.currentUser/);
  assert.match(settings, /client\.teams/);
  assert.match(settings, /client\.sharedVaults/);
  assert.match(settings, /client\.logout/);
  assert.match(settings, /client\.register/);
  assert.match(settings, /SelectiveRemoteCloudTeamManagementView/);
  assert.match(settings, /metadata\?\.registrationEnabled == true/);
  assert.match(accountViews, /Teams & Shared Vaults/);
  assert.match(teamManagement, /NavigationSplitView/);
  assert.match(teamManagement, /client\.createTeam/);
  assert.match(teamManagement, /client\.teamMembers/);
  assert.match(teamManagement, /client\.inviteTeamMember/);
  assert.match(teamManagement, /client\.createTeamInvitationLink/);
  assert.match(teamManagement, /client\.pendingTeamInvitations/);
  assert.match(teamManagement, /client\.acceptTeamInvitation/);
  assert.match(teamManagement, /client\.cancelTeamInvitation/);
  assert.match(teamManagement, /client\.createSharedVault/);
  assert.match(teamManagement, /Team Hosts/);
  assert.match(teamManagement, /@\\\(member\.username\)/);
  assert.doesNotMatch(teamManagement, /Text\(member\.email\)/);
  assert.doesNotMatch(teamManagement, /invitationEmail|TextField\("Email"/);
  assert.match(client, /v1\/auth\/register/);
  assert.match(client, /verificationRequired/);
  assert.match(client, /validLoginJSON/);
  assert.match(client, /validTeamsJSON/);
  assert.match(client, /validTeamMembersJSON/);
  assert.match(client, /deviceID/);
  assert.match(sessions, /kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly/);
  assert.doesNotMatch(sessions, /UserDefaults/);
});

test("connection checks preserve the signed-in account and inventory failures stay isolated", async () => {
  const settings = await readFile(new URL("CloudSettingsView.swift", sourceRoot), "utf8");
  const checkConnection = settings.match(/private func checkConnection\(\)[\s\S]*?\n    \}\n\n    @MainActor/u)?.[0] ?? "";
  assert.match(checkConnection, /refreshCloudMetadata/);
  assert.doesNotMatch(checkConnection, /restoreStoredSession|resetAccountPresentation|loadInventory/);
  assert.match(settings, /private func refreshCloudMetadata\(\) async -> URL\?/);
  assert.match(settings, /personalVaultLoadErrorMessage/);
  assert.match(settings, /do \{[\s\S]*client\.personalVault[\s\S]*\} catch \{[\s\S]*personalVaultLoadErrorMessage[\s\S]*\}\n\n        do \{[\s\S]*client\.teams/u);
  assert.match(settings, /Register on the Website/);
});

test("macOS Cloud commands use the supported settings action and backwards-compatible portal URLs", async () => {
  const [application, client, settings] = await Promise.all([
    readFile(new URL("SelectiveRemoteApp.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudAPIClient.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudSettingsView.swift", sourceRoot), "utf8"),
  ]);
  assert.match(application, /@Environment\(\\\.openSettings\)/);
  assert.match(application, /openSettings\(\)/);
  assert.doesNotMatch(application, /showSettingsWindow:/);
  assert.match(client, /cloud\.pastfly\.ru\/\?auth=login/);
  assert.match(client, /URLQueryItem\(name: "auth", value: "registration"\)/);
  assert.match(settings, /SelectiveRemoteCloudPortalURL\.registration/);
  assert.doesNotMatch(`${application}\n${settings}`, /appending\(path: "login"\)|cloud\.pastfly\.ru\/login/);
});

test("macOS Personal Vault first upload is encrypted, explicit and non-destructive", async () => {
  const [sync, settings, appSettings] = await Promise.all([
    readFile(new URL("CloudPersonalVaultSync.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudSettingsView.swift", sourceRoot), "utf8"),
    readFile(new URL("UpdateExperienceView.swift", sourceRoot), "utf8"),
  ]);
  assert.match(sync, /PBKDF2-SHA256\+A256KW/);
  assert.match(sync, /600_000/);
  assert.match(sync, /selective-remote:vault-envelope:v1/);
  assert.match(sync, /AES\.GCM\.seal/);
  assert.match(sync, /wrapRFC3394/);
  assert.match(sync, /remoteVaultNotEmpty/);
  assert.match(sync, /uploadConflict/);
  assert.match(settings, /includePersonalVaultCredentials = false/);
  assert.match(settings, /authenticateDeviceOwner/);
  assert.match(settings, /guard remote\.revision == 0/);
  assert.match(settings, /Task\.detached/);
  assert.match(settings, /personalVaultRecoveryPhrase = ""/);
  assert.match(appSettings, /CloudSettingsView\(model: model\)/);
});


test("browser and macOS share the bounded Team Host record fixture", async () => {
  const fixtureURL = new URL(
    "../../Tests/SelectiveRemoteTests/Fixtures/team-host-record-v1.json",
    import.meta.url,
  );
  const fixture = validateVaultDocument(JSON.parse(await readFile(fixtureURL, "utf8")));
  assert.equal(fixture.records.length, 2);

  const browser = fixture.records.find((record) => record.id === "33333333-3333-4333-8333-333333333333");
  assert.deepEqual(Object.keys(browser.data).sort(), ["address", "title"]);
  assert.equal(browser.data.address, "ssh://deployer@bastion.example.invalid:2222");

  const mac = fixture.records.find((record) => record.id === "77777777-7777-4777-8777-777777777777");
  assert.deepEqual(
    Object.keys(mac.data).sort(),
    ["address", "connectionType", "profile", "title", "username"],
  );
  const decodedProfile = JSON.parse(Buffer.from(mac.data.profile, "base64url").toString("utf8"));
  assert.equal(decodedProfile.id, mac.id);
  assert.equal(decodedProfile.connectionType, "rdp");
  assert.equal(decodedProfile.host, mac.data.address);
  assert.equal(decodedProfile.username, mac.data.username);
});

test("macOS projects Team Hosts separately and connects without Personal persistence", async () => {
  const [hosts, autoSync, content, appModel, terminal] = await Promise.all([
    readFile(new URL("CloudTeamHosts.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudTeamVaultAutoSync.swift", sourceRoot), "utf8"),
    readFile(new URL("ContentView.swift", sourceRoot), "utf8"),
    readFile(new URL("AppModel.swift", sourceRoot), "utf8"),
    readFile(new URL("TerminalWorkspace.swift", sourceRoot), "utf8"),
  ]);
  assert.match(hosts, /final class SelectiveRemoteTeamHostStore: ObservableObject/);
  assert.match(hosts, /browserKeys[\s\S]*"title", "address"/);
  assert.match(hosts, /macOSKeys[\s\S]*"connectionType", "profile"/);
  assert.match(hosts, /selective-remote\/team-host\/v1/);
  assert.match(hosts, /sshIdentityID = nil/);
  assert.match(hosts, /redirectedFolders = \[\]/);
  assert.match(hosts, /clipboardMode = \.disabled/);
  assert.doesNotMatch(hosts, /profiles\.append|model\.profiles/);

  assert.match(autoSync, /case let \.synchronized\(value\)/);
  assert.match(autoSync, /case let \.uploaded\(value\)/);
  assert.match(autoSync, /await snapshotConsumer\(materialized\)/);
  assert.match(autoSync, /func stop\(\) async[\s\S]*snapshotConsumer\(\[\]\)/);

  assert.match(content, /case teamHosts = "Team Hosts"/);
  assert.match(content, /SelectiveRemoteTeamHostsView/);
  assert.match(content, /ephemeral: true/);
  assert.match(appModel, /func connectTeamHost\(/);
  assert.match(appModel, /allowsStoredCredentials: false/);
  assert.match(appModel, /persistsProfileState: false/);
  assert.doesNotMatch(
    appModel.match(/func connectTeamHost\([\s\S]*?\n    \}\n\n    func sshConnectionSettings/u)?.[0] ?? "",
    /profiles\.append/,
  );
  assert.match(terminal, /var isEphemeral: Bool/);
  assert.match(terminal, /tabs\.filter \{ !\$0\.isEphemeral \}\.map/);
});
