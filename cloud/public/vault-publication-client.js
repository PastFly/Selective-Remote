import { normalizeTeamDevicePublicKey } from "./team-vault-crypto.js";
import {
  verifyReaderHeader,
  verifyReaderDescriptor,
  verifyReaderInventory,
} from "./vault-publication-v1.js";
import {
  unwrapResourceCEK,
  decryptResourcePart,
} from "./resource-crypto-v2.js";
import {
  verifyDeviceForWrapping,
  verifySignedDeviceDirectory,
  advancePinnedTrust,
} from "./device-trust-v1.js";
import { canonicalMigrationJSON } from "./vault-v2-migration.js";
const encode = new TextEncoder(),
  decode = new TextDecoder("utf-8", { fatal: true });
const equal = (a, b) => canonicalMigrationJSON(a) === canonicalMigrationJSON(b);
const fail = (code) => {
  throw new Error(code);
};
const identityFields = ["endpoint", "accountID", "deviceID", "sessionEpoch"];
const lost = new Set([
  "authentication_required",
  "team_not_found",
  "team_access_denied",
  "publication_access_denied",
  "publication_repair_required",
  "device_trust_revoked",
]);
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
function recordVersion(v) {
  return (
    (Number.isSafeInteger(v) && v > 0) ||
    (v &&
      typeof v === "object" &&
      !Array.isArray(v) &&
      Object.entries(v).length > 0 &&
      Object.entries(v).every(
        ([k, n]) => uuid.test(k) && Number.isSafeInteger(n) && n > 0,
      ))
  );
}
function recordTimestamp(v) {
  return (
    (Number.isFinite(v) && v > 0) ||
    (typeof v === "string" && Number.isFinite(Date.parse(v)))
  );
}
export function isPublicationOfflineError(error) {
  return (
    error instanceof TypeError ||
    ["network_unavailable", "publication_network_unavailable"].includes(
      error?.message,
    ) ||
    (error?.status >= 500 && error?.status <= 599)
  );
}
export function isPublicationAccessLoss(error) {
  return lost.has(error?.message);
}
const kinds = {
  HOST: "host",
  CREDENTIAL: "credential",
  SNIPPET: "snippet",
  FORWARDING: "forwarding",
};
function cacheScope(identity, scope) {
  return {
    endpoint: identity.endpoint,
    accountID: identity.accountID,
    deviceID: identity.deviceID,
    teamID: scope.teamID,
    vaultID: scope.vaultID,
  };
}
function resourceModel(payload, descriptor, header) {
  const d = descriptor.payload,
    link = {
      teamID: header.payload.teamID,
      vaultID: header.payload.vaultID,
      generationID: header.payload.generationID,
      resourceID: d.resourceID,
      kind: d.kind,
      part: d.part,
    };
  if (!payload || !equal(payload.link, link))
    fail("publication_payload_link_mismatch");
  const reference = Object.freeze({
    teamID: link.teamID,
    vaultID: link.vaultID,
    resourceID: d.resourceID,
    kind: d.kind,
    parentFolderID: d.parentFolderID,
  });
  const model = {
    ...link,
    parentFolderID: d.parentFolderID,
    reference,
    deviceUsability: "YES",
  };
  if (d.part === "METADATA") {
    if (
      d.kind !== "CREDENTIAL" ||
      !payload.metadata ||
      Object.keys(payload).sort().join() !== "link,metadata" ||
      Object.keys(payload.metadata).some(
        (k) =>
          !["title", "kind", "username"].includes(k) ||
          typeof payload.metadata[k] !== "string",
      )
    )
      fail("publication_payload_schema_invalid");
    return { ...model, metadata: payload.metadata };
  }
  if (d.kind === "FOLDER") {
    if (
      d.part !== "GENERAL" ||
      !payload.folder ||
      Object.keys(payload).sort().join() !== "folder,link" ||
      !["host", "snippet"].includes(payload.folder.type) ||
      Object.keys(payload.folder).sort().join() !== "component,path,type" ||
      typeof payload.folder.path !== "string" ||
      !payload.folder.path ||
      payload.folder.path.startsWith("/") ||
      payload.folder.path.endsWith("/") ||
      payload.folder.path.includes("//") ||
      typeof payload.folder.component !== "string" ||
      payload.folder.path.split("/").at(-1) !== payload.folder.component
    )
      fail("publication_payload_schema_invalid");
    return { ...model, folder: payload.folder };
  }
  const r = payload.record;
  if (
    !kinds[d.kind] ||
    Object.keys(payload).sort().join() !== "link,record" ||
    !r ||
    r.type !== kinds[d.kind] ||
    !recordVersion(r.version) ||
    !recordTimestamp(r.modifiedAt) ||
    !r.data ||
    typeof r.data !== "object" ||
    Array.isArray(r.data) ||
    (d.kind === "CREDENTIAL" && d.part !== "SECRET") ||
    (d.kind !== "CREDENTIAL" && d.part !== "GENERAL")
  )
    fail("publication_payload_schema_invalid");
  return { ...model, record: r };
}
async function verifyLocalReaderKey(
  readerDevice,
  privateKey,
  expectedPublicKey,
  cryptoValue,
) {
  if (
    !readerDevice ||
    !Number.isSafeInteger(readerDevice.keyVersion) ||
    readerDevice.keyVersion < 1
  )
    fail("publication_cache_reader_invalid");
  const publicKey = normalizeTeamDevicePublicKey(readerDevice.publicKey);
  if (
    expectedPublicKey &&
    !equal(publicKey, normalizeTeamDevicePublicKey(expectedPublicKey))
  )
    fail("publication_local_key_mismatch");
  if (
    privateKey?.type !== "private" ||
    privateKey.algorithm?.name !== "ECDH" ||
    privateKey.algorithm?.namedCurve !== "P-256" ||
    privateKey.extractable !== false
  )
    fail("publication_local_key_mismatch");
  const imported = await cryptoValue.subtle.importKey(
      "jwk",
      publicKey,
      { name: "ECDH", namedCurve: "P-256" },
      false,
      [],
    ),
    challenge = await cryptoValue.subtle.generateKey(
      { name: "ECDH", namedCurve: "P-256" },
      false,
      ["deriveBits"],
    );
  let actual, expected;
  try {
    actual = new Uint8Array(
      await cryptoValue.subtle.deriveBits(
        { name: "ECDH", public: challenge.publicKey },
        privateKey,
        256,
      ),
    );
    expected = new Uint8Array(
      await cryptoValue.subtle.deriveBits(
        { name: "ECDH", public: imported },
        challenge.privateKey,
        256,
      ),
    );
    let difference = 0;
    for (let n = 0; n < actual.length; n++)
      difference |= actual[n] ^ expected[n];
    if (difference !== 0) fail("publication_local_key_mismatch");
  } finally {
    actual?.fill(0);
    expected?.fill(0);
  }
  return publicKey;
}
export function createVaultPublicationClient({
  transport,
  identity,
  scope,
  privateKey,
  publicKey = null,
  deviceKeyVersion = 1,
  ownTrustRepository,
  publisherTrustRepository,
  repository,
  cryptoValue = globalThis.crypto,
  onInvalidate = () => {},
  subscribeIdentityChange = () => () => {},
}) {
  let current = null,
    currentIdentity = null,
    pendingVerification = null,
    payloadReceipt = null,
    authenticationInvalidatedOperation = null,
    epoch = 0;
  const scopeValue = { teamID: scope.teamID, vaultID: scope.vaultID };
  const captured = () => {
    const value = identity();
    if (!value || identityFields.some((k) => !value[k]))
      fail("authentication_required");
    return { ...value };
  };
  function guard(start, operationEpoch) {
    const now = identity();
    if (
      operationEpoch !== epoch ||
      !now ||
      identityFields.some((k) => now[k] !== start[k])
    )
      fail("publication_session_changed");
  }
  function lock() {
    authenticationInvalidatedOperation = null;
    epoch++;
    current = null;
    currentIdentity = null;
    pendingVerification = null;
    onInvalidate();
  }
  function displayView() {
    if (current !== null) {
      const now = identity();
      if (
        !now ||
        !currentIdentity ||
        identityFields.some((k) => now[k] !== currentIdentity[k])
      )
        lock();
    }
    return current === null ? null : structuredClone(current);
  }
  const unsubscribe = subscribeIdentityChange(() => {
    const retiredOperation = epoch;
    lock();
    authenticationInvalidatedOperation = identity() === null ? retiredOperation : null;
  });
  function ownsOperation(start, op, error = null) {
    const now = identity();
    if (op === epoch && now && identityFields.every(k => now[k] === start[k])) return true;
    // A genuine current 401 synchronously invalidates identity before the reader catch.
    return now === null && error?.invalidatedSessionEpoch === start.sessionEpoch &&
      (epoch === op || (authenticationInvalidatedOperation === op && epoch === op + 1));
  }
  async function retireDenied(start, op, error, receipt) {
    if (!ownsOperation(start, op, error)) return false;
    current = null;
    currentIdentity = null;
    pendingVerification = null;
    onInvalidate();
    await repository.clearPayload(cacheScope(start, scopeValue), receipt, () => {
      if (!ownsOperation(start, op, error)) fail("publication_session_changed");
    });
    return true;
  }
  async function publisherTrust(bundle, header, start, op) {
    const p = header.payload;
    if (
      bundle.generationID !== p.generationID ||
      bundle.accountID !== p.publisherAccountID ||
      bundle.deviceID !== p.publisherDeviceID ||
      bundle.keyVersion !== p.publisherKeyVersion ||
      bundle.certificate?.payload?.accountID !== bundle.accountID ||
      bundle.certificate?.payload?.deviceID !== bundle.deviceID ||
      bundle.certificate?.payload?.keyVersion !== bundle.keyVersion
    )
      fail("publication_publisher_mismatch");
    const own = bundle.accountID === start.accountID,
      store = own ? ownTrustRepository : publisherTrustRepository;
    const pin = own
      ? await store?.loadPin(start.endpoint, bundle.accountID)
      : await store?.loadPin(
          start.endpoint,
          scopeValue.teamID,
          bundle.accountID,
        );
    guard(start, op);
    if (!pin) {
      const raw = Uint8Array.from(
        atob(bundle.rootPublicKey.replaceAll("-", "+").replaceAll("_", "/")),
        (c) => c.charCodeAt(0),
      );
      const fingerprint = Array.from(
        new Uint8Array(await cryptoValue.subtle.digest("SHA-256", raw)),
        (b) => b.toString(16).padStart(2, "0"),
      ).join("");
      const checkpoint = await verifySignedDeviceDirectory({
        ...bundle,
        cryptoValue,
      });
      const candidate = {
        endpoint: start.endpoint,
        accountID: bundle.accountID,
        rootFingerprint: fingerprint,
        highWater: checkpoint.version,
        checkpointDigest: checkpoint.checkpointDigest,
      };
      await verifyDeviceForWrapping({
        ...bundle,
        trust: candidate,
        expectedDeviceID: bundle.deviceID,
        cryptoValue,
      });
      guard(start, op);
      if (own) fail("publisher_own_pin_missing");
      pendingVerification = { candidate, bundle, start, op };
      const error = new Error("publisher_verification_required");
      error.verification = {
        fingerprint,
        accountID: bundle.accountID,
        deviceID: bundle.deviceID,
        teamID: scopeValue.teamID,
      };
      throw error;
    }
    if (pin.endpoint !== start.endpoint || pin.accountID !== bundle.accountID)
      fail("publication_publisher_mismatch");
    const verified = await verifyDeviceForWrapping({
      ...bundle,
      trust: pin,
      expectedDeviceID: bundle.deviceID,
      cryptoValue,
    });
    const next = advancePinnedTrust(pin, {
      ...pin,
      highWater: verified.highWater,
      checkpointDigest: verified.checkpointDigest,
    });
    guard(start, op);
    if (!equal(pin, next)) {
      if (own) await store.advancePin(pin, next);
      else
        await store.advancePin(
          start.endpoint,
          scopeValue.teamID,
          pin,
          next,
          () => guard(start, op),
        );
      guard(start, op);
    }
    return bundle.rootPublicKey;
  }
  async function part(descriptor, base, root, start, op, subject) {
    const d = descriptor.payload,
      wire = await transport.part(scopeValue, {
        ...base,
        resourceID: d.resourceID,
        part: d.part,
      });
    guard(start, op);
    if (
      wire.headerHash !== base.headerHash ||
      wire.generationID !== base.generationID ||
      !equal(wire.descriptor, descriptor)
    )
      fail("publication_changed");
    const entry = wire.entry,
      w = entry?.wrapper?.context;
    if (
      entry?.accountID !== start.accountID ||
      entry?.deviceKeyVersion !== deviceKeyVersion ||
      !w ||
      w.deviceID !== start.deviceID ||
      w.membershipID !== subject.membershipID ||
      w.membershipEpoch !== subject.membershipEpoch
    )
      fail("publication_subject_mismatch");
    await verifyReaderDescriptor({
      descriptor,
      header: base.header,
      rootPublicKey: root,
      envelope: wire.envelope,
      entry,
      proof: wire.proof,
      cryptoValue,
    });
    const cek = await unwrapResourceCEK({
      wrapper: entry.wrapper,
      context: w,
      privateKey,
      cryptoValue,
    });
    let plaintext;
    try {
      plaintext = await decryptResourcePart({
        envelope: wire.envelope,
        context: d.context,
        cek,
        cryptoValue,
      });
      guard(start, op);
      return resourceModel(
        JSON.parse(decode.decode(plaintext)),
        descriptor,
        base.header,
      );
    } finally {
      cek.fill(0);
      plaintext?.fill(0);
    }
  }
  async function pointer(base, subject, start, op) {
    const final = await transport.header(scopeValue);
    guard(start, op);
    if (
      final.headerHash !== base.headerHash ||
      !equal(final.header, base.header) ||
      !equal(final.subject, subject) ||
      !equal(final.inventory, base.inventory)
    )
      fail("publication_changed");
  }
  return {
    view: displayView,
    lock,
    dispose() {
      lock();
      unsubscribe();
    },
    async confirmPublisher(independentFingerprint) {
      const v = pendingVerification;
      if (!v) fail("publisher_verification_required");
      guard(v.start, v.op);
      if (
        String(independentFingerprint).trim().toLowerCase() !==
        v.candidate.rootFingerprint
      )
        fail("publisher_fingerprint_mismatch");
      await publisherTrustRepository.savePinIfAbsent(
        v.start.endpoint,
        scopeValue.teamID,
        v.candidate,
        () => guard(v.start, v.op),
      );
      guard(v.start, v.op);
      pendingVerification = null;
    },
    async loadStaleCache() {
      const start = captured(),
        op = ++epoch;
      try {
        const stored = await repository.load(cacheScope(start, scopeValue));
        guard(start, op);
        const view = stored?.payload;
        if (!view || !stored.highWater || view.stale !== false)
          fail("publication_cache_unavailable");
        if (
          view.subject?.accountID !== start.accountID ||
          view.subject?.deviceID !== start.deviceID
        )
          fail("publication_subject_mismatch");
        await verifyLocalReaderKey(
          view.readerDevice,
          privateKey,
          publicKey,
          cryptoValue,
        );
        if (
          deviceKeyVersion !== null &&
          deviceKeyVersion !== view.readerDevice.keyVersion
        )
          fail("publication_local_key_mismatch");
        deviceKeyVersion = view.readerDevice.keyVersion;
        guard(start, op);
        const root = await publisherTrust(
          view.publisher,
          view.header,
          start,
          op,
        );
        const headerHash = await verifyReaderHeader({
          header: view.header,
          rootPublicKey: root,
          ...scopeValue,
          highWater: stored.highWater,
          cryptoValue,
        });
        if (
          headerHash !== view.headerHash ||
          headerHash !== stored.highWater.hash ||
          view.header.payload.sequence !== stored.highWater.sequence
        )
          fail("publication_cache_invalid");
        await verifyReaderInventory({
          inventory: view.inventory,
          descriptors: view.descriptors,
          header: view.header,
          rootPublicKey: root,
          subject: view.subject,
          cryptoValue,
        });
        const descriptors = view.descriptors.filter(
          (d) => d.payload.part !== "SECRET",
        );
        if (
          !Array.isArray(view.models) ||
          view.models.length !== descriptors.length
        )
          fail("publication_cache_invalid");
        const models = [];
        for (const descriptor of descriptors) {
          await verifyReaderDescriptor({
            descriptor,
            header: view.header,
            rootPublicKey: root,
            cryptoValue,
          });
          const d = descriptor.payload,
            model = view.models.find(
              (m) => m.resourceID === d.resourceID && m.part === d.part,
            );
          if (!model) fail("publication_cache_invalid");
          const link = {
            teamID: scopeValue.teamID,
            vaultID: scopeValue.vaultID,
            generationID: view.header.payload.generationID,
            resourceID: d.resourceID,
            kind: d.kind,
            part: d.part,
          };
          const verified = resourceModel(
            {
              link,
              ...(d.part === "METADATA"
                ? { metadata: model.metadata }
                : d.kind === "FOLDER"
                  ? { folder: model.folder }
                  : { record: model.record }),
            },
            descriptor,
            view.header,
          );
          if (
            !equal(model.reference, verified.reference) ||
            !equal(
              model.link ??
                Object.fromEntries(Object.keys(link).map((k) => [k, model[k]])),
              link,
            )
          )
            fail("publication_cache_invalid");
          models.push(verified);
        }
        guard(start, op);
        if (current && (!current.stale || current.headerHash !== view.headerHash)) onInvalidate();
        payloadReceipt = stored.payloadReceipt;
        currentIdentity = start;
        current = { ...view, models, stale: true };
        return structuredClone(current);
      } catch (error) {
        guard(start, op);
        current = null;
        onInvalidate();
        throw error;
      }
    },
    async load() {
      const start = captured(),
        op = ++epoch,
        cs = cacheScope(start, scopeValue);
      let stored;
      try {
        stored = await repository.load(cs);
        guard(start, op);
        const wire = await transport.header(scopeValue);
        guard(start, op);
        if (
          wire.subject?.accountID !== start.accountID ||
          wire.subject?.deviceID !== start.deviceID
        )
          fail("publication_subject_mismatch");
        const base = {
          generationID: wire.header.payload.generationID,
          headerHash: wire.headerHash,
          header: wire.header,
          inventory: wire.inventory,
        };
        const bundle = await transport.publisher(scopeValue, base);
        guard(start, op);
        if (bundle.headerHash !== wire.headerHash) fail("publication_changed");
        const root = await publisherTrust(bundle, wire.header, start, op);
        if (
          (await verifyReaderHeader({
            header: wire.header,
            rootPublicKey: root,
            ...scopeValue,
            highWater: stored?.highWater,
            cryptoValue,
          })) !== wire.headerHash
        )
          fail("publication_header_hash_mismatch");
        const descriptors = [],
          seen = new Set();
        let cursor = null;
        do {
          const page = await transport.directory(scopeValue, {
            generationID: base.generationID,
            headerHash: base.headerHash,
            cursor,
            limit: 100,
          });
          guard(start, op);
          if (
            page.headerHash !== base.headerHash ||
            page.generationID !== base.generationID ||
            !equal(page.inventory, wire.inventory)
          )
            fail("publication_changed");
          if (
            !Array.isArray(page.descriptors) ||
            page.descriptors.length > 100 ||
            descriptors.length + page.descriptors.length > 2000 ||
            (page.descriptors.length === 0 && page.nextCursor !== null)
          )
            fail("publication_incomplete");
          for (const d of page.descriptors) {
            await verifyReaderDescriptor({
              descriptor: d,
              header: wire.header,
              rootPublicKey: root,
              cryptoValue,
            });
            descriptors.push(d);
          }
          cursor = page.nextCursor;
          if (cursor !== null) {
            if (typeof cursor !== "string" || !cursor || seen.has(cursor))
              fail("publication_incomplete");
            seen.add(cursor);
          }
        } while (cursor !== null);
        await verifyReaderInventory({
          inventory: wire.inventory,
          descriptors,
          header: wire.header,
          rootPublicKey: root,
          subject: wire.subject,
          cryptoValue,
        });
        const models = [];
        for (const d of descriptors)
          if (d.payload.part !== "SECRET")
            models.push(await part(d, base, root, start, op, wire.subject));
        await pointer(base, wire.subject, start, op);
        const readerPublicKey =
          publicKey ??
          (bundle.accountID === start.accountID &&
          bundle.deviceID === start.deviceID
            ? bundle.certificate.payload.publicKey
            : null);
        if (!readerPublicKey) fail("publication_cache_reader_invalid");
        const readerDevice = {
          publicKey: normalizeTeamDevicePublicKey(readerPublicKey),
          keyVersion: deviceKeyVersion,
        };
        await verifyLocalReaderKey(
          readerDevice,
          privateKey,
          publicKey,
          cryptoValue,
        );
        guard(start, op);
        const view = {
          readerDevice,
          header: wire.header,
          headerHash: wire.headerHash,
          subject: wire.subject,
          inventory: wire.inventory,
          descriptors,
          models,
          stale: false,
          publisher: bundle,
        };
        guard(start, op);
        const persistedReceipt = await repository.persist(
          cs,
          {
            highWater: {
              sequence: wire.header.payload.sequence,
              hash: wire.headerHash,
            },
            payload: view,
          },
          () => guard(start, op),
        );
        guard(start, op);
        if (current && (current.headerHash !== view.headerHash || current.stale !== view.stale)) onInvalidate();
        payloadReceipt = persistedReceipt;
        currentIdentity = start;
        current = view;
        return structuredClone(view);
      } catch (error) {
        if (lost.has(error.message)) {
          await retireDenied(start, op, error, stored?.payloadReceipt ?? payloadReceipt);
          throw error;
        }
        guard(start, op);
        if (
          error.message === "publication_network_unavailable" &&
          stored?.payload
        ) {
          return this.loadStaleCache();
        }
        current = null;
        onInvalidate();
        throw error;
      }
    },
    async revealSecret(resourceID) {
      displayView();
      const start = captured(),
        op = epoch,
        view = current,
        receipt = payloadReceipt;
      if (!view || view.stale) fail("publication_current_required");
      const descriptor = view.descriptors.find(
        (d) =>
          d.payload.resourceID === resourceID && d.payload.part === "SECRET",
      );
      if (!descriptor) fail("publication_secret_unavailable");
      try {
        const base = {
          generationID: view.header.payload.generationID,
          headerHash: view.headerHash,
          header: view.header,
          inventory: view.inventory,
        };
        await pointer(base, view.subject, start, op);
        const root = await publisherTrust(
            view.publisher,
            view.header,
            start,
            op,
          ),
          model = await part(descriptor, base, root, start, op, view.subject);
        await pointer(base, view.subject, start, op);
        guard(start, op);
        return model;
      } catch (error) {
        if (lost.has(error.message)) {
          await retireDenied(start, op, error, receipt);
          throw error;
        }
        guard(start, op);
        current = null;
        onInvalidate();
        throw error;
      }
    },
  };
}
// Durable data and pins live in IndexedDB. Only AES-GCM ciphertext is stored for model payloads;
// high-water and scoped trust metadata survive revocation cleanup. CryptoKeys are nonextractable.
export function createIndexedDBPublicationRepository(
  indexedDBValue = globalThis.indexedDB,
  cryptoValue = globalThis.crypto,
) {
  const scopeKey = (s) =>
    JSON.stringify([s.endpoint, s.accountID, s.deviceID, s.teamID, s.vaultID]);
  async function transaction(mode, operation) {
    if (!indexedDBValue?.open) fail("publication_storage_failed");
    const db = await new Promise((resolve, reject) => {
      const r = indexedDBValue.open("selective-remote-publication-v1", 1);
      r.onupgradeneeded = () => r.result.createObjectStore("records");
      r.onsuccess = () => resolve(r.result);
      r.onerror = r.onblocked = () =>
        reject(Error("publication_storage_failed"));
    });
    try {
      return await new Promise((resolve, reject) => {
        const tx = db.transaction("records", mode);
        let value;
        const done = (v) => {
          value = v;
        };
        try {
          operation(tx.objectStore("records"), done, tx);
        } catch (e) {
          tx.abort();
          reject(e);
        }
        tx.oncomplete = () => resolve(value);
        tx.onerror = tx.onabort = () =>
          reject(tx.publicationFailure ?? Error("publication_storage_failed"));
      });
    } finally {
      db.close();
    }
  }
  async function read(key) {
    return transaction("readonly", (store, done) => {
      const r = store.get(key);
      r.onsuccess = () => done(r.result ?? null);
    });
  }
  async function key(scope) {
    const id = "key:" + scopeKey(scope);
    const existing = await read(id);
    if (existing) return existing;
    const candidate = await cryptoValue.subtle.generateKey(
      { name: "AES-GCM", length: 256 },
      false,
      ["encrypt", "decrypt"],
    );
    return transaction("readwrite", (store, done) => {
      const r = store.get(id);
      r.onsuccess = () => {
        if (r.result) done(r.result);
        else {
          store.add(candidate, id);
          done(candidate);
        }
      };
    });
  }
  const pinKey = (endpoint, team, account) =>
    "pin:" + JSON.stringify([endpoint, team, account]);
  const pinScope = (endpoint, team, account) => ({
    endpoint,
    teamID: team,
    accountID: account,
    deviceID: "publisher-pin",
    vaultID: "publisher-pin",
  });
  const pinAAD = (endpoint, team, account) =>
    encode.encode(
      JSON.stringify({ endpoint, team, account, purpose: "publisher-pin" }),
    );
  async function sealPin(endpoint, team, pin) {
    advancePinnedTrust(pin, pin);
    const k = await key(pinScope(endpoint, team, pin.accountID)),
      nonce = cryptoValue.getRandomValues(new Uint8Array(12)),
      sealed = await cryptoValue.subtle.encrypt(
        {
          name: "AES-GCM",
          iv: nonce,
          additionalData: pinAAD(endpoint, team, pin.accountID),
        },
        k,
        encode.encode(JSON.stringify(pin)),
      );
    return { nonce, sealed };
  }
  async function openPin(endpoint, team, account, value) {
    if (!value) return null;
    const k = await read("key:" + scopeKey(pinScope(endpoint, team, account)));
    if (!k) fail("publication_storage_failed");
    const plaintext = await cryptoValue.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: value.nonce,
        additionalData: pinAAD(endpoint, team, account),
      },
      k,
      value.sealed,
    );
    const pin = JSON.parse(decode.decode(plaintext));
    if (pin.endpoint !== endpoint || pin.accountID !== account)
      fail("device_trust_invalid");
    advancePinnedTrust(pin, pin);
    return pin;
  }
  function sameSealed(a, b) {
    return (
      a === b ||
      (!a && !b) ||
      (a &&
        b &&
        equal(Array.from(a.nonce), Array.from(b.nonce)) &&
        equal(
          Array.from(new Uint8Array(a.sealed)),
          Array.from(new Uint8Array(b.sealed)),
        ))
    );
  }

  return {
    async load(scope) {
      const stored = await read("cache:" + scopeKey(scope));
      if (!stored) return { highWater: null, payload: null };
      const k = await read("key:" + scopeKey(scope));
      if (!k || !stored.highWaterSeal || !stored.highWaterNonce)
        fail("publication_storage_failed");
      const receipt = await cryptoValue.subtle.decrypt(
        {
          name: "AES-GCM",
          iv: stored.highWaterNonce,
          additionalData: encode.encode(
            JSON.stringify({ scope, purpose: "high-water" }),
          ),
        },
        k,
        stored.highWaterSeal,
      );
      if (!equal(JSON.parse(decode.decode(receipt)), stored.highWater))
        fail("publication_high_water_invalid");
      if (!stored.sealed) return { highWater: stored.highWater, payload: null };
      const bytes = await cryptoValue.subtle.decrypt(
        {
          name: "AES-GCM",
          iv: stored.nonce,
          additionalData: encode.encode(
            JSON.stringify({
              scope,
              highWater: stored.highWater,
              generationID: stored.generationID,
            }),
          ),
        },
        k,
        stored.sealed,
      );
      return {
        highWater: stored.highWater,
        payload: JSON.parse(decode.decode(bytes)),
        payloadReceipt: { nonce: stored.nonce, sealed: stored.sealed },
      };
    },
    async persist(scope, { highWater, payload }, guard) {
      const k = await key(scope),
        nonce = cryptoValue.getRandomValues(new Uint8Array(12)),
        bytes = encode.encode(JSON.stringify(payload));
      let sealed;
      try {
        sealed = await cryptoValue.subtle.encrypt(
          {
            name: "AES-GCM",
            iv: nonce,
            additionalData: encode.encode(
              JSON.stringify({
                scope,
                highWater,
                generationID: payload.header.payload.generationID,
              }),
            ),
          },
          k,
          bytes,
        );
      } finally {
        bytes.fill(0);
      }
      const highWaterNonce = cryptoValue.getRandomValues(new Uint8Array(12)),
        highWaterSeal = await cryptoValue.subtle.encrypt(
          {
            name: "AES-GCM",
            iv: highWaterNonce,
            additionalData: encode.encode(
              JSON.stringify({ scope, purpose: "high-water" }),
            ),
          },
          k,
          encode.encode(JSON.stringify(highWater)),
        );
      guard();
      return transaction("readwrite", (store, done, tx) => {
        const id = "cache:" + scopeKey(scope),
          r = store.get(id);
        r.onsuccess = () => {
          try {
            guard();
            const old = r.result?.highWater;
            if (
              old &&
              (highWater.sequence < old.sequence ||
                (highWater.sequence === old.sequence &&
                  highWater.hash !== old.hash))
            )
              fail("publication_fork");
            store.put(
              {
                highWater,
                highWaterNonce,
                highWaterSeal,
                nonce,
                sealed,
                generationID: payload.header.payload.generationID,
              },
              id,
            );
            done({ nonce, sealed });
          } catch (error) {
            tx.publicationFailure = error;
            tx.abort();
          }
        };
      });
    },
    async clearPayload(scope, receipt, guard = () => {}) {
      if (!receipt) return false;
      return transaction("readwrite", (store, done, tx) => {
        const id = "cache:" + scopeKey(scope), r = store.get(id);
        r.onsuccess = () => {
          try {
            guard();
            if (!r.result?.sealed || !sameSealed(r.result, receipt)) return done(false);
            store.put({
              highWater: r.result.highWater,
              highWaterSeal: r.result.highWaterSeal,
              highWaterNonce: r.result.highWaterNonce,
            }, id);
            done(true);
          } catch (error) {
            tx.publicationFailure = error;
            tx.abort();
          }
        };
      });
    },
    async loadPin(endpoint, team, account) {
      return openPin(
        endpoint,
        team,
        account,
        await read(pinKey(endpoint, team, account)),
      );
    },
    async savePinIfAbsent(endpoint, team, pin, guard = () => {}) {
      const id = pinKey(endpoint, team, pin.accountID),
        expected = await read(id);
      if (expected) {
        const old = await openPin(endpoint, team, pin.accountID, expected);
        if (!equal(old, pin)) fail("device_trust_invalid");
      }
      const encrypted = await sealPin(endpoint, team, pin);
      guard();
      return transaction("readwrite", (store, _done, tx) => {
        const r = store.get(id);
        r.onsuccess = () => {
          try {
            guard();
            if (!sameSealed(r.result, expected)) fail("device_trust_invalid");
            if (!r.result) store.add(encrypted, id);
          } catch (error) {
            tx.publicationFailure = error;
            tx.abort();
          }
        };
      });
    },
    async advancePin(endpoint, team, old, next, guard = () => {}) {
      advancePinnedTrust(old, next);
      const id = pinKey(endpoint, team, old.accountID),
        expected = await read(id);
      if (!equal(await openPin(endpoint, team, old.accountID, expected), old))
        fail("device_trust_invalid");
      const encrypted = await sealPin(endpoint, team, next);
      guard();
      return transaction("readwrite", (store, _done, tx) => {
        const r = store.get(id);
        r.onsuccess = () => {
          try {
            guard();
            if (!sameSealed(r.result, expected)) fail("device_trust_invalid");
            store.put(encrypted, id);
          } catch (error) {
            tx.publicationFailure = error;
            tx.abort();
          }
        };
      });
    },
  };
}
const uiCopy = {
  editable: ['Публикация проверена. Изменения доступны после проверки последствий и подтверждения.','Publication verified. Changes require an impact review and confirmation.'],
  readonly: [
    "Публикация проверена · только чтение. Изменение и доступ требуют новой публикации.",
    "Verified publication · read only. Changes and access updates require a new publication.",
  ],
  stale: [
    "Сохранённая проверенная публикация · офлайн, актуальность не подтверждена.",
    "Saved verified publication · offline; current state is unconfirmed.",
  ],
  verifyTitle: ["Проверить личность издателя", "Verify publishing identity"],
  verifyInstructions: [
    "Получите fingerprint независимо: лично или через уже проверенного хранителя. Копирование значения с этой страницы не подтверждает доверие.",
    "Obtain the fingerprint through an independent trusted channel: in person or from an already verified custodian. Copying it from this page does not establish trust.",
  ],
  publisher: ["Издатель", "Publisher"],
  fingerprint: [
    "Fingerprint из независимого доверенного канала",
    "Fingerprint from an independent trusted channel",
  ],
  verifyConfirm: [
    "Подтвердить независимую проверку",
    "Confirm independent verification",
  ],
  cancel: ["Отмена", "Cancel"],
  close: ["Закрыть", "Close"],
  mismatch: [
    "Fingerprint не совпадает. Не продолжайте проверку.",
    "The fingerprint does not match. Do not continue verification.",
  ],
  share: ["Общий доступ", "Share"],
  who: ["У кого есть доступ", "Who has access"],
  reveal: ["Показать секрет", "Reveal secret"],
  detail: ["Просмотреть", "View content"],
  copy: ["Копировать", "Copy"],
  copied: ["Скопировано.", "Copied."],
  copyFailed: ["Не удалось скопировать.", "Could not copy."],
  accessFailed: ["Не удалось подтвердить доступ.", "Could not verify access."],
  secretFailed: [
    "Секрет недоступен или текущая публикация не подтверждена.",
    "The secret is unavailable or the current publication is unconfirmed.",
  ],
  HOST: ["Хост", "Host"],
  CREDENTIAL: ["Учётные данные", "Credential"],
  SNIPPET: ["Сниппет", "Snippet"],
  FORWARDING: ["Forwarding", "Forwarding"],
  FOLDER: ["Папка", "Folder"],
  formatFailed: [
    "Не удалось подтвердить формат Vault. Повторите загрузку.",
    "Could not verify the Vault format. Retry loading.",
  ],
  preparing: [
    "Публикация готовится. Доступ к данным требует завершённой проверенной публикации.",
    "The publication is being prepared. Access requires a complete verified publication.",
  ],
  localKeyFailed: [
    "Локальный ключ устройства не подтверждён. Проверьте допуск устройства.",
    "The local device key is unverified. Check device admission.",
  ],
  repair: [
    "Публикация требует восстановления доступа.",
    "The publication requires access repair.",
  ],
  unverified: [
    "Не удалось подтвердить опубликованный Vault.",
    "Could not verify the published Vault.",
  ],
};
export function publicationCopy(documentValue, key) {
  return (
    uiCopy[key]?.[
      documentValue.documentElement?.lang?.toLowerCase().startsWith("en")
        ? 1
        : 0
    ] ?? key
  );
}
const publicationDialogs = new WeakMap();
function ownPublicationDialog(client, dialog) {
  if (!client) return;
  let dialogs = publicationDialogs.get(client);
  if (!dialogs) publicationDialogs.set(client, dialogs = new Set());
  dialogs.add(dialog);
  dialog.addEventListener("close", () => dialogs.delete(dialog), { once: true });
}
export function closePublicationDialogs(client) {
  const dialogs = publicationDialogs.get(client);
  if (!dialogs) return;
  for (const dialog of [...dialogs]) {
    dialog.querySelectorAll("pre,input").forEach(element => {
      element.textContent = "";
      if ("value" in element) element.value = "";
    });
    dialog.close?.();
    dialog.remove();
  }
  dialogs.clear();
}
export async function requestPublisherVerification(
  documentValue,
  verification,
  client = null,
) {
  const dialog = documentValue.createElement("dialog");
  dialog.dataset.publicationDialog = "publisher";
  ownPublicationDialog(client, dialog);
  const heading = documentValue.createElement("h3");
  heading.textContent = publicationCopy(documentValue, "verifyTitle");
  const explanation = documentValue.createElement("p");
  explanation.textContent = `${publicationCopy(documentValue, "publisher")} ${verification.accountID}. ${publicationCopy(documentValue, "verifyInstructions")}`;
  const fingerprint = documentValue.createElement("code");
  fingerprint.textContent = verification.fingerprint;
  const input = documentValue.createElement("input");
  input.setAttribute(
    "aria-label",
    publicationCopy(documentValue, "fingerprint"),
  );
  input.autocomplete = "off";
  const confirm = documentValue.createElement("button");
  confirm.type = "button";
  confirm.textContent = publicationCopy(documentValue, "verifyConfirm");
  const cancel = documentValue.createElement("button");
  cancel.type = "button";
  cancel.textContent = publicationCopy(documentValue, "cancel");
  const feedback = documentValue.createElement("p");
  feedback.setAttribute("role", "status");
  dialog.append(
    heading,
    explanation,
    fingerprint,
    input,
    feedback,
    confirm,
    cancel,
  );
  documentValue.body.append(dialog);
  return new Promise((resolve) => {
    const localize = () => {
      heading.textContent = publicationCopy(documentValue, "verifyTitle");
      explanation.textContent = `${publicationCopy(documentValue, "publisher")} ${verification.accountID}. ${publicationCopy(documentValue, "verifyInstructions")}`;
      input.setAttribute(
        "aria-label",
        publicationCopy(documentValue, "fingerprint"),
      );
      confirm.textContent = publicationCopy(documentValue, "verifyConfirm");
      cancel.textContent = publicationCopy(documentValue, "cancel");
      if (feedback.textContent)
        feedback.textContent = publicationCopy(documentValue, "mismatch");
    };
    documentValue.addEventListener("selective-remote:locale-changed", localize);
    const finish = (value) => {
      documentValue.removeEventListener(
        "selective-remote:locale-changed",
        localize,
      );
      dialog.close?.();
      dialog.remove();
      resolve(value);
    };
    confirm.addEventListener("click", () => {
      if (input.value.trim().toLowerCase() !== verification.fingerprint) {
        feedback.textContent = publicationCopy(documentValue, "mismatch");
        return;
      }
      finish(input.value);
    });
    cancel.addEventListener("click", () => finish(null));
    dialog.addEventListener("cancel", (event) => {
      event.preventDefault();
      finish(null);
    });
    dialog.addEventListener("close", () => finish(null));
    dialog.showModal();
    input.focus();
  });
}
export function renderPublishedVault({
  documentValue,
  container,
  client,
  filter = "all",
  onAccess = () => {},
  onStatus = () => {},
  mutationAvailable = false,
}) {
  container.replaceChildren();
  const view = client.view();
  if (!view) return;
  const status = documentValue.createElement("p");
  status.dataset.publicationState = view.stale ? "stale" : "verified";
  status.textContent = publicationCopy(
    documentValue,
    view.stale ? "stale" : mutationAvailable ? 'editable' : "readonly",
  );
  container.append(status);
  const labels = Object.fromEntries(
    ["HOST", "CREDENTIAL", "SNIPPET", "FORWARDING", "FOLDER"].map((kind) => [
      kind,
      publicationCopy(documentValue, kind),
    ]),
  );
  for (const model of view.models) {
    if (
      filter !== "all" &&
      model.kind !== "FOLDER" &&
      kinds[model.kind] !== filter
    )
      continue;
    const card = documentValue.createElement("article");
    card.className = "resource-card";
    card.dataset.resourceId = model.resourceID;
    const title = documentValue.createElement("h4");
    title.textContent = String(
      model.record?.data?.title ??
        model.metadata?.title ??
        model.folder?.path ??
        labels[model.kind],
    );
    const summary = documentValue.createElement("p");
    summary.textContent =
      model.folder?.path ??
      model.record?.data?.address ??
      model.metadata?.username ??
      model.record?.data?.description ??
      labels[model.kind];
    const actions = documentValue.createElement("div");
    actions.className = "record-actions";
    for (const [action, label] of [
      ["share", publicationCopy(documentValue, "share")],
      ["who", publicationCopy(documentValue, "who")],
      ...(mutationAvailable ? [['move',documentValue.documentElement?.lang==='en'?'Move':'Переместить'],...(model.kind==='FOLDER'?[]:[['edit',documentValue.documentElement?.lang==='en'?'Edit':'Редактировать']])] : []),
    ]) {
      const button = documentValue.createElement("button");
      button.type = "button";
      button.textContent = label;
      button.disabled = view.stale;
      button.addEventListener("click", () => {
        Promise.resolve(onAccess(model.reference, action)).catch(() =>
          onStatus(publicationCopy(documentValue, "accessFailed")),
        );
      });
      actions.append(button);
    }
    card.addEventListener("contextmenu", (event) => {
      event.preventDefault();
      if (!view.stale)
        Promise.resolve(onAccess(model.reference, "who")).catch(() =>
          onStatus(publicationCopy(documentValue, "accessFailed")),
        );
    });
    if (["SNIPPET", "FORWARDING"].includes(model.kind)) {
      const detail = documentValue.createElement("button");
      detail.type = "button";
      detail.dataset.publicationAction = "detail";
      detail.textContent = publicationCopy(documentValue, "detail");
      detail.addEventListener("click", () => {
        const now = client.view();
        if (!now || now.headerHash !== view.headerHash || container.contains(card) === false) return;
        const verified = now.models.find(m => m.resourceID === model.reference.resourceID &&
          m.teamID === model.reference.teamID && m.vaultID === model.reference.vaultID && m.part === model.part);
        if (!verified) return;
        const data = verified.record.data;
        const value = model.kind === "SNIPPET" ? data.body ?? "" : data.configuration ?? "";
        const contentValue = typeof value === "string" ? value : JSON.stringify(value, null, 2);
        const dialog = documentValue.createElement("dialog");
        dialog.dataset.publicationDialog = "detail";
        dialog.setAttribute("aria-label", String(data.title ?? labels[model.kind]));
        dialog.dataset.resourceId = verified.reference.resourceID;
        dialog.dataset.teamId = verified.reference.teamID;
        dialog.dataset.vaultId = verified.reference.vaultID;
        dialog.dataset.generationId = verified.generationID;
        dialog.dataset.part = verified.part;
        ownPublicationDialog(client, dialog);
        const heading = documentValue.createElement("h3");
        heading.textContent = String(data.title ?? labels[model.kind]);
        const state = documentValue.createElement("p");
        state.dataset.publicationState = now.stale ? "stale" : "verified";
        state.textContent = publicationCopy(documentValue, now.stale ? "stale" : "readonly");
        const content = documentValue.createElement("pre");
        content.textContent = contentValue;
        const target = documentValue.createElement("p");
        target.textContent = model.kind === "FORWARDING" ? String(data.destination ?? "") : "";
        const feedback = documentValue.createElement("p");
        feedback.setAttribute("role", "status");
        const copy = documentValue.createElement("button");
        copy.type = "button";
        copy.dataset.publicationAction = "copy";
        copy.textContent = publicationCopy(documentValue, "copy");
        copy.addEventListener("click", async () => {
          const currentView = client.view();
          if (!dialog.isConnected || !currentView || currentView.headerHash !== now.headerHash) return;
          try {
            await documentValue.defaultView.navigator.clipboard.writeText(contentValue);
            if (dialog.isConnected && client.view()?.headerHash === now.headerHash)
              feedback.textContent = publicationCopy(documentValue, "copied");
          } catch {
            if (dialog.isConnected && client.view()?.headerHash === now.headerHash)
              feedback.textContent = publicationCopy(documentValue, "copyFailed");
          }
        });
        const close = documentValue.createElement("button");
        close.type = "button";
        close.dataset.publicationAction = "close";
        close.textContent = publicationCopy(documentValue, "close");
        const remove = () => {
          content.textContent = "";
          dialog.close?.();
          dialog.remove();
        };
        close.addEventListener("click", remove);
        dialog.addEventListener("cancel", event => { event.preventDefault(); remove(); });
        dialog.addEventListener("close", () => { content.textContent = ""; dialog.remove(); });
        dialog.append(heading, state, target, content, copy, close, feedback);
        documentValue.body.append(dialog);
        dialog.showModal();
      });
      actions.append(detail);
    }
    if (model.kind === "CREDENTIAL") {
      const reveal = documentValue.createElement("button");
      reveal.type = "button";
      reveal.textContent = publicationCopy(documentValue, "reveal");
      reveal.disabled =
        view.stale ||
        !view.descriptors.some(
          (d) =>
            d.payload.resourceID === model.resourceID &&
            d.payload.part === "SECRET",
        );
      reveal.addEventListener("click", async () => {
        reveal.disabled = true;
        try {
          const secret = await client.revealSecret(model.resourceID);
          if (!client.view() || client.view().headerHash !== view.headerHash)
            return;
          const dialog = documentValue.createElement("dialog");
          dialog.dataset.publicationDialog = "secret";
          ownPublicationDialog(client, dialog);
          const content = documentValue.createElement("pre");
          content.textContent = String(secret.record.data.secret ?? "");
          const close = documentValue.createElement("button");
          close.type = "button";
          close.textContent = publicationCopy(documentValue, "close");
          const remove = () => {
            content.textContent = "";
            dialog.close?.();
            dialog.remove();
          };
          close.addEventListener("click", remove);
          dialog.addEventListener("cancel", (event) => {
            event.preventDefault();
            remove();
          });
          dialog.addEventListener("close", () => {
            content.textContent = "";
            dialog.remove();
          });
          dialog.append(content, close);
          documentValue.body.append(dialog);
          dialog.showModal();
        } catch {
          onStatus(publicationCopy(documentValue, "secretFailed"));
        } finally {
          reveal.disabled = !client.view() || client.view()?.stale;
        }
      });
      actions.append(reveal);
    }
    card.append(title, summary, actions);
    container.append(card);
  }
}

