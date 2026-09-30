import assert from "node:assert/strict";
import test from "node:test";
import { webcrypto } from "node:crypto";
import {
  migrationFixture,
  legacy,
  record,
  uuid,
} from "./vault-v2-migration-fixtures.mjs";
import {
  previewLegacyMigration,
  prepareLegacyMigration,
  openMigrationCheckpoint,
} from "../public/vault-v2-migration.js";
import {
  unwrapResourceCEK,
  decryptResourcePart,
} from "../public/resource-crypto-v2.js";
const prepare = (f, document, extra = {}) =>
  prepareLegacyMigration({
    ...f,
    document,
    policy: [],
    recipientTargets: () => [f.recipient],
    persistCheckpoint: async () => {},
    cryptoValue: webcrypto,
    ...extra,
  });
test("inventory preserves exact logical records, folder ancestry and tombstones without side effects", () => {
  const doc = legacy([
    record("host", { folder: "A/B" }),
    record("credential"),
    record("snippet", { folder: "A" }),
    record("forwarding"),
  ]);
  doc.tombstones.push({ id: uuid(), version: 2 });
  const result = previewLegacyMigration({ document: doc });
  assert.equal(result.resourceCount, 7);
  assert.equal(result.partCount, 8);
  assert.equal(result.tombstoneCount, 1);
  assert.deepEqual(result.blockers, []);
  assert.deepEqual(
    doc.records.map((r) => r.type),
    ["host", "credential", "snippet", "forwarding"],
  );
});
test("inventory refuses unsupported records, duplicate IDs, collisions and embedded secrets", () => {
  for (const doc of [
    legacy([record("sshKey")]),
    legacy([record("alien")]),
    legacy([record("host", { password: "secret" })]),
    legacy([record("forwarding", { nested: { privateKey: "secret" } })]),
  ])
    assert.ok(previewLegacyMigration({ document: doc }).blockers.length);
  const r = record("host");
  assert.ok(
    previewLegacyMigration({ document: legacy([r, r]) }).blockers.includes(
      "duplicate_source_id",
    ),
  );
  assert.ok(
    previewLegacyMigration({
      document: legacy([r]),
      existingIDs: [r.id],
    }).blockers.includes("resource_id_collision"),
  );
  assert.equal(
    previewLegacyMigration({
      document: legacy([record("host", {}, "invalid")]),
    }).missingIDs,
    1,
  );
});
test("Credential metadata whitelist and distinct secret CEK preserve all original fields", async () => {
  const f = await migrationFixture(),
    original = record("credential", {
      title: "Label",
      username: "alice",
      secret: "PASSWORD",
      unknown: "PRIVATE",
    });
  const out = await prepare(f, legacy([original]));
  assert.equal(out.objects.length, 2);
  const contents = [];
  const keys = [];
  for (const obj of out.objects) {
    const key = await unwrapResourceCEK({
      wrapper: obj.wrappers[0],
      context: obj.wrappers[0].context,
      privateKey: f.identity.privateKey,
      cryptoValue: webcrypto,
    });
    keys.push(Buffer.from(key).toString("hex"));
    contents.push(
      JSON.parse(
        new TextDecoder().decode(
          await decryptResourcePart({
            envelope: obj.envelope,
            context: obj.envelope.context,
            cek: key,
            cryptoValue: webcrypto,
          }),
        ),
      ),
    );
  }
  assert.notEqual(keys[0], keys[1]);
  assert.deepEqual(contents[0], {
    resourceID: original.id,
    title: "Label",
    username: "alice",
  });
  assert.deepEqual(contents[1].record, original);
  assert.ok(!JSON.stringify(out.manifest).includes("PASSWORD"));
  assert.ok(!JSON.stringify(out.manifest).includes("Label"));
});
test("crash checkpoints preserve generated IDs and completed ciphertext exactly; tamper/scope/source changes fail", async () => {
  const f = await migrationFixture(),
    doc = legacy([record("credential", { secret: "PRIVATE" }, "missing")]);
  let saved;
  await assert.rejects(
    prepare(f, doc, {
      persistCheckpoint: async (v) => {
        saved = v;
      },
      faultAt: (s) => {
        if (s === "part_persisted") throw Error("injected");
      },
    }),
    /injected/,
  );
  const state = await openMigrationCheckpoint({
    checkpoint: saved,
    key: f.checkpointKey,
    scope: f.scope,
    cryptoValue: webcrypto,
  });
  assert.equal(state.objects.length, 1);
  const out = await prepare(f, doc, { checkpoint: saved });
  assert.deepEqual(out.objects[0], state.objects[0]);
  assert.equal(out.resources[0].id, state.resources[0].id);
  await assert.rejects(
    prepare(f, legacy([record("credential")]), { checkpoint: saved }),
    /source_changed/,
  );
  await assert.rejects(
    openMigrationCheckpoint({
      checkpoint: saved,
      key: f.checkpointKey,
      scope: { ...f.scope, sourceRevision: 2 },
      cryptoValue: webcrypto,
    }),
  );
  await assert.rejects(
    openMigrationCheckpoint({
      checkpoint: {
        ...saved,
        ciphertext: saved.ciphertext.slice(0, -2) + "AA",
      },
      key: f.checkpointKey,
      scope: f.scope,
      cryptoValue: webcrypto,
    }),
  );
});
test("untrusted recipient and missing self wrapper fail before signing", async () => {
  const f = await migrationFixture(),
    doc = legacy([record("host")]);
  await assert.rejects(
    prepare(f, doc, {
      pinnedTrust: { loadPin: async () => null, advancePin: async () => {} },
    }),
    /device_trust/,
  );
  await assert.rejects(
    prepare(f, doc, { recipientTargets: () => [] }),
    /recipient_missing/,
  );
  await assert.rejects(
    prepare(f, doc, { identity: { ...f.identity, privateKey: null } }),
  );
});
test("recipient account must bind both signed records before persistence or trust lookup", async () => {
  for (const variant of ["different_account", "missing_account", "certificate_account", "directory_account"]) {
    const f = await migrationFixture();
    const target = structuredClone(f.recipient);
    if (variant === "different_account") target.accountID = uuid();
    if (variant === "missing_account") delete target.accountID;
    if (variant === "certificate_account") target.certificate.payload.accountID = uuid();
    if (variant === "directory_account") target.checkpoint.payload.accountID = uuid();
    let persisted = 0, trustLookups = 0;
    await assert.rejects(prepare(f, legacy([record("host")]), {
      recipientTargets: () => [target],
      persistCheckpoint: async () => { persisted++; },
      pinnedTrust: {
        loadPin: async (...args) => { trustLookups++; return f.pinnedTrust.loadPin(...args); },
        advancePin: f.pinnedTrust.advancePin,
      },
    }), /recipient_account_mismatch/);
    assert.equal(persisted, 0);
    assert.equal(trustLookups, 0);
  }
});
test("every client preparation fault leaves resumable encrypted checkpoint and no persisted CEK", async () => {
  for (const stage of [
    "identities_persisted",
    "ciphertext",
    "wrappers",
    "part_persisted",
    "manifest",
  ]) {
    const f = await migrationFixture();
    let saved;
    const doc = legacy([record("host", { name: "PRIVATE" })]);
    await assert.rejects(
      prepare(f, doc, {
        persistCheckpoint: async (v) => {
          saved = v;
        },
        faultAt: (s) => {
          if (s === stage) throw Error("injected");
        },
      }),
      /injected/,
    );
    assert.ok(saved);
    assert.ok(!JSON.stringify(saved).includes("PRIVATE"));
    const out = await prepare(f, doc, { checkpoint: saved });
    assert.equal(out.objects.length, 1);
    const state = await openMigrationCheckpoint({
      checkpoint: saved,
      key: f.checkpointKey,
      scope: f.scope,
      cryptoValue: webcrypto,
    });
    assert.equal(state.cek, undefined);
  }
});
test("inventory checkpoint supplies attempt-stable IDs before server start, including generated folders", async () => {
  const { prepareMigrationInventory } = await import(
    "../public/vault-v2-migration.js"
  );
  const f = await migrationFixture(),
    doc = legacy([record("host", { folder: "a/b" }, "bad")]);
  let saved;
  const inventory = await prepareMigrationInventory({
    ...f,
    document: doc,
    persistCheckpoint: async (v) => {
      saved = v;
    },
  });
  assert.equal(inventory.resources.length, 3);
  const second = await prepareMigrationInventory({
    ...f,
    document: doc,
    checkpoint: saved,
    persistCheckpoint: async () => {},
  });
  assert.deepEqual(second.resources, inventory.resources);
  const result = await prepare(f, doc, { checkpoint: saved });
  assert.deepEqual(result.resources, inventory.resources);
});
test("opaque Host/Forwarding encoded profiles cannot hide a password inside a View-only part", () => {
  for (const type of ["host", "forwarding"]) {
    const key = type === "host" ? "profile" : "configuration";
    assert.ok(
      previewLegacyMigration({
        document: legacy([
          record(type, { [key]: JSON.stringify({ password: "PRIVATE" }) }),
        ]),
      }).blockers.length,
    );
    assert.ok(
      previewLegacyMigration({
        document: legacy([record(type, { [key]: "opaque" })]),
      }).blockers.length,
    );
  }
});

test("checkpoint budget blocks an oversized source before preparation and supports bounded resume", async () => {
  const tooLarge = legacy([record("snippet", {body:"x".repeat(21*1024*1024)})]);
  assert.ok(previewLegacyMigration({document:tooLarge}).blockers.includes("checkpoint_size_limit"));
  const f = await migrationFixture(), document = legacy([record("snippet", {body:"x".repeat(4*1024*1024)})]);
  const out = await prepare(f, document);
  const resumed = await prepare(f, document, {checkpoint:out.checkpoint});
  assert.deepEqual(resumed.objects, out.objects);
});
