import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {withDB,seedPublishedVault} from './whole-publication-fixtures.mjs';
import {seedMigration} from './vault-v2-migration-db-fixtures.mjs';
import {legacy,record} from './vault-v2-migration-fixtures.mjs';
import {VaultMigrationStore} from '../src/vault-migration-store.mjs';
import {prepareMigrationInventory,prepareLegacyMigration} from '../public/vault-v2-migration.js';
import {MigrationFence} from '../src/migration-fence.mjs';
import {runStagingMigration} from '../scripts/vault-v2-migration-staging.mjs';
const database=process.env.TEST_DATABASE_URL;
test('operator uploads signed reader projection and verifies reserved identities against actual PG rows', {skip:!database},()=>withDB(async pool=>{
  const f=await seedMigration(pool),store=new VaultMigrationStore(pool,f.config);
  const preview=await store.preview(f.input),document=legacy([record('host',{title:'operator fixture'})]);
  const scope={...f.scope,sourceRevision:preview.sourceRevision,sourceHash:preview.sourceHash,snapshotHash:preview.snapshotHash,policyVersion:preview.policyVersion};
  const inventory=await prepareMigrationInventory({...f,scope,document,persistCheckpoint:async()=>{}});
  const started=await store.start({...f.input,resources:inventory.resources});
  f.out=await prepareLegacyMigration({...f,scope:started.scope,document,policy:started.policy,checkpoint:inventory.checkpoint,
    recipientTargets:(r,p)=>started.recipients[r.id][p],persistCheckpoint:async()=>{},
    readerPublication:{publisherAccountID:f.accountID,publisherKeyVersion:1,custodianDeviceIDs:[f.deviceID],custodianTargets:[f.recipient],
      verifyIdentityReservations:resources=>store.verifyIdentityReservations({...f.input,resources})}});
  for(const object of f.out.objects)await store.putPart(f.input,object);
  const directory=await mkdtemp(join(tmpdir(),'operator-reader-'));
  try{
    const fencePath=join(directory,'fence');await writeFile(fencePath,'',{mode:0o600});
    const config={environment:'staging',enabled:true,allowedVaultIDs:[f.input.vaultID],databaseURL:database,fencePath};
    assert.equal(await runStagingMigration(config,{operation:'verify-identities',input:{...f.input,resources:f.out.resources}}),true);
    const result=await runStagingMigration(config,{operation:'upload-reader',input:f.input,
      projection:f.out.readerProjection,sidecar:f.out.administrativeSidecar,checkpoint:f.out.checkpoint});
    assert.ok(result);
  }finally{await rm(directory,{recursive:true,force:true});}
}));

test('operator positively reconciles retained legacy intent and exact replay without inventing abort', {skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),directory=await mkdtemp(join(tmpdir(),'operator-legacy-'));
  try{
    const fencePath=join(directory,'fence');await writeFile(fencePath,'',{mode:0o600});
    const fence=new MigrationFence(fencePath);
    const manifestHash=(await pool.query('SELECT manifest_hash FROM vault_migration_attempts WHERE id=$1',[f.input.attemptID])).rows[0].manifest_hash;
    await fence.intent({teamID:f.input.teamID,vaultID:f.input.vaultID,attemptID:f.input.attemptID,manifestHash,schemaFloor:20});
    const intentID=(await fence.snapshot()).pending[0].intentID;
    const config={environment:'staging',enabled:true,allowedVaultIDs:[f.input.vaultID],databaseURL:database,fencePath};
    const expected={status:'confirmed',intentID};
    assert.deepEqual(await runStagingMigration(config,{operation:'reconcile-fence',intentID}),expected);
    assert.deepEqual(await runStagingMigration(config,{operation:'reconcile-fence',intentID}),expected);
    assert.equal((await fence.snapshot()).pending.length,0);
    assert.equal((await fence.snapshot()).committed[0].manifestHash,manifestHash);
  }finally{await rm(directory,{recursive:true,force:true});}
}));
