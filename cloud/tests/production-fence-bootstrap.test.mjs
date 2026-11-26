import assert from 'node:assert/strict';
import test from 'node:test';
import {execFile} from 'node:child_process';
import {mkdir, mkdtemp, readdir, copyFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {promisify} from 'node:util';
import {bootstrapProductionFence} from '../scripts/bootstrap-production-fence.mjs';
import {isolatedPublicationDatabase} from './publication-runtime-fixture.mjs';
import {syntheticHttpAnchor, syntheticHttpAnchorAvailable} from './synthetic-http-anchor-fixture.mjs';
import {seedMigration} from './vault-v2-migration-db-fixtures.mjs';

const execute=promisify(execFile);
const database=process.env.TEST_DATABASE_URL;
test('separately restored schema 22 authorizes the first format 2 baseline with independent TLS anchor', {
  skip:!database || !syntheticHttpAnchorAvailable, timeout:120000,
}, async () => {
  const dir=await mkdtemp(join(tmpdir(),'sr-baseline-'));
  const prefix=join(dir,'migrations'),journal=join(dir,'journal'),source=fileURLToPath(new URL('../migrations/',import.meta.url));
  let db,restored,anchor;
  try {
    await mkdir(prefix);
    for(const name of await readdir(source)) if (/^\d{3}_.*\.sql$/.test(name) && Number(name.slice(0,3))<=22)
      await copyFile(join(source,name),join(prefix,name));
    db=await isolatedPublicationDatabase(database,{migrationsDirectory:prefix});
    restored=await isolatedPublicationDatabase(database,{migrationsDirectory:prefix});
    await seedMigration(db.pool);
    const backup=join(dir,'synthetic.dump');
    await execute(process.env.PG_DUMP_PATH??'pg_dump',['-Fc','--file',backup,'--dbname',db.databaseURL]);
    await execute(process.env.PG_RESTORE_PATH??'pg_restore',['--exit-on-error','--clean','--if-exists','--dbname',restored.databaseURL,backup]);
    await writeFile(journal,'',{mode:0o600});
    anchor=await syntheticHttpAnchor(journal);
    const run=(pool,mode,expectedDigest)=>bootstrapProductionFence({pool,fence:anchor.fence,mode,expectedDigest});
    const reference=await run(restored.pool,'inspect');
    assert.equal(reference.schemaVersion,22);
    assert.deepEqual(await run(db.pool,'check',reference.baselineDigest),reference);
    await assert.rejects(run(db.pool,'apply','0'.repeat(64)),/deployment_production_baseline_mismatch/);
    assert.deepEqual(await anchor.fence.readRecords(),[]);
    const expect={schemaVersion:23,writerFloor:1,teamAuthorizationProtocol:2};
    const partialFence={
      anchor:anchor.fence.anchor,readRecords:()=>anchor.fence.readRecords(),
      assertWritable:()=>anchor.fence.assertWritable(),append:async event=>{
        if (event.type==='V1_WRITER_FLOOR') throw Error('synthetic_interruption');
        await anchor.fence.append(event);
      },
    };
    await assert.rejects(bootstrapProductionFence({pool:db.pool,fence:partialFence,mode:'apply',expectedDigest:reference.baselineDigest}),
      /synthetic_interruption/);
    assert.equal((await anchor.fence.readRecords()).length,1);
    assert.deepEqual(await run(db.pool,'apply',reference.baselineDigest),expect);
    const records=await anchor.fence.readRecords();
    assert.deepEqual(records.map(row=>row.type),['V1_BASELINE','V1_WRITER_FLOOR','V1_TEAM_AUTHORIZATION_BASELINE']);
    assert.deepEqual(await run(db.pool,'apply',reference.baselineDigest),expect);
    assert.deepEqual(await anchor.fence.readRecords(),records);
    // An old restored DB must never receive fresh guards against a retained floor.
    await assert.rejects(run(restored.pool,'apply',reference.baselineDigest),/deployment_schema_floor/);
    assert.deepEqual(await anchor.fence.readRecords(),records);
  } finally {
    try {await anchor?.cleanup();} finally {
      try {await restored?.cleanup();} finally {
        try {await db?.cleanup();} finally {await rm(dir,{recursive:true,force:true});}
      }
    }
  }
});

test('controller compares the pinned backup digest before closure and finishes bootstrap with ingress closed', async () => {
  const {verifyControllerFixture}=await import('../scripts/verify-staging-controller.mjs');
  const {currentCapabilities}=await import('../src/deployment-compatibility.mjs');
  const {v1ProductionPersonalPilotVersion:unused,...rollback}=currentCapabilities;
  const forward={...rollback,v1ProductionPersonalPilotVersion:1};
  const pair={rollback:{sourceSHA:'1'.repeat(40),imageDigest:'sha256:'+'2'.repeat(64)},
    forward:{sourceSHA:'3'.repeat(40),imageDigest:'sha256:'+'4'.repeat(64)}};
  const candidate={...pair.forward,anchorProtocol:1,productionReleasePair:pair,registrationMode:'production-v1',
    productionBootstrapDigest:'5'.repeat(64)};
  async function scenario(action,failedStage){
    const stages=[];
    const promise=verifyControllerFixture({candidate,bootstrap:action,runCommand:async ({stage})=>{
      stages.push(stage);
      if (stage===failedStage) throw Error('fixture_denied');
      if(stage==='candidate-metadata')return forward;
      if(stage==='peer-metadata')return rollback;
      if(stage==='inspect-baseline')return {schemaVersion:22,baselineDigest:candidate.productionBootstrapDigest};
    }});
    if (failedStage) await assert.rejects(promise,/fixture_denied/); else await promise;
    return stages;
  }
  assert.deepEqual((await scenario('apply')).slice(5),['check-baseline','close-traffic','assert-closed','attest','apply-baseline','check','check']);
  assert.equal((await scenario('inspect')).at(-1),'inspect-baseline');
  assert.equal((await scenario('apply','check-baseline')).includes('close-traffic'),false);
  assert.equal((await scenario('apply','assert-closed')).includes('apply-baseline'),false);
  assert.equal((await scenario('apply','apply-baseline')).includes('open-traffic'),false);
});