export async function resolvePublicationDeviceKeyVersion({
  client,
  repository,
  identity,
  sessionIdentity,
  cryptoValue = globalThis.crypto,
}) {
  const snapshot = await client.deviceTrustSnapshot(),
    pin = await repository.loadPin(
      sessionIdentity.endpoint,
      sessionIdentity.accountID,
    );
  if (!pin) fail("publisher_own_pin_missing");
  const entry = snapshot.checkpoint?.payload?.entries.find(
      (e) => e.deviceID === sessionIdentity.deviceID,
    ),
    certificate = snapshot.certificates?.find(
      (c) =>
        c.payload.deviceID === sessionIdentity.deviceID &&
        c.payload.keyVersion === entry?.keyVersion,
    );
  if (!certificate) fail("publication_local_key_unavailable");
  const verified = await verifyDeviceForWrapping({
    rootPublicKey: snapshot.rootPublicKey,
    checkpoint: snapshot.checkpoint,
    certificate,
    trust: pin,
    expectedDeviceID: sessionIdentity.deviceID,
    cryptoValue,
  });
  if (
    identity.deviceID !== sessionIdentity.deviceID ||
    !equal(verified.publicKey, identity.publicKey)
  )
    fail("publication_local_key_mismatch");
  return certificate.payload.keyVersion;
}
