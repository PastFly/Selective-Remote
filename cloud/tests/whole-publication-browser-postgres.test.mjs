import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {once} from 'node:events';
import {withDB,seedPublishedVault,seedPublishedTeam} from './whole-publication-fixtures.mjs';
import {CloudService} from '../src/service.mjs';
import {PostgresStore} from '../src/postgres-store.mjs';
import {publicOperationError} from '../src/service-error.mjs';
import {wholePublicationRoute,runWholePublicationRoute} from '../src/whole-publication-http.mjs';
import {createWholePublicationTransport} from '../public/whole-publication-api.js';
import {createWholePublicationAccessDriver} from '../public/whole-publication-flow.js';
import {createWholePublicationCheckpointRepository} from '../public/whole-publication-client.js';

import {legacy,record} from './vault-v2-migration-fixtures.mjs';
const database=process.env.TEST_DATABASE_URL;
async function browser(pool,{multiple=false,repeatConsent=false,loseFinalAck=false}={}) {
 const f=multiple?(await seedPublishedTeam(pool,2)).f:await seedPublishedVault(pool,loseFinalAck?{document:legacy([record('host',{title:'large retry',hostname:'test.example',notes:'x'.repeat(350000)})])}:{}),service=new CloudService(new PostgresStore(null,pool),{wholePublication:{...f.config,previewSecret:'real-browser-preview-secret-32-bytes'}}),session={user_id:f.accountID,device_id:f.deviceID,session_id:f.sessionID};
 const server=createServer(async(req,res)=>{try{
  const url=new URL(req.url,'http://127.0.0.1'),route=wholePublicationRoute(url.pathname,req.method);
  const result=await runWholePublicationRoute(req,url,session,service,route);res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify(result));
 }catch(e){const safe=publicOperationError(e);res.writeHead(safe?.status??500,{'content-type':'application/json'});res.end(JSON.stringify({error:safe?.code??'internal_error'}));}});
 server.listen(0,'127.0.0.1');await once(server,'listening');let driver,lost=false,completeReplays=0;
 const base='http://127.0.0.1:'+server.address().port,identity=()=>({endpoint:f.endpoint,accountID:f.accountID,deviceID:f.deviceID,sessionEpoch:'1'});
 const transport=createWholePublicationTransport({teamID:f.input.teamID,getIdentity:identity,request:async(path,options)=>{
  const response=await fetch(base+path,{...options,headers:{...options.headers,'content-type':'application/json'}});
  if(path.includes('/projection-chunks/')){const body=JSON.parse(options.body),result=await response.clone().json();
   if(result.complete&&body.index!==body.count-1)completeReplays++;
   if(loseFinalAck&&result.complete&&!lost){lost=true;throw new TypeError('synthetic lost final assembly acknowledgement');}
  }return response;
 }});
 // Reuse the approved token only in the isolated retry/checkpoint regressions;
 // the consent regression below uses the transport without this adapter.
 if(repeatConsent){const original=transport.preview;let token;transport.preview=async(request,options={})=>{const result=await original(request,options.token?options:token?{...options,token}:options);token??=result.token;return result;};}
 const records=new Map(),storage={async load(k){return structuredClone(records.get(k)??null);},async putIfAbsent(k,v){if(!records.has(k))records.set(k,structuredClone(v));return structuredClone(records.get(k));},async save(k,v){records.set(k,structuredClone(v));}};
 const histories=new Map(),historyKey=scope=>JSON.stringify([scope.endpoint,scope.accountID,scope.deviceID,scope.teamID,scope.vaultID]);
 const publicationRepository={loadHighWater:async scope=>structuredClone(histories.get(historyKey(scope))??null),
  advanceHighWater:async(scope,next,guard=()=>{})=>{guard();const key=historyKey(scope),old=histories.get(key);
   if(old&&(next.sequence<old.sequence||next.sequence===old.sequence&&next.hash!==old.hash))throw Error('publication_fork');histories.set(key,structuredClone(next));}};
 driver=createWholePublicationAccessDriver({transport,sessionIdentity:identity,checkpointRepository:createWholePublicationCheckpointRepository({storage}),publicationRepository,getLocalKeys:async()=>({root:f.root,identity:f.identity,pinnedTrust:f.pinnedTrust})});
 const scope={teamID:f.input.teamID,vaultID:f.input.vaultID};
 return {f,driver,scope,publicationRepository,async close(){driver.dispose();await new Promise(r=>server.close(r));},stats:()=>({lost,completeReplays})};
}
test('real Browser confirmation preserves approved consent through actual HTTP/PostgreSQL timestamps',{skip:!database},()=>withDB(async pool=>{
 const b=await browser(pool);try{
  await b.driver.getContext(b.scope);const approved=await b.driver.preview(b.scope,{type:'GROUP_CREATE',name:'Real confirmation'});
  await new Promise(r=>setTimeout(r,20));const receipt=await b.driver.commit(b.scope,approved);
  assert.equal(receipt.operationID,approved.request.operationID);
  for(const v of receipt.vaults)assert.deepEqual(await b.publicationRepository.loadHighWater({endpoint:b.f.endpoint,accountID:b.f.accountID,deviceID:b.f.deviceID,teamID:b.scope.teamID,vaultID:v.vaultID}),{sequence:v.sequence,hash:v.headerHash});
  assert.equal((await pool.query('SELECT count(*)::int n FROM team_publication_receipts WHERE operation_id=$1',[receipt.operationID])).rows[0].n,1);
 }finally{await b.close();}
}));
test('real Browser resumes a completed multi-chunk projection after losing its final acknowledgement',{skip:!database},()=>withDB(async pool=>{
 const b=await browser(pool,{repeatConsent:true,loseFinalAck:true});try{
  await b.driver.getContext(b.scope);const approved=await b.driver.preview(b.scope,{type:'GROUP_CREATE',name:'Retry confirmation'});
  await assert.rejects(b.driver.commit(b.scope,approved),/publication_network_unavailable/);
  const receipt=await b.driver.resumePrepared(b.scope);assert.equal(receipt.operationID,approved.request.operationID);assert.equal(b.stats().lost,true);assert.ok(b.stats().completeReplays>0);
 }finally{await b.close();}
}));
test('real Browser multi-Vault publication stores its shared protected checkpoint once',{skip:!database},()=>withDB(async pool=>{
 const b=await browser(pool,{multiple:true,repeatConsent:true});try{
  await b.driver.getContext(b.scope);const approved=await b.driver.preview(b.scope,{type:'GROUP_CREATE',name:'Shared checkpoint'});
  const receipt=await b.driver.commit(b.scope,approved);assert.equal(receipt.vaults.length,2);
  const row=(await pool.query('SELECT checkpoint FROM team_publication_operations WHERE id=$1',[receipt.operationID])).rows[0];
  assert.equal(Object.keys(row.checkpoint).length,1);
  assert.equal(Object.keys(row.checkpoint)[0],[...receipt.vaults].sort((a,b)=>a.vaultID.localeCompare(b.vaultID))[0].vaultID);
 }finally{await b.close();}
}));
