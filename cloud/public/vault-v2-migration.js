// Staging foundation only: no UI or production route imports this converter.
import {
  generateResourceCEK,
  encryptResourcePart,
  decryptResourcePart,
  unwrapResourceCEK,
} from "./resource-crypto-v2.js";
import { wrapForVerifiedDevice } from "./device-trust-v1.js";
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
  const blockers = [],
    seen = new Set(),
    folders = new Map(),
    items = [];
  let missingIDs = 0;
  if (
    document?.schemaVersion !== 1 ||
    !Array.isArray(document.records) ||
    !Array.isArray(document.tombstones) ||
    document.records.length > 1000 ||
    enc.encode(JSON.stringify(document)).length > 24 * 1024 * 1024
  )
    throw Error("invalid_legacy_document");
  for (const [ordinal, r] of document.records.entries()) {
    if (
      !r ||
      !kinds[r.type] ||
      !r.data ||
      typeof r.data !== "object" ||
      Array.isArray(r.data)
    ) {
      blockers.push("unsupported_record");
      continue;
    }
    if (r.id && seen.has(String(r.id).toLowerCase()))
      blockers.push("duplicate_source_id");
    seen.add(String(r.id).toLowerCase());
    const valid = idPattern.test(String(r.id).toLowerCase());
    if (!valid) missingIDs++;
    else if (existingIDs.includes(r.id.toLowerCase()))
      blockers.push("resource_id_collision");
    if (["host", "forwarding"].includes(r.type)) {
      if (embeddedSecret(r.data))
        blockers.push("embedded_secret_requires_conversion");
      for (const key of ["profile", "configuration"]) {
        if (r.data[key] === undefined) continue;
        try {
          if (typeof r.data[key] !== "string") throw Error();
          const decoded = JSON.parse(r.data[key]);
          if (!decoded || typeof decoded !== "object" || Array.isArray(decoded))
            throw Error();
          if (embeddedSecret(decoded))
            blockers.push("embedded_secret_requires_conversion");
        } catch {
          blockers.push("opaque_profile_requires_conversion");
        }
      }
    }
    let parentKey = null;
    if (["host", "snippet"].includes(r.type) && r.data.folder) {
      if (
        typeof r.data.folder !== "string" ||
        r.data.folder.split("/").some((p) => !p.trim()) ||
        r.data.folder.split("/").length > 32
      ) {
        blockers.push("invalid_folder");
        continue;
      }
      const pieces = r.data.folder.split("/");
      for (let n = 1; n <= pieces.length; n++) {
        const path = pieces.slice(0, n).join("/"),
          key = r.type + ":" + path;
        if (!folders.has(key))
          folders.set(key, { key, path, type: r.type, parentKey });
        parentKey = key;
      }
    }
    items.push({
      key: "record:" + ordinal,
      ordinal,
      kind: kinds[r.type],
      parentKey,
      record: r,
      id: valid ? r.id.toLowerCase() : null,
    });
  }
  if (items.length + folders.size > 1000) blockers.push("resource_limit");
  const parts = items.reduce((n,r) => n + (r.kind === "CREDENTIAL" ? 2 : 1), folders.size);
  if (migrationCheckpointBudget(document, parts, 0, [...folders.values()]) > MIGRATION_CHECKPOINT_LIMIT) blockers.push("checkpoint_size_limit");
  return {
    items,
    folders: [...folders.values()],
    blockers: [...new Set(blockers)],
    missingIDs,
  };
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
function createInventoryState(
  i,
  document,
  documentHash,
  policyHash,
  cryptoValue,
) {
  const mapping = {};
  for (const f of i.folders) mapping[f.key] = cryptoValue.randomUUID();
  for (const r of i.items) mapping[r.key] = r.id || cryptoValue.randomUUID();
  return {
    documentHash,
    policyHash,
    mapping,
    document,
    resources: [
      ...i.folders.map((f, n) => ({
        id: mapping[f.key],
        kind: "FOLDER",
        parentFolderID: f.parentKey ? mapping[f.parentKey] : null,
        sourceOrdinal: document.records.length + n,
      })),
      ...i.items.map((r) => ({
        id: mapping[r.key],
        kind: r.kind,
        parentFolderID: r.parentKey ? mapping[r.parentKey] : null,
        sourceOrdinal: r.ordinal,
      })),
    ],
    objects: [],
  };
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
    : createInventoryState(i, document, hash, null, cryptoValue);
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
    );
  }
  const targetCache = new Map();
  let wrapperCount = 0, partCount = 0;
  for (const r of state.resources) for (const part of (r.kind === "CREDENTIAL" ? ["METADATA","SECRET"] : ["GENERAL"])) {
    const targets = await recipientTargets(r, part);
    if (!Array.isArray(targets) || !targets.length || targets.length > 100) throw Error("recipient_missing");
    for (const target of targets) requireRecipientAccount(target);
    targetCache.set(r.id + ":" + part, targets);
    wrapperCount += targets.length; partCount++;
  }
  if (migrationCheckpointBudget(document, partCount, wrapperCount, i.folders) > MIGRATION_CHECKPOINT_LIMIT) throw Error("checkpoint_size_limit");
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
    const payloads =
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
        state.objects.push(object);
        await persist();
        await faultAt("part_persisted");
      } finally {
        cek.fill(0);
      }
    }
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
  await faultAt("manifest");
  const signature = toBase64(
    new Uint8Array(
      await cryptoValue.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        root.privateKey,
        migrationBytes(payload),
      ),
    ),
  );
  return {
    resources: state.resources,
    objects: state.objects,
    checkpoint: saved,
    manifest: { payload, signature },
  };
}
