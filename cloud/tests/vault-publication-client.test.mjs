import test from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import {
  migrationFixture,
  legacy,
  record,
  uuid,
} from "./vault-v2-migration-fixtures.mjs";
import { prepareLegacyMigration } from "../public/vault-v2-migration.js";
import {
  unwrapResourceCEK,
  decryptResourcePart,
  encryptResourcePart,
} from "../public/resource-crypto-v2.js";
import { prepareReaderProjection } from "../public/vault-publication-v1.js";
const api = await import("../public/vault-publication-client.js").catch(
  () => ({}),
);
const clone = structuredClone;
export async function browserFixture({
  crossAccount = false,
  empty = false,
  alterPayload = null,
} = {}) {
  const publisher = await migrationFixture(),
    reader = crossAccount ? await migrationFixture() : publisher;
  const subject = { ...reader.recipient, deviceKeyVersion: 1 };
  const records = empty
    ? []
    : [
        record("host", {
          title: "Host",
          address: "private.example",
          folder: "Production",
        }),
        record("credential", {
          title: "Login",
          username: "alice",
          secret: "PRIVATE_PASSWORD",
          kind: "password",
        }),
      ];
  const targets = crossAccount
    ? [{ ...publisher.recipient, deviceKeyVersion: 1 }, subject]
    : [subject];
  const pins = {
    loadPin: async (e, a) =>
      a === reader.accountID
        ? await reader.pinnedTrust.loadPin()
        : await publisher.pinnedTrust.loadPin(),
    advancePin: async () => {},
  };
  const out = await prepareLegacyMigration({
    ...publisher,
    pinnedTrust: pins,
    document: legacy(records),
    policy: [],
    recipientTargets: () => targets,
    persistCheckpoint: async () => {},
    readerPublication: {
      publisherAccountID: publisher.accountID,
      publisherKeyVersion: 1,
      custodianDeviceIDs: [publisher.deviceID],
      custodianTargets: targets,
      verifyIdentityReservations: async () => {},
    },
  });
  if (alterPayload) {
    const object = out.objects.find((o) => o.part === "GENERAL"),
      wrapper = object.wrappers.find(
        (w) => w.context.deviceID === reader.deviceID,
      ),
      cek = await unwrapResourceCEK({
        wrapper,
        context: wrapper.context,
        privateKey: reader.identity.privateKey,
        cryptoValue: webcrypto,
      });
    const bytes = await decryptResourcePart({
        envelope: object.envelope,
        context: object.envelope.context,
        cek,
        cryptoValue: webcrypto,
      }),
      payload = JSON.parse(new TextDecoder().decode(bytes));
    alterPayload(payload);
    object.envelope = await encryptResourcePart({
      cek,
      context: object.envelope.context,
      plaintext: new TextEncoder().encode(JSON.stringify(payload)),
      cryptoValue: webcrypto,
    });
    cek.fill(0);
    bytes.fill(0);
    out.readerProjection = await prepareReaderProjection({
      scope: publisher.scope,
      resources: out.resources,
      objects: out.objects,
      recipients: targets,
      root: publisher.root,
      publisherAccountID: publisher.accountID,
      publisherDeviceID: publisher.deviceID,
      publisherKeyVersion: 1,
      cryptoValue: webcrypto,
    });
  }
  const p = out.readerProjection,
    row = p.recipients.find(
      (r) => r.inventory.payload.deviceID === reader.deviceID,
    ),
    headerHash = row.inventory.payload.headerHash;
  let current = {
      endpoint: reader.endpoint,
      accountID: reader.accountID,
      deviceID: reader.deviceID,
      sessionEpoch: "session-1",
    },
    payload = null,
    highWater = null,
    pin = null,
    payloadReceipt = null;
  const requests = [],
    scope = {
      teamID: publisher.scope.teamID,
      vaultID: publisher.scope.vaultID,
    };
  const transport = {
    async header() {
      requests.push("header");
      return clone({
        header: p.header,
        headerHash,
        subject: row.inventory.payload,
        inventory: row.inventory,
      });
    },
    async publisher() {
      requests.push("publisher");
      return clone({
        headerHash,
        generationID: p.header.payload.generationID,
        accountID: publisher.accountID,
        deviceID: publisher.deviceID,
        keyVersion: 1,
        rootPublicKey: publisher.root.publicKey,
        certificate: publisher.recipient.certificate,
        checkpoint: publisher.recipient.checkpoint,
      });
    },
    async directory() {
      requests.push("directory");
      return clone({
        headerHash,
        generationID: p.header.payload.generationID,
        inventory: row.inventory,
        descriptors: p.descriptors,
        nextCursor: null,
      });
    },
    async part(_scope, q) {
      requests.push(q.part);
      const descriptor = p.descriptors.find(
          (d) =>
            d.payload.resourceID === q.resourceID && d.payload.part === q.part,
        ),
        object = out.objects.find(
          (o) => o.resourceID === q.resourceID && o.part === q.part,
        ),
        proof = row.proofs.find(
          (x) => x.resourceID === q.resourceID && x.part === q.part,
        );
      return clone({
        headerHash,
        generationID: p.header.payload.generationID,
        descriptor,
        envelope: object.envelope,
        entry: proof.entry,
        proof: proof.proof,
      });
    },
  };
  const repository = {
    async load() {
      return { highWater: clone(highWater), payload: clone(payload), payloadReceipt };
    },
    async persist(_scope, value, guard) {
      guard();
      if (
        highWater &&
        (value.highWater.sequence < highWater.sequence ||
          (value.highWater.sequence === highWater.sequence &&
            value.highWater.hash !== highWater.hash))
      )
        throw Error("publication_fork");
      highWater = clone(value.highWater);
      payload = clone(value.payload);
      payloadReceipt = uuid();
      return payloadReceipt;
    },
    async clearPayload(_scope, expected = payloadReceipt, guard = () => {}) {
      guard();
      if (expected !== payloadReceipt || !payloadReceipt) return false;
      payload = null;
      payloadReceipt = null;
      return true;
    },
  };
  const publisherTrustRepository = {
    async loadPin() {
      return pin;
    },
    async savePinIfAbsent(_e, _t, value) {
      if (pin && pin.rootFingerprint !== value.rootFingerprint)
        throw Error("device_trust_invalid");
      pin = clone(value);
    },
    async advancePin(_e, _t, _old, next) {
      pin = clone(next);
    },
  };
  return {
    publisher,
    reader,
    out,
    p,
    row,
    scope,
    transport,
    repository,
    requests,
    publisherTrustRepository,
    options: {
      transport,
      identity: () => current,
      scope,
      privateKey: reader.identity.privateKey,
      publicKey: reader.identity.publicKey,
      deviceKeyVersion: 1,
      ownTrustRepository: reader.pinnedTrust,
      publisherTrustRepository,
      repository,
      cryptoValue: webcrypto,
    },
    switchIdentity(patch) {
      current = { ...current, ...patch };
    },
    getStored: () => ({ payload, highWater }),
  };
}
test("materializes actual linked Host/Folder/Credential metadata using authenticated P256+AES without SECRET download", async () => {
  assert.equal(typeof api.createVaultPublicationClient, "function");
  const f = await browserFixture(),
    client = api.createVaultPublicationClient(f.options),
    view = await client.load();
  assert.equal(view.stale, false);
  assert.equal(view.models.length, 3);
  assert.equal(
    view.models.find((m) => m.kind === "HOST").record.data.address,
    "private.example",
  );
  assert.equal(
    view.models.find((m) => m.kind === "CREDENTIAL").metadata.username,
    "alice",
  );
  assert.equal(f.requests.includes("SECRET"), false);
  assert.equal(
    JSON.stringify(f.getStored()).includes("PRIVATE_PASSWORD"),
    false,
  );
  const secret = await client.revealSecret(
    view.models.find((m) => m.kind === "CREDENTIAL").resourceID,
  );
  assert.equal(secret.record.data.secret, "PRIVATE_PASSWORD");
  assert.equal(f.requests.filter((x) => x === "SECRET").length, 1);
  client.lock();
  assert.equal(client.view(), null);
});
test("empty signed inventory is a coherent empty model set", async () => {
  const f = await browserFixture({ empty: true }),
    client = api.createVaultPublicationClient(f.options);
  assert.deepEqual((await client.load()).models, []);
});
test("cross-account publisher requires independently supplied fingerprint, rejects mismatch and reuses scoped pin", async () => {
  const f = await browserFixture({ crossAccount: true }),
    client = api.createVaultPublicationClient(f.options);
  await assert.rejects(
    client.load(),
    (e) =>
      e.message === "publisher_verification_required" &&
      e.verification.fingerprint === f.publisher.root.fingerprint,
  );
  assert.equal(f.requests.includes("GENERAL"), false);
  await assert.rejects(
    client.confirmPublisher("0".repeat(64)),
    /publisher_fingerprint_mismatch/,
  );
  await client.confirmPublisher(f.publisher.root.fingerprint);
  assert.equal((await client.load()).models.length, 3);
});
for (const [name, mutate, pattern] of [
  [
    "publisher key epoch mismatch",
    (f) => {
      const get = f.transport.publisher;
      f.transport.publisher = async (...a) => ({
        ...(await get(...a)),
        keyVersion: 2,
      });
    },
    /publication_publisher_mismatch/,
  ],
  [
    "invalid Merkle proof",
    (f) => {
      const get = f.transport.part;
      f.transport.part = async (...a) => {
        const r = await get(...a);
        r.proof.total = 2;
        return r;
      };
    },
    /publication_wrapper_proof_invalid/,
  ],
  [
    "wrapper wrong epoch",
    (f) => {
      const get = f.transport.part;
      f.transport.part = async (...a) => {
        const r = await get(...a);
        r.entry.wrapper.context.membershipEpoch++;
        return r;
      };
    },
    /publication_subject_mismatch/,
  ],
  [
    "wrapper wrong device key version",
    (f) => {
      const get = f.transport.part;
      f.transport.part = async (...a) => {
        const r = await get(...a);
        r.entry.deviceKeyVersion++;
        return r;
      };
    },
    /publication_subject_mismatch/,
  ],
  [
    "tampered ciphertext",
    (f) => {
      const part = f.transport.part;
      f.transport.part = async (...a) => {
        const r = await part(...a);
        r.envelope.authTag = "A".repeat(22);
        return r;
      };
    },
    /publication_ciphertext_mismatch/,
  ],
  [
    "incomplete directory",
    (f) => {
      const page = f.transport.directory;
      f.transport.directory = async (...a) => ({
        ...(await page(...a)),
        descriptors: [],
      });
    },
    /publication_incomplete/,
  ],
  [
    "repeated cursor",
    (f) => {
      const page = f.transport.directory;
      f.transport.directory = async (...a) => ({
        ...(await page(...a)),
        nextCursor: "repeat",
      });
    },
    /publication_incomplete|duplicate_descriptor/,
  ],
  [
    "foreign subject",
    (f) => {
      const h = f.transport.header;
      f.transport.header = async () => {
        const r = await h();
        r.subject.deviceID = uuid();
        return r;
      };
    },
    /publication_subject_mismatch/,
  ],
  [
    "changed pointer",
    (f) => {
      let n = 0;
      const h = f.transport.header;
      f.transport.header = async () => {
        const r = await h();
        if (++n > 1) r.headerHash = "f".repeat(64);
        return r;
      };
    },
    /publication_changed/,
  ],
  [
    "local persistence rejection",
    (f) => {
      f.repository.persist = async () => {
        throw Error("publication_storage_failed");
      };
    },
    /publication_storage_failed/,
  ],
  [
    "logout and relogin same device",
    (f) => {
      const part = f.transport.part;
      f.transport.part = async (...a) => {
        const r = await part(...a);
        f.switchIdentity({ sessionEpoch: "session-2" });
        return r;
      };
    },
    /publication_session_changed/,
  ],
  [
    "endpoint switch",
    (f) => {
      const part = f.transport.part;
      f.transport.part = async (...a) => {
        const r = await part(...a);
        f.switchIdentity({ endpoint: "https:\/\/other.example" });
        return r;
      };
    },
    /publication_session_changed/,
  ],
  [
    "account switch",
    (f) => {
      const part = f.transport.part;
      f.transport.part = async (...a) => {
        const r = await part(...a);
        f.switchIdentity({ accountID: uuid() });
        return r;
      };
    },
    /publication_session_changed/,
  ],
  [
    "device switch",
    (f) => {
      const part = f.transport.part;
      f.transport.part = async (...a) => {
        const r = await part(...a);
        f.switchIdentity({ deviceID: uuid() });
        return r;
      };
    },
    /publication_session_changed/,
  ],
  [
    "identity changes after durable transaction",
    (f) => {
      const persist = f.repository.persist;
      f.repository.persist = async (...a) => {
        await persist(...a);
        f.switchIdentity({ sessionEpoch: "session-2" });
      };
    },
    /publication_session_changed/,
  ],
])
  test(name + " never publishes partial models", async () => {
    const f = await browserFixture();
    mutate(f);
    const client = api.createVaultPublicationClient(f.options);
    await assert.rejects(client.load(), pattern);
    assert.equal(client.view(), null);
  });
