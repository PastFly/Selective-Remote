import {syntheticHttpAnchor,syntheticHttpAnchorAvailable} from './synthetic-http-anchor-fixture.mjs';
// Synthetic TLS SMTP endpoint: bind only loopback, accept only the test mailbox,
// trust only the ephemeral self-signed certificate and never log its messages.
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {spawn,execFileSync} from 'node:child_process';
import {createServer as createTcpServer} from 'node:net';
import {createServer as createTlsServer} from 'node:tls';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {MigrationFence} from '../src/migration-fence.mjs';
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
        else if(verb==='RCPT'){rcpt=/^RCPT TO:<synthetic-registration@example\.test>$/i.test(line);socket.write(rcpt?'250 ok\r\n':'550 synthetic recipient only\r\n');}
        else if(verb==='DATA'&&rcpt){data=true;socket.write('354 end with dot\r\n');}
        else if(verb==='QUIT'){socket.write('221 bye\r\n');socket.end();}
        else socket.write('500 unsupported\r\n');
      }
    });
  });
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
  return {port:server.address().port,cert,messages,async close(){for(const socket of sockets)socket.destroy();await new Promise(resolve=>server.close(resolve));await rm(dir,{recursive:true,force:true});}};
}

test('real registration, synthetic email verification and login preserve fenced Personal Vault', {skip:!process.env.TEST_DATABASE_URL||!syntheticHttpAnchorAvailable,timeout:60000}, async()=>{
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);let runtime,smtp,anchorFixture;
  try{
    const fixture=await publicationRuntimeFixture(db.databaseURL);anchorFixture=await syntheticHttpAnchor(fixture.path);const fence=anchorFixture.fence;
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    smtp=await testMailServer();
    const sock=createTcpServer();await new Promise(resolve=>sock.listen(0,'127.0.0.1',resolve));const port=sock.address().port;await new Promise(resolve=>sock.close(resolve));const origin=`http://127.0.0.1:${port}`;
    const child=spawn(process.execPath,['src/server.mjs'],{cwd:fileURLToPath(new URL('../',import.meta.url)),stdio:'ignore',env:{
      PATH:process.env.PATH,USER:process.env.USER,DATABASE_URL:db.databaseURL,CLOUD_HOST:'127.0.0.1',CLOUD_PORT:String(port),CLOUD_PUBLIC_ORIGIN:origin,
      SESSION_TOKEN_PEPPER:'s'.repeat(32),EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),
      TEAM_INVITATION_TOKEN_PEPPER:'i'.repeat(32),TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),ABUSE_TOKEN_PEPPER:'a'.repeat(32),PROXY_SHARED_SECRET:'b'.repeat(64),
      PUBLICATION_FENCE_PATH:fixture.path,...anchorFixture.env,ALLOW_REGISTRATION:'true',SMTP_HOST:'localhost',SMTP_PORT:String(smtp.port),SMTP_SECURE:'true',
      SMTP_USER:'synthetic',SMTP_PASSWORD:'test-only-password',SMTP_FROM:'sender@example.test',NODE_EXTRA_CA_CERTS:smtp.cert,NODE_OPTIONS:'--dns-result-order=ipv4first',
    }});runtime={child,cleanup:fixture.cleanup};
    let ready=false;for(let i=0;i<200;i++){if(child.exitCode!==null)throw Error('test_cloud_start_failed');try{if((await fetch(`${origin}/readyz`)).ok){ready=true;break;}}catch{}await new Promise(resolve=>setTimeout(resolve,50));}assert.equal(ready,true);
    const device={id:randomUUID(),name:'TEST-ONLY-CODEX',platform:'web',appVersion:'test'};
    const registration={email:'synthetic-registration@example.test',username:'synthetic_register',displayName:'Synthetic',password:'TEST-ONLY-PASSWORD-123',device};
    const post=(path,body)=>fetch(origin+path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    const registered=await post('/v1/auth/register',registration);assert.equal(registered.status,201,await registered.clone().text());assert.deepEqual(await registered.json(),{verificationRequired:true});
    for(let i=0;i<200&&smtp.messages.length===0;i++)await new Promise(resolve=>setTimeout(resolve,25));assert.equal(smtp.messages.length,1);
    const normalized=smtp.messages[0].replace(/=\r\n/g,'').replace(/=3D/g,'=');const match=normalized.match(/verify-email\?token=([a-zA-Z0-9_-]+)/);assert.ok(match,'test verification link is present');
    const verified=await post('/v1/auth/verify-email',{token:match[1]});assert.equal(verified.status,200,await verified.clone().text());assert.deepEqual(await verified.json(),{verified:true});
    const login=await post('/v1/auth/login',{email:registration.email,password:registration.password,device});assert.equal(login.status,200,await login.clone().text());assert.ok((await login.json()).token);
    const snapshot=await fence.snapshot();assert.equal(snapshot.v1Pending.length,0);assert.equal(snapshot.v1Committed.length,1);assert.equal(snapshot.v1Committed[0].vaultKind,'PERSONAL');
    await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),snapshot);
  }finally{await stopPublicationRuntime(runtime);await anchorFixture?.cleanup();await smtp?.close();await db.cleanup();}
});
