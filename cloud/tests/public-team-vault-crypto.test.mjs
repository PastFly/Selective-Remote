import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import {
  decryptTeamVaultPayload,
  encryptTeamVaultPayload,
  ensureTeamDeviceIdentity,
  generateTeamDeviceIdentity,
  normalizeTeamVaultScope,
  teamVaultWrapperContext,
  teamVaultWrapperContextHash,
  unwrapTeamVaultKeyForDevice,
  wrapTeamVaultKeyForDevice,
} from "../public/team-vault-crypto.js";
import { generateVaultKey } from "../public/vault-crypto.js";
import {
  teamVaultWrapperContextHash as serverContextHash,
  validateTeamVaultEnvelope,
} from "../src/security.mjs";

const teamID = "11111111-1111-4111-8111-111111111111";
const vaultID = "22222222-2222-4222-8222-222222222222";
const otherVaultID = "33333333-3333-4333-8333-333333333333";
const membershipA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const membershipB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const deviceA = "44444444-4444-4444-8444-444444444444";
const deviceB = "55555555-5555-4555-8555-555555555555";

function recipient(identity, membershipID, deviceID) {
  return { membershipID, membershipEpoch: 1, deviceID, publicKey: identity.publicKey };
}

async function rawKey(key) {
  return Buffer.from(await webcrypto.subtle.exportKey("raw", key));
}

test("browser and server use the same canonical Team wrapper context", async () => {
  const input = {
    teamID: teamID.toUpperCase(),
    vaultID,
    keyGeneration: 7,
    membershipID: membershipA,
    membershipEpoch: 3,
    deviceID: deviceA,
  };
  assert.equal(
    teamVaultWrapperContext(input),
    [
      "selective-remote/team-vault-wrapper/v1",
      teamID,
      vaultID,
      "7",
      membershipA,
      "3",
      deviceA,
    ].join("\0"),
  );
  assert.equal(await teamVaultWrapperContextHash(input, webcrypto), serverContextHash(input));
});

test("one shared Vault key wraps independently for two non-exportable device keys", async () => {
  const identityA = await generateTeamDeviceIdentity(webcrypto);
  const identityB = await generateTeamDeviceIdentity(webcrypto);
  const vaultKey = await generateVaultKey(webcrypto);
  const [wrapperA, wrapperB] = await Promise.all([
    wrapTeamVaultKeyForDevice({
      vaultKey,
      recipient: recipient(identityA, membershipA, deviceA),
      teamID,
      vaultID,
      keyGeneration: 1,
      cryptoValue: webcrypto,
    }),
    wrapTeamVaultKeyForDevice({
      vaultKey,
      recipient: recipient(identityB, membershipB, deviceB),
      teamID,
      vaultID,
      keyGeneration: 1,
      cryptoValue: webcrypto,
    }),
  ]);

  assert.equal(identityA.privateKey.extractable, false);
  await assert.rejects(webcrypto.subtle.exportKey("jwk", identityA.privateKey));
  assert.notEqual(wrapperA.ciphertext, wrapperB.ciphertext);
  assert.notEqual(wrapperA.ephemeralPublicKey.x, wrapperB.ephemeralPublicKey.x);
  assert.equal(wrapperA.ciphertext.length, 43);
  assert.equal(wrapperA.nonce.length, 16);
  assert.equal(wrapperA.authTag.length, 22);
  assert.equal(wrapperA.contextHash.length, 43);
  assert.equal(wrapperA.contextHash, serverContextHash({
    teamID,
    vaultID,
    keyGeneration: 1,
    membershipID: membershipA,
    membershipEpoch: 1,
    deviceID: deviceA,
  }));

  const [unwrappedA, unwrappedB] = await Promise.all([
    unwrapTeamVaultKeyForDevice({
      privateKey: identityA.privateKey,
      wrapper: wrapperA,
      teamID,
      vaultID,
      keyGeneration: 1,
      deviceID: deviceA,
      cryptoValue: webcrypto,
    }),
    unwrapTeamVaultKeyForDevice({
      privateKey: identityB.privateKey,
      wrapper: wrapperB,
      teamID,
      vaultID,
      keyGeneration: 1,
      deviceID: deviceB,
      cryptoValue: webcrypto,
    }),
  ]);
  assert.deepEqual(await rawKey(unwrappedA), await rawKey(vaultKey));
  assert.deepEqual(await rawKey(unwrappedB), await rawKey(vaultKey));

  const envelope = await encryptTeamVaultPayload({
    vaultKey,
    payload: { schemaVersion: 1, records: [], tombstones: [] },
    scope: { type: "team", teamID, vaultID },
    baseRevision: 0,
    keyGeneration: 1,
    wrappers: [wrapperA, wrapperB],
    cryptoValue: webcrypto,
  });
  assert.deepEqual(validateTeamVaultEnvelope(envelope), envelope);
});