test("durable same-sequence fork and rollback fail, transient cache is stale, repair loss removes cache while retaining high-water", async () => {
  const f = await browserFixture(),
    client = api.createVaultPublicationClient(f.options);
  await client.load();
  const hw = clone(f.getStored().highWater);
  f.transport.header = async () => {
    throw Error("publication_network_unavailable");
  };
  assert.equal((await client.load()).stale, true);
  f.transport.header = async () => {
    throw Error("publication_repair_required");
  };
  await assert.rejects(client.load(), /publication_repair_required/);
  assert.equal(client.view(), null);
  assert.equal(f.getStored().payload, null);
  assert.deepEqual(f.getStored().highWater, hw);
  f.repository.load = async () => ({
    highWater: { sequence: hw.sequence, hash: "a".repeat(64) },
    payload: null,
  });
  f.transport.header = async () => ({
    header: f.p.header,
    headerHash: f.row.inventory.payload.headerHash,
    subject: f.row.inventory.payload,
    inventory: f.row.inventory,
  });
  await assert.rejects(client.load(), /publication_fork/);
  f.repository.load = async () => ({
    highWater: { sequence: 2, hash: hw.hash },
    payload: null,
  });
  await assert.rejects(client.load(), /publication_rollback/);
});
import { createAuthenticatedVaultClient } from "../public/vault-sync.js";
import * as app from "../public/app.js";
test("authenticated publication adapter uses no-store routes and opaque epoch changes on login/logout/401", async () => {
  const accountID = uuid(),
    deviceID = uuid(),
    scope = { teamID: uuid(), vaultID: uuid() },
    calls = [];
  const client = createAuthenticatedVaultClient({
    fetchValue: async (path, options) => {
      calls.push({ path, options });
      return new Response(
        JSON.stringify(
          path === "/v1/auth/login"
            ? { user: { id: accountID }, deviceID, token: "t".repeat(43) }
            : { headerHash: "a".repeat(64) },
        ),
        { status: 200 },
      );
    },
  });
  assert.equal(typeof client.publicationTransport, "function");
  await client.login({ deviceID });
  const first = client.publicationIdentity("https://staging.example.test");
  await client.publicationTransport().header(scope);
  assert.equal(calls.at(-1).options.cache, "no-store");
  assert.equal(
    calls.at(-1).options.headers.Authorization,
    "Bearer " + "t".repeat(43),
  );
  await client.logout();
  assert.equal(
    client.publicationIdentity("https://staging.example.test"),
    null,
  );
  await client.login({ deviceID });
  assert.notEqual(
    client.publicationIdentity("https://staging.example.test").sessionEpoch,
    first.sessionEpoch,
  );
});
test("actual app format selection only permits legacy after authoritative V1 context and never a failed probe", async () => {
  assert.equal(typeof app.resolveTeamVaultFormat, "function");
  assert.equal(
    await app.resolveTeamVaultFormat(
      {
        accessClient: () => ({
          getContext: async () => ({ formatState: "V1_ACTIVE" }),
        }),
      },
      { teamID: uuid(), vaultID: uuid() },
    ),
    "V1_ACTIVE",
  );
  for (const formatState of ["V2_ACTIVE", "V2_PREPARING", "V2_READY"])
    assert.equal(
      await app.resolveTeamVaultFormat(
        { accessClient: () => ({ getContext: async () => ({ formatState }) }) },
        {},
      ),
      formatState,
    );
  await assert.rejects(
    app.resolveTeamVaultFormat(
      {
        accessClient: () => ({
          getContext: async () => {
            throw Error("publication_repair_required");
          },
        }),
      },
      {},
    ),
    /publication_repair_required/,
  );
});
test("actual app background maintenance never creates legacy controllers for V2 or failed context", async () => {
  let count = 0;
  const scope = { id: uuid(), role: "owner" },
    options = {
      client: {
        accessClient: () => ({
          getContext: async () => ({ formatState: "V2_ACTIVE" }),
        }),
      },
      identity: {},
      team: scope,
      vaults: [{ id: uuid() }],
      controllerFactory: () => {
        count++;
        throw Error("legacy called");
      },
    };
  await app.maintainAccessibleTeamVaultWrappers(options);
  assert.equal(count, 0);
  options.client.accessClient = () => ({
    getContext: async () => {
      throw Error("offline");
    },
  });
  await app.maintainAccessibleTeamVaultWrappers(options);
  assert.equal(count, 0);
});

