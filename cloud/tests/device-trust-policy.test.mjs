import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import { generateTeamDeviceIdentity } from "../public/team-vault-crypto.js";
import { createTrustRoot, issueDeviceCertificate, signDeviceDirectory } from "../public/device-trust-v1.js";
import { validateSignedDeviceBundle } from "../src/device-trust-policy.mjs";

const accountID = "11111111-1111-4111-8111-111111111111";
const deviceID = "55555555-5555-4555-8555-555555555555";

test("server rejects a substituted key or forged signed bootstrap bundle", async () => {
  const root = await createTrustRoot({ endpoint: "https://cloud.example.test", accountID,
    cryptoValue: webcrypto });
  const device = await generateTeamDeviceIdentity(webcrypto);
  const certificate = await issueDeviceCertificate({ root, accountID, deviceID,
    publicKey: device.publicKey, keyVersion: 1, issuedAt: 1_800_000_000,
    serial: "88888888-8888-4888-8888-888888888888", cryptoValue: webcrypto });
  const checkpoint = await signDeviceDirectory({ root, accountID, version: 1,
    certificates: [certificate], cryptoValue: webcrypto });
  const input = { rootPublicKey: root.publicKey, certificate, checkpoint,
    accountID, deviceID, publicKey: device.publicKey };
  const valid = await validateSignedDeviceBundle(input);
  assert.equal(valid.keyVersion, 1);
  assert.equal(valid.directoryVersion, 1);
  assert.equal(valid.serial, certificate.payload.serial);
  const attacker = await generateTeamDeviceIdentity(webcrypto);
  await assert.rejects(validateSignedDeviceBundle({ ...input, publicKey: attacker.publicKey }),
    /device_trust/u);
  await assert.rejects(validateSignedDeviceBundle({ ...input,
    certificate: { ...certificate, payload: { ...certificate.payload,
      deviceID: "66666666-6666-4666-8666-666666666666" } } }), /device_trust/u);
  await assert.rejects(validateSignedDeviceBundle({ ...input,
    checkpoint: { ...checkpoint, payload: { ...checkpoint.payload, version: 2 } } }),
  /device_trust/u);
});