test("Team wrapper replay and a foreign private key fail closed", async () => {
  const identityA = await generateTeamDeviceIdentity(webcrypto);
  const identityB = await generateTeamDeviceIdentity(webcrypto);
  const vaultKey = await generateVaultKey(webcrypto);
  const wrapper = await wrapTeamVaultKeyForDevice({
    vaultKey,
    recipient: recipient(identityA, membershipA, deviceA),
    teamID,
    vaultID,
    keyGeneration: 2,
    cryptoValue: webcrypto,
  });

  await assert.rejects(
    unwrapTeamVaultKeyForDevice({
      privateKey: identityA.privateKey,
      wrapper,
      teamID,
      vaultID: otherVaultID,
      keyGeneration: 2,
      deviceID: deviceA,
      cryptoValue: webcrypto,
    }),
    /team_vault_wrapper_context_mismatch/,
  );
  await assert.rejects(
    unwrapTeamVaultKeyForDevice({
      privateKey: identityA.privateKey,
      wrapper,
      teamID,
      vaultID,
      keyGeneration: 3,
      deviceID: deviceA,
      cryptoValue: webcrypto,
    }),
    /team_vault_wrapper_context_mismatch/,
  );
  await assert.rejects(
    unwrapTeamVaultKeyForDevice({
      privateKey: identityB.privateKey,
      wrapper,
      teamID,
      vaultID,
      keyGeneration: 2,
      deviceID: deviceA,
      cryptoValue: webcrypto,
    }),
    /team_vault_key_unwrap_failed/,
  );
});

test("Team payload encryption is scope and generation bound without plaintext leakage", async () => {
  const vaultKey = await generateVaultKey(webcrypto);
  const scope = normalizeTeamVaultScope({ type: "team", teamID, vaultID });
  const payload = {
    schemaVersion: 1,
    records: [{ id: membershipA, type: "credential", data: { title: "Synthetic", secret: "never-on-server" } }],
    tombstones: [],
  };
  const envelope = await encryptTeamVaultPayload({
    vaultKey,
    payload,
    scope,
    baseRevision: 4,
    keyGeneration: 2,
    cryptoValue: webcrypto,
  });

  assert.deepEqual(await decryptTeamVaultPayload({ vaultKey, envelope, scope, cryptoValue: webcrypto }), payload);
  assert.equal(JSON.stringify(envelope).includes("never-on-server"), false);
  assert.equal("wrappers" in envelope, false);
  assert.deepEqual(validateTeamVaultEnvelope(envelope), { ...envelope, wrappers: null });
  await assert.rejects(
    decryptTeamVaultPayload({
      vaultKey,
      envelope,
      scope: { type: "team", teamID, vaultID: otherVaultID },
      cryptoValue: webcrypto,
    }),
    /team_vault_content_hash_mismatch/,
  );
  await assert.rejects(
    decryptTeamVaultPayload({
      vaultKey,
      envelope: { ...envelope, keyGeneration: 3 },
      scope,
      cryptoValue: webcrypto,
    }),
    /team_vault_content_hash_mismatch/,
  );
});

