import test from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import { fileURLToPath } from 'node:url';
import { applyMigrations, loadMigrations } from '../src/migrations.mjs';
import { seedMigration,addSyntheticDevices } from './vault-v2-migration-db-fixtures.mjs';
import { VaultMigrationStore } from '../src/vault-migration-store.mjs';
import { legacy, record, uuid, migrationFixture } from './vault-v2-migration-fixtures.mjs';
import { prepareLegacyMigration, prepareMigrationInventory } from '../public/vault-v2-migration.js';
import { prepareReaderProjection, validateReaderProjection, wrapperCommitment, prepareAdministrativeSidecarCommitment } from '../public/vault-publication-v1.js';
import { PostgresStore } from '../src/postgres-store.mjs';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { hashSessionToken } from '../src/security.mjs';
import { publicationRuntimeFixture, isolatedPublicationDatabase, stopPublicationRuntime } from './publication-runtime-fixture.mjs';
import { loadConfig } from '../src/config.mjs';
import { defaultMigrationPolicy } from '../src/migration-policy.mjs';
const directory=fileURLToPath(new URL('../migrations/',import.meta.url));
const database=process.env.TEST_DATABASE_URL;
const resource=()=>({id:uuid(),kind:'HOST',parentFolderID:null,sourceOrdinal:0});

// These concurrency tests deliberately leave statements waiting at barriers.
// Keep the checked-out clients so cleanup can destroy them even on failure.
function boundedPublicationTestPool(connectionString){
 const rawPool=new pg.Pool({connectionString,max:8,connectionTimeoutMillis:5000,statement_timeout:12000,query_timeout:15000});
 const active=new Set(),streams=new Set();let closing=false;
 rawPool.on('connect',client=>{
  const stream=client.connection.stream;
  if(closing){stream.destroy();return;}
  streams.add(stream);stream.once('close',()=>streams.delete(stream));
 });
 const connect=async()=>{
  const client=await rawPool.connect();
  if(closing){const stream=client.connection.stream;client.release(true);stream.destroy();throw Error('test_pool_closed');}
  let released=false;
  const handle={processID:client.processID,query:(...args)=>client.query(...args),release:(destroy=false)=>{
   if(released)return;released=true;active.delete(handle);client.release(destroy);
  }};
  active.add(handle);return handle;
 };
 const pool={connect,query:async(...args)=>{
  const client=await connect();
  try{return await client.query(...args);}catch(error){client.release(true);throw error;}finally{client.release();}
 }};
 return {pool,connect,onConnect:callback=>rawPool.on('connect',callback),close:async()=>{
  closing=true;
  for(const client of [...active])client.release(true);
  const ended=rawPool.end();
  // pool.end() may only half-close idle connections. This is a test-only
  // teardown: force-close even if a synthetic or broken peer never responds.
  for(const stream of streams)stream.destroy();
  await ended;
 }};
}
async function boundedPublicationWait(promise,label){
 let timer;try{return await Promise.race([promise,new Promise((_,reject)=>{
  timer=setTimeout(()=>reject(Error(`test_wait_timeout:${label}`)),8000);
 })]);}finally{clearTimeout(timer);}
}
async function waitForBlockedPublisher(pool,pid){
 for(let n=0;n<400;n++){
  const pending=(await pool.query("SELECT count(*)::int n FROM pg_stat_activity WHERE pid=$1 AND datname=current_database() AND query LIKE 'LOCK TABLE devices,%' AND wait_event_type='Lock'",[pid])).rows[0].n;
  if(pending)return true;await new Promise(r=>setTimeout(r,10));
 }
 return false;
}

test('reader schema20 remains present in latest schema22',async()=>{
 const versions=(await loadMigrations(directory)).map(m=>m.version);assert.ok(versions.includes(20));assert.equal(versions.at(-1),22);
});
test('discard retains permanent identity, permits scoped successor and rejects cross scope or kind reuse',{skip:!database},async()=>{
 const pool=new pg.Pool({connectionString:database});
 try {
  await applyMigrations(pool,directory,{info(){}});
  const f=await seedMigration(pool),s=new VaultMigrationStore(pool,f.config),r=resource();
  await s.start({...f.input,resources:[r]});await s.discard(f.input);
  assert.equal((await pool.query('SELECT count(*)::int n FROM vault_resource_identity_reservations WHERE id=$1',[r.id])).rows[0].n,1);
  await s.start({...f.input,attemptID:uuid(),resources:[r]});
  await assert.rejects(s.start({...f.input,attemptID:uuid(),resources:[{...r,kind:'SNIPPET'}]}),/resource_id_collision/);
  const other=await seedMigration(pool),o=new VaultMigrationStore(pool,other.config);
  await assert.rejects(o.start({...other.input,resources:[r]}),/resource_id_collision/);
 }finally{await pool.end();}
});
test('empty reader projection has explicit signed zero inventory and still rejects empty wrapper sets',async()=>{
 const f=await migrationFixture(),recipient={...f.recipient,deviceKeyVersion:1};
 const input={scope:f.scope,resources:[],objects:[],recipients:[recipient],root:f.root,publisherAccountID:f.accountID,
  publisherDeviceID:f.deviceID,publisherKeyVersion:1};
 const projection=await prepareReaderProjection(input);
 assert.equal(projection.recipients.length,1);assert.equal(projection.recipients[0].inventory.payload.count,0);
 await validateReaderProjection({...input,projection,rootPublicKey:f.root.publicKey});
 await assert.rejects(wrapperCommitment([]),/wrapper_set_empty/);
 await assert.rejects(prepareReaderProjection({...input,recipients:[]}),/publication_recipient_missing/);
});
test('empty converter uses explicitly verified custodian targets for encrypted sidecar',async()=>{
 const f=await migrationFixture();
 const out=await prepareLegacyMigration({...f,document:legacy([]),policy:[],recipientTargets:()=>[],persistCheckpoint:async()=>{},
  readerPublication:{publisherAccountID:f.accountID,publisherKeyVersion:1,custodianDeviceIDs:[f.deviceID],
   custodianTargets:[f.recipient],verifyIdentityReservations:async()=>{}}});
 assert.equal(out.resources.length,0);assert.equal(out.readerProjection.recipients[0].inventory.payload.count,0);
 assert.equal(out.administrativeSidecar.wrappers.length,1);
});

