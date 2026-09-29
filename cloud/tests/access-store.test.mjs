import assert from "node:assert/strict";
import test from "node:test";
import { AccessStore } from "../src/access-store.mjs";

test("a direct SQL deadlock retries the whole access mutation transaction", async () => {
  let connections = 0;
  let releases = 0;
  const pool = { async connect() {
    connections++;
    const attempt = connections;
    return { async query(sql) {
      if (attempt === 1 && sql.includes("INSERT INTO team_access_mutation_receipts")) {
        const error = new Error("deadlock");
        error.code = "40P01";
        throw error;
      }
      if (sql.includes("INSERT INTO team_access_mutation_receipts")) {
        return { rows: [{ actor_user_id: "actor" }] };
      }
      return { rows: [] };
    }, release() { releases++; } };
  } };
  const access = new AccessStore(pool);
  const result = await access.withMutation({ actorUserID: "actor",
    idempotencyKey: "retry:0123456789", operation: "access.test",
    request: { target: "resource" } }, async () => ({ ok: true }));
  assert.deepEqual(result, { ok: true });
  assert.equal(connections, 2);
  assert.equal(releases, 2);
});

test("receipt replay rechecks current actor admission before returning prior result", async () => {
  const request = { actorUserID: "actor", actorDeviceID: "device",
    teamID: "team", vaultID: "vault" };
  const { createHash } = await import("node:crypto");
  const hash = createHash("sha256").update(JSON.stringify(request)).digest("hex");
  const pool = { async connect() { return { async query(sql) {
    if (sql.includes("INSERT INTO team_access_mutation_receipts")) return { rows: [] };
    if (sql.includes("SELECT request_sha256, response")) {
      return { rows: [{ request_sha256: hash, response: { secret: "prior" } }] };
    }
    if (sql.includes("FROM team_memberships AS membership")) return { rows: [] };
    return { rows: [] };
  }, release() {} }; } };
  const access = new AccessStore(pool);
  await assert.rejects(access.withMutation({ actorUserID: "actor",
    idempotencyKey: "replay:0123456789", operation: "access.test", request },
  async () => { throw new Error("must not run"); }), /team_not_found/);
});

test("preview detail paging rejects an invalid cursor before database work", async () => {
  const access = new AccessStore({});
  await assert.rejects(access.previewAccessChange({ cursor: "bad", request: {
    changes: [{ type: "GRANT_CREATE", principalKind: "USER",
      principalID: "11111111-1111-4111-8111-111111111111",
      targetKind: "RESOURCE", targetID: "22222222-2222-4222-8222-222222222222",
      permissionMask: 1 }],
  } }), /invalid_access_page/);
});