for (const [name, alterPayload, pattern] of [
  [
    "authentic signed wrong generation plaintext",
    (p) => (p.link.generationID = uuid()),
    /publication_payload_link_mismatch/,
  ],
  [
    "authentic signed wrong kind plaintext",
    (p) => (p.link.kind = "SNIPPET"),
    /publication_payload_link_mismatch/,
  ],
  [
    "authentic signed unsupported schema",
    (p) => (p.record.type = "unknown"),
    /publication_payload_schema_invalid/,
  ],
  [
    "authentic signed metadata SECRET confusion",
    (p) => (p.secret = "SECRET_IN_GENERAL"),
    /publication_payload_schema_invalid/,
  ],
])
  test(name + " cannot become an app model", async () => {
    const f = await browserFixture({ alterPayload });
    const client = api.createVaultPublicationClient(f.options);
    await assert.rejects(client.load(), pattern);
    assert.equal(client.view(), null);
  });
test("revoked explicit SECRET action invalidates managed models and never persists secret", async () => {
  const f = await browserFixture(),
    client = api.createVaultPublicationClient(f.options),
    view = await client.load();
  f.transport.part = async () => {
    throw Error("publication_access_denied");
  };
  await assert.rejects(
    client.revealSecret(
      view.models.find((m) => m.kind === "CREDENTIAL").resourceID,
    ),
    /publication_access_denied/,
  );
  assert.equal(client.view(), null);
  assert.equal(f.getStored().payload, null);
  assert.equal(f.getStored().highWater.hash, view.headerHash);
});
test("SECRET reveal pointer switch invalidates live views without destroying coherent stale cache", async () => {
  const f = await browserFixture(),
    client = api.createVaultPublicationClient(f.options),
    view = await client.load();
  const h = f.transport.header;
  f.transport.header = async () => ({
    ...(await h()),
    headerHash: "0".repeat(64),
  });
  await assert.rejects(
    client.revealSecret(
      view.models.find((m) => m.kind === "CREDENTIAL").resourceID,
    ),
    /publication_changed/,
  );
  assert.equal(client.view(), null);
  assert.notEqual(f.getStored().payload, null);
});
test("materializes original production V1 vector-clock record and ISO timestamp, preserving verified resource identity", async () => {
  const deviceID = uuid(),
    f = await browserFixture({
      alterPayload: (p) => {
        p.record.version = { [deviceID]: 1 };
        p.record.modifiedAt = "2026-10-01T08:00:00.000Z";
      },
    }),
    client = api.createVaultPublicationClient(f.options);
  const view = await client.load();
  assert.ok(view.models.some((m) => m.record?.version?.[deviceID] === 1));
});
test("app resolves exact admitted local key epoch from verified own directory and rejects key substitution", async () => {
  assert.equal(typeof api.resolvePublicationDeviceKeyVersion, "function");
  const f = await browserFixture(),
    snapshot = {
      rootPublicKey: f.reader.root.publicKey,
      checkpoint: f.reader.recipient.checkpoint,
      certificates: [f.reader.recipient.certificate],
    },
    options = {
      client: { deviceTrustSnapshot: async () => snapshot },
      repository: f.reader.pinnedTrust,
      identity: { ...f.reader.identity, deviceID: f.reader.deviceID },
      sessionIdentity: f.options.identity(),
      cryptoValue: webcrypto,
    };
  assert.equal(await api.resolvePublicationDeviceKeyVersion(options), 1);
  await assert.rejects(
    api.resolvePublicationDeviceKeyVersion({
      ...options,
      identity: {
        ...options.identity,
        publicKey: (await browserFixture()).reader.identity.publicKey,
      },
    }),
    /publication_local_key_mismatch/,
  );
});
test("publication UI uses the selected interface language for independent identity verification and read-only state", () => {
  assert.equal(typeof api.publicationCopy, "function");
  assert.match(
    api.publicationCopy({ documentElement: { lang: "en" } }, "readonly"),
    /read.only/i,
  );
  assert.match(
    api.publicationCopy({ documentElement: { lang: "ru" } }, "readonly"),
    /чтение/,
  );
  assert.match(
    api.publicationCopy(
      { documentElement: { lang: "en" } },
      "verifyInstructions",
    ),
    /independent/,
  );
});
test("empty pages with unique continuation cursors cannot cause unbounded authenticated reads", async () => {
  const f = await browserFixture(),
    page = f.transport.directory;
  let requests = 0;
  f.transport.directory = async (...a) => {
    if (++requests > 3) throw Error("unexpected_extra_page");
    return {
      ...(await page(...a)),
      descriptors: [],
      nextCursor: "cursor-" + requests,
    };
  };
  const client = api.createVaultPublicationClient(f.options);
  await assert.rejects(client.load(), /publication_incomplete/);
  assert.equal(requests, 1);
});
test("display boundary clears a prior coherent view after identity changes even without an event subscription", async () => {
  const f = await browserFixture(),
    client = api.createVaultPublicationClient(f.options);
  await client.load();
  f.switchIdentity({ sessionEpoch: "new-session" });
  assert.equal(client.view(), null);
  await assert.rejects(
    client.revealSecret(
      f.out.resources.find((r) => r.kind === "CREDENTIAL").id,
    ),
    /publication_current_required/,
  );
});
test("explicit protected prior-publication cache opens stale without header/directory/key-snapshot requests", async () => {
  const f = await browserFixture(),
    client = api.createVaultPublicationClient(f.options);
  await client.load();
  client.lock();
  f.requests.length = 0;
  assert.equal(typeof client.loadStaleCache, "function");
  const view = await client.loadStaleCache();
  assert.equal(view.stale, true);
  assert.equal(view.models.length, 3);
  assert.deepEqual(f.requests, []);
  await assert.rejects(
    client.revealSecret(
      view.models.find((m) => m.kind === "CREDENTIAL").resourceID,
    ),
    /publication_current_required/,
  );
});
for (const [name, change, pattern] of [
  [
    "missing cache",
    async (f) => f.repository.clearPayload(),
    /publication_cache_unavailable/,
  ],
  [
    "wrong account",
    async (f) => f.switchIdentity({ accountID: uuid() }),
    /publication_subject_mismatch/,
  ],
  [
    "wrong device",
    async (f) => f.switchIdentity({ deviceID: uuid() }),
    /publication_subject_mismatch/,
  ],
  [
    "fork high-water",
    async (f) => {
      const load = f.repository.load;
      f.repository.load = async () => ({
        ...(await load()),
        highWater: { sequence: 1, hash: "f".repeat(64) },
      });
    },
    /publication_fork/,
  ],
  [
    "rollback high-water",
    async (f) => {
      const load = f.repository.load;
      f.repository.load = async () => ({
        ...(await load()),
        highWater: { sequence: 2, hash: "f".repeat(64) },
      });
    },
    /publication_rollback/,
  ],
])
  test("explicit protected stale path rejects " + name, async () => {
    const f = await browserFixture(),
      client = api.createVaultPublicationClient(f.options);
    await client.load();
    client.lock();
    await change(f);
    await assert.rejects(client.loadStaleCache(), pattern);
    assert.equal(client.view(), null);
  });
