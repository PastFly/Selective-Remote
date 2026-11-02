import assert from "node:assert/strict";
import { randomUUID, createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { request as httpRequest } from "node:http";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { hashSessionToken } from "../src/security.mjs";
import { createAuthenticatedVaultClient, personalVaultScope } from "../public/vault-sync.js";
import { isolatedPublicationDatabase, publicationRuntimeFixture, stopPublicationRuntime } from "./publication-runtime-fixture.mjs";

// The unfenced 0.31 wire format must not overwrite a newer
// server snapshot after obtaining its revision. Synthetic loopback database only.
test("unmodified legacy writers cannot overwrite Personal or Team Vault snapshots", {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const isolated = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  let runtime;
  try {
    const user = randomUUID(), device = randomUUID(), session = randomUUID(), token = "a".repeat(43), pepper = "s".repeat(32);
    await isolated.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'p0@example.test','p0_test',now())", [user]);
    await isolated.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'test','web')", [device, user]);
    await isolated.pool.query("INSERT INTO personal_vaults(user_id) VALUES($1)", [user]);
    await isolated.pool.query("INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day')", [session, user, device, hashSessionToken(token, pepper)]);
    const fence = await publicationRuntimeFixture(isolated.databaseURL), socket = createServer();
    await new Promise(resolve => socket.listen(0, "127.0.0.1", resolve));
    const port = socket.address().port;
    await new Promise(resolve => socket.close(resolve));
    const origin = `http://127.0.0.1:${port}`;
    const appName=`p0_inflight_${randomUUID().replaceAll("-", "")}`;
    const runtimeDatabase=new URL(isolated.databaseURL); runtimeDatabase.searchParams.set("application_name",appName);
    const child = spawn(process.execPath, ["src/server.mjs"], {
      cwd: fileURLToPath(new URL("../", import.meta.url)),
      env: { PATH: process.env.PATH, DATABASE_URL: runtimeDatabase.href, CLOUD_HOST: "127.0.0.1", CLOUD_PORT: String(port),
        CLOUD_PUBLIC_ORIGIN: origin, SESSION_TOKEN_PEPPER: pepper, EMAIL_VERIFICATION_TOKEN_PEPPER: "e".repeat(32),
        PASSWORD_RESET_TOKEN_PEPPER: "p".repeat(32), TEAM_INVITATION_TOKEN_PEPPER: "t".repeat(32),
        TEAM_OUTBOX_ENCRYPTION_KEY: "o".repeat(32), ABUSE_TOKEN_PEPPER: "a".repeat(32),
        PROXY_SHARED_SECRET: "b".repeat(64), PUBLICATION_FENCE_PATH: fence.path }, stdio: "ignore",
    });
    runtime = { child, cleanup: fence.cleanup };
    let ready = false;
    for (let i = 0; i < 100; i++) {
      if (child.exitCode !== null) throw Error("test_cloud_start_failed");
      try { if ((await fetch(`${origin}/readyz`)).ok) { ready = true; break; } } catch {}
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.equal(ready, true);
    const headers = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
    const envelope = { baseRevision: 0, envelopeVersion: 1, wrappedKey: { algorithm: "synthetic" }, ciphertext: "bmV3ZXI", nonce: "A".repeat(16), authTag: "A".repeat(22), contentHash: "A".repeat(43) };
    await isolated.pool.query(`UPDATE personal_vaults SET revision=1,envelope_version=1,wrapped_key=$2,ciphertext=$3,
      nonce=$4,auth_tag=$5,content_hash=$6,updated_by_device_id=$7 WHERE user_id=$1`,
      [user, envelope.wrappedKey, envelope.ciphertext, envelope.nonce, envelope.authTag, envelope.contentHash, device]);
    const previous = await isolated.pool.query("SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1", [user]);
    const legacyRead = await fetch(`${origin}/v1/vault`, { headers });
    assert.equal(legacyRead.status, 200);
    const revision = (await legacyRead.json()).revision;
    const stale = await fetch(`${origin}/v1/vault`, { method: "PUT", headers, body: JSON.stringify({ ...envelope, baseRevision: revision, ciphertext: "c3RhbGU" }) });
    const after = await isolated.pool.query("SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1", [user]);
    const digest = value => createHash("sha256").update(value).digest("hex");
    console.log(`legacy_status=${stale.status}; before_revision=${previous.rows[0].revision}; after_revision=${after.rows[0].revision}; before_ciphertext_sha256=${digest(previous.rows[0].ciphertext)}; after_ciphertext_sha256=${digest(after.rows[0].ciphertext)}`);
    assert.ok([403, 409, 426].includes(stale.status), "unmodified legacy writer must be rejected");
    assert.deepEqual(after.rows, previous.rows, "legacy request must not change the newer ciphertext, revision or Vault ID");
    const markedHeaders = { ...headers, "X-Selective-V1-Write-Fence": "1" };
    const unarmedMeta = await fetch(`${origin}/v1/meta`);
    assert.equal(unarmedMeta.headers.get('x-selective-v1-write-fence'), null, 'unsafe writes must not be advertised without a retained floor');
    const unarmed = await fetch(`${origin}/v1/vault`, { method: 'PUT', headers: markedHeaders,
      body: JSON.stringify({ protocol:'framed-v1', envelope:{ ...envelope, baseRevision:1 } }) });
    assert.equal(unarmed.status, 503, 'a current writer must fail closed before the floor is armed');
    assert.deepEqual((await isolated.pool.query("SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1", [user])).rows, previous.rows);
    const { installV1CommitFence } = await import('../src/v1-commit-fence.mjs');
    const { MigrationFence } = await import('../src/migration-fence.mjs');
    await installV1CommitFence(isolated.pool);
    await new MigrationFence(fence.path).append({ version:2,type:'V1_WRITER_FLOOR',writerProtocol:1 });
    assert.equal((await fetch(`${origin}/v1/meta`)).headers.get('x-selective-v1-write-fence'),'1');
    const malformed = await fetch(`${origin}/v1/vault`, {
      method: "PUT", headers: markedHeaders, body: JSON.stringify({ ...envelope, baseRevision: 1 }),
    });
    assert.equal(malformed.status, 400, "the marker alone must not enable an old flat write");
    assert.deepEqual((await isolated.pool.query("SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1", [user])).rows, previous.rows);
    const current = await fetch(`${origin}/v1/vault`, {
      method: "PUT", headers: markedHeaders,
      body: JSON.stringify({ protocol: "framed-v1", envelope: { ...envelope, baseRevision: 1, ciphertext: "Y3VycmVudA" } }),
    });
    assert.equal(current.status, 200, "a framed current client can still save");
    assert.equal((await current.json()).revision, 2);
    const browser = createAuthenticatedVaultClient({
      sessionStorageValue: { getItem: () => session, setItem() {}, removeItem() {} },
      fetchValue: (path, options = {}) => fetch(origin + path, {
        ...options, headers: { ...options.headers, Cookie: `sr_session=${token}`, Origin: origin },
      }),
    });
    await browser.restoreSession();
    assert.deepEqual(await browser.putVault(personalVaultScope, { ...envelope, baseRevision: 2, ciphertext: "YnJvd3Nlcg" }), {
      conflict: false, revision: 3,
    });
    const beforeTamper = (await isolated.pool.query("SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1", [user])).rows;
    const marker = (await isolated.pool.query('SELECT clock_timestamp() AS at')).rows[0].at;
    const body = JSON.stringify({protocol:'framed-v1',envelope:{...envelope,baseRevision:3,ciphertext:'c3RhbGU'}});
    const pending = httpRequest(`${origin}/v1/vault`,{method:'PUT',headers:markedHeaders});
    const pendingResult = new Promise((resolve,reject) => {
      pending.on('response',res=>{let text='';res.setEncoding('utf8');res.on('data',chunk=>{text+=chunk;});res.on('end',()=>resolve({status:res.statusCode,body:JSON.parse(text)}));}); pending.on('error',reject);
    });
    pendingResult.catch(()=>{});
    pending.write(body.slice(0,1));
    let accepted = false;
    for(let n=0;n<200;n++) {
      accepted=(await isolated.pool.query("SELECT 1 FROM pg_stat_activity WHERE application_name=$1 AND state='idle' AND state_change>$2 AND query LIKE 'UPDATE sessions SET last_used_at%'",[appName,marker])).rowCount>0;
      if(accepted)break;
      await new Promise(resolve=>setTimeout(resolve,50));
    }
    assert.equal(accepted,true,'request must pass its initial deployment and session checks');
    await isolated.pool.query('ALTER TABLE public.personal_vaults DISABLE TRIGGER selective_remote_framed_v1_writer');
    pending.end(body.slice(1));
    const pendingResponse = await pendingResult;
    assert.deepEqual(pendingResponse,{status:503,body:{error:'vault_write_fence_unavailable'}},'a changed barrier must return a retryable service error');
    assert.equal((await fetch(`${origin}/v1/meta`)).status,503,'a missing or disabled barrier must close traffic');
    assert.equal((await fetch(`${origin}/v1/vault`,{method:'PUT',headers:markedHeaders,
      body:JSON.stringify({protocol:'framed-v1',envelope:{...envelope,baseRevision:3}})})).status,503);
    assert.deepEqual((await isolated.pool.query("SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1", [user])).rows,beforeTamper);
    await isolated.pool.query('ALTER TABLE public.personal_vaults ENABLE TRIGGER selective_remote_framed_v1_writer');
    assert.equal((await fetch(`${origin}/v1/meta`)).status,200);


    const team = randomUUID(), teamVault = randomUUID();
    await isolated.pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'TEST-ONLY-CODEX-P0',$2)", [team, user]);
    await isolated.pool.query("INSERT INTO team_memberships(team_id,user_id,role) VALUES($1,$2,'owner')", [team, user]);
    await isolated.pool.query(`INSERT INTO shared_vaults(id,team_id,name,created_by_user_id,revision,envelope_version,ciphertext,nonce,auth_tag,content_hash,updated_by_device_id)
      VALUES($1,$2,'TEST-ONLY-CODEX-VAULT',$3,1,1,$4,$5,$6,$7,$8)`,
      [teamVault, team, user, envelope.ciphertext, envelope.nonce, envelope.authTag, envelope.contentHash, device]);
    const beforeTeam = await isolated.pool.query("SELECT id,revision,ciphertext FROM shared_vaults WHERE id=$1", [teamVault]);
    const { wrappedKey: _, ...teamEnvelope } = envelope;
    const oldTeamWrite = await fetch(`${origin}/v1/teams/${team}/vaults/${teamVault}`, {
      method: "PUT", headers: { ...headers, "Idempotency-Key": "synthetic-team-write-01" },
      body: JSON.stringify({ ...teamEnvelope, baseRevision: 1, keyGeneration: 1, ciphertext: "c3RhbGU" }),
    });
    assert.equal(oldTeamWrite.status, 426);
    assert.deepEqual((await isolated.pool.query("SELECT id,revision,ciphertext FROM shared_vaults WHERE id=$1", [teamVault])).rows, beforeTeam.rows);
  } finally {
    await stopPublicationRuntime(runtime);
    await isolated.cleanup();
  }
});
