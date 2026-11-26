// Only synthetic HTTP test databases use this explicit positive evidence. Never
// call this from startup/operator code: real activation writes its own journal.
import {execFileSync} from 'node:child_process';
import {request as forwardHTTP} from 'node:http';
import {createServer as createHTTPS, request as requestHTTPS} from 'node:https';
import {createServer} from 'node:net';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {randomUUID} from 'node:crypto';
import {once} from 'node:events';
import pg from 'pg';
import {MigrationFence} from '../src/migration-fence.mjs';
import {readActivePublications} from '../src/migration-compatibility.mjs';
export async function stopPublicationRuntime(runtime) {
  if(!runtime)return;
  const {child}=runtime;
  if(child.exitCode===null&&child.signalCode===null){
    const closed=once(child,'close');
    child.kill();
    await closed;
  }
  await runtime.cleanup?.();
}
export async function publicationRuntimeFixture(databaseURL) {
  const directory=await mkdtemp(join(tmpdir(),'synthetic-http-fence-'));
  const path=join(directory,'journal'),pool=new pg.Pool({connectionString:databaseURL,max:1});
  try {
    await writeFile(path,'',{mode:0o600});
    const fence=new MigrationFence(path);
    const rows=await readActivePublications((sql,values)=>pool.query(sql,values),22);
    for(const row of rows){
      if(row.sequence == null){
        const {teamID,vaultID,attemptID,manifestHash}=row;
        await fence.intent({teamID,vaultID,attemptID,manifestHash,schemaFloor:19});
      }else{
        const {teamID,vaultID,generationID,sequence,headerHash,manifestHash}=row;
        await fence.append({version:2,type:'PENDING_INTENT',intentID:randomUUID(),operationID:randomUUID(),
          kind:'PUBLICATION',schemaFloor:22,vaults:[{teamID,vaultID,generationID,sequence,headerHash,manifestHash}]});
      }
      const pending=(await fence.snapshot()).pending[0];
      await fence.append({version:2,type:'CONFIRMED_COMMIT',intentID:pending.intentID,intentDigest:pending.intentDigest});
    }
    return {path,cleanup:()=>rm(directory,{recursive:true,force:true})};
  }catch(error){await rm(directory,{recursive:true,force:true});throw error;}
  finally{await pool.end();}
}

// Real HTTP suites need separate DBs: other suites deliberately corrupt active
// projections to test fail-closed behavior, which must also stop the controller.
export async function dropDisposablePublicationDatabase(admin, name, {delay=ms=>new Promise(resolve=>setTimeout(resolve,ms))}={}) {
  if (!/^prc_http_[0-9]+_[a-f0-9]{32}_test$/u.test(name)) throw Error('disposable_test_database_required');
  for (let attempt=0; attempt<6; attempt++) {
    try { await admin.query(`DROP DATABASE "${name}"`); return; }
    catch (error) {
      if (error?.code !== '55006' || attempt === 5) throw error;
      await delay(Math.min(100 * (2 ** attempt), 1000));
    }
  }
}

export async function isolatedPublicationDatabase(databaseURL, { migrationsDirectory } = {}) {
  const base=new URL(databaseURL);
  if(!['127.0.0.1','localhost','[::1]'].includes(base.hostname)||!base.pathname.endsWith('_test'))throw Error('disposable_test_database_required');
  const name=`prc_http_${process.pid}_${randomUUID().replaceAll('-','')}_test`;
  const admin=new pg.Pool({connectionString:databaseURL,max:1});let pool,created=false;
  const cleanup=async()=>{try{await pool?.end();if(created)await dropDisposablePublicationDatabase(admin,name);}finally{await admin.end();}};
  try{
    await admin.query(`CREATE DATABASE "${name}" TEMPLATE template0`);created=true;base.pathname='/'+name;
    pool=new pg.Pool({connectionString:base.href});
    const {applyMigrations}=await import('../src/migrations.mjs');
    const {fileURLToPath}=await import('node:url');
    await applyMigrations(pool,migrationsDirectory??fileURLToPath(new URL('../migrations/',import.meta.url)),{info(){}});
    return {pool,databaseURL:base.href,cleanup};
  }catch(error){await cleanup();throw error;}
}

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  return server.address().port;
}

async function close(server) {
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
}

function localHTTPS(url, ca, request = {}) {
  return new Promise((resolve, reject) => {
    const outgoing = requestHTTPS(url, { method: request.method, headers: request.headers, ca, rejectUnauthorized:true }, incoming => {
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

export async function loopbackHTTPSProxy(directory) {
  const keyPath = join(directory, "server.key"), certPath = join(directory, "server.crt");
  execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
    "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", keyPath, "-out", certPath],
  { stdio: "ignore" });
  const [key, cert] = await Promise.all([readFile(keyPath), readFile(certPath)]);
  const socket = createServer();
  const cloudPort = await listen(socket);
  await close(socket);
  const proxy = createHTTPS({ key, cert }, (incoming, response) => {
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
  return {origin, cloudPort, fetchValue, close: () => close(proxy)};
}