export async function publishedFixture(pool,doc=legacy([record('credential',{title:'label',secret:'NEVER_SERVER_PLAINTEXT'})]),{activate=true,withReader=true,beforeStart=async()=>{},policy=null,beforeValidate=async()=>{}}={}) {
 const f=await seedMigration(pool),store=new VaultMigrationStore(pool,f.config);
 await beforeStart(f);
 const preview=await store.preview(f.input),scope={...f.scope,sourceRevision:preview.sourceRevision,sourceHash:preview.sourceHash,
  snapshotHash:preview.snapshotHash,policyVersion:preview.policyVersion};
 const inventory=await prepareMigrationInventory({...f,scope,document:doc,persistCheckpoint:async()=>{}});
 const selected=policy?await policy(f,inventory.resources,preview.snapshot):undefined;
 const started=await store.start({...f.input,resources:inventory.resources,...(selected?{policy:selected}:{})});
 const out=await prepareLegacyMigration({...f,scope:started.scope,document:doc,policy:started.policy,
  checkpoint:inventory.checkpoint,
  recipientTargets:(r,p)=>started.recipients[r.id][p],persistCheckpoint:async()=>{},
  readerPublication:withReader?{publisherAccountID:f.accountID,publisherKeyVersion:1,custodianDeviceIDs:[f.deviceID],
   custodianTargets:[f.recipient],verifyIdentityReservations:async(resources)=>store.verifyIdentityReservations({...f.input,resources})}:null});
 for(const o of out.objects)await store.putPart(f.input,o,out.checkpoint);
 await beforeValidate(f,store,out);
 if(withReader)await store.putReaderProjection(f.input,out.readerProjection,out.administrativeSidecar,out.checkpoint);
 await store.validate(f.input,out.manifest);
 if(activate)await store.activate(f.input,await store.manifestHash(f.input));
 const reader=new PostgresStore(null,pool).publication({...f.config,cursorSecret:'c'.repeat(32)});
 const input={...f.input,sessionID:uuid()};
 return {...f,store,reader,input,out,started};
}
test('READY reader storage freezes projection and activation exposes only exact subject transport',{skip:!database},async()=>{
 const pool=new pg.Pool({connectionString:database});
 try {
  const store=new VaultMigrationStore(pool,{});
  assert.equal(typeof store.putReaderProjection,'function');
  const f=await publishedFixture(pool),h=await f.reader.header(f.input);
  assert.deepEqual(Object.keys(h).sort(),['header','headerHash','inventory','subject']);
  assert.equal(h.subject.accountID,f.accountID);assert.equal(h.inventory.payload.count,2);
  const pin={...f.input,generationID:h.header.payload.generationID,headerHash:h.headerHash};
  const page=await f.reader.directory(pin);assert.equal(page.descriptors.length,2);assert.equal(page.nextCursor,null);
  const part=await f.reader.part({...pin,resourceID:f.out.resources[0].id,part:'METADATA'});
  assert.deepEqual(Object.keys(part).sort(),['descriptor','entry','envelope','generationID','headerHash','proof']);
  assert.equal(part.entry.accountID,f.accountID);assert.equal(part.entry.wrapper.context.deviceID,f.deviceID);
  assert.equal(JSON.stringify(part).includes('administrativeSidecar'),false);
  const bundle=await f.reader.publisher(pin);assert.equal(bundle.accountID,f.accountID);assert.equal(bundle.rootPublicKey,f.root.publicKey);
  await assert.rejects(pool.query('UPDATE vault_publication_projections SET header_hash=$2 WHERE attempt_id=$1',[f.input.attemptID,'f'.repeat(64)]),/immutable_migration_object/);
  await assert.rejects(f.reader.directory({...pin,generationID:uuid()}),/publication_changed/);
  await assert.rejects(f.reader.part({...pin,resourceID:uuid(),part:'SECRET'}),/team_access_denied/);
  await assert.rejects(f.reader.header({...pin,actorUserID:uuid(),actorDeviceID:uuid()}),/team_not_found/);
  await pool.query('DELETE FROM team_membership_device_admissions WHERE membership_id=$1',[f.recipient.membershipID]);
  await assert.rejects(f.reader.part({...pin,resourceID:f.out.resources[0].id,part:'SECRET'}),/publication_access_denied/);
 }finally{await pool.end();}
});
test('empty ACTIVE publication has explicit custodian zero directory; noncustodian cannot derive delivery from role',{skip:!database},async()=>{
 const pool=new pg.Pool({connectionString:database});
 try {
  assert.equal(typeof new VaultMigrationStore(pool,{}).putReaderProjection,'function');
  const f=await publishedFixture(pool,legacy([])),h=await f.reader.header(f.input);
  assert.equal(h.inventory.payload.count,0);
  const d=await f.reader.directory({...f.input,generationID:h.header.payload.generationID,headerHash:h.headerHash});
  assert.deepEqual(d.descriptors,[]);assert.equal(d.nextCursor,null);
 }finally{await pool.end();}
});

const runtimeEnv={DATABASE_URL:database??'postgres://example.invalid/test',SESSION_TOKEN_PEPPER:'s'.repeat(32),
 EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),TEAM_INVITATION_TOKEN_PEPPER:'t'.repeat(32),
 TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),ABUSE_TOKEN_PEPPER:'a'.repeat(32),PROXY_SHARED_SECRET:'b'.repeat(64)};
