// Production password service/store and browser crypto, with synthetic local SQL/auth responses.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import { CloudService } from "../../src/service.mjs";
import { PostgresStore } from "../../src/postgres-store.mjs";
import { hashPassword, verifyPassword } from "../../src/security.mjs";
import { publicOperationError } from "../../src/service-error.mjs";
import { accountVaultPassphrase } from "../../public/app.js";
if (!process.env.PLAYWRIGHT_MODULE) throw new Error("PLAYWRIGHT_MODULE is required");
const { chromium } = await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE));
const baseline = process.env.PASSWORD_BASELINE === "1";
const uploadOrder = process.env.PASSWORD_UPLOAD_ORDER ?? "upload-first";
assert.ok(["upload-first", "password-first"].includes(uploadOrder));
const output = process.env.PASSWORD_QA_OUTPUT ?? "/private/tmp/convergence-password-preservation";
await mkdir(output, { recursive: true });
const oldPassword = "synthetic old account password", newPassword = "synthetic new account password";
const oldPassphrase = accountVaultPassphrase(oldPassword), newPassphrase = accountVaultPassphrase(newPassword);
const userID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", deviceID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const session = { user_id: userID, email: "synthetic@invalid.invalid", session_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", device_id: deviceID };
const state = { passwordHash: await hashPassword(oldPassword), vault: { id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", revision: 0, envelope_version: 1, wrapped_key: null, ciphertext: null, nonce: null, auth_tag: null, content_hash: null, updated_at: "2026-10-01T00:00:00.000Z" }, sessionRevocations: 0, passwordWrites: 0, uploads: 0 };
const originalPasswordHash = state.passwordHash;
const query = async (sql, params = []) => {
  if (/JOIN account_identities/.test(sql)) return { rows: [{ id: userID, email: session.email, password_hash: state.passwordHash, disabled_at: null }] };
  if (/FROM personal_vaults/.test(sql)) {
    assert.deepEqual(params, [userID]);
    return { rows: state.vault ? [structuredClone(state.vault)] : [] };
  }
  if (/UPDATE personal_vaults/.test(sql)) { Object.assign(state.vault, { revision: params[1], envelope_version: params[2], wrapped_key: params[3], ciphertext: params[4], nonce: params[5], auth_tag: params[6], content_hash: params[7] }); state.uploads++; }
  if (/UPDATE account_identities/.test(sql)) { assert.equal(params[0], userID); state.passwordHash = params[1]; state.passwordWrites++; return { rows: [{ id: userID }] }; }
  if (/UPDATE sessions/.test(sql)) state.sessionRevocations++;
  return { rows: [] };
};
const store = new PostgresStore("synthetic-injected-pool", { query, connect: async () => ({ query, release() {} }) });
const service = new CloudService(store, {});
const publicRoot = resolve("cloud/public");
const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://localhost");
    if (url.pathname === "/") { res.setHeader("Content-Type", "text/html"); return res.end('<!doctype html><html lang="en"><title>Synthetic password preservation</title></html>'); }
    if (/^\/[\w-]+\.js$/.test(url.pathname)) { res.setHeader("Content-Type", "application/javascript"); return res.end(await readFile(join(publicRoot, url.pathname.slice(1)))); }
    let input = {};
    if (["POST", "PATCH", "PUT"].includes(req.method)) { let text = ""; for await (const part of req) text += part; input = JSON.parse(text); }
    let response;
    if (url.pathname === "/v1/auth/login") {
      if (!await verifyPassword(input.password, state.passwordHash)) throw Error("invalid_credentials");
      response = { token: "s".repeat(43), user: { id: userID, email: session.email, username: "synthetic", displayName: "Synthetic" }, deviceID };
    } else if (url.pathname === "/v1/account/password") response = await service.changePassword(session, input);
    else if (url.pathname === "/v1/vault") response = req.method === "PUT" ? await service.putVault(session, input) : await service.getVault(session);
    else { res.writeHead(404).end(); return; }
    res.setHeader("Content-Type", "application/json"); res.end(JSON.stringify(response));
  } catch (error) { const out = publicOperationError(error) ?? { status: 500, code: "unexpected_synthetic_error" }; res.writeHead(out.status, { "Content-Type": "application/json" }).end(JSON.stringify({ error: out.code })); }
});
await new Promise(r => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_PATH ?? chromium.executablePath() });
try {
  const sourceContext = await browser.newContext(), sourcePage = await sourceContext.newPage();
  await sourcePage.goto(origin);
  const prepared = await sourcePage.evaluate(async ({ oldPassphrase, deviceID }) => {
    const { createLocalVaultController } = await import("/vault-local.js");
    let snapshot = null, sync = null;
    const repository = { load: async () => snapshot, save: async value => { snapshot = structuredClone(value); }, loadSync: async () => sync, saveSync: async value => { sync = structuredClone(value); } };
    let next = 0;
    const vault = createLocalVaultController({ repository, cryptoValue: crypto, randomUUID: () => next++ ? "dddddddd-dddd-4ddd-8ddd-dddddddddddd" : deviceID });
    await vault.create(oldPassphrase);
    await vault.upsert({ type: "snippet", data: { title: "Synthetic preservation marker", body: "synthetic vault content" } });
    return vault.prepareUpload(0);
  }, { oldPassphrase, deviceID });
  const e = prepared.envelope;
  if (uploadOrder === "upload-first") assert.deepEqual(await service.putVault(session, e), { conflict: false, revision: 1 });
  const originalVault = structuredClone(state.vault);
  const change = await sourcePage.evaluate(async ({ oldPassword, newPassword }) => {
    const result = await fetch("/v1/account/password", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ currentPassword: oldPassword, newPassword }) });
    return { status: result.status, body: await result.json() };
  }, { oldPassword, newPassword });
  assert.deepEqual(state.vault, originalVault, "password operation never rewrites ciphertext implicitly");
  if (uploadOrder === "password-first") assert.deepEqual(await service.putVault(session, e), { conflict: false, revision: 1 });
  await sourceContext.close();
  const freshContext = await browser.newContext(), freshPage = await freshContext.newPage();
  await freshPage.goto(origin);
  const fresh = await freshPage.evaluate(async ({ oldPassword, newPassword, oldPassphrase, newPassphrase, deviceID, baseline }) => {
    const { createAuthenticatedVaultClient } = await import("/vault-sync.js");
    const { createLocalVaultController } = await import("/vault-local.js");
    const client = createAuthenticatedVaultClient();
    let newLoginError = null;
    try { await client.login({ email: "synthetic@invalid.invalid", password: newPassword, deviceID }); }
    catch (error) { newLoginError = error.message; }
    if (!baseline) await client.login({ email: "synthetic@invalid.invalid", password: oldPassword, deviceID });
    const remote = await client.getVault();
    let snapshot = null, sync = null;
    const vault = createLocalVaultController({ repository: { load: async () => snapshot, save: async value => { snapshot = structuredClone(value); }, loadSync: async () => sync, saveSync: async value => { sync = structuredClone(value); } }, cryptoValue: crypto, randomUUID: () => deviceID });
    let vaultError = null;
    try { await vault.importRemote(remote, baseline ? newPassphrase : oldPassphrase); }
    catch (error) { vaultError = error.message; }
    return { newLoginError, vaultError, vaultStatus: await vault.status(), records: vaultError ? null : (await vault.document()).records.length };
  }, { oldPassword, newPassword, oldPassphrase, newPassphrase, deviceID, baseline });
  await freshContext.close();
  assert.deepEqual(state.vault.wrapped_key, e.wrappedKey);
  assert.equal(state.vault.ciphertext, e.ciphertext);
  assert.equal(state.uploads, 1);
  if (baseline) {
    assert.equal(change.status, 200); assert.equal(change.body.changed, true);
    assert.equal(fresh.newLoginError, null); assert.equal(fresh.vaultError, "invalid_recovery_passphrase");
    assert.equal(state.passwordWrites, 1); assert.equal(state.sessionRevocations, 1);
  } else {
    assert.equal(change.status, 409); assert.equal(change.body.error, "personal_vault_rewrap_required");
    assert.equal(state.passwordHash, originalPasswordHash); assert.equal(state.passwordWrites, 0); assert.equal(state.sessionRevocations, 0);
    assert.equal(fresh.newLoginError, "invalid_credentials"); assert.equal(fresh.vaultError, null); assert.equal(fresh.vaultStatus, "unlocked"); assert.equal(fresh.records, 1);
  }
  const report = { mode: "LOCAL_SYNTHETIC_FRESH_BROWSER", authenticatedStaging: false, baseline, uploadOrder, change, fresh, passwordWrites: state.passwordWrites, sessionRevocations: state.sessionRevocations, vaultEnvelopePreserved: true };
  await writeFile(join(output, baseline ? `baseline-${uploadOrder}.json` : `fixed-${uploadOrder}.json`), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report));
} finally { await browser.close(); await new Promise(r => server.close(r)); }
