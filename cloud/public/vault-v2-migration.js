// Staging foundation only: no UI or production route imports this converter.
import {
  generateResourceCEK,
  encryptResourcePart,
  decryptResourcePart,
  unwrapResourceCEK,
} from "./resource-crypto-v2.js";
import { wrapForVerifiedDevice } from "./device-trust-v1.js";
import { inspectLegacyResources, mapLegacyResources, legacyAdministrativeMetadata } from "./legacy-resource-mapping.js";
import { prepareReaderProjection, publicationHash, validateReaderProjection } from "./vault-publication-v1.js";
export const canonicalMigrationJSON = (value) => {
  if (value === null || typeof value === "string" || typeof value === "boolean")
    return JSON.stringify(value);
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (Array.isArray(value))
    return "[" + value.map(canonicalMigrationJSON).join(",") + "]";
  if (
    value &&
    typeof value === "object" &&
    Object.getPrototypeOf(value) === Object.prototype
  )
    return (
      "{" +
      Object.keys(value)
        .sort()
        .map((k) => JSON.stringify(k) + ":" + canonicalMigrationJSON(value[k]))
        .join(",") +
      "}"
    );
  throw Error("invalid_migration_json");
};
const enc = new TextEncoder(),
  dec = new TextDecoder(),
  idPattern =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
function requireRecipientAccount(target) {
  if (typeof target?.accountID !== "string" || !idPattern.test(target.accountID)
    || target.accountID !== target.certificate?.payload?.accountID
    || target.accountID !== target.checkpoint?.payload?.accountID)
    throw Error("recipient_account_mismatch");
}
export const migrationBytes = (value) =>
  enc.encode(
    "selective-remote/vault-migration/v2\0" + canonicalMigrationJSON(value),
  );
export const toBase64 = (value) => {
  let binary = "";
  for (let offset = 0; offset < value.length; offset += 32768)
    binary += String.fromCharCode(...value.subarray(offset, offset + 32768));
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
};
export const MIGRATION_CHECKPOINT_LIMIT = 64 * 1024 * 1024;
export function migrationCheckpointBudget(document, partCount, wrapperCount = 0, folders = []) {
  // Conservative allowance for source + duplicated payload JSON + two base64 layers,
  // bounded descriptors and complete device wrappers. Checked before encryption.
  return 4 * (enc.encode(canonicalMigrationJSON(document)).length + enc.encode(canonicalMigrationJSON(folders)).length) + partCount * 8192 + wrapperCount * 4096;
}
export const fromBase64 = (value) =>
  Uint8Array.from(atob(value.replaceAll("-", "+").replaceAll("_", "/")), (c) =>
    c.charCodeAt(0),
  );
