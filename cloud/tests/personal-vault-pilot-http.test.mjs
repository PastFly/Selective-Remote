import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { request as forwardHTTP } from "node:http";
import { createServer as createHTTPS, request as requestHTTPS } from "node:https";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { decryptVaultEnvelope, encryptVaultPayload, generateVaultKey, wrapVaultKey } from "../public/vault-crypto.js";
import { createAuthenticatedVaultClient, personalVaultScope } from "../public/vault-sync.js";
import { fenceIntentDigest, reduceFenceEvents } from "../src/migration-fence-journal.mjs";
import { hashPassword } from "../src/security.mjs";
import { installV1CommitFence } from "../src/v1-commit-fence.mjs";
import { readV1VaultState, v1CiphertextHash } from "../src/v1-data-fence.mjs";
import { personalWritePilotIsCurrent } from "../src/v1-write-fence.mjs";
import { isolatedPublicationDatabase, publicationRuntimeFixture, stopPublicationRuntime } from "./publication-runtime-fixture.mjs";
import { syntheticHttpAnchor, syntheticHttpAnchorAvailable } from "./synthetic-http-anchor-fixture.mjs";

const fenceHeaders = {
  "X-Selective-V1-Write-Fence": "1",
  "X-Selective-Personal-Vault-Writer": "migration-checkpoint-v1",
};
const seedPilot = (vaultID, ownerID, issuedAt) => ({
  version: 2,
  type: "V1_PERSONAL_PILOT_OPENED",
  pilotID: randomUUID(),
  ownerID,
  vaultID,
  issuedAt,
  expiresAt: issuedAt + 300_000,
});

test("a scoped pilot cannot close over a pending write or be reopened using its old ID", () => {
  const vaultID = randomUUID(), ownerID = randomUUID();
  const pilot = seedPilot(vaultID, ownerID, 1_000_000);
  const baseline = { version: 2, type: "V1_BASELINE", baselineID: randomUUID(), vaults: [
    { vaultKind: "PERSONAL", vaultID, ownerID, revision: 0, ciphertextHash: v1CiphertextHash(null), envelopeHash: "a".repeat(64) },
  ] };
  const floor = { version: 2, type: "V1_WRITER_FLOOR", writerProtocol: 1 };
  const close = { version: 2, type: "V1_PERSONAL_PILOT_CLOSED", pilotID: pilot.pilotID };
  const intent = { version: 2, type: "V1_PENDING_INTENT", intentID: randomUUID(), operationID: randomUUID(),
    vaultKind: "PERSONAL", ownerID, vaultID, baseRevision: 0, revision: 1, ciphertextHash: "b".repeat(64),
    envelopeHash: "c".repeat(64), pilotID: pilot.pilotID };
  assert.throws(() => reduceFenceEvents([baseline, pilot]), /deployment_fence_conflict/);
  assert.throws(() => reduceFenceEvents([baseline, floor, pilot, intent, close]), /deployment_fence_conflict/);
  const aborted = { version: 2, type: "V1_PROVEN_ABORT", intentID: intent.intentID, intentDigest: fenceIntentDigest(intent) };
  assert.equal(reduceFenceEvents([baseline, floor, pilot, intent, aborted, close]).personalWritePilot, undefined);
  assert.throws(() => reduceFenceEvents([baseline, floor, pilot, close, intent]), /deployment_fence_conflict/);
  assert.throws(() => reduceFenceEvents([baseline, floor, pilot, close, pilot]), /deployment_fence_conflict/);
  assert.equal(personalWritePilotIsCurrent(pilot, pilot.issuedAt - 1), false);
  assert.equal(personalWritePilotIsCurrent(pilot, pilot.issuedAt), true);
  assert.equal(personalWritePilotIsCurrent(pilot, pilot.expiresAt), false);
});

async function listen(server) {
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  return server.address().port;
}

async function close(server) {
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
}

function localHTTPS(url, ca, request = {}) {
  return new Promise((resolve, reject) => {
    const outgoing = requestHTTPS(url, { method: request.method, headers: request.headers, ca }, incoming => {
      const chunks = [];
      incoming.on("data", chunk => chunks.push(chunk));
      incoming.on("error", reject);
      incoming.on("end", () => resolve(new Response(chunks.length ? Buffer.concat(chunks) : null, {
        status: incoming.statusCode, headers: incoming.headers,
      })));
    });
    outgoing.on("error", reject);
    outgoing.setTimeout(5000, () => outgoing.destroy(new Error("pilot_fixture_https_timeout")));
    outgoing.end(request.body);
  });
}

