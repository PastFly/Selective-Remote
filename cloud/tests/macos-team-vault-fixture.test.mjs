import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createHash, webcrypto } from "node:crypto";
import test from "node:test";
import {
  teamDevicePublicKeyFingerprint,
  teamVaultWrapperContext,
  teamVaultWrapperContextHash,
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
