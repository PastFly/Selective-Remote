import { createHash, webcrypto } from "node:crypto";
import { normalizeTeamDevicePublicKey } from "../public/team-vault-crypto.js";
import { deviceCertificateBytes, deviceDirectoryBytes, deviceDirectoryDigest,
  verifyDeviceForWrapping } from "../public/device-trust-v1.js";

const fail = () => { throw new Error("device_trust_invalid"); };
const encoded = (value, length) => {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/u.test(value)) fail();
  const result = Buffer.from(value, "base64url");
  if (result.length !== length || result.toString("base64url") !== value) fail();
  return result;
};
const publicBytes = (value) => {
  const key = normalizeTeamDevicePublicKey(value);
  return Buffer.concat([Buffer.from([4]), encoded(key.x, 32), encoded(key.y, 32)]);
};

export async function validateSignedDeviceBundle({ rootPublicKey, certificate,
  checkpoint, accountID, deviceID, publicKey }) {
  try {
    const rootBytes = encoded(rootPublicKey, 65);
    const rootFingerprint = createHash("sha256").update(rootBytes).digest("hex");
    const checkpointDigest = await deviceDirectoryDigest(checkpoint, webcrypto);
    const verified = await verifyDeviceForWrapping({ rootPublicKey, certificate,
      checkpoint, trust: { endpoint: "https://device-trust.invalid", accountID,
        rootFingerprint, highWater: checkpoint.payload.version, checkpointDigest },
      expectedDeviceID: deviceID, cryptoValue: webcrypto });
    if (!publicBytes(verified.publicKey).equals(publicBytes(publicKey))) fail();
    return { rootBytes, fingerprint: Buffer.from(rootFingerprint, "hex"),
      certificateBytes: Buffer.from(deviceCertificateBytes(certificate.payload)),
      certificateSignature: encoded(certificate.signature, 64),
      directoryBytes: Buffer.from(deviceDirectoryBytes(checkpoint.payload)),
      directorySignature: encoded(checkpoint.signature, 64),
      publicKeyBytes: publicBytes(publicKey),
      keyDigest: createHash("sha256").update(publicBytes(publicKey)).digest(),
      keyVersion: certificate.payload.keyVersion,
      directoryVersion: checkpoint.payload.version,
      serial: certificate.payload.serial,
      checkpointDigest };
  } catch { fail(); }
}
