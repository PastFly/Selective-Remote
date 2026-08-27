import assert from "node:assert/strict";
import test from "node:test";
import { PostgresStore } from "../src/postgres-store.mjs";

function recordingStore(respond = () => ({ rows: [] })) {
  const queries = [];
  let released = false;
  const client = {
    async query(sql, parameters = []) {
      queries.push({ sql, parameters });
      return respond(sql, parameters);
    },
    release() { released = true; },
  };
  const pool = { async connect() { return client; } };
  return {
    store: new PostgresStore("unused-for-injected-pool", pool),
    queries,
    released: () => released,
  };
}

test("replacing an email verification token invalidates the previous active hash", async () => {
  const fixture = recordingStore();
  const expiresAt = new Date("2030-01-02T00:00:00.000Z");
  const tokenHash = "a".repeat(64);

  await fixture.store.replaceEmailVerificationToken({ userID: "user-1", tokenHash, expiresAt });

  assert.deepEqual(fixture.queries.map(({ sql }) => sql.trim().split(/\s+/).slice(0, 2).join(" ")), [
    "BEGIN",
    "SELECT id",
    "UPDATE email_verification_tokens",
    "INSERT INTO",
    "COMMIT",
  ]);
  assert.deepEqual(fixture.queries[1].parameters, ["user-1"]);
  assert.match(fixture.queries[1].sql, /FOR UPDATE/);
  assert.deepEqual(fixture.queries[2].parameters, ["user-1"]);
  assert.deepEqual(fixture.queries[3].parameters, ["user-1", tokenHash, expiresAt]);
  assert.equal(fixture.queries.some(({ sql }) => sql.includes(tokenHash)), false);
  assert.equal(fixture.released(), true);
});

test("consuming an active email verification hash marks the account verified", async () => {
  const verifiedUser = {
    id: "user-1",
    email: "user@example.com",
    display_name: "User",
    email_verified_at: new Date("2030-01-01T00:00:00.000Z"),
    created_at: new Date("2029-01-01T00:00:00.000Z"),
  };
  const fixture = recordingStore((sql) => {
    if (sql.includes("RETURNING token.user_id")) return { rows: [{ user_id: "user-1" }] };
    if (sql.includes("UPDATE users SET email_verified_at")) return { rows: [verifiedUser] };
    return { rows: [] };
  });
  const tokenHash = "b".repeat(64);

  assert.equal(await fixture.store.consumeEmailVerificationToken(tokenHash), verifiedUser);

  const consume = fixture.queries.find(({ sql }) => sql.includes("RETURNING token.user_id"));
  assert.deepEqual(consume.parameters, [tokenHash]);
  assert.match(consume.sql, /token\.expires_at > now\(\)/);
  assert.match(consume.sql, /token\.consumed_at IS NULL/);
  assert.match(consume.sql, /token\.invalidated_at IS NULL/);
  assert.equal(fixture.queries.some(({ sql }) => sql.includes(tokenHash)), false);
  assert.equal(fixture.queries.at(-1).sql, "COMMIT");
  assert.equal(fixture.released(), true);
});

test("expired or replayed email verification hashes are rejected without changing a user", async () => {
  const fixture = recordingStore();

  assert.equal(await fixture.store.consumeEmailVerificationToken("c".repeat(64)), null);

  assert.equal(fixture.queries.some(({ sql }) => sql.includes("UPDATE users SET email_verified_at")), false);
  assert.equal(fixture.queries.at(-1).sql, "COMMIT");
  assert.equal(fixture.released(), true);
});

test("verification token writes roll back and release their connection on failure", async () => {
  const failure = new Error("database_failure");
  const fixture = recordingStore((sql) => {
    if (sql.includes("INSERT INTO email_verification_tokens")) throw failure;
    return { rows: [] };
  });

  await assert.rejects(
    fixture.store.replaceEmailVerificationToken({
      userID: "user-1",
      tokenHash: "d".repeat(64),
      expiresAt: new Date("2030-01-02T00:00:00.000Z"),
    }),
    failure,
  );

  assert.equal(fixture.queries.at(-1).sql, "ROLLBACK");
  assert.equal(fixture.released(), true);
});
