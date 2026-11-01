import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { hashPassword, hashSessionToken } from "../src/security.mjs";
import { createAuthenticatedVaultClient } from "../public/vault-sync.js";
import { isolatedPublicationDatabase, publicationRuntimeFixture, stopPublicationRuntime } from "./publication-runtime-fixture.mjs";

test("real Cloud HTTP rejects an old tab binding before another cookie session can read, write or sign out", {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const isolated = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  let runtime;
  try {
    const pepper = "s".repeat(32), accounts = [];
    for (const label of ["a", "b"]) {
      const user = randomUUID(), device = randomUUID(), session = randomUUID(), token = label.repeat(43);
      await isolated.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,$2,$3,now())",
        [user, `${label}@example.test`, `test_${label}`]);
      await isolated.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'test','web')", [device, user]);
      await isolated.pool.query("INSERT INTO personal_vaults(user_id) VALUES($1)", [user]);
      await isolated.pool.query("INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day')",
        [session, user, device, hashSessionToken(token, pepper)]);
      accounts.push({ user, device, session, token, email: `${label}@example.test` });
    }
    const fence = await publicationRuntimeFixture(isolated.databaseURL);
    const socket = createServer();
    await new Promise(resolve => socket.listen(0, "127.0.0.1", resolve));
    const port = socket.address().port;
    await new Promise(resolve => socket.close(resolve));
    const origin = `http://127.0.0.1:${port}`;
    const child = spawn(process.execPath, ["src/server.mjs"], {
      cwd: fileURLToPath(new URL("../", import.meta.url)),
      env: { PATH: process.env.PATH, DATABASE_URL: isolated.databaseURL, CLOUD_HOST: "127.0.0.1", CLOUD_PORT: String(port),
        CLOUD_PUBLIC_ORIGIN: origin, SESSION_TOKEN_PEPPER: pepper, EMAIL_VERIFICATION_TOKEN_PEPPER: "e".repeat(32),
        PASSWORD_RESET_TOKEN_PEPPER: "p".repeat(32), TEAM_INVITATION_TOKEN_PEPPER: "t".repeat(32),
        TEAM_OUTBOX_ENCRYPTION_KEY: "o".repeat(32), ABUSE_TOKEN_PEPPER: "a".repeat(32),
        PROXY_SHARED_SECRET: "b".repeat(64), PUBLICATION_FENCE_PATH: fence.path },
      stdio: "ignore",
    });
    runtime = { child, cleanup: fence.cleanup };
    for (let i = 0; i < 100; i += 1) {
      if (child.exitCode !== null) throw Error("test_cloud_start_failed");
      try { if ((await fetch(`${origin}/readyz`)).ok) break; } catch {}
      await new Promise(resolve => setTimeout(resolve, 20));
      if (i === 99) throw Error("test_cloud_start_timeout");
    }
    const [a, b] = accounts;
    const request = (path, account, options = {}) => fetch(`${origin}${path}`, {
      ...options, headers: { Cookie: `sr_session=${account.token}`, Origin: origin, ...options.headers },
    });
    const me = await request("/v1/me", a);
    assert.equal(me.status, 200);
    assert.equal(me.headers.get("x-selective-session-binding"), a.session);
    assert.equal((await request("/v1/vault", a, { headers: { "X-Selective-Session-Binding": a.session } })).status, 200);
    assert.equal((await request("/v1/vault", a)).status, 409);
    for (const [path, method] of [["/v1/vault", "GET"], ["/v1/vault", "PUT"], ["/v1/auth/logout", "POST"]]) {
      const rejected = await request(path, b, { method, headers: { "X-Selective-Session-Binding": a.session } });
      assert.equal(rejected.status, 409);
      assert.equal((await rejected.json()).error, "browser_session_changed");
      assert.equal(rejected.headers.get("set-cookie"), null);
    }
    assert.equal((await request("/v1/me", b)).status, 200);
    const invalid = await request("/v1/me", { token: "invalid".repeat(7) });
    assert.equal(invalid.status, 401);
    assert.equal(invalid.headers.get("set-cookie"), null);
    const logoutA = await fetch(`${origin}/v1/auth/logout`, { method: "POST", headers: {
      Authorization: `Bearer ${a.token}`, Cookie: `sr_session=${b.token}`, Origin: origin,
    } });
    assert.equal(logoutA.status, 204);
    assert.equal(logoutA.headers.get("set-cookie"), null, "an old response must not erase another tab's cookie");
    assert.equal((await request("/v1/me", b)).status, 200);
    const rows = await isolated.pool.query("SELECT user_id,revision FROM personal_vaults ORDER BY user_id");
    assert.deepEqual(rows.rows.map(row => Number(row.revision)), [0, 0]);
    assert.equal((await isolated.pool.query("SELECT revoked_at FROM sessions WHERE id=$1", [b.session])).rows[0].revoked_at, null);
    const bearer = await fetch(`${origin}/v1/vault`, { headers: { Authorization: `Bearer ${b.token}` } });
    assert.equal(bearer.status, 200);
    const password = "synthetic password for this isolated runtime";
    await isolated.pool.query("INSERT INTO account_identities(user_id,provider,subject,password_hash) VALUES($1,'password',$2,$3)",
      [b.user, b.email, await hashPassword(password)]);
    const values = new Map(), storage = { getItem: key => values.get(key) ?? null,
      setItem: (key, value) => values.set(key, String(value)), removeItem: key => values.delete(key) };
    let browserCookie = "";
    const browserFetch = async (path, options = {}) => {
      const response = await fetch(`${origin}${path}`, { ...options,
        headers: { ...options.headers, ...(browserCookie ? { Cookie: browserCookie } : {}), Origin: origin } });
      const cookieHeader = response.headers.get("set-cookie");
      if (cookieHeader) browserCookie = cookieHeader.split(";")[0];
      return response;
    };
    const browser = createAuthenticatedVaultClient({ fetchValue: browserFetch, sessionStorageValue: storage });
    assert.equal((await browser.login({ email: b.email, password, deviceID: b.device })).id, b.user);
    assert.ok(browserCookie.startsWith("sr_session="));
    const reloaded = createAuthenticatedVaultClient({ fetchValue: browserFetch, sessionStorageValue: storage });
    assert.equal((await reloaded.restoreSession()).id, b.user);
    assert.equal((await reloaded.getVault()).revision, 0);
  } finally {
    await stopPublicationRuntime(runtime);
    await isolated.cleanup();
  }
});
