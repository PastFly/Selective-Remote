import { performance } from "node:perf_hooks";
import { webcrypto } from "node:crypto";
import { generateTeamDeviceIdentity } from "../public/team-vault-crypto.js";
import { generateResourceCEK, encryptResourcePart, decryptResourcePart,
  wrapResourceCEK } from "../public/resource-crypto-v2.js";

const teamID = "11111111-1111-4111-8111-111111111111";
const vaultID = "22222222-2222-4222-8222-222222222222";
const membershipID = "44444444-4444-4444-8444-444444444444";
const deviceID = "55555555-5555-4555-8555-555555555555";
const plaintext = new Uint8Array(1024);

for (const count of [100, 1000]) {
  const started = performance.now();
  for (let i = 0; i < count; i++) {
    const context = { teamID, vaultID,
      resourceID: `33333333-3333-4333-8333-${i.toString(16).padStart(12, "0")}`,
      part: "GENERAL", keyVersion: 1, policyVersion: 1, registryVersion: 1,
      resourceVersion: 1, manifestVersion: 1 };
    const cek = generateResourceCEK(webcrypto);
    const envelope = await encryptResourcePart({ plaintext, cek, context, cryptoValue: webcrypto });
    await decryptResourcePart({ envelope, cek, context, cryptoValue: webcrypto });
    cek.fill(0);
  }
  process.stdout.write(`resources=${count} ms=${(performance.now() - started).toFixed(1)}\n`);
}

const identity = await generateTeamDeviceIdentity(webcrypto);
for (const count of [10, 100]) {
  const started = performance.now();
  const cek = generateResourceCEK(webcrypto);
  for (let i = 0; i < count; i++) {
    await wrapResourceCEK({ cek, recipientPublicKey: identity.publicKey,
      context: { teamID, vaultID, resourceID: "33333333-3333-4333-8333-333333333333",
        part: "GENERAL", keyVersion: 1, membershipID, membershipEpoch: 1,
        deviceID: `55555555-5555-4555-8555-${i.toString(16).padStart(12, "0")}` },
      cryptoValue: webcrypto });
  }
  cek.fill(0);
  process.stdout.write(`wrappers=${count} ms=${(performance.now() - started).toFixed(1)}\n`);
}
