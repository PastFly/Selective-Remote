import pg from 'pg';
import {fileURLToPath} from 'node:url';
import {applyMigrations} from '../src/migrations.mjs';
import {WholePublicationStore} from '../src/whole-publication-store.mjs';
import { seedMigration } from './vault-v2-migration-db-fixtures.mjs';
import { uuid, legacy, record } from './vault-v2-migration-fixtures.mjs';
import { VaultMigrationStore } from '../src/vault-migration-store.mjs';
import { prepareMigrationInventory, prepareLegacyMigration } from '../public/vault-v2-migration.js';

export async function seedPublishedVault(pool,{document=legacy([record('host',{title:'fixture',hostname:'test.example'})]),base=null,custodianDeviceIDs=null,custodianTargets=null,policyFor=null}={}) {
  const f=base??await seedMigration(pool),s=new VaultMigrationStore(pool,f.config),preview=await s.preview(f.input);
  const scope={...f.scope,sourceRevision:preview.sourceRevision,sourceHash:preview.sourceHash,snapshotHash:preview.snapshotHash,policyVersion:preview.policyVersion};
  const inventory=await prepareMigrationInventory({...f,scope,document,persistCheckpoint:async()=>{}});
  const started=await s.start({...f.input,resources:inventory.resources,...(policyFor?{policy:policyFor(inventory.resources,preview.snapshot)}:{})});
  const out=await prepareLegacyMigration({...f,scope:started.scope,document,policy:started.policy,checkpoint:inventory.checkpoint,
    recipientTargets:(r,p)=>started.recipients[r.id][p],persistCheckpoint:async()=>{},
    readerPublication:{publisherAccountID:f.accountID,publisherKeyVersion:1,custodianDeviceIDs:custodianDeviceIDs??[f.deviceID],custodianTargets:custodianTargets??[f.recipient],
      verifyIdentityReservations:resources=>s.verifyIdentityReservations({...f.input,resources})}});
  for(const object of out.objects)await s.putPart(f.input,object);
  await s.putReaderProjection(f.input,out.readerProjection,out.administrativeSidecar);
  await s.validate(f.input,out.manifest);await s.activate(f.input,await s.manifestHash(f.input));
  const sessionID=uuid();
  await pool.query('INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval \'1 day\')',[sessionID,f.accountID,f.deviceID,uuid()]);
  return {...f,out,started,input:{...f.input,sessionID},sessionID};
}

export async function insertSchemaOperation(pool,f) {
  const id=uuid(),request={version:1,operationID:id,teamID:f.input.teamID,vaults:[{vaultID:f.input.vaultID}]};
  const counts={vaults:1,resources:f.out.resources.length,parts:f.out.objects.length+1,wrappers:f.out.objects.length+1};
  await pool.query(`INSERT INTO team_publication_operations(id,team_id,actor_user_id,actor_device_id,session_id,actor_key_version,
    request_hash,request,prepared,counts,effective_at) VALUES($1,$2,$3,$4,$5,1,$6,$7,$8,$9,$10)`,
    [id,f.input.teamID,f.accountID,f.deviceID,f.sessionID,'a'.repeat(64),request,{},counts,'2026-10-02T00:00:00Z']);
  return id;
}

const database=process.env.TEST_DATABASE_URL;
export async function withDB(work){
  const target=new URL(database);
  if(!['postgres:','postgresql:'].includes(target.protocol)||!['127.0.0.1','localhost','[::1]'].includes(target.hostname)||!target.pathname.endsWith('_test')||target.search)throw Error('disposable_test_database_required');
  const pool=new pg.Pool({connectionString:database});
  try{await applyMigrations(pool,fileURLToPath(new URL('../migrations/',import.meta.url)),{info(){}});await work(pool);}finally{await pool.end();}
}
export function requestFor(f){return {version:1,teamID:f.input.teamID,operationID:uuid(),groupMutation:null,
  vaults:[{vaultID:f.input.vaultID,resources:f.out.resources,policy:f.started.policy,contentChanges:[],custodianDeviceIDs:[f.deviceID]}]};}
