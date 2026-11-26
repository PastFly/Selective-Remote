import {syntheticHttpAnchor,syntheticHttpAnchorAvailable} from './synthetic-http-anchor-fixture.mjs';
// Synthetic TLS SMTP endpoint: bind only loopback, accept only two synthetic test mailboxes,
// trust only the ephemeral self-signed certificate and never log its messages.
import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync, randomUUID} from 'node:crypto';
import {spawn,spawnSync,execFileSync} from 'node:child_process';
import {createServer as createTlsServer} from 'node:tls';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {fenceHistoryHead} from '../src/fence-history-head.mjs';
import {installV1TeamAuthorizationFence,readV1TeamAuthorizationDigest,teamAuthorizationProtocol} from '../src/v1-team-authorization.mjs';
import {readV1VaultState,assertV1DataFloor} from '../src/v1-data-fence.mjs';
import {installV1CommitFence} from '../src/v1-commit-fence.mjs';
import {isolatedPublicationDatabase,loopbackHTTPSProxy,publicationRuntimeFixture,stopPublicationRuntime} from './publication-runtime-fixture.mjs';

async function testMailServer(){
  const dir=await mkdtemp(join(tmpdir(),'sr-test-only-smtp-'));
  const config=join(dir,'openssl.cnf'),key=join(dir,'key.pem'),cert=join(dir,'cert.pem');
  await writeFile(config,'[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\n');
  execFileSync('openssl',['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-keyout',key,'-out',cert,'-config',config],{stdio:'ignore'});
  const messages=[];const sockets=new Set();
  const server=createTlsServer({key:await readFile(key),cert:await readFile(cert)},socket=>{
    sockets.add(socket);socket.on('close',()=>sockets.delete(socket));socket.on('error',()=>{});socket.write('220 localhost ESMTP synthetic\r\n');
    let buffer='',data=false,lines=[],rcpt=false;
    socket.on('data',chunk=>{buffer+=chunk.toString('utf8');let end;
      while((end=buffer.indexOf('\r\n'))!==-1){const line=buffer.slice(0,end);buffer=buffer.slice(end+2);
        if(data){if(line==='.') {messages.push(lines.join('\r\n'));data=false;lines=[];socket.write('250 queued\r\n');}else lines.push(line);continue;}
        const verb=line.split(' ')[0].toUpperCase();
        if(verb==='EHLO')socket.write('250-localhost\r\n250-AUTH PLAIN\r\n250 SIZE 1048576\r\n');
        else if(verb==='AUTH')socket.write('235 authenticated\r\n');
        else if(verb==='MAIL')socket.write('250 ok\r\n');
        else if(verb==='RCPT'){rcpt=/^RCPT TO:<synthetic-registration-(?:a|b)@example\.test>$/i.test(line);socket.write(rcpt?'250 ok\r\n':'550 synthetic recipient only\r\n');}
        else if(verb==='DATA'&&rcpt){data=true;socket.write('354 end with dot\r\n');}
        else if(verb==='QUIT'){socket.write('221 bye\r\n');socket.end();}
        else socket.write('500 unsupported\r\n');
      }
    });
  });
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
  return {port:server.address().port,cert,messages,async close(){for(const socket of sockets)socket.destroy();await new Promise(resolve=>server.close(resolve));await rm(dir,{recursive:true,force:true});}};
}

const integrationOptions = {skip:!process.env.TEST_DATABASE_URL || !syntheticHttpAnchorAvailable, timeout:60000};

test('two real registrations, email verifications and logins preserve fenced Personal Vaults',
  integrationOptions, () => exerciseRegistration());

for (const environment of ['staging', 'production']) {
  test(`registered ${environment} with retained authorization serves new Personal accounts with writes closed`,
    integrationOptions, () => exerciseRegistration(environment));
}