test("logout synchronously removes identity before subscribers and keeps only the captured authenticated logout request while response is pending", async () => {
  const accountID = uuid(),
    deviceID = uuid(),
    scope = { teamID: uuid(), vaultID: uuid() };
  let finishLogout,
    protectedReads = 0,
    logoutHeaders;
  const client = createAuthenticatedVaultClient({
    fetchValue: async (path, options) => {
      if (path === "/v1/auth/login")
        return new Response(
          JSON.stringify({
            user: { id: accountID },
            deviceID,
            token: "t".repeat(43),
          }),
          { status: 200 },
        );
      if (path === "/v1/auth/logout") {
        logoutHeaders = options.headers;
        return new Promise((resolve) => {
          finishLogout = () => resolve(new Response("{}", { status: 200 }));
        });
      }
      protectedReads++;
      return new Response("{}", { status: 200 });
    },
  });
  await client.login({ deviceID });
  let seenDuringEvent = "not-called";
  client.subscribePublicationIdentity(() => {
    seenDuringEvent = client.publicationIdentity(
      "https://staging.example.test",
    );
  });
  const pending = client.logout();
  assert.equal(
    client.publicationIdentity("https://staging.example.test"),
    null,
  );
  assert.equal(client.session(), null);
  assert.equal(seenDuringEvent, null);
  assert.equal(logoutHeaders.Authorization, "Bearer " + "t".repeat(43));
  await assert.rejects(
    client.publicationTransport().header(scope),
    /authentication_required/,
  );
  assert.equal(protectedReads, 0);
  finishLogout();
  await pending;
});
test("real authenticated 401 clears identity before subscribers and invalidates published live state", async () => {
  const f = await browserFixture();
  let deny = false;
  const client = createAuthenticatedVaultClient({
    fetchValue: async (path) => {
      if (path === "/v1/auth/login")
        return new Response(
          JSON.stringify({
            user: { id: f.reader.accountID },
            deviceID: f.reader.deviceID,
            token: "t".repeat(43),
          }),
          { status: 200 },
        );
      return new Response(
        JSON.stringify(
          deny ? { error: "session_revoked" } : await f.transport.header(),
        ),
        { status: deny ? 401 : 200 },
      );
    },
  });
  await client.login({ deviceID: f.reader.deviceID });
  const publication = api.createVaultPublicationClient({
    ...f.options,
    identity: () => client.publicationIdentity(f.reader.endpoint),
    subscribeIdentityChange: (cb) => client.subscribePublicationIdentity(cb),
  });
  await publication.load();
  let eventIdentity = "not-called";
  client.subscribePublicationIdentity(() => {
    eventIdentity = client.publicationIdentity(f.reader.endpoint);
  });
  deny = true;
  await assert.rejects(
    client.publicationTransport().header(f.scope),
    /authentication_required/,
  );
  assert.equal(eventIdentity, null);
  assert.equal(client.publicationIdentity(f.reader.endpoint), null);
  assert.equal(publication.view(), null);
});
test("a delayed old-session 401 cannot erase a newly authenticated identity", async () => {
  const accountID = uuid(),
    deviceID = uuid(),
    scope = { teamID: uuid(), vaultID: uuid() };
  let finishRequest;
  const client = createAuthenticatedVaultClient({
    fetchValue: async (path) => {
      if (path === "/v1/auth/login")
        return new Response(
          JSON.stringify({
            user: { id: accountID },
            deviceID,
            token: "t".repeat(43),
          }),
          { status: 200 },
        );
      return new Promise((resolve) => {
        finishRequest = () =>
          resolve(
            new Response(JSON.stringify({ error: "session_revoked" }), {
              status: 401,
            }),
          );
      });
    },
  });
  await client.login({ deviceID });
  const request = client.publicationTransport().header(scope);
  await client.login({ deviceID });
  const newIdentity = client.publicationIdentity(
    "https://staging.example.test",
  );
  finishRequest();
  await assert.rejects(request, /authentication_required/);
  assert.deepEqual(
    client.publicationIdentity("https://staging.example.test"),
    newIdentity,
  );
});
test("offline cache retains verified reader public key and epoch and rejects a different nonextractable private key at the same account/device", async () => {
  const f = await browserFixture(),
    client = api.createVaultPublicationClient(f.options),
    view = await client.load();
  assert.equal(view.readerDevice?.keyVersion, 1);
  assert.deepEqual(view.readerDevice?.publicKey, f.reader.identity.publicKey);
  client.lock();
  const changedKey = (await browserFixture()).reader.identity.privateKey,
    other = api.createVaultPublicationClient({
      ...f.options,
      privateKey: changedKey,
    });
  await assert.rejects(
    other.loadStaleCache(),
    /publication_local_key_mismatch/,
  );
  assert.equal(other.view(), null);
  f.transport.header = async () => {
    throw Error("publication_network_unavailable");
  };
  await assert.rejects(other.load(), /publication_local_key_mismatch/);
  assert.equal(other.view(), null);
});