export function storeFor(pool,f,extra={}){return new WholePublicationStore(pool,{...f.config,previewSecret:'synthetic-local-test-secret-32-bytes',...extra});}

export async function prepareWholeFixture(f,preview){
  const {prepareWholePublication,createWholePublicationCheckpointRepository}=await import('../public/whole-publication-client.js');
  const {unwrapResourceCEK,decryptResourcePart}=await import('../public/resource-crypto-v2.js');
  const open=async object=>{
    const wrapper=object.wrappers.find(w=>w.context.deviceID===f.deviceID);
    const cek=await unwrapResourceCEK({wrapper,context:wrapper.context,privateKey:f.identity.privateKey});
    try{return JSON.parse(new TextDecoder().decode(await decryptResourcePart({envelope:object.envelope,context:object.envelope.context,cek})));}finally{cek.fill(0);}
  };
  const plaintextByVault={},administrativeByVault={};
  for(const source of f.vaults??[f]){
    const predecessor=preview.binding.predecessors.find(p=>p.vaultID===source.input.vaultID),parts={};
    for(const o of source.out.objects){parts[o.resourceID]??={};parts[o.resourceID][o.part]=await open(o);}
    plaintextByVault[source.input.vaultID]={verified:true,predecessor,parts};
    administrativeByVault[source.input.vaultID]={verified:true,predecessor,data:await open(source.out.administrativeSidecar)};
  }
  const records=new Map(),storage={async load(k){return structuredClone(records.get(k)??null);},async putIfAbsent(k,v){if(!records.has(k))records.set(k,structuredClone(v));return structuredClone(records.get(k));},async save(k,v){records.set(k,structuredClone(v));}};
  const checkpointRepository=createWholePublicationCheckpointRepository({storage});
  const getIdentity=()=>({endpoint:f.endpoint,accountID:f.accountID,deviceID:f.deviceID,sessionID:f.sessionID,keyVersion:1,predecessors:preview.binding.predecessors});
  return prepareWholePublication({...f,pinnedTrust:f.publicationPins??f.pinnedTrust,preview,plaintextByVault,administrativeByVault,checkpointRepository,getIdentity});
}
export async function uploadWholeFixture(s,f,preview,out){
  await s.start(f.input,preview.token,preview.request);
  for(const g of out.generations){
    for(const o of g.objects)await s.putPart(f.input,out.request.operationID,g.vaultID,o);
    await s.putProjection(f.input,out.request.operationID,g.vaultID,g.readerProjection,g.administrativeSidecar,{version:out.checkpoint.version,nonce:out.checkpoint.nonce,ciphertext:out.checkpoint.ciphertext});
  }
  return s.validate(f.input,out.request.operationID,out.generations.map(g=>({vaultID:g.vaultID,manifest:g.manifest})));
}

export async function seedPublishedTeam(pool,count=2){
  const first=await seedPublishedVault(pool),vaults=[first];
  for(let i=1;i<count;i++){
    const vaultID=uuid(),attemptID=uuid();
    await pool.query("INSERT INTO shared_vaults(id,team_id,name,created_by_user_id,revision,envelope_version,ciphertext,nonce,auth_tag,content_hash,updated_by_device_id) VALUES($1,$2,$6,$3,1,1,'LEGACY_ENCRYPTED_DATA','AAAAAAAAAAAAAAAA','AAAAAAAAAAAAAAAAAAAAAA',$4,$5)",[vaultID,first.input.teamID,first.accountID,'A'.repeat(43),first.deviceID,'synthetic additional '+i]);
    const base={...first,scope:{...first.scope,vaultID,attemptID},input:{...first.input,vaultID,attemptID},config:{...first.config,allowedVaultIDs:[vaultID]}};
    vaults.push(await seedPublishedVault(pool,{base}));
  }
  first.config={...first.config,allowedVaultIDs:vaults.map(v=>v.input.vaultID)};first.vaults=vaults;
  const request=requestFor(first);request.vaults=vaults.flatMap(v=>requestFor(v).vaults);
  return {f:first,request};
}
