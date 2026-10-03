import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {once} from 'node:events';
import {wholePublicationRoute,runWholePublicationRoute} from '../src/whole-publication-http.mjs';
import {CloudService} from '../src/service.mjs';
import {PostgresStore} from '../src/postgres-store.mjs';
import {publicOperationError} from '../src/service-error.mjs';
import {loadConfig} from '../src/config.mjs';
import {withDB,seedPublishedVault,requestFor,prepareWholeFixture,uploadWholeFixture} from './whole-publication-fixtures.mjs';
import {uuid} from './vault-v2-migration-fixtures.mjs';
const headers={'content-type':'application/json','authorization':'Bearer LOCAL-SYNTHETIC-SESSION','x-vault-schema-version':'2','x-vault-capability':'resource_acl_v2','x-publication-version':'1'};
const database=process.env.TEST_DATABASE_URL;
test('whole publication expected conflicts are typed safe HTTP results',()=>{
  for(const [code,status] of Object.entries({invalid_migration_checkpoint:400,access_group_conflict:409,access_group_member_scope_or_epoch_invalid:409,publication_upload_conflict:409})){
    const error=Object.assign(Error(code),{code});assert.deepEqual(publicOperationError(error),{code,status});
  }
});
async function http(service,session,work){
  const server=createServer(async(req,res)=>{try{
    if(req.headers.authorization!==headers.authorization){res.writeHead(401);res.end(JSON.stringify({error:'unauthorized'}));return;}
    const url=new URL(req.url,'http://127.0.0.1'),route=wholePublicationRoute(url.pathname,req.method);if(!route){res.writeHead(404);res.end();return;}
    const result=await runWholePublicationRoute(req,url,session,service,route);res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify(result));
  }catch(e){const error=publicOperationError(e);res.writeHead(error?.status??500,{'content-type':'application/json'});res.end(JSON.stringify({error:error?.code??'internal_error'}));}});
  server.listen(0,'127.0.0.1');await once(server,'listening');try{await work('http://127.0.0.1:'+server.address().port);}finally{await new Promise(r=>server.close(r));}
}
const environment={DATABASE_URL:'postgres://example.invalid/test',SESSION_TOKEN_PEPPER:'s'.repeat(32),EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),TEAM_INVITATION_TOKEN_PEPPER:'t'.repeat(32),TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),ABUSE_TOKEN_PEPPER:'a'.repeat(32),PROXY_SHARED_SECRET:'b'.repeat(64)};
test('whole publication configuration defaults OFF; distinct secret and explicit staging reader/allowlist required',()=>{
  assert.equal(loadConfig(environment).wholePublication.enabled,false);
  assert.throws(()=>loadConfig({...environment,WHOLE_PUBLICATION_ENABLED:'true',WHOLE_PUBLICATION_PREVIEW_SECRET:'w'.repeat(32)}),/staging reader/);
  const enabled={...environment,WHOLE_PUBLICATION_ENABLED:'true',WHOLE_PUBLICATION_PREVIEW_SECRET:'w'.repeat(32),PUBLICATION_READER_ENABLED:'true',PUBLICATION_ENVIRONMENT:'staging',PUBLICATION_CURSOR_SECRET:'c'.repeat(32),PUBLICATION_ALLOWED_VAULT_IDS:'12345678-1234-4234-a234-123456789012'};
  assert.equal(loadConfig(enabled).wholePublication.enabled,true);
  assert.throws(()=>loadConfig({...enabled,WHOLE_PUBLICATION_PREVIEW_SECRET:enabled.PUBLICATION_CURSOR_SECRET}),/independent/);
  assert.throws(()=>loadConfig({...enabled,PUBLICATION_ENVIRONMENT:'production'}),/staging/);
});
test('actual HTTP authenticates service actor, rejects forged body/old client/oversized/query and preserves read-only preview',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),store=new PostgresStore(null,pool),config={wholePublication:{...f.config,previewSecret:'test-whole-preview-secret-32-bytes'}},service=new CloudService(store,config),session={user_id:f.accountID,device_id:f.deviceID,session_id:f.sessionID};
  await http(service,session,async base=>{
    const path=base+'/v1/teams/'+f.input.teamID+'/publication/',request=requestFor(f);
    const fetchJSON=async(tail,body,extra={})=>{const response=await fetch(path+tail,{method:body===undefined?'GET':'POST',headers:{...headers,...extra},...(body===undefined?{}:{body:typeof body==='string'?body:JSON.stringify(body)})});return {status:response.status,value:await response.json()};};
    const context=await fetchJSON('context');assert.equal(context.status,200);assert.equal(context.value.sessionID,f.sessionID);assert.equal(context.value.actorKeyVersion,1);
    const p=await fetchJSON('preview',{request});assert.equal(p.status,200);assert.equal(p.value.binding.actorAccountID,f.accountID);
    const next=await fetchJSON('preview',{request,token:p.value.token});assert.equal(next.status,200);assert.equal(next.value.token,p.value.token);
    assert.equal((await fetchJSON('preview',{request,actorUserID:f.accountID})).status,400);
    assert.equal((await fetchJSON('preview',{request},{'x-vault-schema-version':'1'})).status,409);
    assert.equal((await fetchJSON('preview',{request},{authorization:'Bearer forged'})).status,401);
    assert.equal((await fetchJSON('preview',JSON.stringify({request,padding:'x'.repeat(1024*1024)}))).status,413);
    assert.equal((await fetchJSON('context?scope=other')).status,400);
    const started=await fetchJSON('start',{request,token:p.value.token});assert.equal(started.status,200);
    assert.equal((await fetchJSON('operations/'+request.operationID+'/receipt')).value,null);
    assert.equal((await fetchJSON('operations/'+request.operationID+'/discard',{})).value.state,'DISCARDED');
  });
  assert.strictEqual(store.wholePublication(config.wholePublication),store.wholePublication(config.wholePublication));
}));
test('disabled/default, production or off-allowlist whole runtime never exposes ACTIVE mutation',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),store=new PostgresStore(null,pool),session={user_id:f.accountID,device_id:f.deviceID,session_id:f.sessionID};
  for(const config of [{},{...f.config,environment:'production',previewSecret:'x'.repeat(32)},{...f.config,allowedVaultIDs:[],previewSecret:'x'.repeat(32)}]){
    const service=new CloudService(store,{wholePublication:config});
    await assert.rejects(service.wholePublication(session,f.input.teamID,'context',{}, {schemaVersion:2,capability:'resource_acl_v2',publicationVersion:1}),/publication_staging_only/);
  }
}));
test('owned READY recovery context survives authenticated session renewal without exempting another operation',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),store=new PostgresStore(null,pool),config={wholePublication:{...f.config,previewSecret:'recovery-context-preview-secret-32-bytes'}},service=new CloudService(store,config),s=store.wholePublication(config.wholePublication),request=requestFor(f),p=await s.preview(f.input,request),out=await prepareWholeFixture(f,p);
  await uploadWholeFixture(s,f,p,out);
  const sessionID=uuid();await pool.query("INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day')",[sessionID,f.accountID,f.deviceID,uuid()]);
  await http(service,{user_id:f.accountID,device_id:f.deviceID,session_id:sessionID},async base=>{
    const path=base+'/v1/teams/'+f.input.teamID+'/publication/';
    assert.equal((await fetch(path+'context',{headers})).status,409);
    const response=await fetch(path+'operations/'+request.operationID+'/context',{headers});assert.equal(response.status,200);
    const context=await response.json();assert.equal(context.sessionID,sessionID);assert.equal(context.actorKeyVersion,1);assert.equal(context.current[0].generationID,f.scope.attemptID);
    assert.equal((await fetch(path+'operations/'+uuid()+'/context',{headers})).status,404);
    assert.equal((await fetch(path+'operations/'+request.operationID+'/context?other=1',{headers})).status,400);
    const discard=await fetch(path+'operations/'+request.operationID+'/discard',{method:'POST',headers,body:'{}'});assert.equal(discard.status,200);
    assert.equal((await fetch(path+'context',{headers})).status,200);
  });
}));
test('committed owned recovery exposes only receipt metadata after mutation role and custody loss',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),store=new PostgresStore(null,pool),config={wholePublication:{...f.config,previewSecret:'committed-recovery-preview-secret-32-bytes'}},service=new CloudService(store,config),s=store.wholePublication(config.wholePublication),request=requestFor(f),p=await s.preview(f.input,request),out=await prepareWholeFixture(f,p);
  await uploadWholeFixture(s,f,p,out);const receipt=await s.commit(f.input,request.operationID,p.token,request);
  await pool.query("UPDATE team_memberships SET role='viewer' WHERE id=$1",[f.recipient.membershipID]);
  await pool.query('DELETE FROM team_membership_device_admissions WHERE device_id=$1',[f.deviceID]);
  const sessionID=uuid();await pool.query("INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day')",[sessionID,f.accountID,f.deviceID,uuid()]);
  await http(service,{user_id:f.accountID,device_id:f.deviceID,session_id:sessionID},async base=>{
    const path=base+'/v1/teams/'+f.input.teamID+'/publication/';
    assert.notEqual((await fetch(path+'context',{headers})).status,200);
    const response=await fetch(path+'operations/'+request.operationID+'/context',{headers});assert.equal(response.status,200);
    assert.deepEqual(await response.json(),{teamID:f.input.teamID,publicationAvailable:true,environment:'staging',sessionID,actorKeyVersion:1,operationState:'COMMITTED',recoveryOnly:true,actorRole:null,groups:[],edges:[],memberships:[],current:receipt.vaults.map(v=>({...v,teamID:f.input.teamID,resources:[],policy:[],custodianDeviceIDs:[]}))});
    const recovered=await fetch(path+'operations/'+request.operationID+'/receipt',{headers});assert.equal(recovered.status,200);assert.deepEqual(await recovered.json(),receipt);
    assert.notEqual((await fetch(path+'operations/'+request.operationID+'/readback/'+f.input.vaultID,{headers})).status,200);
    assert.equal((await fetch(path+'operations/'+uuid()+'/context',{headers})).status,404);
  });
}));