test("reader rejects more than 100 descriptors before fetching any encrypted part", async () => {
  const f = await browserFixture(),
    directory = f.transport.directory,
    ids = Array.from({ length: 51 }, () => uuid());
  f.transport.directory = async (...args) => {
    const page = await directory(...args);
    return {
      ...page,
      descriptors: Array.from({ length: 101 }, (_, i) => ({
        ...page.descriptors[0],
        payload: {
          ...page.descriptors[0].payload,
          resourceID: ids[Math.floor(i / 2)],
          part: i % 2 ? "SECRET" : "METADATA",
        },
      })),
    };
  };
  const client = api.createVaultPublicationClient(f.options);
  await assert.rejects(client.load(), /publication_incomplete/);
  assert.equal(f.requests.includes("GENERAL"), false);
});
test("main browser logout clears views synchronously and cannot finish over a newer session", async () => {
  const { completeBrowserSessionLogout } = await import("../public/app.js");
  let user = { id: "old" },
    finishLogout,
    restored = 0;
  const calls = [];
  const client = {
    session: () => user,
    logout() {
      user = null;
      calls.push("identity-cleared");
      return new Promise((r) => {
        finishLogout = r;
      });
    },
  };
  const vault = {
    lock() {
      calls.push("locked");
    },
    async forgetRememberedSession() {
      calls.push("forgot-old-vault");
    },
  };
  const pending = completeBrowserSessionLogout({
    client,
    vault,
    clearView() {
      calls.push("views-cleared");
    },
    restoreView() {
      restored++;
    },
  });
  assert.deepEqual(calls, [
    "identity-cleared",
    "locked",
    "views-cleared",
    "forgot-old-vault",
  ]);
  user = { id: "new" };
  finishLogout();
  await pending;
  assert.equal(restored, 0);
});

