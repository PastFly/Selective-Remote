import assert from 'node:assert/strict';
import test from 'node:test';
import {createHash, randomUUID} from 'node:crypto';
import {mkdtemp, realpath, writeFile, readFile, chmod, symlink, rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {migrationHash} from '../src/migration-policy.mjs';
import {MigrationFence} from '../src/migration-fence.mjs';
import {createStagingActivationGuard,readStagingControllerIdentity} from '../src/staging-activation-policy.mjs';

async function fixture(work) {
  const directory = await realpath(await mkdtemp(join(tmpdir(), 'activation-policy-')));
  try {
    const controllerIdentity = {sourceSHA:'a'.repeat(40), imageDigest:`sha256:${'b'.repeat(64)}`, controllerDigest:'c'.repeat(64)};
    const teamID=randomUUID(), vaultID=randomUUID(), attemptID=randomUUID();
    const manifest={payload:{reader:{projectionHash:'d'.repeat(64)}},signature:'STORE_VALIDATES_SIGNATURE'};
    const manifestHash=await migrationHash(manifest);
    const name='TEST-ONLY-CODEX-run-1-vault';
    const backupPath=join(directory,'backup.dump'), attestationPath=join(directory,'restore.json'), policyPath=join(directory,'policy.json');
    const backup=Buffer.alloc(192*1024+3,61);
    await writeFile(backupPath,backup,{mode:0o600});
    const digest=createHash('sha256').update(backup).digest('hex');
    const attestation={formatVersion:1,isolatedRestoreVerified:true,backupSHA256:digest,controllerIdentity};
    const policy={formatVersion:1,environment:'staging',runID:'run-1',namePrefix:'TEST-ONLY-CODEX-run-1',
      vaults:[{teamID,vaultID,name}],confirmation:{attemptID,manifestHash},oldClientGateEnabled:true,
      controllerIdentity,backup:{path:backupPath,sha256:digest,restoreAttestationPath:attestationPath}};
    const save=async()=>{
      await writeFile(policyPath,JSON.stringify(policy),{mode:0o600});
      await writeFile(attestationPath,JSON.stringify(attestation),{mode:0o600});
    };
    await save();
    const payload={kind:'MIGRATION',input:{teamID,vaultID,attemptID},operationID:attemptID,
      vaults:[{teamID,vaultID,generationID:attemptID,sequence:1,headerHash:'e'.repeat(64),manifestHash}],
      manifests:[{vaultID,manifest}],snapshots:[{vaultID,snapshot:{}}],
      vaultMetadata:[{id:vaultID,team_id:teamID,name,format_state:'V1_ACTIVE'}]};
    const fencePath=join(directory,'fence.json');
    // Exercise the actual file-backed journal boundary, not a no-op fence fixture.
    const fence=new MigrationFence(fencePath);
    await writeFile(fencePath,'',{mode:0o600,flag:'wx'});
    const guard=createStagingActivationGuard({policyPath,fence,controllerIdentity});
    await work({directory,controllerIdentity,payload,policy,attestation,save,guard,policyPath,backupPath,attestationPath,fencePath,fence});
  } finally { await rm(directory,{recursive:true,force:true}); }
}

test('operator guard binds exact locked metadata, manifest, backup and retained writable fence',()=>fixture(async f=>{
  const before=await readFile(f.fencePath);
  assert.equal(await f.guard(f.payload),true);
  assert.deepEqual(await readFile(f.fencePath),before);
}));

for(const [label,change] of [
  ['actual renamed Vault',f=>{f.payload.vaultMetadata[0].name='ordinary';}],
  ['actual other Team',f=>{f.payload.vaultMetadata[0].team_id=randomUUID();}],
  ['actual other ID',f=>{f.payload.vaultMetadata[0].id=randomUUID();}],
  ['already V2 metadata',f=>{f.payload.vaultMetadata[0].format_state='V2_ACTIVE';}],
  ['multiple locked Vaults',f=>{f.payload.vaultMetadata.push({...f.payload.vaultMetadata[0]});}],
  ['missing signed reader projection',f=>{delete f.payload.manifests[0].manifest.payload.reader;}],
  ['different manifest',f=>{f.payload.manifests[0].manifest.payload.other='changed';}],
  ['different operation',f=>{f.payload.operationID=randomUUID();}],
  ['different journal generation',f=>{f.payload.vaults[0].generationID=randomUUID();}],
  ['floor19 projectionless activation',f=>{delete f.payload.vaults[0].generationID;f.payload.vaults[0].attemptID=f.payload.operationID;}],
  ['ordinary publication call',f=>{f.payload.kind='PUBLICATION';}],
  ['non-string run ID',f=>{f.policy.runID=12;f.policy.namePrefix='TEST-ONLY-CODEX-12';f.policy.vaults[0].name='TEST-ONLY-CODEX-12-vault';f.payload.vaultMetadata[0].name=f.policy.vaults[0].name;}],
  ['changed operator confirmation',f=>{f.policy.confirmation.attemptID=randomUUID();}],
  ['disabled old client gate',f=>{f.policy.oldClientGateEnabled=false;}],
  ['wrong deployed source',f=>{f.policy.controllerIdentity={...f.policy.controllerIdentity,sourceSHA:'f'.repeat(40)};}],
  ['different restore source',f=>{f.attestation.controllerIdentity={...f.attestation.controllerIdentity,controllerDigest:'f'.repeat(64)};}],
  ['unverified isolated restore',f=>{f.attestation.isolatedRestoreVerified=false;}],
  ['different restored backup',f=>{f.attestation.backupSHA256='f'.repeat(64);}],
  ['ordinary name allowed by ID only',f=>{f.policy.vaults[0].name='ordinary';f.payload.vaultMetadata[0].name='ordinary';}],
]) test(`operator guard rejects ${label}`,()=>fixture(async f=>{
  change(f);await f.save();await assert.rejects(f.guard(f.payload),/staging_activation_/);
}));

test('operator policy is re-read for every activation, without a permissive cached decision',()=>fixture(async f=>{
  assert.equal(await f.guard(f.payload),true);
  f.policy.confirmation.manifestHash='f'.repeat(64);await f.save();
  await assert.rejects(f.guard(f.payload),/staging_activation_/);
}));

test('backup corruption, missing file, unsafe policy modes and symlinks fail closed',()=>fixture(async f=>{
  await writeFile(f.backupPath,'damaged');
  await assert.rejects(f.guard(f.payload),/staging_activation_backup_invalid/);
  await rm(f.backupPath);
  await assert.rejects(f.guard(f.payload),/staging_activation_/);
  await chmod(f.policyPath,0o644);
  await assert.rejects(f.guard(f.payload),/staging_activation_/);
  await chmod(f.policyPath,0o600);
  const link=join(f.directory,'link.json');await symlink(f.policyPath,link);
  const linked=createStagingActivationGuard({policyPath:link,fence:f.fence,controllerIdentity:f.controllerIdentity});
  await assert.rejects(linked(f.payload),/staging_activation_/);
}));

test('empty dump cannot be made valid by a matching operator hash',()=>fixture(async f=>{
  await writeFile(f.backupPath,'');
  const empty=createHash('sha256').update('').digest('hex');
  f.policy.backup.sha256=empty;f.attestation.backupSHA256=empty;await f.save();
  await assert.rejects(f.guard(f.payload),/staging_activation_backup_invalid/);
}));

test('missing actual fence fails without creating a replacement',()=>fixture(async f=>{
  await rm(f.fencePath);
  await assert.rejects(f.guard(f.payload),/staging_activation_fence_invalid/);
  await assert.rejects(readFile(f.fencePath),{code:'ENOENT'});
}));

test('guard cannot accept a request boolean in place of protected local operator evidence',()=>fixture(async f=>{
  await rm(f.attestationPath);
  Object.assign(f.payload,{isolatedRestoreVerified:true,oldClientGateEnabled:true,signedValidation:true});
  await assert.rejects(f.guard(f.payload),/staging_activation_/);
}));

test('pending durable intent blocks new activation even with complete operator evidence',()=>fixture(async f=>{
  const tuple=f.payload.vaults[0];
  await f.fence.intent({teamID:tuple.teamID,vaultID:tuple.vaultID,attemptID:f.payload.operationID,manifestHash:tuple.manifestHash,schemaFloor:19});
  await assert.rejects(f.guard(f.payload),/deployment_fence_pending/);
}));

test('installed controller identity is a strict protected file, not request metadata',()=>fixture(async f=>{
  const path=join(f.directory,'identity.json');await writeFile(path,JSON.stringify(f.controllerIdentity),{mode:0o600});
  const identity=await readStagingControllerIdentity(path);
  assert.deepEqual(identity,f.controllerIdentity);assert.equal(Object.isFrozen(identity),true);
  await chmod(path,0o644);await assert.rejects(readStagingControllerIdentity(path),/staging_activation_/);
  await chmod(path,0o600);await writeFile(path,JSON.stringify({...f.controllerIdentity,unverified:true}));
  await assert.rejects(readStagingControllerIdentity(path),/staging_activation_/);
  await writeFile(path,JSON.stringify({...f.controllerIdentity,sourceSHA:[f.controllerIdentity.sourceSHA]}));
  await assert.rejects(readStagingControllerIdentity(path),/staging_activation_/);
}));