async function exerciseRegistration(environment) {
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);let runtime,smtp,anchorFixture,fixture,proxy;
  try{
    fixture=await publicationRuntimeFixture(db.databaseURL);anchorFixture=await syntheticHttpAnchor(fixture.path);const fence=anchorFixture.fence;
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    if (environment) {
      await installV1TeamAuthorizationFence(db.pool);
      const digest = await readV1TeamAuthorizationDigest((sql, values) => db.pool.query(sql, values));
      await fence.append({version:2, type:'V1_TEAM_AUTHORIZATION_BASELINE', authorizationProtocol:teamAuthorizationProtocol, digest});
    }
    smtp=await testMailServer();
    proxy = await loopbackHTTPSProxy(dirname(fixture.path));
    const {cloudPort, origin, fetchValue} = proxy;
    const cwd = fileURLToPath(new URL('../', import.meta.url));
    const env = {
      PATH:process.env.PATH,USER:process.env.USER,DATABASE_URL:db.databaseURL,CLOUD_HOST:'127.0.0.1',CLOUD_PORT:String(cloudPort),CLOUD_PUBLIC_ORIGIN:origin,
      ...(environment && {
        NODE_ENV:'production', PUBLICATION_ENVIRONMENT:environment,
        PUBLICATION_READER_ENABLED:'false', WHOLE_PUBLICATION_ENABLED:'false',
      }),
      ...(environment === 'staging' && {
        STAGING_REGISTRATION_EMAIL_ALLOWLIST:'synthetic-registration-a@example.test,synthetic-registration-b@example.test',
      }),
      SESSION_TOKEN_PEPPER:'s'.repeat(32),EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),
      TEAM_INVITATION_TOKEN_PEPPER:'i'.repeat(32),TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),ABUSE_TOKEN_PEPPER:'a'.repeat(32),PROXY_SHARED_SECRET:'b'.repeat(64),
      PUBLICATION_FENCE_PATH:fixture.path,...anchorFixture.env,ALLOW_REGISTRATION:'true',SMTP_HOST:'localhost',SMTP_PORT:String(smtp.port),SMTP_SECURE:'true',
      SMTP_USER:'synthetic',SMTP_PASSWORD:'test-only-password',SMTP_FROM:'sender@example.test',NODE_EXTRA_CA_CERTS:smtp.cert,NODE_OPTIONS:'--dns-result-order=ipv4first',
    };
    async function startServer(serverEnv, args = []) {
      await stopPublicationRuntime(runtime);
      const child = spawn(process.execPath, ['src/server.mjs', ...args], {cwd, stdio:'ignore', env:serverEnv});
      runtime = {child};
      for (let i = 0; i < 200; i++) {
        if (child.exitCode !== null) throw Error('test_cloud_start_failed');
        try { if ((await fetchValue('/readyz')).ok) return; } catch {}
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      assert.fail('Cloud did not become ready');
    }
    if (environment === 'production') {
      // A new installation has neither an empty-create nor a wrapper event yet.
      const pristine = await fence.snapshot();
      assert.equal(pristine.v1Committed.length, 0);
      await startServer({...env, CLOUD_PRODUCTION_TEAM_ENABLED:'true'});
      const meta = await fetchValue('/v1/meta');
      assert.equal(meta.headers.get('x-selective-v1-write-fence'), '1');
      assert.equal(meta.headers.get('x-selective-v1-write-status'), null);
      assert.equal((await meta.json()).registrationEnabled, true);
    }
    await startServer(env);
    const post=(path,body)=>fetchValue(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    const tokens=[];
    const devices=[];
    if (environment) {
      const metadata = await fetchValue('/v1/meta');
      assert.equal(metadata.status, 200);
      assert.equal((await metadata.json()).registrationEnabled, true);
      assert.equal(metadata.headers.get('x-selective-v1-write-fence'), '1');
      assert.equal(metadata.headers.get('x-selective-v1-write-status'), 'vault_write_temporarily_unavailable');
      assert.equal(metadata.headers.get('x-selective-personal-vault-write-status'), null);
    }
    for (const [index,suffix] of ['a','b'].entries()) {
      const device={id:randomUUID(),name:`TEST-ONLY-CODEX-${suffix}`,platform:'web',appVersion:'test'};
      if (environment === 'production')
        device.publicKey = generateKeyPairSync('ec', {namedCurve:'prime256v1'}).publicKey.export({format:'jwk'});
      devices.push(device);
      const registration={email:`synthetic-registration-${suffix}@example.test`,username:`synthetic_register_${suffix}`,displayName:`Synthetic ${suffix}`,password:`TEST-ONLY-PASSWORD-${suffix}-123`,device};
      const registered=await post('/v1/auth/register',registration);
      assert.equal(registered.status,201,'synthetic registration failed');assert.deepEqual(await registered.json(),{verificationRequired:true});
      for(let i=0;i<200&&smtp.messages.length<=index;i++)await new Promise(resolve=>setTimeout(resolve,25));
      assert.equal(smtp.messages.length,index+1,'one confirmation per synthetic user');
      const normalized=smtp.messages[index].replace(/=\r\n/g,'').replace(/=3D/g,'=');
      const match=normalized.match(/verify-email\?token=([a-zA-Z0-9_-]+)/);assert.ok(match,'synthetic verification link is present');
      const verified=await post('/v1/auth/verify-email',{token:match[1]});assert.equal(verified.status,200,'synthetic verification failed');assert.deepEqual(await verified.json(),{verified:true});
      const login=await post('/v1/auth/login',{email:registration.email,password:registration.password,device});assert.equal(login.status,200,'synthetic login failed');
      const token=(await login.json()).token;assert.ok(token);assert.equal(tokens.includes(token),false,'different sessions required');tokens.push(token);
    }
    assert.equal(tokens.length,2);
    const snapshot=await fence.snapshot();assert.equal(snapshot.v1Pending.length,0);assert.equal(snapshot.v1Committed.length,2);
    assert.ok(snapshot.v1Committed.every(item=>item.vaultKind==='PERSONAL'));
    await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),snapshot);
    if (environment) {
      const before = await fence.anchor.read();
      const check = (script, ...args) => spawnSync(process.execPath, [script, ...args], {cwd, env, encoding:'utf8', timeout:10000});
      // The candidate manifest from PR #263 at 3ee202a predates registered format-2 startup.
      const oldManifest = join(dirname(fixture.path), 'closed-registration-image.json');
      await writeFile(oldManifest, JSON.stringify({
        version:1, fenceVersion:2, maxSchemaVersion:23, readerProjectionVersion:1, wholePublicationVersion:1,
        v1WriterProtocol:1, emptyVaultCreationVersion:1, v1AnchorProtocol:1, wrapperEnvelopeVersion:1,
        teamSafetyStopVersion:1, v1TeamAuthorizationProtocol:2,
      }));
      const rejected = check('scripts/check-deployment-compatibility.mjs', '--candidate', oldManifest);
      assert.equal(rejected.status, 1);
      assert.equal(rejected.stderr.trim(), 'deployment_code_floor');
      const accepted = check('scripts/check-deployment-compatibility.mjs', '--candidate', 'deployment-compatibility.json');
      assert.equal(accepted.status, 0, accepted.stderr);
      assert.equal(JSON.parse(accepted.stdout).compatible, true);
      const query = (sql, values) => db.pool.query(sql, values);
      assert.equal(snapshot.v1TeamAuthorization.protocol, teamAuthorizationProtocol);
      assert.equal(snapshot.v1TeamAuthorization.digest, await readV1TeamAuthorizationDigest(query));
      assert.equal(snapshot.v1TeamAuthorization.pending, null);
      assert.ok(snapshot.v1TeamAuthorizationOutcomes.length > 0);
      assert.ok(snapshot.v1TeamAuthorizationOutcomes.every(outcome => outcome.type === 'V1_TEAM_AUTHORIZATION_CONFIRMED'));
      assert.equal(snapshot.personalWritePilot, undefined);
      assert.deepEqual(before, fenceHistoryHead(await fence.readRecords()));
      const headers = {Authorization:`Bearer ${tokens[0]}`};
      const vault = await fetchValue('/v1/vault', {headers});
      assert.equal(vault.status, 200);
      const {id, revision, ciphertext} = await vault.json();
      const committed = snapshot.v1Committed.find(item => item.vaultID === id);
      assert.ok(committed);
      const operator = check('scripts/staging-personal-vault-pilot.mjs', 'open', randomUUID(), committed.ownerID, id, '1');
      assert.equal(operator.status, 1);
      assert.equal(operator.stderr.trim(), 'personal_pilot_environment_unavailable');
      assert.equal(revision, 0);
      assert.equal(ciphertext, null);
      const availability = await fetchValue('/v1/vault/write-availability', {headers});
      assert.equal(availability.status, 503);
      assert.deepEqual(await availability.json(), {error:'vault_write_temporarily_unavailable'});
      const write = await fetchValue('/v1/vault', {
        method:'PUT',
        headers:{...headers, 'Content-Type':'application/json', 'X-Selective-V1-Write-Fence':'1',
          'X-Selective-Personal-Vault-Writer':'migration-checkpoint-v1', 'Idempotency-Key':randomUUID()},
        body:JSON.stringify({protocol:'framed-v1', envelope:{}}),
      });
      assert.equal(write.status, 503);
      assert.deepEqual(await write.json(), {error:'vault_write_temporarily_unavailable'});
      const teams = await fetchValue('/v1/teams', {headers});
      assert.equal(teams.status, 503);
      assert.deepEqual(await teams.json(), {error:'team_security_temporarily_unavailable'});
      assert.deepEqual(await fence.anchor.read(), before);
      if (environment === 'production') {
        const production = {...env, CLOUD_PRODUCTION_TEAM_ENABLED:'true'};
        const pilotID = randomUUID();
        const issuedAt = Date.now();
        await fence.append({version:2, type:'V1_PRODUCTION_PERSONAL_PILOT_OPENED', pilotID,
          ownerID:committed.ownerID, vaultID:id, issuedAt, expiresAt:issuedAt + 60000});
        await startServer(production);
        const meta = await fetchValue('/v1/meta');
        assert.equal(meta.headers.get('x-selective-v1-write-status'), null);
        assert.equal(meta.headers.get('x-selective-personal-vault-write-status'), null);
        assert.equal((await fetchValue('/v1/teams')).status, 401);
        const call = (token, path, method = 'GET', body) => fetchValue(path, {method,
          headers:{Authorization:'Bearer ' + token, 'Content-Type':'application/json', 'Idempotency-Key':randomUUID(),
            'X-Selective-V1-Write-Fence':'1', 'X-Selective-Personal-Vault-Writer':'migration-checkpoint-v1'},
          ...(body && {body:JSON.stringify(body)})});
        for (const [index, token] of tokens.entries()) {
          assert.equal((await call(token, '/v1/teams')).status, 200);
          assert.equal((await call(token, '/v1/vault/write-availability')).status, 503);
          assert.equal((await call(token, '/v1/vault', 'PUT', {protocol:'framed-v1', envelope:{}})).status, 503);
          const bootstrap = await call(token, '/v1/devices/bootstrap-key', 'POST', {publicKey:devices[index].publicKey,
            password:`TEST-ONLY-PASSWORD-${['a','b'][index]}-123`});
          assert.equal(bootstrap.status, 200);
        }
        const created = await call(tokens[0], '/v1/teams', 'POST', {name:'Synthetic registered Team'});
        assert.equal(created.status, 201);
        const teamPath = '/v1/teams/' + (await created.json()).team.id;
        const invited = await call(tokens[0], teamPath + '/invitations', 'POST', {username:'synthetic_register_b', role:'viewer'});
        assert.equal(invited.status, 201);
        const invitationID = (await invited.json()).invitation.id;
        const pending = await call(tokens[1], '/v1/team-invitations');
        assert.equal((await pending.json()).invitations[0].id, invitationID);
        const accepted = await call(tokens[1], '/v1/team-invitations/accept', 'POST', {invitationID});
        assert.equal(accepted.status, 200);
        const membership = (await accepted.json()).membership;
        assert.equal(membership.role, 'viewer');
        const memberPath = teamPath + '/members/' + membership.id;
        const forbidden = await call(tokens[1], memberPath, 'PATCH', {role:'editor'});
        assert.equal(forbidden.status, 403);
        const changed = await call(tokens[0], memberPath, 'PATCH', {role:'editor'});
        assert.equal(changed.status, 200);
        assert.equal((await changed.json()).membership.role, 'editor');
        const publication = await call(tokens[0], teamPath + '/vaults/' + randomUUID() + '/publication/header');
        assert.equal(publication.status, 503);
        const after = await fence.snapshot();
        assert.equal(after.v1TeamAuthorization.digest, await readV1TeamAuthorizationDigest(query));
        assert.equal(after.v1TeamAuthorization.pending, null);
        assert.equal(after.personalWritePilot.pilotID, pilotID);
        await fence.append({version:2, type:'V1_PRODUCTION_PERSONAL_PILOT_CLOSED', pilotID});
        assert.equal((await fence.snapshot()).personalWritePilot, undefined);
        assert.equal((await call(tokens[0], teamPath + '/members')).status, 200);
        await startServer(env);
        assert.equal((await call(tokens[0], teamPath + '/members')).status, 503);
      }
      if (environment === 'staging') {
        const privateEnv = { ...env, ALLOW_REGISTRATION:'false' };
        delete privateEnv.STAGING_REGISTRATION_EMAIL_ALLOWLIST;
        await startServer({ ...privateEnv, STAGING_TEAM_ACCOUNT_IDS:snapshot.v1Committed.map(row => row.ownerID).join(','),
          STAGING_TEAM_EXPIRES_AT:new Date(Date.now() + 60000).toISOString() }, ['--isolated-team-acceptance']);
        const metadata = await fetchValue('/v1/meta');
        assert.equal(metadata.headers.get('x-selective-v1-write-status'), null);
        assert.equal(metadata.headers.get('x-selective-personal-vault-write-status'), null);
        assert.equal((await metadata.json()).registrationEnabled, false);
        assert.equal((await fetchValue('/v1/teams')).status, 401);
        const publication = '/v1/teams/' + randomUUID() + '/vaults/' + randomUUID() + '/publication/header';
        for (const token of tokens) {
          const auth = {headers:{Authorization:'Bearer ' + token}};
          assert.equal((await fetchValue('/v1/teams', auth)).status, 200);
          assert.equal((await fetchValue('/v1/vault/write-availability', auth)).status, 503);
          assert.equal((await fetchValue(publication, auth)).status, 503);
        }
        await startServer(privateEnv);
        for (const token of tokens) {
          const auth = {headers:{Authorization:'Bearer ' + token}};
          assert.equal((await fetchValue('/v1/me', auth)).status, 200);
          assert.equal((await fetchValue('/v1/teams', auth)).status, 503);
        }
        assert.deepEqual(await fence.anchor.read(), before);
      }
    }
  }finally{await stopPublicationRuntime(runtime);await proxy?.close();await anchorFixture?.cleanup();await fixture?.cleanup();await smtp?.close();await db.cleanup();}
}