// Keep authentication and all reader crypto real; only remote HTTP is synthetic.
async function authenticatedPublicationFixture() {
  const f = await browserFixture();
  let intercept = null;
  const authenticated = createAuthenticatedVaultClient({
    fetchValue: async (path) => {
      if (path === "/v1/auth/login") return Response.json({
        user: { id: f.reader.accountID }, deviceID: f.reader.deviceID, token: "t".repeat(43),
      });
      if (path === "/v1/auth/logout") return Response.json({});
      const url = new URL(path, f.reader.endpoint), q = Object.fromEntries(url.searchParams);
      if (intercept) {
        const result = intercept(url);
        if (result) return result;
      }
      let value;
      if (url.pathname.endsWith("/header")) value = await f.transport.header();
      else if (url.pathname.endsWith("/publisher")) value = await f.transport.publisher();
      else if (url.pathname.endsWith("/directory")) value = await f.transport.directory();
      else {
        const match = url.pathname.match(/resources\/([^/]+)\/parts\/([^/]+)$/);
        value = await f.transport.part(f.scope, { ...q, resourceID: match[1], part: match[2] });
      }
      return Response.json(value);
    },
  });
  await authenticated.login({ deviceID: f.reader.deviceID });
  const options = { ...f.options, transport: authenticated.publicationTransport(),
    identity: () => authenticated.publicationIdentity(f.reader.endpoint),
    subscribeIdentityChange: cb => authenticated.subscribePublicationIdentity(cb) };
  return { ...f, authenticated, options, intercept: fn => { intercept = fn; } };
}

