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
  const source = await readFile(new URL("CloudTeamCrypto.swift", sourceRoot), "utf8");
  assert.match(source, /selective-remote\/team-device-key\/v1/);
  assert.match(source, /selective-remote\/team-vault-wrapper\/v1/);
  assert.match(source, /selective-remote\/team-vault-wrapper-key\/v1/);
  assert.match(source, /selective-remote\/team-vault-payload\/v1/);
  assert.match(source, /actualKeys == \["crv", "ext", "key_ops", "kty", "x", "y"\]/);
  assert.match(source, /P256\.KeyAgreement\.PublicKey/);
});
