import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {once} from 'node:events';
import {publicOperationError} from '../src/service-error.mjs';

// Exercise the production route block without starting the process-wide server or database.
// Authentication is synthetic here; full-server authentication has separate integration coverage.
const source=await readFile(new URL('../src/server.mjs',import.meta.url),'utf8');
const start=source.indexOf('    const publicationRoute=');
const end=source.indexOf('    if (method === "POST" && url.pathname === "/v1/auth/logout")',start);
assert.ok(start>=0&&end>start,'production publication GET route anchors');
const route=new Function('request','response','url','method','session','service','handleOperation',source.slice(start,end));
const capabilities={'x-vault-schema-version':'2','x-vault-capability':'resource_acl_v2','x-publication-version':'1'};
const auth={authorization:'Bearer LOCAL-SYNTHETIC-SESSION'};
const routes=['header','publisher','directory','resources/12345678-1234-4234-a234-123456789012/parts/SECRET'];

async function withRoute(work){
  const calls=[],session={session_id:'synthetic'};
  const service={getPublication:async(...args)=>{calls.push(args);return {delivered:true};}};
  const send=(res,status,value)=>{res.writeHead(status,{'content-type':'application/json'});res.end(JSON.stringify(value));};
  const handleOperation=async(res,operation)=>{try{send(res,200,await operation());}catch(e){const error=publicOperationError(e);send(res,error?.status??500,{error:error?.code??'internal_error'});}};
  const server=createServer((req,res)=>{
    if(req.headers.authorization!==auth.authorization)return send(res,401,{error:'unauthorized'});
    return route(req,res,new URL(req.url,'http://127.0.0.1'),req.method,session,service,handleOperation);
  });
  server.listen(0,'127.0.0.1');await once(server,'listening');
  try{await work(`http://127.0.0.1:${server.address().port}/v1/teams/team/vaults/vault/publication/`,calls,session);}
  finally{await new Promise(resolve=>server.close(resolve));}
}

test('publication GET requires all exact capabilities before delivering any route',()=>withRoute(async(base,calls)=>{
  const variants=[
    ['old 0.31 client',{}],
    ['old 0.32 client',{'x-vault-schema-version':'2','x-vault-capability':'resource_acl_v2'}],
    ['no capability',{'x-vault-schema-version':'2','x-publication-version':'1'}],
    ...Object.keys(capabilities).map(key=>[`missing ${key}`,Object.fromEntries(Object.entries(capabilities).filter(([name])=>name!==key))]),
    ...Object.keys(capabilities).flatMap(key=>['0','2, 2','unknown'].map(value=>[`invalid ${key}=${value}`,{...capabilities,[key]:value}])),
    ['old schema',{...capabilities,'x-vault-schema-version':'1'}],
    ['future publication',{...capabilities,'x-publication-version':'2'}],
  ];
  for(const tail of routes)for(const [name,headers]of variants){
    const response=await fetch(base+tail,{headers:{...auth,...headers}});
    assert.equal(response.status,409,`${tail}: ${name}`);
    assert.deepEqual(await response.json(),{error:'vault_upgrade_required'});
    assert.equal(calls.length,0,'capability mismatch must not reach delivery');
  }
}));

test('publication GET exact capabilities preserve authenticated routes and pinned query',()=>withRoute(async(base,calls,session)=>{
  for(const [index,tail]of routes.entries()){
    const query=index===0?'':'?generationID=generation&headerHash=hash'+(tail==='directory'?'&cursor=next&limit=5':'');
    const response=await fetch(base+tail+query,{headers:{...auth,...capabilities}});
    assert.equal(response.status,200);assert.deepEqual(await response.json(),{delivered:true});
    const [actualSession,teamID,vaultID,operation,input]=calls.at(-1);
    assert.equal(actualSession,session);assert.equal(teamID,'team');assert.equal(vaultID,'vault');
    assert.equal(operation,index===3?'part':tail);
    assert.deepEqual(input,index===0?{}:{generationID:'generation',headerHash:'hash',...(tail==='directory'?{cursor:'next',limit:5}:{}),...(index===3?{resourceID:'12345678-1234-4234-a234-123456789012',part:'SECRET'}:{})});
  }
  assert.equal(calls.length,4);
  const response=await fetch(base+'header',{headers:capabilities});assert.equal(response.status,401);assert.equal(calls.length,4);
}));
