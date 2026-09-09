import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createAuthenticatedVaultClient } from "../public/vault-sync.js";

const deviceID = "84f6c860-0d26-4ef5-8652-27cb8b991b70";

test("browser registration sends JSON without persisting or returning a password", async () => {
  let request;
  const client = createAuthenticatedVaultClient({
    async fetchValue(...values) {
      request = values;
      return { ok: true, status: 201, async json() { return { verificationRequired: true }; } };
    },
  });

  const result = await client.register({
    displayName: "Leonid",
    email: "owner@example.com",
    password: "a sufficiently long password",
    deviceID,
  });
  assert.deepEqual(result, { verificationRequired: true });
  assert.equal(request[0], "/v1/auth/register");
  assert.equal(request[1].method, "POST");
  assert.equal(request[1].headers["Content-Type"], "application/json");
  assert.equal(request[1].cache, "no-store");
  const body = JSON.parse(request[1].body);
  assert.equal(body.email, "owner@example.com");
  assert.equal(body.device.id, deviceID);
  assert.equal("password" in result, false);
});

test("browser surfaces bounded registration and login errors", async () => {
  const registrationClient = createAuthenticatedVaultClient({
    fetchValue: async () => ({ ok: false, status: 403, async json() { return { error: "registration_disabled" }; } }),
  });
  await assert.rejects(
    registrationClient.register({ displayName: "Owner", email: "owner@example.com", password: "a sufficiently long password", deviceID }),
    /registration_disabled/,
  );

  const loginClient = createAuthenticatedVaultClient({
    fetchValue: async () => ({ ok: false, status: 403, async json() { return { error: "email_not_verified" }; } }),
  });
  await assert.rejects(
    loginClient.login({ email: "owner@example.com", password: "a sufficiently long password", deviceID }),
    /email_not_verified/,
  );
});

test("password recovery uses a generic no-store response", async () => {
  let request;
  const client = createAuthenticatedVaultClient({
    fetchValue: async (...values) => {
      request = values;
      return { ok: true, status: 202, async json() { return { accepted: true }; } };
    },
  });
  assert.deepEqual(await client.requestPasswordReset("owner@example.com"), { accepted: true });
  assert.equal(request[0], "/v1/auth/request-password-reset");
  assert.equal(request[1].cache, "no-store");
  assert.deepEqual(JSON.parse(request[1].body), { email: "owner@example.com" });
});

test("authenticated account deletion clears the in-memory session", async () => {
  const calls = [];
  const client = createAuthenticatedVaultClient({ fetchValue: async (path, options = {}) => {
    calls.push([path, options]);
    if (path === "/v1/auth/login") return new Response(JSON.stringify({
      token: "t".repeat(43), user: { id: deviceID, email: "owner@example.com", displayName: "Owner" }, deviceID,
    }), { status: 200, headers: { "Content-Type": "application/json" } });
    if (path === "/v1/me" && options.method === "DELETE") {
      return new Response(JSON.stringify({ deleted: true }), { status: 200, headers: { "Content-Type": "application/json" } });
    }
    throw new Error(`unexpected:${path}`);
  } });
  await client.login({ email: "owner@example.com", password: "a sufficiently long password", deviceID });
  assert.deepEqual(await client.deleteAccount({ email: "owner@example.com", password: "a sufficiently long password" }), { deleted: true });
  assert.equal(client.session(), null);
  assert.deepEqual(JSON.parse(calls.at(-1)[1].body), { email: "owner@example.com", password: "a sufficiently long password" });
  assert.match(calls.at(-1)[1].headers.Authorization, /^Bearer /u);
});

test("portal exposes visible login and registration modes and never promises emailed passwords", async () => {
  const [html, server] = await Promise.all([
    readFile(new URL("../public/index.html", import.meta.url), "utf8"),
    readFile(new URL("../src/server.mjs", import.meta.url), "utf8"),
  ]);
  assert.match(html, /id="cloud-login-tab"/u);
  assert.match(html, /id="cloud-register-tab"/u);
  assert.match(html, /id="cloud-registration-form"/u);
  assert.match(html, /id="cloud-recovery-form"/u);
  assert.match(html, /Пароли по почте не отправляются/u);
  assert.doesNotMatch(html, /отправим[^<]*(?:логин|пароль)/iu);
  assert.match(server, /\["\.html", "\.js", "\.css"\][^\n]*"no-cache"/u);
});
