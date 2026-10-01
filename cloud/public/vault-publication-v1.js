// Immutable reader projection. Trust pins and policy authorization are caller requirements.
import { canonicalMigrationJSON } from './vault-v2-migration.js';
import { validateResourceCipherEnvelope, validateResourceKeyWrapper } from './resource-crypto-v2.js';

const encoder=new TextEncoder(), uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const digest=/^[a-f0-9]{64}$/u, kinds=new Set(['HOST','CREDENTIAL','SNIPPET','FORWARDING','FOLDER']);
function fail(code='publication_invalid') { throw Error(code); }
function exact(value,keys) {
  if(!value || typeof value!=='object' || Array.isArray(value)
    || Object.keys(value).sort().join('\0')!==[...keys].sort().join('\0')) fail();
}
function id(value) { if(typeof value!=='string'||!uuid.test(value)) fail();return value; }
function hash(value) { if(typeof value!=='string'||!digest.test(value)) fail();return value; }
function positive(value) { if(!Number.isSafeInteger(value)||value<1) fail();return value; }
function b64(bytes) { let s='';for(const b of bytes)s+=String.fromCharCode(b);return btoa(s).replaceAll('+','-').replaceAll('/','_').replace(/=+$/u,''); }
function bytes(value,length) {
  if(typeof value!=='string'||!/^[A-Za-z0-9_-]+$/u.test(value))fail();
  let raw;try {raw=Uint8Array.from(atob(value.replaceAll('-','+').replaceAll('_','/')+'='.repeat((4-value.length%4)%4)),x=>x.charCodeAt(0));}catch{fail();}
  if(raw.length!==length||b64(raw)!==value)fail();return raw;
}
export function publicationBytes(purpose,value) {
  if(typeof purpose!=='string'||!/^[a-z-]+$/u.test(purpose))fail();
  return encoder.encode('selective-remote/publication/v1\0'+purpose+'\0'+canonicalMigrationJSON(value));
}
export async function publicationHash(purpose,value,cryptoValue=globalThis.crypto) {
  return Array.from(new Uint8Array(await cryptoValue.subtle.digest('SHA-256',publicationBytes(purpose,value))),x=>x.toString(16).padStart(2,'0')).join('');
}
async function sign(purpose,payload,root,cryptoValue) {
  return {payload,signature:b64(new Uint8Array(await cryptoValue.subtle.sign({name:'ECDSA',hash:'SHA-256'},root.privateKey,publicationBytes(purpose,payload))))};
}
async function verify(purpose,signed,rootPublicKey,cryptoValue) {
  exact(signed,['payload','signature']);
  const key=await cryptoValue.subtle.importKey('raw',bytes(rootPublicKey,65),{name:'ECDSA',namedCurve:'P-256'},false,['verify']);
  if(!await cryptoValue.subtle.verify({name:'ECDSA',hash:'SHA-256'},key,bytes(signed.signature,64),publicationBytes(purpose,signed.payload)))fail('publication_signature_invalid');
}
function headerPayload(p) {
  exact(p,['version','teamID','vaultID','generationID','sequence','previousHash','descriptorCommitment',
    'publisherAccountID','publisherDeviceID','publisherKeyVersion']);
  if(p.version!==1)fail();['teamID','vaultID','generationID','publisherAccountID','publisherDeviceID'].forEach(k=>id(p[k]));
  positive(p.sequence);positive(p.publisherKeyVersion);hash(p.descriptorCommitment);
  if(p.sequence===1 ? p.previousHash!==null : !digest.test(p.previousHash))fail();
}
function descriptorPayload(p) {
  exact(p,['headerHash','resourceID','kind','part','parentFolderID','context','ciphertextHash','wrapperRoot']);
  hash(p.headerHash);id(p.resourceID);hash(p.ciphertextHash);hash(p.wrapperRoot);
  if(!kinds.has(p.kind)||!(p.kind==='CREDENTIAL'?['METADATA','SECRET']:['GENERAL']).includes(p.part))fail();
  if(p.parentFolderID!==null)id(p.parentFolderID);
  if(p.parentFolderID===p.resourceID)fail();
  if(p.context?.resourceID!==p.resourceID||p.context?.part!==p.part)fail();
  // Reuse the strict resource-context validator rather than inventing an AAD schema.
  validateResourceCipherEnvelope({formatVersion:2,algorithm:'AES-256-GCM',aadVersion:2,
    context:p.context,nonce:'AAAAAAAAAAAAAAAA',ciphertext:'AA',authTag:'AAAAAAAAAAAAAAAAAAAAAA'});
}
function wrapperEntry(entry) {
  exact(entry,['accountID','deviceKeyVersion','wrapper']);id(entry.accountID);positive(entry.deviceKeyVersion);
  validateResourceKeyWrapper(entry.wrapper);
  ['teamID','vaultID','resourceID','membershipID','deviceID'].forEach(k=>id(entry.wrapper.context[k]));
  return entry.wrapper.context.membershipID+'/'+entry.wrapper.context.deviceID;
}
async function leaf(entry,c) { wrapperEntry(entry);return publicationHash('wrapper-leaf',entry,c); }
async function parent(left,right,c) { return publicationHash('wrapper-parent',{left:hash(left),right:hash(right)},c); }
export async function wrapperCommitment(entries,cryptoValue=globalThis.crypto) {
  if(!Array.isArray(entries)||entries.length===0)fail('wrapper_set_empty');
  if(entries.length>10000)fail('publication_limit');
  const sorted=[...entries].sort((a,b)=>wrapperEntry(a)<wrapperEntry(b)?-1:wrapperEntry(a)>wrapperEntry(b)?1:0);
  if(new Set(sorted.map(wrapperEntry)).size!==sorted.length)fail('duplicate_wrapper');
  const levels=[await Promise.all(sorted.map(e=>leaf(e,cryptoValue)))];
  while(levels.at(-1).length>1) {
    const level=levels.at(-1),next=[];
    for(let n=0;n<level.length;n+=2)next.push(await parent(level[n],level[n+1]??level[n],cryptoValue));
    levels.push(next);
  }
  return {root:levels.at(-1)[0],items:sorted.map((entry,index)=>{
    let pos=index;const siblings=[];
    for(const level of levels.slice(0,-1)){siblings.push(level[pos^1]??level[pos]);pos=Math.floor(pos/2);}
    return {entry,proof:{index,total:sorted.length,siblings}};
  })};
}
export async function verifyWrapperProof({entry,proof,root,cryptoValue=globalThis.crypto}) {
  hash(root);exact(proof,['index','total','siblings']);
  if(!Number.isSafeInteger(proof.total)||proof.total<1||proof.total>10000
    ||!Number.isSafeInteger(proof.index)||proof.index<0||proof.index>=proof.total
    ||!Array.isArray(proof.siblings)||proof.siblings.length!==Math.ceil(Math.log2(proof.total)))fail('publication_wrapper_proof_invalid');
  let node=await leaf(entry,cryptoValue),position=proof.index,count=proof.total;
  for(const sibling of proof.siblings) {
    hash(sibling);
    if(position%2===0&&position+1===count&&sibling!==node)fail('publication_wrapper_proof_invalid');
    node=position%2===0?await parent(node,sibling,cryptoValue):await parent(sibling,node,cryptoValue);
    position=Math.floor(position/2);count=Math.ceil(count/2);
  }
  if(node!==root)fail('publication_wrapper_proof_invalid');return true;
}
export async function verifyReaderHeader({header,rootPublicKey,teamID,vaultID,highWater=null,cryptoValue=globalThis.crypto}) {
  exact(header,['payload','signature']);headerPayload(header.payload);
  if(header.payload.teamID!==teamID||header.payload.vaultID!==vaultID)fail('publication_scope_mismatch');
  await verify('header',header,rootPublicKey,cryptoValue);
  const currentHash=await publicationHash('header',header,cryptoValue);
  if(highWater){positive(highWater.sequence);hash(highWater.hash);
    if(header.payload.sequence<highWater.sequence)fail('publication_rollback');
    if(header.payload.sequence===highWater.sequence&&currentHash!==highWater.hash)fail('publication_fork');}
  return currentHash;
}
export async function verifyReaderDescriptor({descriptor,header,rootPublicKey,envelope,entry,proof,cryptoValue=globalThis.crypto}) {
  exact(descriptor,['payload','signature']);descriptorPayload(descriptor.payload);headerPayload(header.payload);
  const p=descriptor.payload;
  if(p.headerHash!==await publicationHash('header',header,cryptoValue)
    ||p.context.teamID!==header.payload.teamID||p.context.vaultID!==header.payload.vaultID)fail('publication_scope_mismatch');
  await verify('descriptor',descriptor,rootPublicKey,cryptoValue);
  if(envelope!==undefined){validateResourceCipherEnvelope(envelope);
    if(canonicalMigrationJSON(envelope.context)!==canonicalMigrationJSON(p.context)
      ||await publicationHash('ciphertext',envelope,cryptoValue)!==p.ciphertextHash)fail('publication_ciphertext_mismatch');}
  if(entry!==undefined){const w=entry.wrapper.context;
    if(['teamID','vaultID','resourceID','part','keyVersion'].some(k=>w[k]!==p.context[k]))fail('publication_scope_mismatch');
    await verifyWrapperProof({entry,proof,root:p.wrapperRoot,cryptoValue});}
  return publicationHash('descriptor',descriptor,cryptoValue);
}
export async function inventoryIdentities(descriptors,cryptoValue=globalThis.crypto) {
  if(!Array.isArray(descriptors)||descriptors.length>2000)fail('publication_limit');
  const items=await Promise.all(descriptors.map(async d=>{
    descriptorPayload(d.payload);return {resourceID:d.payload.resourceID,part:d.payload.part,
      descriptorHash:await publicationHash('descriptor',d,cryptoValue)};
  }));
  items.sort((a,b)=>identity(a)<identity(b)?-1:identity(a)>identity(b)?1:0);
  if(new Set(items.map(identity)).size!==items.length)fail('duplicate_descriptor');return items;
}
function identity(p) { return p.resourceID+'/'+p.part; }
function recipientKey(p) { return p.membershipID+'/'+p.deviceID; }
function validateRecipient(p) {
  ['accountID','deviceID','membershipID'].forEach(k=>id(p[k]));positive(p.membershipEpoch);positive(p.deviceKeyVersion);
}
export async function verifyReaderInventory({inventory,descriptors,header,rootPublicKey,subject,cryptoValue=globalThis.crypto}) {
  exact(inventory,['payload','signature']);const p=inventory.payload;
  exact(p,['headerHash','accountID','deviceID','membershipID','membershipEpoch','count','digest']);
  ['accountID','deviceID','membershipID'].forEach(k=>id(p[k]));positive(p.membershipEpoch);hash(p.headerHash);hash(p.digest);
  if(!Number.isSafeInteger(p.count)||p.count<0||p.count>2000)fail();
  if(['accountID','deviceID','membershipID','membershipEpoch'].some(k=>p[k]!==subject[k]))fail('publication_subject_mismatch');
  if(p.headerHash!==await publicationHash('header',header,cryptoValue))fail('publication_scope_mismatch');
  await verify('inventory',inventory,rootPublicKey,cryptoValue);
  if(p.count!==descriptors.length||p.digest!==await publicationHash('inventory-items',await inventoryIdentities(descriptors,cryptoValue),cryptoValue))fail('publication_incomplete');
  return true;
}
export async function prepareReaderProjection({scope,resources,objects,recipients,root,publisherAccountID,
  publisherDeviceID,publisherKeyVersion,sequence=1,previousHash=null,cryptoValue=globalThis.crypto}) {
  if(!Array.isArray(resources)||resources.length>1000||!Array.isArray(objects)
    ||objects.length>2000||!Array.isArray(recipients)||recipients.length>10000)fail('publication_limit');
  const resourceMap=new Map(resources.map(r=>[r.id,r]));if(resourceMap.size!==resources.length)fail('duplicate_resource');
  const targets=new Map();for(const r of recipients){validateRecipient(r);const key=recipientKey(r);
    if(targets.has(key)&&canonicalMigrationJSON(targets.get(key))!==canonicalMigrationJSON(r))fail('duplicate_recipient');targets.set(key,r);}
  if(resources.length===0&&targets.size===0)fail('publication_recipient_missing');
  const suppliedParts=new Set(objects.map(identity));
  const requiredParts=resources.flatMap(r=>(r.kind==='CREDENTIAL'?['METADATA','SECRET']:['GENERAL']).map(part=>r.id+'/'+part));
  if(suppliedParts.size!==objects.length||suppliedParts.size!==requiredParts.length||requiredParts.some(key=>!suppliedParts.has(key)))fail('publication_incomplete');
  const cores=[],commitments=[];let wrapperCount=0,totalBytes=0;
  for(const o of objects){const r=resourceMap.get(o.resourceID);if(!r)fail();validateResourceCipherEnvelope(o.envelope);
    totalBytes+=encoder.encode(canonicalMigrationJSON(o)).length;
    if(encoder.encode(canonicalMigrationJSON(o.envelope)).length>1024*1024||totalBytes>128*1024*1024)fail('publication_limit');
    if(!Array.isArray(o.wrappers)||(wrapperCount+=o.wrappers.length)>10000)fail('publication_limit');
    const entries=o.wrappers.map(wrapper=>{
      if(['teamID','vaultID','resourceID','part','keyVersion'].some(k=>wrapper.context[k]!==o.envelope.context[k]))fail('publication_scope_mismatch');
      const target=targets.get(recipientKey(wrapper.context));if(!target||target.membershipEpoch!==wrapper.context.membershipEpoch)fail('publication_recipient_missing');
      return {accountID:target.accountID,deviceKeyVersion:target.deviceKeyVersion,wrapper};});
    const commitment=await wrapperCommitment(entries,cryptoValue);
    const core={resourceID:r.id,kind:r.kind,part:o.part,parentFolderID:r.parentFolderID,
      context:o.envelope.context,ciphertextHash:await publicationHash('ciphertext',o.envelope,cryptoValue),wrapperRoot:commitment.root};
    descriptorPayload({headerHash:'0'.repeat(64),...core});
    if(core.context.teamID!==scope.teamID||core.context.vaultID!==scope.vaultID)fail('publication_scope_mismatch');
    cores.push(core);commitments.push(commitment);
  }
  const order=cores.map((_,i)=>i).sort((a,b)=>identity(cores[a])<identity(cores[b])?-1:identity(cores[a])>identity(cores[b])?1:0);
  if(new Set(cores.map(identity)).size!==cores.length)fail('duplicate_descriptor');
  const payload={version:1,teamID:scope.teamID,vaultID:scope.vaultID,generationID:scope.attemptID,sequence,
    previousHash,descriptorCommitment:await publicationHash('descriptors',order.map(i=>cores[i]),cryptoValue),
    publisherAccountID,publisherDeviceID,publisherKeyVersion};headerPayload(payload);
  const header=await sign('header',payload,root,cryptoValue),headerHash=await publicationHash('header',header,cryptoValue);
  const descriptors=[],byRecipient=new Map();
  if(resources.length===0) for(const [key,target] of targets) byRecipient.set(key,{target,descriptors:[],proofs:[]});
  for(const i of order){const descriptor=await sign('descriptor',{headerHash,...cores[i]},root,cryptoValue);descriptors.push(descriptor);
    for(const item of commitments[i].items){const key=recipientKey(item.entry.wrapper.context);
      if(!byRecipient.has(key))byRecipient.set(key,{target:targets.get(key),descriptors:[],proofs:[]});
      const row=byRecipient.get(key);row.descriptors.push(descriptor);row.proofs.push({resourceID:cores[i].resourceID,part:cores[i].part,...item});}}
  const inventories=[];
  for(const key of [...byRecipient.keys()].sort()){const row=byRecipient.get(key),t=row.target;
    const inventory=await sign('inventory',{headerHash,accountID:t.accountID,deviceID:t.deviceID,
      membershipID:t.membershipID,membershipEpoch:t.membershipEpoch,count:row.descriptors.length,
      digest:await publicationHash('inventory-items',await inventoryIdentities(row.descriptors,cryptoValue),cryptoValue)},root,cryptoValue);
    inventories.push({inventory,proofs:row.proofs});}
  return {version:1,header,descriptors,recipients:inventories};
}
export async function validateReaderProjection({projection,scope,resources,objects,recipients,rootPublicKey,
  cryptoValue=globalThis.crypto}) {
  exact(projection,['version','header','descriptors','recipients']);if(projection.version!==1)fail();
  const headerHash=await verifyReaderHeader({header:projection.header,rootPublicKey,teamID:scope.teamID,vaultID:scope.vaultID,cryptoValue});
  if(projection.header.payload.generationID!==scope.attemptID||projection.header.payload.sequence!==1
    ||projection.header.payload.previousHash!==null)fail('publication_scope_mismatch');
  if(!Array.isArray(projection.descriptors)||projection.descriptors.length!==objects.length
    ||!Array.isArray(projection.recipients)||projection.recipients.length>10000)fail('publication_incomplete');
  const expected=new Map(objects.map(o=>[identity(o),o])),resourceMap=new Map(resources.map(r=>[r.id,r]));
  if(expected.size!==objects.length||resourceMap.size!==resources.length)fail();
  const targets=new Map(recipients.map(t=>[recipientKey(t),t])),cores=[],seen=new Set(),wrapperCoverage=new Set();
  for(const d of projection.descriptors){const key=identity(d.payload),o=expected.get(key),r=resourceMap.get(d.payload.resourceID);
    if(!o||!r||seen.has(key)||r.kind!==d.payload.kind||r.parentFolderID!==d.payload.parentFolderID)fail();seen.add(key);
    await verifyReaderDescriptor({descriptor:d,header:projection.header,rootPublicKey,envelope:o.envelope,cryptoValue});
    const entries=o.wrappers.map(wrapper=>{const t=targets.get(recipientKey(wrapper.context));if(!t)fail();return {accountID:t.accountID,deviceKeyVersion:t.deviceKeyVersion,wrapper};});
    if((await wrapperCommitment(entries,cryptoValue)).root!==d.payload.wrapperRoot)fail('publication_wrapper_mismatch');
    const {headerHash:ignored,...core}=d.payload;cores.push(core);}
  cores.sort((a,b)=>identity(a)<identity(b)?-1:identity(a)>identity(b)?1:0);
  if(projection.header.payload.descriptorCommitment!==await publicationHash('descriptors',cores,cryptoValue))fail('publication_descriptor_mismatch');
  const seenRecipients=new Set();
  for(const row of projection.recipients){exact(row,['inventory','proofs']);const p=row.inventory.payload,key=recipientKey(p),t=targets.get(key);
    if(!t||seenRecipients.has(key)||!Array.isArray(row.proofs)||(objects.length>0&&row.proofs.length<1)||row.proofs.length>2000)fail();seenRecipients.add(key);
    const ds=[];for(const item of row.proofs){exact(item,['resourceID','part','entry','proof']);
      const d=projection.descriptors.find(d=>identity(d.payload)===identity(item));if(!d)fail();
      if(item.entry.accountID!==t.accountID||item.entry.deviceKeyVersion!==t.deviceKeyVersion
        ||recipientKey(item.entry.wrapper.context)!==key||item.entry.wrapper.context.membershipEpoch!==t.membershipEpoch)fail('publication_subject_mismatch');
      await verifyReaderDescriptor({descriptor:d,header:projection.header,rootPublicKey,...item,cryptoValue});
      const coverage=identity(item)+'/'+key;if(wrapperCoverage.has(coverage))fail();wrapperCoverage.add(coverage);ds.push(d);}
    await verifyReaderInventory({inventory:row.inventory,descriptors:ds,header:projection.header,rootPublicKey,subject:t,cryptoValue});}
  if(objects.length===0&&(resources.length!==0||targets.size===0||seenRecipients.size!==targets.size))fail('publication_incomplete');
  const expectedCoverage=objects.reduce((n,o)=>n+o.wrappers.length,0);
  if(wrapperCoverage.size!==expectedCoverage)fail('publication_incomplete');return {headerHash};
}
