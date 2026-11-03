import {createSecureContext} from 'node:tls';
import {X509Certificate} from 'node:crypto';

// This prevents configuration mistakes, not a deceptive DNS alias or an
// operator placing two databases in one snapshot/failover domain.
export function loadFenceAnchorConfig(env,primaryURL){
 const names=['PUBLICATION_FENCE_ANCHOR_URL','PUBLICATION_FENCE_ANCHOR_ID','PUBLICATION_FENCE_ANCHOR_CA_BASE64'];
 if(names.every(name=>env[name]===undefined))return null;
 const fail=()=>{throw Error('invalid_deployment_anchor_configuration');};
 if(names.some(name=>typeof env[name]!=='string'||!env[name]))return fail();
 const [raw,id,encoded]=names.map(name=>env[name]);
 let anchor,primary,ca;
 try {
  anchor=new URL(raw);primary=new URL(primaryURL);
  if(!['postgres:','postgresql:'].includes(anchor.protocol)||!['postgres:','postgresql:'].includes(primary.protocol)
   ||!anchor.hostname||!anchor.username||!anchor.password||anchor.pathname==='/'||anchor.search||anchor.hash
   ||anchor.hostname===primary.hostname
   ||!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(id)
   ||encoded.length>22000||!/^[A-Za-z0-9+/]+={0,2}$/u.test(encoded))return fail();
  const bytes=Buffer.from(encoded,'base64');
  if(bytes.toString('base64')!==encoded||!bytes.length||bytes.length>16384)return fail();
  ca=bytes.toString('utf8');new X509Certificate(ca);createSecureContext({ca});
 }catch{return fail();}
 return Object.freeze({connectionString:raw,deploymentID:id,ca});
}