test("private HTTPS pilot syncs two authenticated writers across restart and closes on production or revocation", {
  skip: !process.env.TEST_DATABASE_URL || !syntheticHttpAnchorAvailable,
  timeout: 120_000,
}, async () => {
  const db = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  const directory = await mkdtemp(join(tmpdir(), "personal-vault-pilot-"));
  let journal, independent, proxy, runtime;
  try {
    const ownerID = randomUUID(), otherID = randomUUID(), nativeDevice = randomUUID();
    const vaultID = randomUUID(), password = randomUUID() + randomUUID();
    const ownerEmail = "pilot-owner@example.test", otherEmail = "pilot-other@example.test";
    const passwordHash = await hashPassword(password);
    for (const [id, email, name] of [[ownerID, ownerEmail, "pilot_owner"], [otherID, otherEmail, "pilot_other"]]) {
      await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,$2,$3,now())", [id, email, name]);
      await db.pool.query(
        "INSERT INTO account_identities(user_id,provider,subject,password_hash) VALUES($1,'password',$2,$3)",
        [id, email, passwordHash],
      );
    }
    await db.pool.query("INSERT INTO personal_vaults(id,user_id) VALUES($1,$2)", [vaultID, ownerID]);
    await db.pool.query("INSERT INTO personal_vaults(user_id) VALUES($1)", [otherID]);
    journal = await publicationRuntimeFixture(db.databaseURL);
    independent = await syntheticHttpAnchor(journal.path);
    const fence = independent.fence;
    await installV1CommitFence(db.pool);
    await fence.append({ version: 2, type: "V1_BASELINE", baselineID: randomUUID(),
      vaults: await readV1VaultState(db.pool.query.bind(db.pool)) });
    await fence.append({ version: 2, type: "V1_WRITER_FLOOR", writerProtocol: 1 });
    const pilotID = randomUUID();

    const keyPath = join(directory, "server.key"), certPath = join(directory, "server.crt");
    execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
      "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", keyPath, "-out", certPath],
    { stdio: "ignore" });
    const [key, cert] = await Promise.all([readFile(keyPath), readFile(certPath)]);
    const socket = createServer();
    const cloudPort = await listen(socket);
    await close(socket);
    proxy = createHTTPS({ key, cert }, (incoming, response) => {
      const internal = forwardHTTP({ hostname: "127.0.0.1", port: cloudPort, path: incoming.url,
        method: incoming.method, headers: incoming.headers }, upstream => {
        response.writeHead(upstream.statusCode, upstream.headers);
        upstream.pipe(response);
      });
      internal.on("error", () => response.writeHead(502).end());
      incoming.pipe(internal);
    });
    const origin = `https://127.0.0.1:${await listen(proxy)}`;
    const fetchValue = (path, options) => localHTTPS(origin + path, cert, options);
    const cloudDirectory = fileURLToPath(new URL("../", import.meta.url));
    const runtimeEnv = environment => ({
      PATH: process.env.PATH, DATABASE_URL: db.databaseURL, CLOUD_HOST: "127.0.0.1",
      CLOUD_PORT: String(cloudPort), CLOUD_PUBLIC_ORIGIN: origin, NODE_ENV: "production",
      PUBLICATION_ENVIRONMENT: environment, PUBLICATION_FENCE_PATH: journal.path,
      SESSION_TOKEN_PEPPER: "s".repeat(32), EMAIL_VERIFICATION_TOKEN_PEPPER: "e".repeat(32),
      PASSWORD_RESET_TOKEN_PEPPER: "p".repeat(32), TEAM_INVITATION_TOKEN_PEPPER: "i".repeat(32),
      TEAM_OUTBOX_ENCRYPTION_KEY: "o".repeat(32), ABUSE_TOKEN_PEPPER: "a".repeat(32),
      PROXY_SHARED_SECRET: "b".repeat(64), ...independent.env,
    });
    const setPilot = (environment, ...args) => execFileSync(
      process.execPath, ["scripts/staging-personal-vault-pilot.mjs", ...args], {
        cwd: cloudDirectory, stdio: ["ignore", "pipe", "pipe"], encoding: "utf8",
        env: runtimeEnv(environment), timeout: 30_000,
      },
    ).trim();
    assert.throws(() => setPilot("production", "open", pilotID, ownerID, vaultID, "5"),
      error => error.stderr.trim() === "personal_pilot_environment_unavailable");
    assert.equal(setPilot("staging", "open", pilotID, ownerID, vaultID, "5"), "personal_pilot_opened");

    const start = async environment => {
      const child = spawn(process.execPath, ["src/server.mjs"], {
        cwd: cloudDirectory, stdio: "ignore", env: runtimeEnv(environment),
      });
      runtime = { child };
      for (let i = 0; i < 100; i++) {
        if (child.exitCode !== null) throw Error("pilot_fixture_cloud_exited");
        if ((await fetchValue("/readyz")).ok) return;
        await delay(50);
      }
      throw Error("pilot_fixture_cloud_not_ready");
    };
    const browser = createAuthenticatedVaultClient({ fetchValue });
    const outsider = createAuthenticatedVaultClient({ fetchValue });
    await start("staging");
    await browser.login({ email: ownerEmail, password, deviceID: randomUUID() });
    await outsider.login({ email: otherEmail, password, deviceID: randomUUID() });
    const login = await fetchValue("/v1/auth/login", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: ownerEmail, password, device: { id: nativeDevice, name: "Test Mac", platform: "macos" } }),
    });
    assert.equal(login.status, 200);
    const nativeHeaders = { Authorization: `Bearer ${(await login.json()).token}`, "Content-Type": "application/json" };
    const admissionPath = "/v1/vault/write-availability";
    assert.equal((await fetchValue(admissionPath)).status, 401);
    assert.equal((await fetchValue(admissionPath, { headers: nativeHeaders })).status, 204);
    await browser.preflightPersonalVaultWrite();
    await assert.rejects(outsider.preflightPersonalVaultWrite(), /vault_write_temporarily_unavailable/);
    const nativeRead = async () => {
      const response = await fetchValue("/v1/vault", { headers: nativeHeaders });
      assert.equal(response.status, 200);
      return response.json();
    };
    const nativeWrite = envelope => fetchValue("/v1/vault", {
      method: "PUT", headers: { ...nativeHeaders, ...fenceHeaders },
      body: JSON.stringify({ protocol: "framed-v1", envelope }),
    });
    const vaultKey = await generateVaultKey();
    const wrappedKey = await wrapVaultKey(vaultKey, randomUUID() + randomUUID());
    const id = randomUUID();
    const payload = title => ({ schemaVersion: 1, records: [{ id, type: "host", title }], tombstones: [] });
    const encrypt = (title, baseRevision) => encryptVaultPayload({ vaultKey, payload: payload(title), baseRevision, wrappedKey });
    const first = await encrypt("Browser pilot", 0);
    await assert.rejects(outsider.putVault(personalVaultScope, first), /vault_write_temporarily_unavailable/);
    assert.deepEqual(await browser.putVault(personalVaultScope, first), { conflict: false, revision: 1 });
    const seenByNative = await nativeRead();
    assert.equal(seenByNative.revision, 1);
    assert.deepEqual(await decryptVaultEnvelope(vaultKey, seenByNative), payload("Browser pilot"));

    const writtenByNative = await nativeWrite(await encrypt("Native pilot", 1));
    assert.equal(writtenByNative.status, 200);
    assert.deepEqual(await writtenByNative.json(), { conflict: false, revision: 2 });
    const seenByBrowser = await browser.getVault(personalVaultScope);
    assert.equal(seenByBrowser.revision, 2);
    assert.deepEqual(await decryptVaultEnvelope(vaultKey, seenByBrowser.envelope), payload("Native pilot"));

    await stopPublicationRuntime(runtime);
    await start("production");
    const productionMeta = await fetchValue("/v1/meta");
    assert.equal(productionMeta.headers.get("x-selective-personal-vault-write-status"), null);
    assert.equal((await nativeWrite(await encrypt("Production stays closed", 2))).status, 503);
    await stopPublicationRuntime(runtime);
    await start("staging");
    assert.equal((await nativeRead()).revision, 2);
    assert.equal((await browser.getVault(personalVaultScope)).revision, 2);
    const retained = await fence.readRecords();
    assert.equal(retained.filter(event => event.type === "V1_PENDING_INTENT" && event.pilotID === pilotID).length, 2);

    assert.equal(setPilot("staging", "close", pilotID), "personal_pilot_closed");
    const afterClose = await fetchValue("/v1/meta");
    assert.equal(afterClose.headers.get("x-selective-personal-vault-write-status"), null);
    assert.equal((await fetchValue(admissionPath, { headers: nativeHeaders })).status, 503);
    await assert.rejects(browser.putVault(personalVaultScope, await encrypt("Closed pilot", 2)), /vault_write_temporarily_unavailable/);
    assert.equal((await nativeRead()).revision, 2);
  } finally {
    await stopPublicationRuntime(runtime);
    if (proxy?.listening) await close(proxy);
    await independent?.cleanup();
    await journal?.cleanup();
    await db.cleanup();
    await rm(directory, { recursive: true, force: true });
  }
});
