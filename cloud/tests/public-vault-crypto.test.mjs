import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import {
  decryptVaultEnvelope,
  encryptVaultPayload,
  generateVaultKey,
  recoveryKDFIterations,
  unwrapVaultKey,
  vaultEnvelopeVersion,
  wrapVaultKey,
} from "../public/vault-crypto.js";
import { validateVaultEnvelope } from "../src/security.mjs";

const passphrase = "correct horse battery staple for recovery";

async function fixture() {
  const vaultKey = await generateVaultKey(webcrypto);
  const wrappedKey = await wrapVaultKey(vaultKey, passphrase, webcrypto);
  const payload = {
    schemaVersion: 1,
    records: [{ id: "018f2d22-bb75-7d2a-8e72-d6ad9f5c2180", type: "host", title: "Synthetic host" }],
    tombstones: [],
  };
  const envelope = await encryptVaultPayload({
    vaultKey,
    payload,
    baseRevision: 0,
    wrappedKey,
    cryptoValue: webcrypto,
  });
  return { vaultKey, wrappedKey, payload, envelope };
}

test("browser Vault envelope round-trips only through the recovery-wrapped key", async () => {
  const { wrappedKey, payload, envelope } = await fixture();
  const recoveredVaultKey = await unwrapVaultKey(wrappedKey, passphrase, webcrypto);

  assert.deepEqual(await decryptVaultEnvelope(recoveredVaultKey, envelope, webcrypto), payload);
  assert.equal(envelope.envelopeVersion, vaultEnvelopeVersion);
  assert.equal(envelope.baseRevision, 0);
  assert.equal(envelope.nonce.length, 16);
  assert.equal(envelope.authTag.length, 22);
  assert.equal(envelope.contentHash.length, 43);
  assert.equal(wrappedKey.algorithm, "PBKDF2-SHA256+A256KW");
  assert.equal(wrappedKey.iterations, recoveryKDFIterations);
  assert.equal(wrappedKey.salt.length, 22);
  assert.equal(wrappedKey.value.length, 54);
  assert.deepEqual(validateVaultEnvelope(envelope), envelope);
});

test("ciphertext and recovery metadata never contain Vault plaintext", async () => {
  const { envelope } = await fixture();
  const serialized = JSON.stringify(envelope);

  assert.equal(serialized.includes("Synthetic host"), false);
  assert.equal(serialized.includes("records"), false);
  assert.equal(serialized.includes(passphrase), false);
});

test("fresh nonces make equal Vault payloads produce different encrypted revisions", async () => {
  const { vaultKey, wrappedKey, payload } = await fixture();
  const first = await encryptVaultPayload({ vaultKey, wrappedKey, payload, baseRevision: 1, cryptoValue: webcrypto });
  const second = await encryptVaultPayload({ vaultKey, wrappedKey, payload, baseRevision: 1, cryptoValue: webcrypto });

  assert.notEqual(first.nonce, second.nonce);
  assert.notEqual(first.ciphertext, second.ciphertext);
  assert.notEqual(first.contentHash, second.contentHash);
});

test("wrong recovery passphrases and downgraded KDF metadata fail closed", async () => {
  const { wrappedKey } = await fixture();
  await assert.rejects(
    unwrapVaultKey(wrappedKey, "a different recovery passphrase", webcrypto),
    (error) => error.message === "invalid_recovery_passphrase",
  );
  await assert.rejects(
    unwrapVaultKey({ ...wrappedKey, iterations: 10_000 }, passphrase, webcrypto),
    (error) => error.message === "invalid_wrapped_key",
  );
  await assert.rejects(
    unwrapVaultKey({ ...wrappedKey, serverHint: "unexpected" }, passphrase, webcrypto),
    (error) => error.message === "invalid_wrapped_key",
  );
});

test("canonically equivalent Unicode recovery passphrases are interoperable", async () => {
  const vaultKey = await generateVaultKey(webcrypto);
  const decomposed = "long recovery cafe\u0301 passphrase";
  const composed = "long recovery café passphrase";
  const wrappedKey = await wrapVaultKey(vaultKey, decomposed, webcrypto);
  const recoveredVaultKey = await unwrapVaultKey(wrappedKey, composed, webcrypto);
  const envelope = await encryptVaultPayload({
    vaultKey,
    wrappedKey,
    payload: { schemaVersion: 1, records: [], tombstones: [] },
    baseRevision: 0,
    cryptoValue: webcrypto,
  });

  assert.deepEqual(
    await decryptVaultEnvelope(recoveredVaultKey, envelope, webcrypto),
    { schemaVersion: 1, records: [], tombstones: [] },
  );
});

test("ciphertext, tag and hash tampering is rejected before plaintext is returned", async () => {
  const { vaultKey, envelope } = await fixture();
  const tamperedHash = `${envelope.contentHash.startsWith("A") ? "B" : "A"}${envelope.contentHash.slice(1)}`;
  await assert.rejects(
    decryptVaultEnvelope(vaultKey, { ...envelope, contentHash: tamperedHash }, webcrypto),
    (error) => error.message === "vault_content_hash_mismatch",
  );

  const tamperedCiphertext = `${envelope.ciphertext.slice(0, -1)}${envelope.ciphertext.endsWith("A") ? "B" : "A"}`;
  await assert.rejects(
    decryptVaultEnvelope(vaultKey, { ...envelope, ciphertext: tamperedCiphertext }, webcrypto),
    (error) => error.message === "vault_content_hash_mismatch",
  );
});

test("a valid content hash cannot bypass AES-GCM authentication with the wrong Vault key", async () => {
  const { envelope } = await fixture();
  const wrongVaultKey = await generateVaultKey(webcrypto);

  await assert.rejects(
    decryptVaultEnvelope(wrongVaultKey, envelope, webcrypto),
    (error) => error.message === "vault_decryption_failed",
  );
});

test("invalid payloads and revisions never enter encryption", async () => {
  const vaultKey = await generateVaultKey(webcrypto);
  const wrappedKey = await wrapVaultKey(vaultKey, passphrase, webcrypto);

  await assert.rejects(
    encryptVaultPayload({ vaultKey, wrappedKey, payload: [], baseRevision: 0, cryptoValue: webcrypto }),
    (error) => error.message === "invalid_vault_payload",
  );
  await assert.rejects(
    encryptVaultPayload({ vaultKey, wrappedKey, payload: {}, baseRevision: -1, cryptoValue: webcrypto }),
    (error) => error.message === "invalid_base_revision",
  );
});
