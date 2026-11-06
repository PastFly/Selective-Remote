import {syntheticHttpAnchor,syntheticHttpAnchorAvailable} from './synthetic-http-anchor-fixture.mjs';
// Synthetic TLS SMTP endpoint: bind only loopback, accept only two synthetic test mailboxes,
// trust only the ephemeral self-signed certificate and never log its messages.
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {spawn,execFileSync,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createServer as createTlsServer} from 'node:tls';
import {mkdir,mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {readV1VaultState,assertV1DataFloor} from '../src/v1-data-fence.mjs';
import {installV1CommitFence} from '../src/v1-commit-fence.mjs';
import {isolatedPublicationDatabase,publicationRuntimeFixture,stopPublicationRuntime} from './publication-runtime-fixture.mjs';

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

const execute = promisify(execFile);
const root = fileURLToPath(new URL('../../', import.meta.url));
const browserEnabled = process.env.SR_TEAM_HOST_BROWSER === '1';
const reportPath = join(root, 'qa-artifacts/browser/team-host-mvp.json');

// CLI output can contain test credentials or verification links. Never log it.
async function browser(session, ...args) {
  try {
    const {stdout, stderr} = await execute('playwright-cli', [`-s=${session}`, ...args], {
      cwd: root, timeout: 90000, maxBuffer: 2 * 1024 * 1024,
    });
    if (/### Error|TimeoutError|Error:/.test(stdout + stderr)) throw Error('browser_action_failed');
    return stdout;
  } catch {
    // execFile errors include its complete arguments; they can contain test tokens.
    throw Error('browser_action_failed');
  }
}

test('disposable browser Team Host MVP progress', {
  skip: !browserEnabled,
  timeout: 360000,
}, async () => {
  const stages = Object.fromEntries(['register_a','verify_a','login_a','team_create','host_create',
    'register_b','verify_b','login_b','invite_b','accept','device_approval','sync','edit','revoke']
    .map(name => [name, 'NOT_RUN']));
  const sessions = ['sr-mvp-a', 'sr-mvp-b'];
  let db, runtime, smtp, anchorFixture, currentStage='setup';
  try {
    assert.ok(process.env.TEST_DATABASE_URL && syntheticHttpAnchorAvailable,'disposable PostgreSQL and TLS anchor are required');
    const databaseURL = new URL(process.env.TEST_DATABASE_URL);
    assert.ok(['localhost','127.0.0.1','[::1]'].includes(databaseURL.hostname),'test database must be loopback');
    db = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
    const fixture = await publicationRuntimeFixture(db.databaseURL);
    anchorFixture = await syntheticHttpAnchor(fixture.path);
    const fence = anchorFixture.fence;
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    smtp = await testMailServer();
    const origin = 'http://127.0.0.1:8765';
    const child=spawn(process.execPath,['src/server.mjs'],{cwd:fileURLToPath(new URL('../',import.meta.url)),stdio:'ignore',env:{
      PATH:process.env.PATH,USER:process.env.USER,DATABASE_URL:db.databaseURL,CLOUD_HOST:'127.0.0.1',CLOUD_PORT:'8765',CLOUD_PUBLIC_ORIGIN:origin,
      SESSION_TOKEN_PEPPER:'s'.repeat(32),EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),
      TEAM_INVITATION_TOKEN_PEPPER:'i'.repeat(32),TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),ABUSE_TOKEN_PEPPER:'a'.repeat(32),PROXY_SHARED_SECRET:'b'.repeat(64),
      PUBLICATION_FENCE_PATH:fixture.path,...anchorFixture.env,ALLOW_REGISTRATION:'true',SMTP_HOST:'localhost',SMTP_PORT:String(smtp.port),SMTP_SECURE:'true',
      SMTP_USER:'synthetic',SMTP_PASSWORD:'test-only-password',SMTP_FROM:'sender@example.test',NODE_EXTRA_CA_CERTS:smtp.cert,NODE_OPTIONS:'--dns-result-order=ipv4first',
    }}); runtime={child,cleanup:fixture.cleanup};
    let ready=false;
    for(let i=0;i<200;i++){if(child.exitCode!==null)throw Error('test_cloud_start_failed');try{if((await fetch(`${origin}/readyz`)).ok){ready=true;break;}}catch{}await new Promise(resolve=>setTimeout(resolve,50));}
    assert.equal(ready,true,'isolated Cloud did not start');

    for (const [index,suffix] of ['a','b'].entries()) {
      const session=sessions[index];
      const email=`synthetic-registration-${suffix}@example.test`;
      const username=`synthetic_register_${suffix}`;
      const password=`TEST-ONLY-PASSWORD-${suffix}-123`;
      currentStage=`register_${suffix}`;
      await browser(session,'open',origin,'--browser=chrome');
      await browser(session,'run-code',`async (page) => {
        const continueButton = page.getByRole('button', {name: /^(Continue|Продолжить)$/});
        if (await continueButton.isVisible()) await continueButton.click();
        await page.locator('[data-open-auth="registration"]').first().click();
        await page.locator('#cloud-registration-name').fill('Synthetic ${suffix}');
        await page.locator('#cloud-registration-username').fill('${username}');
        await page.locator('#cloud-registration-email').fill('${email}');
        await page.locator('#cloud-registration-password').fill('${password}');
        await page.locator('#cloud-registration-confirmation').fill('${password}');
        const response = page.waitForResponse(r => r.url().endsWith('/v1/auth/register') && r.request().method() === 'POST');
        await page.locator('#cloud-registration-form button[type="submit"]').click();
        if ((await response).status() !== 201) throw Error('registration_http_failed');
        await page.locator('#cloud-registration-success').waitFor({state:'visible'});
      }`);
      stages[`register_${suffix}`]='PASS';
      for(let i=0;i<200&&smtp.messages.length<=index;i++)await new Promise(resolve=>setTimeout(resolve,25));
      assert.equal(smtp.messages.length,index+1,'test confirmation email missing');
      const normalized=smtp.messages[index].replace(/=\r\n/g,'').replace(/=3D/g,'=');
      const match=normalized.match(/verify-email\?token=([a-zA-Z0-9_-]+)/);
      assert.ok(match,'test confirmation link missing');
      currentStage=`verify_${suffix}`;
      await browser(session,'run-code',`async (page) => {
        const response = page.waitForResponse(r => r.url().endsWith('/v1/auth/verify-email') && r.request().method() === 'POST');
        await page.goto('${origin}/#verify-email?token=${match[1]}');
        if ((await response).status() !== 200) throw Error('verification_http_failed');
      }`);
      stages[`verify_${suffix}`]='PASS';
      currentStage=`login_${suffix}_open`;
      await browser(session,'run-code',`async (page) => {
        await page.locator('[data-open-auth="login"]').first().click();
      }`);
      currentStage=`login_${suffix}_submit`;
      await browser(session,'run-code',`async (page) => {
        await page.locator('#cloud-email').fill('${email}');
        await page.locator('#cloud-password').fill('${password}');
        const response = page.waitForResponse(r => r.url().endsWith('/v1/auth/login') && r.request().method() === 'POST');
        await page.locator('#cloud-login-form button[type="submit"]').click();
        if ((await response).status() !== 200) throw Error('login_http_failed');
        await page.locator('#cloud-signed-in').waitFor({state:'visible'});
      }`);
      stages[`login_${suffix}`]='PASS';
    }
    const snapshot=await fence.snapshot();
    assert.equal(snapshot.v1Pending.length,0);
    assert.equal(snapshot.v1Committed.length,2);
    await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),snapshot);

    // A stop remains a stop: do not replace routes, inject state, or disable guards.
    currentStage='team_stop';
    await browser(sessions[0],'run-code',`async (page) => {
      const response = await page.evaluate(async () => {
        const r = await fetch('/v1/teams');
        return {status:r.status,body:await r.json()};
      });
      if (response.status !== 503 || response.body.error !== 'team_security_temporarily_unavailable')
        throw Error('team_stop_not_observed');
    }`);
    for (const name of ['team_create','host_create','invite_b','accept','device_approval','sync','edit','revoke']) stages[name]='BLOCKED';
  } catch (error) {
    process.stdout.write(`MVP_FAILED_STAGE=${currentStage}\n`);
    try {
      await mkdir(join(root,'qa-artifacts/browser'),{recursive:true});
      const session = currentStage.includes('_b') ? sessions[1] : sessions[0];
      await browser(session,'screenshot',`--filename=${join(root,'qa-artifacts/browser/mvp-failure.png')}`);
    } catch {}
    throw error;
  } finally {
    for(const session of sessions) { try { await browser(session,'close'); } catch {} }
    await stopPublicationRuntime(runtime);
    await anchorFixture?.cleanup();
    await smtp?.close();
    await db?.cleanup();
    await mkdir(join(root,'qa-artifacts/browser'),{recursive:true});
    await writeFile(reportPath,JSON.stringify({scope:'disposable-development-only',stages},null,2)+'\n');
    process.stdout.write(`MVP_STAGES=${JSON.stringify(stages)}\n`);
  }
});