test("client-side rotation moves ciphertext to a new key and excludes the removed device", async () => {
  const identityA = await generateTeamDeviceIdentity(webcrypto);
  const identityB = await generateTeamDeviceIdentity(webcrypto);
  const firstKey = await generateVaultKey(webcrypto);
  const secondKey = await generateVaultKey(webcrypto);
  const scope = { type: "team", teamID, vaultID };
  const payload = { schemaVersion: 1, records: [], tombstones: [] };
  const oldWrapperB = await wrapTeamVaultKeyForDevice({
    vaultKey: firstKey,
    recipient: recipient(identityB, membershipB, deviceB),
    teamID,
    vaultID,
    keyGeneration: 1,
    cryptoValue: webcrypto,
  });
  const nextWrapperA = await wrapTeamVaultKeyForDevice({
    vaultKey: secondKey,
    recipient: recipient(identityA, membershipA, deviceA),
    teamID,
    vaultID,
    keyGeneration: 2,
    cryptoValue: webcrypto,
  });
  const rotated = await encryptTeamVaultPayload({
    vaultKey: secondKey,
    payload,
    scope,
    baseRevision: 8,
    keyGeneration: 2,
    wrappers: [nextWrapperA],
    cryptoValue: webcrypto,
  });

  const recovered = await unwrapTeamVaultKeyForDevice({
    privateKey: identityA.privateKey,
    wrapper: nextWrapperA,
    teamID,
    vaultID,
    keyGeneration: 2,
    deviceID: deviceA,
    cryptoValue: webcrypto,
  });
  assert.deepEqual(await decryptTeamVaultPayload({ vaultKey: recovered, envelope: rotated, scope, cryptoValue: webcrypto }), payload);
  await assert.rejects(
    unwrapTeamVaultKeyForDevice({
      privateKey: identityB.privateKey,
      wrapper: oldWrapperB,
      teamID,
      vaultID,
      keyGeneration: 2,
      deviceID: deviceB,
      cryptoValue: webcrypto,
    }),
    /team_vault_wrapper_context_mismatch/,
  );
});

test("device identity is generated once and repository persistence never needs an exportable private key", async () => {
  let stored = null;
  let saves = 0;
  const repository = {
    async load() { return stored ? structuredClone(stored) : null; },
    async save(value) { stored = structuredClone(value); saves += 1; },
  };
  const first = await ensureTeamDeviceIdentity({ repository, deviceID: deviceA, cryptoValue: webcrypto });
  const second = await ensureTeamDeviceIdentity({ repository, deviceID: deviceA, cryptoValue: webcrypto });

  assert.equal(saves, 1);
  assert.deepEqual(second.publicKey, first.publicKey);
  assert.equal(second.privateKey.extractable, false);
  await assert.rejects(webcrypto.subtle.exportKey("raw", second.privateKey));
});

test("identity loading rejects a public key that does not match the non-exportable private key", async () => {
  const first = await generateTeamDeviceIdentity(webcrypto);
  const second = await generateTeamDeviceIdentity(webcrypto);
  const repository = {
    async load() {
      return { deviceID: deviceA, privateKey: first.privateKey, publicKey: second.publicKey };
    },
    async save() { throw new Error("must_not_save"); },
  };
  await assert.rejects(
    ensureTeamDeviceIdentity({ repository, deviceID: deviceA, cryptoValue: webcrypto }),
    /invalid_team_device_identity/,
  );
});

test("a create-if-absent repository makes simultaneous tabs converge on one device identity", async () => {
  let stored = null;
  const repository = {
    async load() { return null; },
    async save() { throw new Error("saveIfAbsent_required"); },
    async saveIfAbsent(value) {
      if (!stored) stored = structuredClone(value);
      return structuredClone(stored);
    },
  };
  const [first, second] = await Promise.all([
    ensureTeamDeviceIdentity({ repository, deviceID: deviceA, cryptoValue: webcrypto }),
    ensureTeamDeviceIdentity({ repository, deviceID: deviceA, cryptoValue: webcrypto }),
  ]);
  assert.deepEqual(first.publicKey, second.publicKey);
});