test("causal authenticated current 401 retires protected payload even after its identity event, retaining high-water", async () => {
  const f = await authenticatedPublicationFixture(), client = api.createVaultPublicationClient(f.options);
  await client.load();
  const highWater = clone(f.getStored().highWater);
  f.intercept(() => Response.json({ error: "session_revoked" }, { status: 401 }));
  await assert.rejects(client.load(), /authentication_required/);
  assert.equal(f.authenticated.publicationIdentity(f.reader.endpoint), null);
  assert.equal(client.view(), null);
  assert.equal(f.getStored().payload, null);
  assert.deepEqual(f.getStored().highWater, highWater);
});

for (const [operation, status] of [["load", 401], ["load", 403], ["SECRET", 401], ["SECRET", 403], ["SECRET", 200]]) {
  test(`delayed authenticated ${operation} ${status} cannot invalidate a same-account relogin's protected publication`, async () => {
    const f = await authenticatedPublicationFixture();
    let invalidations = 0, finish, started;
    const ready = new Promise(resolve => { started = resolve; });
    const old = api.createVaultPublicationClient({ ...f.options, onInvalidate: () => invalidations++ });
    const view = await old.load(), credential = view.models.find(m => m.kind === "CREDENTIAL");
    f.intercept(url => {
      if ((operation === "load" && url.pathname.endsWith("/header")) ||
          (operation === "SECRET" && url.pathname.endsWith("/parts/SECRET"))) {
        f.intercept(null);
        started();
        return new Promise(resolve => { finish = async () => {
          const value = status === 200 ? await f.transport.part(f.scope, { resourceID: credential.resourceID, part: "SECRET" }) :
            { error: status === 401 ? "session_revoked" : "publication_access_denied" };
          resolve(Response.json(value, { status }));
        }; });
      }
      return null;
    });
    const pending = (operation === "load" ? old.load() : old.revealSecret(credential.resourceID)).catch(e => e);
    await ready;
    await f.authenticated.logout();
    await f.authenticated.login({ deviceID: f.reader.deviceID });
    const newer = api.createVaultPublicationClient(f.options), newView = await newer.load();
    const before = invalidations, newIdentity = f.options.identity(), cached = clone(f.getStored());
    await finish();
    const error = await pending;
    assert.match(error.message, /authentication_required|publication_access_denied|publication_session_changed/);
    assert.deepEqual(f.options.identity(), newIdentity);
    assert.deepEqual(newer.view(), newView);
    assert.deepEqual(f.getStored(), cached, "old completion erased the new protected payload");
    assert.equal(invalidations, before, "old completion invalidated the newer UI owner");
  });
}

