import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

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

test("macOS Cloud settings expose real device-bound sign-in and read-only Team inventory", async () => {
  const [settings, accountViews, client, sessions] = await Promise.all([
    readFile(new URL("CloudSettingsView.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudAccountViews.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudAPIClient.swift", sourceRoot), "utf8"),
    readFile(new URL("CloudSessionStore.swift", sourceRoot), "utf8"),
  ]);
  assert.match(accountViews, /SecureField/);
  assert.doesNotMatch(accountViews, /@AppStorage/);
  assert.match(settings, /identityManager\.identity/);
  assert.match(settings, /publicKey: identity\.publicKey/);
  assert.match(settings, /restoreStoredSession/);
  assert.match(settings, /client\.currentUser/);
  assert.match(settings, /client\.teams/);
  assert.match(settings, /client\.sharedVaults/);
  assert.match(settings, /client\.logout/);
  assert.match(accountViews, /Teams & Shared Vaults/);
  assert.match(client, /validLoginJSON/);
  assert.match(client, /validTeamsJSON/);
  assert.match(sessions, /kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly/);
  assert.doesNotMatch(sessions, /UserDefaults/);
});
