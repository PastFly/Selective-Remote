import test from 'node:test';
import assert from 'node:assert/strict';
import {DeviceTrustStore} from '../src/device-trust-store.mjs';
import {createHash} from 'node:crypto';
import {generateTeamDeviceIdentity} from '../public/team-vault-crypto.js';
import {validateSignedDeviceBundle,validateSignedDeviceDirectory} from '../src/device-trust-policy.mjs';
import {issueDeviceCertificate,signDeviceDirectory} from '../public/device-trust-v1.js';
import {VaultPublicationStore} from '../src/vault-publication-store.mjs';
import {seedMigration,addSyntheticDevices} from './vault-v2-migration-db-fixtures.mjs';
import {withDB,seedPublishedVault,requestFor,storeFor,prepareWholeFixture,uploadWholeFixture} from './whole-publication-fixtures.mjs';
import {uuid} from './vault-v2-migration-fixtures.mjs';

// The legacy rotation flag on an active V2 Vault prevents even the surviving
// custodian from opening a repair preview. Exercise the signed production revoke.
for(const action of ['revoke','rekey'])test(`real device ${action} preserves legacy rotation and permits complete V2 successor repair`,{skip:!process.env.TEST_DATABASE_URL},()=>withDB(async pool=>{
  const base=await seedMigration(pool),[removed]=await addSyntheticDevices(pool,base,1);
  base.recipient.checkpoint=(await pool.query('SELECT directory_json FROM device_trust_directories_v1 WHERE account_id=$1 ORDER BY version DESC LIMIT 1',[base.accountID])).rows[0].directory_json;
  const f=await seedPublishedVault(pool,{base}),legacyID=uuid(),preparingID=uuid(),revokedSessionID=uuid();
  await pool.query("INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day')",[revokedSessionID,f.accountID,removed.deviceID,uuid()]);
  await pool.query("INSERT INTO shared_vaults(id,team_id,name,created_by_user_id) VALUES($1,$2,'legacy sibling',$3)",[legacyID,f.input.teamID,f.accountID]);
  await pool.query("INSERT INTO shared_vaults(id,team_id,name,created_by_user_id,format_state,format_schema_version) VALUES($1,$2,'preparing sibling',$3,'V2_PREPARING',2)",[preparingID,f.input.teamID,f.accountID]);
  const trust=new DeviceTrustStore(pool);
  if(action==='revoke'){
    const checkpoint=await signDeviceDirectory({root:f.root,accountID:f.accountID,version:3,certificates:[f.recipient.certificate]});
    const bundle=await validateSignedDeviceDirectory({rootPublicKey:f.root.publicKey,checkpoint,accountID:f.accountID});
    await trust.revokeDevice({accountID:f.accountID,actorDeviceID:f.deviceID,deviceID:removed.deviceID,checkpoint,bundle,idempotencyKey:uuid()});
  }else{
    const identity=await generateTeamDeviceIdentity(),requestID=uuid(),challengeID=uuid();
    const certificate=await issueDeviceCertificate({root:f.root,accountID:f.accountID,deviceID:removed.deviceID,publicKey:identity.publicKey,keyVersion:2,issuedAt:1800000001,serial:uuid()});
    const checkpoint=await signDeviceDirectory({root:f.root,accountID:f.accountID,version:3,certificates:[f.recipient.certificate,certificate]});
    const bundle=await validateSignedDeviceBundle({rootPublicKey:f.root.publicKey,certificate,checkpoint,accountID:f.accountID,deviceID:removed.deviceID,publicKey:identity.publicKey});
    await trust.createRequest({accountID:f.accountID,actorDeviceID:removed.deviceID,deviceID:removed.deviceID,requestID,publicKeyBytes:bundle.publicKeyBytes,publicKeyJSON:JSON.stringify(identity.publicKey),keyDigest:createHash('sha256').update(bundle.publicKeyBytes).digest(),keyVersion:2,idempotencyKey:uuid()});
    const challenge={version:1,accountID:f.accountID,requestID,deviceID:removed.deviceID,publicKey:identity.publicKey};
    await trust.startChallenge({accountID:f.accountID,actorDeviceID:f.deviceID,requestID,challengeID,challengeBytes:Buffer.from(JSON.stringify(challenge)),challenge,idempotencyKey:uuid()});
    await trust.answerChallenge({accountID:f.accountID,actorDeviceID:removed.deviceID,requestID,challengeID,proof:Buffer.alloc(32,7),idempotencyKey:uuid()});
    await trust.approveRequest({accountID:f.accountID,actorDeviceID:f.deviceID,requestID,challengeID,bundle,certificate,checkpoint,idempotencyKey:uuid()});
    assert.equal((await pool.query('SELECT key_version::int AS key_version FROM device_trust_revocations_v1 WHERE account_id=$1 AND device_id=$2',[f.accountID,removed.deviceID])).rows[0].key_version,1);
    assert.equal((await pool.query('SELECT device_id FROM team_membership_device_admissions WHERE device_id=$1',[removed.deviceID])).rowCount,0);
  }
  const reader=new VaultPublicationStore(pool,f.config),revokedInput={...f.input,actorDeviceID:removed.deviceID,sessionID:revokedSessionID};
  await assert.rejects(reader.header(f.input),/publication_repair_required/);
  await assert.rejects(reader.header(revokedInput),/publication_access_denied|team_not_found|publication_repair_required/);
  const s=storeFor(pool,f),request=requestFor(f),preview=await s.preview(f.input,request);
  const directory=await s.repairDirectory(f.input,preview.token,{request,vaultID:f.input.vaultID});
  assert.equal(directory.generationID,f.scope.attemptID);
  for(const object of [...f.out.objects,{resourceID:f.out.administrativeSidecar.resourceID,part:'ADMINISTRATIVE'}]){
    const repaired=await s.repairPart(f.input,preview.token,{request,vaultID:f.input.vaultID,resourceID:object.resourceID,part:object.part});
    assert.equal(repaired.entry.wrapper.context.deviceID,f.deviceID);
  }
  await assert.rejects(s.preview(revokedInput,request),action==='revoke'?/publication_session_invalid/:/migration_device_admission_required/);
  const out=await prepareWholeFixture(f,preview);
  for(const object of out.generations[0].objects){
    const prior=f.out.objects.find(o=>o.resourceID===object.resourceID&&o.part===object.part);
    assert.notEqual(object.envelope.ciphertext,prior.envelope.ciphertext);
  }
  assert.notEqual(out.generations[0].administrativeSidecar.envelope.ciphertext,f.out.administrativeSidecar.envelope.ciphertext);
  assert.ok(out.generations.every(g=>g.objects.every(o=>o.wrappers.every(w=>w.context.deviceID!==removed.deviceID))));
  await uploadWholeFixture(s,f,preview,out);await s.commit(f.input,request.operationID,preview.token,request);
  assert.equal((await reader.header(f.input)).header.payload.sequence,2);
  await assert.rejects(reader.header(revokedInput),/publication_access_denied|team_not_found/);
  const flags=(await pool.query('SELECT id,rotation_required FROM shared_vaults WHERE id=ANY($1::uuid[])',[[legacyID,preparingID,f.input.vaultID]])).rows;
  assert.equal(flags.find(v=>v.id===legacyID).rotation_required,true);
  assert.equal(flags.find(v=>v.id===preparingID).rotation_required,true);
  assert.equal(flags.find(v=>v.id===f.input.vaultID).rotation_required,false);
  const tasks=(await pool.query('SELECT vault_id FROM shared_vault_rotation_tasks WHERE removed_device_id=$1',[removed.deviceID])).rows;
  assert.deepEqual(tasks.map(t=>t.vault_id).sort(),[legacyID,preparingID].sort());
}));
