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
