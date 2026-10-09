import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {runStagingMigration} from '../scripts/vault-v2-migration-staging.mjs';

const config={environment:'staging',enabled:true,allowedVaultIDs:[randomUUID()],
  databaseURL:'postgresql://invalid.invalid/unreachable',fencePath:'/tmp/unavailable-fence'};
test('activation refuses absent protected policy/installed identity before opening database',async()=>{
  await assert.rejects(runStagingMigration(config,{operation:'activate',input:{},manifestHash:'a'.repeat(64)}),
    /staging_activation_policy_required/);
});
test('reconciliation rejects malformed intent and caller-supplied outcome before DB access',async()=>{
  await assert.rejects(runStagingMigration(config,{operation:'reconcile-fence',intentID:'not-an-intent'}),/invalid_migration_operation/);
  await assert.rejects(runStagingMigration(config,{operation:'reconcile-fence',intentID:randomUUID(),confirmed:true}),/invalid_migration_operation/);
});
