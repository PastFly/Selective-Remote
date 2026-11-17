import { migrationFixture, uuid } from "./vault-v2-migration-fixtures.mjs";
import { validateSignedDeviceBundle } from "../src/device-trust-policy.mjs";
import { MemoryPublicationFence } from "./publication-fence-fixtures.mjs";
export async function seedMigration(pool) {
  const f = await migrationFixture(),
    user = f.accountID,
    team = f.scope.teamID,
    vault = f.scope.vaultID;
  await pool.query(
    "INSERT INTO users(id,email,username,email_verified_at) VALUES($1,$2,$3,now())",
    [
      user,
      `${user}@example.test`,
      "m_" + user.replaceAll("-", "").slice(0, 24),
    ],
  );
  await pool.query(
    "INSERT INTO devices(id,user_id,name,platform,public_key,public_key_algorithm,key_registered_at,key_approved_at) VALUES($1,$2,'synthetic','test',$3,'p256-ecdh-v1',now(),now())",
    [f.deviceID, user, JSON.stringify(f.identity.publicKey)],
  );
  await pool.query(
    "INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'synthetic',$2)",
    [team, user],
  );
  await pool.query(
    "INSERT INTO team_memberships(id,team_id,user_id,role) VALUES($1,$2,$3,'owner')",
    [f.recipient.membershipID, team, user],
  );
  await pool.query(
    "INSERT INTO team_membership_device_admissions(membership_id,membership_epoch,device_id) VALUES($1,1,$2)",
    [f.recipient.membershipID, f.deviceID],
  );
  await pool.query(
    "INSERT INTO shared_vaults(id,team_id,name,created_by_user_id,revision,envelope_version,ciphertext,nonce,auth_tag,content_hash,updated_by_device_id) VALUES($1,$2,'synthetic',$3,1,1,'LEGACY_ENCRYPTED_DATA','AAAAAAAAAAAAAAAA','AAAAAAAAAAAAAAAAAAAAAA',$4,$5)",
    [vault, team, user, "A".repeat(43), f.deviceID],
  );
  const b = await validateSignedDeviceBundle({
    ...f.recipient,
    accountID: user,
  });
  await pool.query(
    "INSERT INTO device_trust_roots_v1(account_id,root_public_key,fingerprint,custodian_device_id) VALUES($1,$2,$3,$4)",
    [user, b.rootBytes, b.fingerprint, f.deviceID],
  );
  await pool.query(
    "INSERT INTO device_trust_certificates_v1(account_id,device_id,key_version,certificate_bytes,signature,serial,certificate_json) VALUES($1,$2,1,$3,$4,$5,$6)",
    [
      user,
      f.deviceID,
      b.certificateBytes,
      b.certificateSignature,
      b.serial,
      f.recipient.certificate,
    ],
  );
  await pool.query(
    "INSERT INTO device_trust_directories_v1(account_id,version,directory_bytes,signature,directory_json) VALUES($1,1,$2,$3,$4)",
    [user, b.directoryBytes, b.directorySignature, f.recipient.checkpoint],
  );
  return {
    ...f,
    input: {
      actorUserID: user,
      actorDeviceID: f.deviceID,
      teamID: team,
      vaultID: vault,
      attemptID: f.scope.attemptID,
      schemaVersion: 2,
      capability: "resource_acl_v2",
    },
    config: {
      environment: "staging",
      enabled: true,
      allowedVaultIDs: [vault],
      // Explicit unit fixtures only: integration durability tests inject a real file fence.
      fence: new MemoryPublicationFence(),
      activationGuard: async () => {},
    },
  };
}
export async function addSyntheticDevices(pool, f, count = 2) {
  const { generateTeamDeviceIdentity } = await import(
    "../public/team-vault-crypto.js"
  );
  const { issueDeviceCertificate, signDeviceDirectory } = await import(
    "../public/device-trust-v1.js"
  );
  const certificates = [f.recipient.certificate];
  const identities = [];
  for (let n = 0; n < count; n++) {
    const deviceID = uuid(),
      identity = await generateTeamDeviceIdentity();
    const certificate = await issueDeviceCertificate({
      root: f.root,
      accountID: f.accountID,
      deviceID,
      publicKey: identity.publicKey,
      keyVersion: 1,
      issuedAt: 1800000000,
      serial: uuid(),
    });
    certificates.push(certificate);
    identities.push({ deviceID, identity, certificate });
  }
  const checkpoint = await signDeviceDirectory({
    root: f.root,
    accountID: f.accountID,
    version: 2,
    certificates,
  });
  for (const { deviceID, identity, certificate } of identities) {
    const b = await validateSignedDeviceBundle({
      rootPublicKey: f.root.publicKey,
      certificate,
      checkpoint,
      accountID: f.accountID,
      deviceID,
      publicKey: identity.publicKey,
    });
    await pool.query(
      "INSERT INTO devices(id,user_id,name,platform,public_key,public_key_algorithm,key_registered_at,key_approved_at) VALUES($1,$2,'synthetic extra','test',$3,'p256-ecdh-v1',now(),now())",
      [deviceID, f.accountID, JSON.stringify(identity.publicKey)],
    );
    await pool.query(
      "INSERT INTO team_membership_device_admissions(membership_id,membership_epoch,device_id) VALUES($1,1,$2)",
      [f.recipient.membershipID, deviceID],
    );
    await pool.query(
      "INSERT INTO device_trust_certificates_v1(account_id,device_id,key_version,certificate_bytes,signature,serial,certificate_json) VALUES($1,$2,1,$3,$4,$5,$6)",
      [
        f.accountID,
        deviceID,
        b.certificateBytes,
        b.certificateSignature,
        b.serial,
        certificate,
      ],
    );
  }
  const { validateSignedDeviceDirectory } = await import(
    "../src/device-trust-policy.mjs"
  );
  const b = await validateSignedDeviceDirectory({
    rootPublicKey: f.root.publicKey,
    checkpoint,
    accountID: f.accountID,
  });
  await pool.query(
    "INSERT INTO device_trust_directories_v1(account_id,version,directory_bytes,signature,directory_json) VALUES($1,2,$2,$3,$4)",
    [f.accountID, b.directoryBytes, b.directorySignature, checkpoint],
  );
  return identities;
}
