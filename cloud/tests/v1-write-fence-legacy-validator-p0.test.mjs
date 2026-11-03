import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { validateVaultEnvelope, validateTeamVaultEnvelope } from "./fixtures/legacy-cloud-9831990-security.mjs";

// This is an exact immutable copy of the production-baseline validators, not a
// reimplementation of their logic. It demonstrates only the framed client write
// after a rollback; stopping old writers on an old server needs a separate fence.
test("production-baseline Cloud rejects current framed Personal and Team writes", async () => {
  const source = await readFile(new URL("./fixtures/legacy-cloud-9831990-security.mjs", import.meta.url));
  assert.equal(createHash("sha256").update(source).digest("hex"), "3cce3d30f8116dc8d5dac6151059509afeff13ebd301dddf40a266dbab007a42");
  const personal = { baseRevision: 1, envelopeVersion: 1, wrappedKey: { algorithm: "synthetic" }, ciphertext: "AA", nonce: "A".repeat(16), authTag: "A".repeat(22), contentHash: "A".repeat(43) };
  const { wrappedKey: _, ...payload } = personal;
  const team = { ...payload, keyGeneration: 1 };
  for (const [validator, envelope] of [[validateVaultEnvelope, personal], [validateTeamVaultEnvelope, team]]) {
    assert.doesNotThrow(() => validator(envelope), "the legacy validator must accept its original flat envelope");
    assert.throws(() => validator({ protocol: "framed-v1", envelope }), /invalid_vault_envelope/u);
  }
});
