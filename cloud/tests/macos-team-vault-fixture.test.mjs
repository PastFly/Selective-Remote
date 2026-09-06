import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createHash, webcrypto } from "node:crypto";
import test from "node:test";
import {
  decryptTeamVaultPayload,
  teamDevicePublicKeyFingerprint,
  teamVaultWrapperContext,
  teamVaultWrapperContextHash,
  unwrapTeamVaultKeyForDevice,
} from "../public/team-vault-crypto.js";

const fixtureURL = new URL(
  "../../Tests/SelectiveRemoteTests/Fixtures/team-vault-v1.json",
  import.meta.url,
);

function decodeBase64URL(value) {
  return Buffer.from(value, "base64url");
}

test("shared macOS/browser fixture locks Team crypto canonicalization", async () => {
  const fixture = JSON.parse(await readFile(fixtureURL, "utf8"));
  assert.equal(fixture.version, 1);
  assert.equal(
    await teamDevicePublicKeyFingerprint(fixture.publicKey, webcrypto),
    fixture.fingerprint,
  );
  assert.equal(
    Buffer.from(teamVaultWrapperContext(fixture.wrapper)).toString("base64url"),
    fixture.wrapper.contextBase64URL,
  );
  assert.equal(
    await teamVaultWrapperContextHash(fixture.wrapper, webcrypto),
    fixture.wrapper.contextHash,
  );

  const payloadContext = [
    "selective-remote/team-vault-payload/v1",
    fixture.payload.teamID,
    fixture.payload.vaultID,
    String(fixture.payload.keyGeneration),
  ].join("\0");
  assert.equal(Buffer.from(payloadContext).toString("base64url"), fixture.payload.contextBase64URL);
  const contentHash = createHash("sha256").update(Buffer.concat([
    Buffer.from([fixture.payload.envelopeVersion]),
    Buffer.from(payloadContext),
    decodeBase64URL(fixture.payload.nonce),
    decodeBase64URL(fixture.payload.ciphertext),
    decodeBase64URL(fixture.payload.authTag),
  ])).digest("base64url");
  assert.equal(contentHash, fixture.payload.contentHash);
});

test("browser unwraps the deterministic macOS Team Vault key wrapper", async () => {
  const fixture = JSON.parse(await readFile(fixtureURL, "utf8"));
  const privateKey = await webcrypto.subtle.importKey(
    "jwk",
    {
      ...fixture.publicKey,
      d: fixture.keyWrap.recipientPrivateScalar,
      key_ops: ["deriveBits"],
    },
    { name: "ECDH", namedCurve: "P-256" },
    false,
    ["deriveBits"],
  );
  const wrapper = {
    membershipID: fixture.wrapper.membershipID,
    membershipEpoch: fixture.wrapper.membershipEpoch,
    deviceID: fixture.wrapper.deviceID,
    wrapperVersion: 1,
    ephemeralPublicKey: fixture.keyWrap.ephemeralPublicKey,
    ciphertext: fixture.keyWrap.ciphertext,
    nonce: fixture.keyWrap.nonce,
    authTag: fixture.keyWrap.authTag,
    contextHash: fixture.wrapper.contextHash,
  };
  const key = await unwrapTeamVaultKeyForDevice({
    privateKey,
    wrapper,
    teamID: fixture.wrapper.teamID,
    vaultID: fixture.wrapper.vaultID,
    keyGeneration: fixture.wrapper.keyGeneration,
    deviceID: fixture.wrapper.deviceID,
    cryptoValue: webcrypto,
  });
  assert.equal(
    Buffer.from(await webcrypto.subtle.exportKey("raw", key)).toString("base64url"),
    fixture.keyWrap.vaultKey,
  );
});

test("browser decrypts the deterministic macOS Team Vault payload", async () => {
  const fixture = JSON.parse(await readFile(fixtureURL, "utf8"));
  const vaultKey = await webcrypto.subtle.importKey(
    "raw",
    decodeBase64URL(fixture.keyWrap.vaultKey),
    { name: "AES-GCM", length: 256 },
    false,
    ["decrypt"],
  );
  const envelope = {
    baseRevision: fixture.payload.baseRevision,
    keyGeneration: fixture.payload.keyGeneration,
    envelopeVersion: fixture.payload.envelopeVersion,
    ciphertext: fixture.payload.ciphertext,
    nonce: fixture.payload.nonce,
    authTag: fixture.payload.authTag,
    contentHash: fixture.payload.contentHash,
  };
  const payload = await decryptTeamVaultPayload({
    vaultKey,
    envelope,
    scope: {
      type: "team",
      teamID: fixture.payload.teamID,
      vaultID: fixture.payload.vaultID,
    },
    cryptoValue: webcrypto,
  });
  assert.deepEqual(payload, JSON.parse(decodeBase64URL(fixture.payload.plaintext).toString("utf8")));
});