export async function migrationHash(value, cryptoValue = globalThis.crypto) {
  return Array.from(
    new Uint8Array(
      await cryptoValue.subtle.digest("SHA-256", migrationBytes(value)),
    ),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
}
const kinds = {
  host: "HOST",
  credential: "CREDENTIAL",
  snippet: "SNIPPET",
  forwarding: "FORWARDING",
};
function embeddedSecret(value) {
  return (
    value &&
    typeof value === "object" &&
    Object.entries(value).some(
      ([k, v]) =>
        (/password|secret|private.?key|passphrase|token/i.test(k) &&
          v !== null &&
          v !== "") ||
        embeddedSecret(v),
    )
  );
}
function inventory(document, existingIDs = []) {
  const result = inspectLegacyResources(document, existingIDs);
  const parts = result.items.reduce((n,r) => n + (r.kind === "CREDENTIAL" ? 2 : 1), result.folders.length);
  if (migrationCheckpointBudget(document, parts, 0, result.folders) > MIGRATION_CHECKPOINT_LIMIT)
    result.blockers.push("checkpoint_size_limit");
  return result;
}
export function previewLegacyMigration({ document, existingIDs = [] }) {
  const i = inventory(document, existingIDs);
  return {
    resourceCount: i.items.length + i.folders.length,
    folderCount: i.folders.length,
    credentialCount: i.items.filter((r) => r.kind === "CREDENTIAL").length,
    partCount: i.items.reduce(
      (n, r) => n + (r.kind === "CREDENTIAL" ? 2 : 1),
      i.folders.length,
    ),
    tombstoneCount: document.tombstones.length,
    missingIDs: i.missingIDs,
    blockers: i.blockers,
  };
}
function validateScope(scope) {
  if (
    !scope ||
    !["teamID", "vaultID", "attemptID"].every((k) =>
      idPattern.test(scope[k]),
    ) ||
    !["sourceRevision", "policyVersion"].every(
      (k) => Number.isSafeInteger(scope[k]) && scope[k] > 0,
    ) ||
    !["sourceHash", "snapshotHash"].every((k) =>
      /^[a-f0-9]{64}$/.test(scope[k]),
    )
  )
    throw Error("invalid_migration_scope");
}
async function seal(state, key, scope, crypto) {
  const nonce = crypto.getRandomValues(new Uint8Array(12)),
    imported = await crypto.subtle.importKey("raw", key, "AES-GCM", false, [
      "encrypt",
    ]);
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce, additionalData: migrationBytes(scope) },
    imported,
    enc.encode(canonicalMigrationJSON(state)),
  );
  if (Math.ceil(ciphertext.byteLength * 4 / 3) > MIGRATION_CHECKPOINT_LIMIT) throw Error("checkpoint_size_limit");
  return {
    version: 1,
    nonce: toBase64(nonce),
    ciphertext: toBase64(new Uint8Array(ciphertext)),
  };
}
export async function openMigrationCheckpoint({
  checkpoint,
  key,
  scope,
  cryptoValue = globalThis.crypto,
}) {
  validateScope(scope);
  if (
    checkpoint?.version !== 1 ||
    typeof checkpoint.ciphertext !== "string" ||
    checkpoint.ciphertext.length > MIGRATION_CHECKPOINT_LIMIT
  )
    throw Error("invalid_migration_checkpoint");
  const imported = await cryptoValue.subtle.importKey(
    "raw",
    key,
    "AES-GCM",
    false,
    ["decrypt"],
  );
  return JSON.parse(
    dec.decode(
      await cryptoValue.subtle.decrypt(
        {
          name: "AES-GCM",
          iv: fromBase64(checkpoint.nonce),
          additionalData: migrationBytes(scope),
        },
        imported,
        fromBase64(checkpoint.ciphertext),
      ),
    ),
  );
}
function createInventoryState(i, document, documentHash, policyHash, crypto, scope) {
  const identities = mapLegacyResources({document, scope, cryptoValue: crypto});
  return {documentHash, policyHash, mapping: identities.mapping, mappingState: identities,
    document, resources: identities.resources, objects: []};
}
export async function prepareMigrationInventory({
  document,
  scope,
  checkpointKey,
  checkpoint,
  persistCheckpoint,
  existingIDs = [],
  cryptoValue = globalThis.crypto,
}) {
  validateScope(scope);
  const i = inventory(document, existingIDs);
  if (i.blockers.length) throw Error(i.blockers[0]);
  if (typeof persistCheckpoint !== "function")
    throw Error("checkpoint_persistence_required");
  const hash = await migrationHash(document, cryptoValue);
  const state = checkpoint
    ? await openMigrationCheckpoint({
        checkpoint,
        key: checkpointKey,
        scope,
        cryptoValue,
      })
    : createInventoryState(i, document, hash, null, cryptoValue, scope);
  if (state.documentHash !== hash) throw Error("migration_source_changed");
  const sealed = await seal(state, checkpointKey, scope, cryptoValue);
  await persistCheckpoint(sealed);
  return { resources: state.resources, checkpoint: sealed };
}
export async function prepareLegacyMigration({
  document,
  scope,
  policy,
  recipientTargets,
  pinnedTrust,
  root,
  identity,
  deviceID,
  endpoint,
  checkpointKey,
  checkpoint,
  persistCheckpoint,
  readerPublication = null,
  faultAt = () => {},
  cryptoValue = globalThis.crypto,
}) {
  validateScope(scope);
  const i = inventory(document);
  if (i.blockers.length) throw Error(i.blockers[0]);
  if (typeof persistCheckpoint !== "function")
    throw Error("checkpoint_persistence_required");
  const documentHash = await migrationHash(document, cryptoValue),
    policyHash = await migrationHash(policy, cryptoValue);
  let state;
  if (checkpoint) {
    state = await openMigrationCheckpoint({
      checkpoint,
      key: checkpointKey,
      scope,
      cryptoValue,
    });
    if (
      state.documentHash !== documentHash ||
      (state.policyHash !== null && state.policyHash !== policyHash)
    )
      throw Error("migration_source_changed");
  } else {
    state = createInventoryState(
      i,
      document,
      documentHash,
      policyHash,
      cryptoValue,
      scope,
    );
  }
  if (readerPublication) {
    if (!state.mappingState || typeof readerPublication.verifyIdentityReservations !== "function")
      throw Error("identity_reservation_verification_required");
    if (readerPublication.publisherAccountID !== root.accountID
      || !Number.isSafeInteger(readerPublication.publisherKeyVersion) || readerPublication.publisherKeyVersion < 1
      || !Array.isArray(readerPublication.custodianDeviceIDs) || !readerPublication.custodianDeviceIDs.length
      || readerPublication.custodianDeviceIDs.length > 100
      || !readerPublication.custodianDeviceIDs.includes(deviceID)
      || new Set(readerPublication.custodianDeviceIDs).size !== readerPublication.custodianDeviceIDs.length
      || readerPublication.custodianDeviceIDs.some(id => !idPattern.test(id))) throw Error("invalid_publishing_custodian");
    const options = { publisherAccountID: readerPublication.publisherAccountID,
      publisherKeyVersion: readerPublication.publisherKeyVersion,
      custodianDeviceIDs: [...readerPublication.custodianDeviceIDs].sort() };
    if (state.readerOptions && canonicalMigrationJSON(state.readerOptions) !== canonicalMigrationJSON(options))
      throw Error("migration_reader_options_changed");
    if (!state.readerOptions && state.objects.length) throw Error("reader_checkpoint_upgrade_required");
    state.readerOptions = options;
    legacyAdministrativeMetadata({ document, mapping: state.mappingState, sourceFingerprint: documentHash });
    await readerPublication.verifyIdentityReservations(state.resources);
    await faultAt("identities_reserved");
  } else if (state.readerOptions) throw Error("migration_reader_options_changed");
  const targetCache = new Map();
  let wrapperCount = 0, partCount = 0;
  for (const r of state.resources) for (const part of (r.kind === "CREDENTIAL" ? ["METADATA","SECRET"] : ["GENERAL"])) {
    const targets = await recipientTargets(r, part);
    if (!Array.isArray(targets) || !targets.length || targets.length > 100) throw Error("recipient_missing");
    for (const target of targets) requireRecipientAccount(target);
    targetCache.set(r.id + ":" + part, targets);
    wrapperCount += targets.length; partCount++;
  }
  if (readerPublication && wrapperCount + readerPublication.custodianDeviceIDs.length > 10000)
    throw Error("publication_limit");
  if (migrationCheckpointBudget(document, partCount + (readerPublication ? 1 : 0),
    wrapperCount + (readerPublication ? readerPublication.custodianDeviceIDs.length : 0), i.folders) > MIGRATION_CHECKPOINT_LIMIT)
    throw Error("checkpoint_size_limit");
  state.policyHash = policyHash;
  let saved;
  const persist = async () => {
    saved = await seal(state, checkpointKey, scope, cryptoValue);
    await persistCheckpoint(saved);
  };
  await persist();
  await faultAt("identities_persisted");
  for (const resource of state.resources) {
    const r = i.items.find((r) => state.mapping[r.key] === resource.id),
      folder = i.folders.find((f) => state.mapping[f.key] === resource.id);
    let payloads =
      r?.kind === "CREDENTIAL"
        ? {
            METADATA: Object.fromEntries([
              ["resourceID", resource.id],
              ...["title", "kind", "username"]
                .filter((k) => typeof r.record.data[k] === "string")
                .map((k) => [k, r.record.data[k]]),
            ]),
            SECRET: { record: r.record },
          }
        : {
            GENERAL: r
              ? { record: r.record }
              : { folder, resourceID: resource.id },
          };
    if (readerPublication) {
      const link = part => ({ teamID: scope.teamID, vaultID: scope.vaultID,
        generationID: scope.attemptID, resourceID: resource.id, kind: resource.kind, part });
      payloads = r?.kind === "CREDENTIAL" ? {
        METADATA: { link: link("METADATA"), metadata: Object.fromEntries(["title", "kind", "username"]
          .filter(k => typeof r.record.data[k] === "string").map(k => [k, r.record.data[k]])) },
        SECRET: { link: link("SECRET"), record: r.record },
      } : { GENERAL: { link: link("GENERAL"), ...(r ? { record: r.record } :
        { folder: { type: folder.type, path: folder.path, component: folder.component } }) } };
    }
    for (const [part, payload] of Object.entries(payloads)) {
      if (
        state.objects.some(
          (o) => o.resourceID === resource.id && o.part === part,
        )
      )
        continue;
      const targets = targetCache.get(resource.id + ":" + part);
      if (!Array.isArray(targets) || !targets.length || targets.length > 100)
        throw Error("recipient_missing");
      const context = {
        teamID: scope.teamID,
        vaultID: scope.vaultID,
        resourceID: resource.id,
        part,
        keyVersion: 1,
        policyVersion: scope.policyVersion,
        registryVersion: 1,
        resourceVersion: 1,
        manifestVersion: 1,
      };
      const cek = generateResourceCEK(cryptoValue);
      try {
        const envelope = await encryptResourcePart({
          plaintext: enc.encode(canonicalMigrationJSON(payload)),
          cek,
          context,
          cryptoValue,
        });
        await faultAt("ciphertext");
        const wrappers = [];
        for (const target of targets) {
          requireRecipientAccount(target);
          const wrap = await wrapForVerifiedDevice({
            cek,
            context: {
              teamID: scope.teamID,
              vaultID: scope.vaultID,
              resourceID: resource.id,
              part,
              keyVersion: 1,
              membershipID: target.membershipID,
              membershipEpoch: target.membershipEpoch,
              deviceID: target.deviceID,
            },
            rootPublicKey: target.rootPublicKey,
            certificate: target.certificate,
            checkpoint: target.checkpoint,
            endpoint,
            pinRepository: pinnedTrust,
            cryptoValue,
          });
          wrappers.push(wrap.wrapper);
        }
        await faultAt("wrappers");
        const self = wrappers.find((w) => w.context.deviceID === deviceID);
        if (!self) throw Error("self_wrapper_required");
        const roundtrip = await unwrapResourceCEK({
          wrapper: self,
          context: self.context,
          privateKey: identity.privateKey,
          cryptoValue,
        });
        try {
          const opened = await decryptResourcePart({
            envelope,
            context,
            cek: roundtrip,
            cryptoValue,
          });
          if (dec.decode(opened) !== canonicalMigrationJSON(payload))
            throw Error("migration_roundtrip_failed");
        } finally {
          roundtrip.fill(0);
        }
        const object = { resourceID: resource.id, part, envelope, wrappers };
        object.sha256 = await migrationHash(object, cryptoValue);
        if (readerPublication && enc.encode(canonicalMigrationJSON(object)).length > 1024 * 1024)
          throw Error("publication_limit");
        state.objects.push(object);
        await persist();
        await faultAt("part_persisted");
      } finally {
        cek.fill(0);
      }
    }
  }
  if (readerPublication) {
    const targets = new Map();
    for (const list of [...targetCache.values(), readerPublication.custodianTargets ?? []]) for (const target of list) {
      requireRecipientAccount(target);
      const key = target.membershipID + "/" + target.deviceID;
      if (targets.has(key) && canonicalMigrationJSON(targets.get(key)) !== canonicalMigrationJSON(target))
        throw Error("migration_recipient_changed");
      targets.set(key, target);
    }
    const recipients = [...targets.values()].map(target => ({ accountID: target.accountID,
      membershipID: target.membershipID, membershipEpoch: target.membershipEpoch,
      deviceID: target.deviceID, deviceKeyVersion: target.certificate.payload.keyVersion }));
    const publisher = [...targets.values()].find(t => t.deviceID === deviceID && t.accountID === root.accountID);
    if (!publisher || publisher.rootPublicKey !== root.publicKey
      || publisher.certificate.payload.keyVersion !== readerPublication.publisherKeyVersion)
      throw Error("invalid_publishing_custodian");
    if (!state.administrativeSidecar) {
      const custodians = state.readerOptions.custodianDeviceIDs.map(id => {
        const target = [...targets.values()].find(t => t.deviceID === id);
        if (!target) throw Error("publication_custodian_unavailable"); return target;
      });
      if (!state.sidecarID) { state.sidecarID = cryptoValue.randomUUID(); await persist(); }
      const context = { teamID: scope.teamID, vaultID: scope.vaultID, resourceID: state.sidecarID,
        part: "SECRET", keyVersion: 1, policyVersion: scope.policyVersion, registryVersion: 1,
        resourceVersion: 1, manifestVersion: 1 };
      const cek = generateResourceCEK(cryptoValue);
      try {
        const metadata = { ...legacyAdministrativeMetadata({ document, mapping: state.mappingState,
          sourceFingerprint: documentHash }), generationID: scope.attemptID };
        const envelope = await encryptResourcePart({ plaintext: enc.encode(canonicalMigrationJSON(metadata)),
          cek, context, cryptoValue });
        const wrappers = [];
        for (const target of custodians) {
          const prepared = await wrapForVerifiedDevice({ cek, context: { teamID: scope.teamID,
            vaultID: scope.vaultID, resourceID: state.sidecarID, part: "SECRET", keyVersion: 1,
            membershipID: target.membershipID, membershipEpoch: target.membershipEpoch, deviceID: target.deviceID },
            rootPublicKey: target.rootPublicKey, certificate: target.certificate, checkpoint: target.checkpoint,
            endpoint, pinRepository: pinnedTrust, cryptoValue });
          wrappers.push(prepared.wrapper);
        }
        state.administrativeSidecar = { resourceID: state.sidecarID, part: "SECRET", envelope, wrappers };
        if (enc.encode(canonicalMigrationJSON(state.administrativeSidecar)).length > 1024 * 1024)
          throw Error("publication_limit");
        const self = wrappers.find(w => w.context.deviceID === deviceID);
        const openedKey = await unwrapResourceCEK({ wrapper: self, context: self.context,
          privateKey: identity.privateKey, cryptoValue });
        try {
          const opened = await decryptResourcePart({ envelope, context, cek: openedKey, cryptoValue });
          if (dec.decode(opened) !== canonicalMigrationJSON(metadata)) throw Error("migration_roundtrip_failed");
        } finally { openedKey.fill(0); }
        await persist(); await faultAt("sidecar_persisted");
      } finally { cek.fill(0); }
    }
    if (!state.readerProjection) {
      state.readerProjection = await prepareReaderProjection({ scope, resources: state.resources,
        objects: state.objects, recipients, root, publisherAccountID: root.accountID,
        publisherDeviceID: deviceID, publisherKeyVersion: readerPublication.publisherKeyVersion, cryptoValue });
      await persist(); await faultAt("projection_persisted");
    }
    await validateReaderProjection({ projection: state.readerProjection, scope, resources: state.resources,
      objects: state.objects, recipients, rootPublicKey: root.publicKey, cryptoValue });
  }
  const payload = {
    version: 2,
    scope,
    policyHash,
    resources: state.resources,
    parts: state.objects.map((o) => ({
      resourceID: o.resourceID,
      part: o.part,
      sha256: o.sha256,
    })),
  };
  if (readerPublication) payload.reader = {
    projectionHash: await publicationHash("projection", state.readerProjection, cryptoValue),
    sidecarHash: await publicationHash("sidecar", state.administrativeSidecar, cryptoValue),
    custodianDeviceIDs: state.readerOptions.custodianDeviceIDs,
  };
  await faultAt("manifest");
  const signature = state.signedReaderManifest?.signature ?? toBase64(
    new Uint8Array(
      await cryptoValue.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        root.privateKey,
        migrationBytes(payload),
      ),
    ),
  );
  if (readerPublication) {
    if (state.signedReaderManifest && canonicalMigrationJSON(state.signedReaderManifest.payload) !== canonicalMigrationJSON(payload))
      throw Error("migration_replay_conflict");
    state.signedReaderManifest = { payload, signature };
    await persist(); await faultAt("signed_projection_persisted");
  }
  return {
    resources: state.resources,
    objects: state.objects,
    checkpoint: saved,
    manifest: { payload, signature },
    ...(readerPublication ? { readerProjection: state.readerProjection,
      administrativeSidecar: state.administrativeSidecar } : {}),
  };
}