test("payload cleanup compares the captured receipt even when another client persists before cleanup", async () => {
  const f = await authenticatedPublicationFixture(), old = api.createVaultPublicationClient(f.options);
  await old.load();
  const clear = f.repository.clearPayload;
  let resume, entered;
  const ready = new Promise(resolve => { entered = resolve; });
  f.repository.clearPayload = async (...args) => {
    entered(); await new Promise(resolve => { resume = resolve; });
    return clear(...args);
  };
  f.intercept(() => { f.intercept(null); return Response.json({ error: "publication_access_denied" }, { status: 403 }); });
  const pending = old.load().catch(e => e);
  await ready;
  const newer = api.createVaultPublicationClient(f.options), newView = await newer.load(), cached = clone(f.getStored());
  resume();
  assert.equal((await pending).message, "publication_access_denied");
  assert.deepEqual(f.getStored(), cached);
  assert.deepEqual(newer.view(), newView);
});


test("a verified-to-stale transition retires current content dialogs before offline rendering", async () => {
  const f = await browserFixture();
  let invalidations = 0;
  const client = api.createVaultPublicationClient({...f.options, onInvalidate:()=>invalidations++});
  await client.load();
  assert.equal(invalidations, 0);
  f.transport.header = async ()=>{throw Error("publication_network_unavailable");};
  assert.equal((await client.load()).stale, true);
  assert.equal(invalidations, 1, "verified detail remains open with false current label");
});


test("causal authenticated current401 retires cache without an identity event subscription", async () => {
  const f = await authenticatedPublicationFixture();
  const client = api.createVaultPublicationClient({...f.options, subscribeIdentityChange:undefined});
  await client.load();
  f.intercept(()=>Response.json({error:"session_revoked"},{status:401}));
  await assert.rejects(client.load(), /authentication_required/);
  assert.equal(f.getStored().payload, null);
  assert.equal(f.getStored().highWater.sequence, 1);
});
