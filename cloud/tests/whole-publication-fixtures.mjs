import { seedMigration } from './vault-v2-migration-db-fixtures.mjs';
import { uuid, legacy, record } from './vault-v2-migration-fixtures.mjs';
import { VaultMigrationStore } from '../src/vault-migration-store.mjs';
import { prepareMigrationInventory, prepareLegacyMigration } from '../public/vault-v2-migration.js';

export async function seedPublishedVault(pool,{document=legacy([record('host',{title:'fixture',hostname:'test.example'})]),base=null}={}) {
  const f=base??await seedMigration(pool),s=new VaultMigrationStore(pool,f.config),preview=await s.preview(f.input);
  const scope={...f.scope,sourceRevision:preview.sourceRevision,sourceHash:preview.sourceHash,snapshotHash:preview.snapshotHash,policyVersion:preview.policyVersion};
  const inventory=await prepareMigrationInventory({...f,scope,document,persistCheckpoint:async()=>{}});
  const started=await s.start({...f.input,resources:inventory.resources});
  const out=await prepareLegacyMigration({...f,scope:started.scope,document,policy:started.policy,checkpoint:inventory.checkpoint,
    recipientTargets:(r,p)=>started.recipients[r.id][p],persistCheckpoint:async()=>{},
    readerPublication:{publisherAccountID:f.accountID,publisherKeyVersion:1,custodianDeviceIDs:[f.deviceID],custodianTargets:[f.recipient],
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