test('publication config is default OFF and rejects enabled production, missing allowlist or cursor secret',()=>{
 assert.equal(loadConfig(runtimeEnv).publication.enabled,false);
 const enabled={...runtimeEnv,PUBLICATION_FENCE_PATH:'/tmp/config-test-fence',PUBLICATION_READER_ENABLED:'true',PUBLICATION_ENVIRONMENT:'staging',PUBLICATION_ALLOWED_VAULT_IDS:uuid(),PUBLICATION_CURSOR_SECRET:'z'.repeat(32)};
 assert.equal(loadConfig(enabled).publication.enabled,true);
 for(const delta of [{PUBLICATION_ENVIRONMENT:'production'},{PUBLICATION_ALLOWED_VAULT_IDS:''},{PUBLICATION_CURSOR_SECRET:undefined},
  {PUBLICATION_CURSOR_SECRET:runtimeEnv.SESSION_TOKEN_PEPPER}])assert.throws(()=>loadConfig({...enabled,...delta}),/PUBLICATION/);
});
const publicationHeaders={'x-vault-schema-version':'2','x-vault-capability':'resource_acl_v2','x-publication-version':'1'};
async function launch(env) {
 const fixture=env.PUBLICATION_READER_ENABLED==='true'&&!env.PUBLICATION_FENCE_PATH?await publicationRuntimeFixture(env.DATABASE_URL??database):null;
 if(fixture)env={...env,PUBLICATION_FENCE_PATH:fixture.path};
 const socket=createServer();await new Promise(r=>socket.listen(0,'127.0.0.1',r));const port=socket.address().port;
 await new Promise(r=>socket.close(r));
 const child=spawn(process.execPath,['src/server.mjs'],{cwd:fileURLToPath(new URL('../',import.meta.url)),env:{...process.env,...runtimeEnv,...env,CLOUD_HOST:'127.0.0.1',CLOUD_PORT:String(port)}});
 let output='';child.stdout.on('data',d=>output+=d);child.stderr.on('data',d=>output+=d);
 const origin='http://127.0.0.1:'+port;
 for(let n=0;n<100;n++){
  if(child.exitCode!==null){await fixture?.cleanup();throw Error('synthetic server failed: '+output);}
  try{if((await fetch(origin+'/healthz')).ok)return {child,origin,fencePath:env.PUBLICATION_FENCE_PATH,cleanup:()=>fixture?.cleanup()};}catch{}
  await new Promise(r=>setTimeout(r,20));
 }
 await stopPublicationRuntime({child,cleanup:()=>fixture?.cleanup()});throw Error('synthetic server readiness timeout');
}
test('real HTTP publication routes authenticate, pin generation, deliver scoped proof, prohibit cache and enforce stage gate',{skip:!database},async()=>{
 const isolated=await isolatedPublicationDatabase(database),pool=isolated.pool;let runtime;
 try {
  const f=await publishedFixture(pool),token='synthetic-publication-session-'+uuid();
  await pool.query("INSERT INTO sessions(user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,now()+interval '1 hour')",[f.accountID,f.deviceID,hashSessionToken(token,runtimeEnv.SESSION_TOKEN_PEPPER)]);
  runtime=await launch({DATABASE_URL:isolated.databaseURL,PUBLICATION_READER_ENABLED:'true',PUBLICATION_ENVIRONMENT:'staging',PUBLICATION_ALLOWED_VAULT_IDS:f.input.vaultID,PUBLICATION_CURSOR_SECRET:'z'.repeat(32)});
  const base='/v1/teams/'+f.input.teamID+'/vaults/'+f.input.vaultID+'/publication';
  const get=(path,auth=true)=>fetch(runtime.origin+path,{headers:auth?{...publicationHeaders,Authorization:'Bearer '+token}:{}});
  assert.equal((await get(base+'/header',false)).status,401);
  for(const caps of [{},{'x-vault-schema-version':'1'},{'x-vault-schema-version':'2'},
    {...publicationHeaders,'x-publication-version':'0'}, {...publicationHeaders,'x-vault-capability':'whole_vault'}]){
   const denied=await fetch(runtime.origin+base+'/header',{headers:{Authorization:'Bearer '+token,...caps}});
   assert.equal(denied.status,409);assert.equal((await denied.json()).error,'vault_upgrade_required');
  }
  const h=await get(base+'/header');assert.equal(h.status,200);assert.equal(h.headers.get('cache-control'),'no-store');
  const header=await h.json(),query='?generationID='+header.header.payload.generationID+'&headerHash='+header.headerHash;
  const d=await get(base+'/directory'+query);assert.equal(d.status,200);assert.equal((await d.json()).descriptors.length,2);
  const b=await get(base+'/publisher'+query);assert.equal(b.status,200);assert.equal((await b.json()).accountID,f.accountID);
  const p=await get(base+'/resources/'+f.out.resources[0].id+'/parts/METADATA'+query);assert.equal(p.status,200);
  const body=await p.json();assert.equal(body.entry.wrapper.context.deviceID,f.deviceID);assert.equal(body.wrappers,undefined);
  const {MigrationFence}=await import('../src/migration-fence.mjs');
  const fence=new MigrationFence(runtime.fencePath),intentID=uuid();
  await fence.append({version:2,type:'PENDING_INTENT',intentID,operationID:uuid(),kind:'PUBLICATION',schemaFloor:22,
   vaults:[{teamID:f.input.teamID,vaultID:f.input.vaultID,generationID:uuid(),sequence:2,headerHash:'d'.repeat(64),manifestHash:'e'.repeat(64)}]});
  assert.equal((await get(base+'/header')).status,503);
  assert.equal((await fetch(runtime.origin+'/readyz')).status,503);
  assert.equal((await fetch(runtime.origin+'/healthz')).status,200);
  const pending=(await fence.snapshot()).pending[0];
  // Deliberately resolved synthetic intent; production abort proof is transaction-bound.
  await fence.append({version:2,type:'PROVEN_ABORT',intentID,intentDigest:pending.intentDigest});
  assert.equal((await get(base+'/header')).status,200);
  const stale=await get(base+'/directory?generationID='+uuid()+'&headerHash='+header.headerHash);
  assert.equal(stale.status,409);assert.equal((await stale.json()).error,'publication_changed');
  await pool.query('DELETE FROM team_membership_device_admissions WHERE membership_id=$1',[f.recipient.membershipID]);
  assert.equal((await get(base+'/resources/'+f.out.resources[0].id+'/parts/SECRET'+query)).status,403);
  await stopPublicationRuntime(runtime);runtime=await launch({DATABASE_URL:isolated.databaseURL});
  assert.equal((await get(base+'/header')).status,404);
 }finally{await stopPublicationRuntime(runtime);await isolated.cleanup();}
});
async function addMember(pool,f,role='viewer') {
 const g=await seedMigration(pool),membershipID=uuid();
 await pool.query('INSERT INTO team_memberships(id,team_id,user_id,role) VALUES($1,$2,$3,$4)',[membershipID,f.input.teamID,g.accountID,role]);
 await pool.query('INSERT INTO team_membership_device_admissions(membership_id,membership_epoch,device_id) VALUES($1,1,$2)',[membershipID,g.deviceID]);
 const pins=f.pinnedTrust;
 f.pinnedTrust={loadPin:(endpoint,account)=>account===g.accountID?g.pinnedTrust.loadPin(endpoint,account):pins.loadPin(endpoint,account),
  advancePin:(old,next)=>old.accountID===g.accountID?g.pinnedTrust.advancePin(old,next):pins.advancePin(old,next)};
 return {...g,memberInput:{...f.input,actorUserID:g.accountID,actorDeviceID:g.deviceID,sessionID:uuid()},membershipID};
}
test('effective permission matrix isolates metadata, Folder inheritance, exact devices and nonentitled admins',{skip:!database},async()=>{
 const pool=new pg.Pool({connectionString:database});let viewer,admin;
 try{
  const f=await publishedFixture(pool,legacy([record('credential',{title:'safe',secret:'SECRET'}),record('host',{folder:'Private/Child'})]),{
   beforeStart:async f=>{viewer=await addMember(pool,f);admin=await addMember(pool,f,'admin');},
   policy:(f,resources,snapshot)=>{
    const grants=defaultMigrationPolicy({resources,snapshot}).filter(g=>g.principalID===f.accountID);
    const folder=resources.find(r=>r.kind==='FOLDER'&&r.parentFolderID===null);
    grants.push({id:uuid(),teamID:f.input.teamID,vaultID:f.input.vaultID,principalKind:'USER',principalID:viewer.accountID,
     membershipID:viewer.membershipID,membershipEpoch:1,targetKind:'FOLDER',targetID:folder.id,mask:1,revokedAt:null});
    const credential=resources.find(r=>r.kind==='CREDENTIAL');
    grants.push({...grants.at(-1),id:uuid(),targetKind:'RESOURCE',targetID:credential.id});
    return grants;
   }});
  const h=await f.reader.header(viewer.memberInput),pin={...viewer.memberInput,generationID:h.header.payload.generationID,headerHash:h.headerHash};
  const d=await f.reader.directory(pin);assert.equal(d.descriptors.length,4);assert.equal(h.inventory.payload.count,4);
  assert.equal(d.descriptors.some(d=>d.payload.part==='SECRET'),false);
  const credential=f.out.resources.find(r=>r.kind==='CREDENTIAL');
  const p=await f.reader.part({...pin,resourceID:credential.id,part:'METADATA'});assert.equal(p.entry.accountID,viewer.accountID);
  assert.equal(p.entry.wrapper.context.membershipID,viewer.membershipID);
  await assert.rejects(f.reader.part({...pin,resourceID:credential.id,part:'SECRET'}),/team_access_denied/);
  await assert.rejects(f.reader.header(admin.memberInput),/team_access_denied/);
  const bundle=await f.reader.publisher({...admin.memberInput,generationID:pin.generationID,headerHash:pin.headerHash});
  assert.equal(bundle.accountID,f.accountID);
  await assert.rejects(f.reader.header({...viewer.memberInput,actorDeviceID:uuid()}),/publication_access_denied/);
  await pool.query('UPDATE team_memberships SET revoked_at=now() WHERE id=$1',[viewer.membershipID]);
  await assert.rejects(f.reader.directory(pin),/team_not_found/);
 }finally{await pool.end();}
});
test('101-resource signed directory caps pages, supports off-page part and binds expiring cursor to session',{skip:!database},async()=>{
 const pool=new pg.Pool({connectionString:database});
 try{
  const f=await publishedFixture(pool,legacy(Array.from({length:101},()=>record('host',{hostname:'synthetic.example.test'}))));
  const h=await f.reader.header(f.input),pin={...f.input,generationID:h.header.payload.generationID,headerHash:h.headerHash};
  const first=await f.reader.directory(pin);assert.equal(first.descriptors.length,100);assert.ok(first.nextCursor);
  const second=await f.reader.directory({...pin,cursor:first.nextCursor});assert.equal(second.descriptors.length,1);assert.equal(second.nextCursor,null);
  assert.equal(second.inventory.payload.count,101);
  const part=await f.reader.part({...pin,resourceID:second.descriptors[0].payload.resourceID,part:'GENERAL'});assert.equal(part.entry.accountID,f.accountID);
  await assert.rejects(f.reader.directory({...pin,cursor:first.nextCursor,sessionID:uuid()}),/invalid_access_page/);
  await assert.rejects(f.reader.directory({...pin,cursor:first.nextCursor.slice(0,-1)+'X'}),/invalid_access_page/);
  await assert.rejects(async()=>f.reader.directory({...pin,limit:101}),/invalid_access_page/);
  f.reader.clock=()=>Date.now()+300001;
  await assert.rejects(f.reader.directory({...pin,cursor:first.nextCursor}),/invalid_access_page/);
  const plan=(await pool.query('EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT object FROM vault_migration_parts WHERE attempt_id=$1 AND resource_id=$2 AND part=$3',[f.input.attemptID,second.descriptors[0].payload.resourceID,'GENERAL'])).rows[0]['QUERY PLAN'][0];
  assert.ok(plan.Plan['Actual Rows']===1);console.log('PUBLICATION_EXPLAIN '+JSON.stringify(plan));
 }finally{await pool.end();}
});
test('descriptor budget keeps Credential pairs together across complete signed directory pages',{skip:!database},async()=>{
 const pool=new pg.Pool({connectionString:database});
 try{
  const f=await publishedFixture(pool,legacy(Array.from({length:101},(_,i)=>record('credential',{title:'synthetic '+i,secret:'synthetic secret'}))));
  const h=await f.reader.header(f.input),pin={...f.input,generationID:h.header.payload.generationID,headerHash:h.headerHash};
  const seen=new Set(),sizes=[];let cursor=null;
  do{
   const page=await f.reader.directory({...pin,cursor});
   assert.ok(page.descriptors.length<=100,'signed descriptors, not resources, determine the page budget');
   assert.equal(page.inventory.payload.count,202);
   const ids=[...new Set(page.descriptors.map(d=>d.payload.resourceID))];
   for(const id of ids){assert.equal(seen.has(id),false);seen.add(id);
    assert.deepEqual(page.descriptors.filter(d=>d.payload.resourceID===id).map(d=>d.payload.part).sort(),['METADATA','SECRET']);}
   sizes.push(page.descriptors.length);cursor=page.nextCursor;
  }while(cursor!==null);
  assert.equal(seen.size,101);assert.deepEqual(sizes,[100,100,2]);
 }finally{await pool.end();}
});
test('direct physical identity tombstone immediately blocks ACTIVE reads',{skip:!database},async()=>{
 const pool=new pg.Pool({connectionString:database});
 try{
  const f=await publishedFixture(pool),h=await f.reader.header(f.input);
  await pool.query('UPDATE vault_resource_identity_reservations SET deleted_at=now() WHERE id=$1',[f.out.resources[0].id]);
  await assert.rejects(f.reader.part({...f.input,generationID:h.header.payload.generationID,headerHash:h.headerHash,
   resourceID:f.out.resources[0].id,part:'SECRET'}),/publication_repair_required/);
 }finally{await pool.end();}
});
test('reader activation fence requires schema20 and READY rejects unsigned omitted or substituted reader commitments',{skip:!database},async()=>{
 const pool=new pg.Pool({connectionString:database});
 try{
  const f=await publishedFixture(pool,undefined,{activate:false});
  await f.store.activate(f.input,await f.store.manifestHash(f.input));
  const intent=f.store.fence.events.find(event=>event.type==='PENDING_INTENT'&&event.operationID===f.input.attemptID);
  assert.equal(intent.schemaFloor,20);
  for(const change of [m=>delete m.payload.reader,m=>m.payload.reader.sidecarHash='f'.repeat(64),m=>m.signature='A'.repeat(86)]){
   const g=await publishedFixture(pool,undefined,{activate:false});const changed=structuredClone(g.out.manifest);change(changed);
   await assert.rejects(g.store.validate(g.input,changed));
  }
 }finally{await pool.end();}
});
test('empty publication denies admitted devices outside explicit custody despite owner role',{skip:!database},async()=>{
 const pool=new pg.Pool({connectionString:database});let other;
 try{
  const f=await publishedFixture(pool,legacy([]),{beforeStart:async f=>{[other]=await addSyntheticDevices(pool,f,1);}});
  await assert.rejects(f.reader.header({...f.input,actorDeviceID:other.deviceID}),/team_access_denied/);
 }finally{await pool.end();}
});
test('unprojected foundation ACTIVE generations remain inaccessible through reader transport',{skip:!database},async()=>{
 const pool=new pg.Pool({connectionString:database});
 try{const f=await publishedFixture(pool,undefined,{withReader:false});await assert.rejects(f.reader.header(f.input),/publication_unavailable/);}
 finally{await pool.end();}
});
test('direct SQL projection insert cannot turn an original signed foundation manifest into a reader publication',{skip:!database},async()=>{
 const pool=new pg.Pool({connectionString:database});
 try{
  const f=await publishedFixture(pool,undefined,{activate:false,withReader:false,beforeValidate:async(f,store,out)=>{
   await pool.query("INSERT INTO vault_publication_projections(attempt_id,team_id,vault_id,projection,administrative_sidecar,header_hash) VALUES($1,$2,$3,$4,'{}',$5)",[f.input.attemptID,f.input.teamID,f.input.vaultID,
    {version:1,header:{payload:{generationID:f.input.attemptID}},descriptors:[],recipients:[]},'a'.repeat(64)]);
   await pool.query("UPDATE vault_migration_attempts SET state='V2_READY',manifest=$2,manifest_hash=$3 WHERE id=$1",[f.input.attemptID,out.manifest,await (await import('../src/migration-policy.mjs')).migrationHash(out.manifest)]);
  }});
  await assert.rejects(f.store.activate(f.input,await f.store.manifestHash(f.input)),/publication_invalid|publication_incomplete/);
  assert.equal((await pool.query('SELECT format_state FROM shared_vaults WHERE id=$1',[f.input.vaultID])).rows[0].format_state,'V1_ACTIVE');
 }finally{await pool.end();}
});
test('repeatable read begun before revoke finishes coherently while the next read denies access',{skip:!database},async()=>{
 const pool=new pg.Pool({connectionString:database});const c=await pool.connect();
 try{
  const f=await publishedFixture(pool);await c.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
  const selected=await f.reader.selected(c,f.input,{pinned:false});
  await pool.query('DELETE FROM team_membership_device_admissions WHERE membership_id=$1',[f.recipient.membershipID]);
  const continued=await f.reader.selected(c,f.input,{pinned:false});assert.equal(continued.a.header_hash,selected.a.header_hash);
  await c.query('COMMIT');await assert.rejects(f.reader.header(f.input),/publication_access_denied/);
 }finally{await c.query('ROLLBACK');c.release();await pool.end();}
});
test('concurrency test cleanup forcibly closes active and idle nonresponding peers',{timeout:15000},async()=>{
 const peers=[],sockets=[];let queryObserved;
 const queryStarted=new Promise(resolve=>{queryObserved=resolve;});
 const server=createServer({allowHalfOpen:true},peer=>{
  peers.push(peer);
  peer.once('data',()=>{
   peer.write(Buffer.from('5200000008000000005a0000000549','hex'));
   peer.once('data',queryObserved);
  });
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const scoped=boundedPublicationTestPool(`postgres://synthetic@127.0.0.1:${server.address().port}/synthetic`);
 scoped.onConnect(client=>sockets.push(client.connection.stream));
 let closed=false;
 try{
  const active=await scoped.connect();
  const waiting=active.query('SELECT 1').then(()=>null,error=>error);
  await boundedPublicationWait(queryStarted,'synthetic active query');
  const idle=await scoped.pool.connect();idle.release();
  closed=true;await boundedPublicationWait(scoped.close(),'nonresponding pool close');
  assert.match((await boundedPublicationWait(waiting,'synthetic query disconnect'))?.message??'',/connection terminated/i);
  assert.equal(sockets.length,2);assert.ok(sockets.every(socket=>socket.destroyed));
 }finally{
  if(!closed)await scoped.close();
  for(const peer of peers)peer.destroy();
  await new Promise(resolve=>server.close(resolve));
 }
});
for(const operation of ['connect','query'])test(`concurrency test cleanup rejects late pool ${operation}`,{timeout:15000},async()=>{
 let peer,started;const received=new Promise(resolve=>{started=resolve;});
 const server=createServer({allowHalfOpen:true},socket=>{peer=socket;socket.once('data',started);});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const scoped=boundedPublicationTestPool(`postgres://synthetic@127.0.0.1:${server.address().port}/synthetic`);
 let socket;scoped.onConnect(client=>{socket=client.connection.stream;});
 let closing=false;
 try{
  const opening=(operation==='connect'?scoped.pool.connect():scoped.pool.query('SELECT 1')).then(()=>null,error=>error);
  await boundedPublicationWait(received,'pending connect');
  closing=true;const ended=scoped.close();
  peer.write(Buffer.from('5200000008000000005a0000000549','hex'));
  assert.ok(await boundedPublicationWait(opening,'late connect rejected'));
  await boundedPublicationWait(ended,'late connection pool close');
  assert.equal(socket?.destroyed,true);
 }finally{
  peer?.destroy();
  if(!closing)await scoped.close();
  await new Promise(resolve=>server.close(resolve));
 }
});
test('concurrency test cleanup terminates a blocked database client',{skip:!database,timeout:30000},async()=>{
 const scoped=boundedPublicationTestPool(database),{pool}=scoped;let owner;
 try{
  const key=uuid();owner=await scoped.connect();const blocked=await scoped.connect();
  await owner.query('SELECT pg_advisory_lock(hashtext($1))',[key]);
  const waiting=blocked.query('SELECT pg_advisory_lock(hashtext($1))',[key]).then(()=>null,error=>error);
  let isWaiting=false;for(let n=0;n<400;n++){
   isWaiting=(await pool.query("SELECT wait_event_type='Lock' AS waiting FROM pg_stat_activity WHERE pid=$1",[blocked.processID])).rows[0]?.waiting===true;
   if(isWaiting)break;await new Promise(r=>setTimeout(r,10));
  }
  assert.equal(isWaiting,true);
  blocked.release(true);
  const error=await boundedPublicationWait(waiting,'destroyed blocked client');
  assert.match(error?.message??'',/connection terminated/i);
  owner.release(true); // Let PostgreSQL leave the lock wait and observe the disconnect.
  let gone=false;for(let n=0;n<400;n++){
   gone=(await pool.query('SELECT count(*)::int n FROM pg_stat_activity WHERE pid=$1',[blocked.processID])).rows[0].n===0;
   if(gone)break;await new Promise(r=>setTimeout(r,10));
  }
  assert.equal(gone,true);
 }finally{owner?.release(true);await scoped.close();}
});
test('publisher/account deletion deadlock retries identical atomic deletion without duplicate rotation or audit',{skip:!database,timeout:30000},async()=>{
 const scoped=boundedPublicationTestPool(database),{pool}=scoped;let release,publisherPID;
 try{
  const f=await seedMigration(pool),g=await addMember(pool,f);
  await pool.query('UPDATE team_memberships SET revoked_at=now() WHERE team_id=$1 AND user_id=$2',[g.input.teamID,g.accountID]);
  await pool.query('UPDATE teams SET archived_at=now() WHERE id=$1',[g.input.teamID]);
  let reached;const paused=new Promise(r=>{reached=r;}),resume=new Promise(r=>{release=r;});
  let stopped=false;const errors=[];
  const instrumented={connect:async()=>{
   const c=await scoped.connect();await c.query("SET deadlock_timeout='50ms'");
   return {release:()=>c.release(),query:async(sql,values)=>{
    try{const result=await c.query(sql,values);
     if(!stopped&&sql.includes('UPDATE team_memberships SET revoked_at')){stopped=true;reached();await resume;}return result;
    }catch(e){if(e.code==='40P01')errors.push({code:e.code,detail:e.detail});throw e;}
   }};
  }};
  const deletion=new PostgresStore(null,instrumented).deleteAccount(g.accountID).then(value=>({value}),error=>({error}));
  await boundedPublicationWait(paused,'first deletion attempt');
  let publisherStarted;const publisherReady=new Promise(r=>{publisherStarted=r;});
  const publisherPool={connect:async()=>{const c=await scoped.connect();publisherPID??=c.processID;publisherStarted();return c;}};
  const migration=new VaultMigrationStore(publisherPool,f.config).start({...f.input,resources:[resource()]}).then(value=>({value}),error=>({error}));
  await boundedPublicationWait(publisherReady,'publisher connection');
  assert.equal(await waitForBlockedPublisher(pool,publisherPID),true);release();
  const [deleted,prepared]=await boundedPublicationWait(Promise.all([deletion,migration]),'deadlock transactions');
  assert.ok(errors.length>=1);console.log('PUBLICATION_DELETION_DEADLOCK '+JSON.stringify(errors));
  assert.deepEqual(deleted,{value:{deleted:true}});
  // Either preparation wins before deletion, or deletion marks the source for
  // rotation and the retried preparation must fail closed. It cannot publish
  // the stale snapshot after the member has been removed.
  if(prepared.value)await assert.rejects(new VaultMigrationStore(pool,f.config).validate(f.input,{}),/migration_source_not_ready/);
  else assert.equal(prepared.error?.message,'migration_source_not_ready',prepared.error?.stack);
  assert.deepEqual((await pool.query('SELECT format_state,rotation_required FROM shared_vaults WHERE id=$1',[f.input.vaultID])).rows[0],
   {format_state:'V1_ACTIVE',rotation_required:true});
  assert.equal((await pool.query('SELECT count(*)::int n FROM users WHERE id=$1',[g.accountID])).rows[0].n,0);
  assert.equal((await pool.query("SELECT count(*)::int n FROM team_audit_events WHERE team_id=$1 AND action='team.member_account_deleted' AND target_membership_id=$2",[f.input.teamID,g.membershipID])).rows[0].n,1);
  assert.equal((await pool.query('SELECT count(*)::int n FROM shared_vault_rotation_tasks WHERE vault_id=$1 AND removed_membership_id=$2',[f.input.vaultID,g.membershipID])).rows[0].n,1);
 }finally{release?.();await scoped.close();}
});
test('publication retry fails closed when deletion wins after injected transaction conflicts',{skip:!database,timeout:30000},async()=>{
 const scoped=boundedPublicationTestPool(database),{pool}=scoped;let resumeFirst,resumeSecond,secondPaused,deletionFinished,publisherPID;
 try{
  const f=await seedMigration(pool),g=await addMember(pool,f);
  await pool.query('UPDATE team_memberships SET revoked_at=now() WHERE team_id=$1 AND user_id=$2',[g.input.teamID,g.accountID]);
  await pool.query('UPDATE teams SET archived_at=now() WHERE id=$1',[g.input.teamID]);
  let firstPaused;
  const first=new Promise(r=>{firstPaused=r;}),second=new Promise(r=>{secondPaused=r;});
  const deletionDone=new Promise(r=>{deletionFinished=r;});
  const resumeFirstPromise=new Promise(r=>{resumeFirst=r;}),resumeSecondPromise=new Promise(r=>{resumeSecond=r;});
  const bounded=boundedPublicationWait;
  let deletionAttempts=0,migrationAttempts=0,injectedDeletion=false,injectedPublisher=false;
  const conflict=()=>Object.assign(new Error('synthetic_transaction_conflict'),{code:'40P01'});
  const deletePool={connect:async()=>{
   const c=await scoped.connect(),attempt=++deletionAttempts;
   await c.query(`SET deadlock_timeout='${attempt===1?'50ms':'5s'}'`);
   return {release:()=>c.release(),query:async(sql,values)=>{
    const result=await c.query(sql,values);
    if(attempt===1&&sql.includes('UPDATE team_memberships SET revoked_at')){
     firstPaused();await resumeFirstPromise;injectedDeletion=true;throw conflict();
    }
    if(attempt===2&&sql.includes('SELECT member.id, member.team_id')){secondPaused();await resumeSecondPromise;}
    return result;
   }};
  }};
  const migrationPool={connect:async()=>{
   const c=await scoped.connect(),attempt=++migrationAttempts;
   if(attempt===1){publisherPID=c.processID;publisherStarted();}
   return {release:()=>c.release(),query:async(sql,values)=>{
    if(attempt>1&&sql.startsWith('LOCK TABLE '))await bounded(deletionDone,'deletion');
    const result=await c.query(sql,values);
    if(attempt===1&&sql.startsWith('LOCK TABLE ')){
     await bounded(second,'second attempt');resumeSecond();injectedPublisher=true;throw conflict();
    }
    return result;
   }};
  }};
  let publisherStarted;const publisherReady=new Promise(r=>{publisherStarted=r;});
  const deletion=new PostgresStore(null,deletePool).deleteAccount(g.accountID).then(
   value=>{deletionFinished();return {value};},error=>{deletionFinished();return {error};});
  await bounded(first,'first attempt');
  const migration=new VaultMigrationStore(migrationPool,f.config).start({...f.input,resources:[resource()]}).then(value=>({value}),error=>({error}));
  await bounded(publisherReady,'publisher connection');
  assert.equal(await waitForBlockedPublisher(pool,publisherPID),true);resumeFirst();
  const [deleted,prepared]=await bounded(Promise.all([deletion,migration]),'transactions');
  assert.equal(injectedDeletion,true);assert.equal(injectedPublisher,true);
  assert.deepEqual(deleted,{value:{deleted:true}});
  assert.equal((await pool.query('SELECT count(*)::int n FROM users WHERE id=$1',[g.accountID])).rows[0].n,0);
  assert.equal((await pool.query('SELECT count(*)::int n FROM users WHERE id=$1',[f.accountID])).rows[0].n,1);
  assert.equal(prepared.error?.message,'migration_source_not_ready',prepared.error?.stack);
  assert.equal((await pool.query('SELECT count(*)::int n FROM vault_migration_attempts WHERE id=$1',[f.input.attemptID])).rows[0].n,0);
  assert.deepEqual((await pool.query('SELECT format_state,rotation_required FROM shared_vaults WHERE id=$1',[f.input.vaultID])).rows[0],
   {format_state:'V1_ACTIVE',rotation_required:true});
  assert.equal((await pool.query("SELECT count(*)::int n FROM team_audit_events WHERE team_id=$1 AND action='team.member_account_deleted' AND target_membership_id=$2",[f.input.teamID,g.membershipID])).rows[0].n,1);
  assert.equal((await pool.query('SELECT count(*)::int n FROM shared_vault_rotation_tasks WHERE vault_id=$1 AND removed_membership_id=$2',[f.input.vaultID,g.membershipID])).rows[0].n,1);
 }finally{resumeFirst?.();resumeSecond?.();secondPaused?.();deletionFinished?.();await scoped.close();}
});
test('real HTTP viewer metadata, admin inspection, outsider, device and membership revocation matrix',{skip:!database},async()=>{
 const isolated=await isolatedPublicationDatabase(database),pool=isolated.pool;let runtime,viewer,admin;
 try{
  const f=await publishedFixture(pool,undefined,{beforeStart:async f=>{viewer=await addMember(pool,f);admin=await addMember(pool,f,'admin');},
   policy:(f,resources,snapshot)=>defaultMigrationPolicy({resources,snapshot}).filter(g=>g.principalID!==admin.accountID).map(g=>g.principalID===viewer.accountID?{...g,mask:1}:g)});
  const outsider=await seedMigration(pool),tokens=new Map();
  for(const actor of [f,viewer,admin,outsider]){
   const token='synthetic-publication-matrix-'+uuid();tokens.set(actor.accountID,token);
   await pool.query("INSERT INTO sessions(user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,now()+interval '1 hour')",[actor.accountID,actor.deviceID,hashSessionToken(token,runtimeEnv.SESSION_TOKEN_PEPPER)]);
  }
  runtime=await launch({DATABASE_URL:isolated.databaseURL,PUBLICATION_READER_ENABLED:'true',PUBLICATION_ENVIRONMENT:'staging',PUBLICATION_ALLOWED_VAULT_IDS:f.input.vaultID,PUBLICATION_CURSOR_SECRET:'z'.repeat(32)});
  const base=runtime.origin+'/v1/teams/'+f.input.teamID+'/vaults/'+f.input.vaultID+'/publication';
  const get=(actor,path)=>fetch(base+path,{headers:{...publicationHeaders,Authorization:'Bearer '+tokens.get(actor.accountID)}});
  const h=await (await get(viewer,'/header')).json(),query='?generationID='+h.header.payload.generationID+'&headerHash='+h.headerHash;
  const resourcePath='/resources/'+f.out.resources[0].id+'/parts/';
  assert.equal((await get(viewer,resourcePath+'METADATA'+query)).status,200);
  assert.equal((await get(viewer,resourcePath+'SECRET'+query)).status,403);
  assert.equal((await get(admin,'/header')).status,403);assert.equal((await get(admin,'/publisher'+query)).status,200);
  assert.equal((await get(outsider,'/header')).status,404);assert.equal((await get(outsider,'/publisher'+query)).status,404);
  assert.equal((await get(viewer,'/directory'+query+'&kind=CREDENTIAL')).status,400);
  assert.equal((await get(viewer,'/directory'+query+'&generationID='+uuid())).status,400);
  await pool.query('UPDATE team_memberships SET revoked_at=now() WHERE id=$1',[viewer.membershipID]);
  assert.equal((await get(viewer,'/header')).status,404);
  await pool.query('UPDATE devices SET revoked_at=now() WHERE id=$1',[admin.deviceID]);
  assert.equal((await get(admin,'/publisher'+query)).status,401);
 }finally{await stopPublicationRuntime(runtime);await isolated.cleanup();}
});
test('1000-resource/10000-wrapper boundary stores and reads real cryptographic projection; boundary+1 is atomic denial',{skip:!database},async()=>{
 const pool=new pg.Pool({connectionString:database});
 try{
  const {encryptResourcePart,wrapResourceCEK}=await import('../public/resource-crypto-v2.js');
  const {migrationHash,migrationBytes,toBase64}=await import('../public/vault-v2-migration.js');
  const {publicationHash}=await import('../public/vault-publication-v1.js');
  const f=await seedMigration(pool),store=new VaultMigrationStore(pool,f.config);
  await addSyntheticDevices(pool,f,8);
  const viewer=await addMember(pool,f);
  const resources=Array.from({length:1000},(_,sourceOrdinal)=>({...resource(),sourceOrdinal}));
  const before=(await pool.query('SELECT count(*)::int n FROM vault_migration_attempts')).rows[0].n;
  await assert.rejects(store.start({...f.input,resources:[...resources,{...resource(),sourceOrdinal:1000}]}),/invalid_migration_resources/);
  assert.equal((await pool.query('SELECT count(*)::int n FROM vault_migration_attempts')).rows[0].n,before);
  const began=performance.now(),preview=await store.preview(f.input);
  const policy=defaultMigrationPolicy({resources,snapshot:preview.snapshot}).filter(g=>!(g.principalID===viewer.accountID&&g.targetID===resources.at(-1).id));
  const started=await store.start({...f.input,resources,policy}),objects=[];
  for(const r of resources){const context={teamID:f.input.teamID,vaultID:f.input.vaultID,resourceID:r.id,part:'GENERAL',keyVersion:1,
    policyVersion:started.scope.policyVersion,registryVersion:1,resourceVersion:1,manifestVersion:1};
   const cek=crypto.getRandomValues(new Uint8Array(32));
   try{
    const envelope=await encryptResourcePart({cek,context,plaintext:new TextEncoder().encode(JSON.stringify({link:{...context,generationID:f.input.attemptID,kind:'HOST'},record:{hostname:'synthetic.example.test'}}))});
    const wrappers=await Promise.all(started.recipients[r.id].GENERAL.map(t=>wrapResourceCEK({cek,context:{teamID:context.teamID,vaultID:context.vaultID,
      resourceID:r.id,part:'GENERAL',keyVersion:1,membershipID:t.membershipID,membershipEpoch:t.membershipEpoch,deviceID:t.deviceID},recipientPublicKey:t.publicKey})));
    const object={resourceID:r.id,part:'GENERAL',envelope,wrappers};object.sha256=await migrationHash(object);objects.push(object);
   }finally{cek.fill(0);}
  }
  const targets=started.recipients[resources[0].id].GENERAL,recipients=targets.map(t=>({...t,deviceKeyVersion:t.certificate.payload.keyVersion}));
  const projection=await prepareReaderProjection({scope:started.scope,resources,objects,recipients,root:f.root,
   publisherAccountID:f.accountID,publisherDeviceID:f.deviceID,publisherKeyVersion:1});
  await assert.rejects(prepareReaderProjection({scope:started.scope,resources,objects,recipients:Array.from({length:10001},()=>recipients[0]),
   root:f.root,publisherAccountID:f.accountID,publisherDeviceID:f.deviceID,publisherKeyVersion:1}),/publication_limit/);
  const context={...objects[0].envelope.context,resourceID:uuid(),part:'SECRET'},cek=crypto.getRandomValues(new Uint8Array(32));
  const sidecar={resourceID:context.resourceID,part:'SECRET',envelope:await encryptResourcePart({cek,context,plaintext:new TextEncoder().encode(JSON.stringify({generationID:f.input.attemptID,sourceMetadata:{tombstones:[],vectorClock:{}}}))}),
   wrappers:[await wrapResourceCEK({cek,context:{teamID:f.input.teamID,vaultID:f.input.vaultID,resourceID:context.resourceID,part:'SECRET',keyVersion:1,
    membershipID:f.recipient.membershipID,membershipEpoch:1,deviceID:f.deviceID},recipientPublicKey:f.identity.publicKey})]};cek.fill(0);
  await pool.query("INSERT INTO vault_migration_parts(attempt_id,resource_id,part,object,sha256) SELECT $1,(o->>'resourceID')::uuid,o->>'part',o,o->>'sha256' FROM jsonb_array_elements($2::jsonb) o",[f.input.attemptID,JSON.stringify(objects)]);
  const other=targets.find(t=>t.deviceID!==f.deviceID),extraKey=crypto.getRandomValues(new Uint8Array(32));
  const extraWrapper=await wrapResourceCEK({cek:extraKey,context:{teamID:f.input.teamID,vaultID:f.input.vaultID,resourceID:context.resourceID,part:'SECRET',keyVersion:1,
   membershipID:other.membershipID,membershipEpoch:other.membershipEpoch,deviceID:other.deviceID},recipientPublicKey:other.publicKey});extraKey.fill(0);
  await assert.rejects(store.putReaderProjection(f.input,projection,{...sidecar,wrappers:[...sidecar.wrappers,extraWrapper]}),/publication_limit/);
  assert.equal((await pool.query('SELECT count(*)::int n FROM vault_publication_projections WHERE attempt_id=$1',[f.input.attemptID])).rows[0].n,0);
  await store.putReaderProjection(f.input,projection,sidecar);
  const payload={version:2,scope:started.scope,policyHash:await migrationHash(started.policy),resources,
   parts:objects.map(o=>({resourceID:o.resourceID,part:o.part,sha256:o.sha256})),
   reader:{projectionHash:await publicationHash('projection',projection),sidecarHash:await publicationHash('sidecar',sidecar),
    sidecarCommitment:(await prepareAdministrativeSidecarCommitment(sidecar,targets)).commitment,custodianDeviceIDs:[f.deviceID]}};
  const manifest={payload,signature:toBase64(new Uint8Array(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},f.root.privateKey,migrationBytes(payload))))};
  await store.validate(f.input,manifest);await store.activate(f.input,await store.manifestHash(f.input));
  const reader=new PostgresStore(null,pool).publication({...f.config,cursorSecret:'c'.repeat(32)}),input={...f.input,sessionID:uuid()},h=await reader.header(input);
  assert.equal(h.inventory.payload.count,1000);
  const page=await reader.directory({...input,generationID:f.input.attemptID,headerHash:h.headerHash});assert.equal(page.descriptors.length,100);
  console.log('PUBLICATION_SCALE '+JSON.stringify({resources:1000,resourceWrappers:9999,sidecarWrappers:1,projectionBytes:Buffer.byteLength(JSON.stringify(projection)),elapsedMS:Math.round(performance.now()-began),outcome:'READY/ACTIVE + signed 100-resource page; boundary+1 denied'}));
 }finally{await pool.end();}
});
