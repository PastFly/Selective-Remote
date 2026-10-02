import test from 'node:test';
import assert from 'node:assert/strict';
import {seedPublishedVault,withDB,requestFor,storeFor} from './whole-publication-fixtures.mjs';
import {uuid,legacy,record} from './vault-v2-migration-fixtures.mjs';
import {VaultPublicationStore} from '../src/vault-publication-store.mjs';
import {seedMigration,addSyntheticDevices} from './vault-v2-migration-db-fixtures.mjs';
import {wholeHash} from '../src/whole-publication-snapshot.mjs';
import {publicationHash} from '../public/vault-publication-v1.js';

const database=process.env.TEST_DATABASE_URL;
test('whole preview is read-only and every signed page exhausts complete rows',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool,{document:legacy(Array.from({length:101},(_,i)=>record('host',{title:'host '+i,hostname:'test.example'})))});
  const s=storeFor(pool,f),request=requestFor(f),before=(await pool.query('SELECT count(*)::int AS n FROM team_publication_operations')).rows[0].n;
  let preview=await s.preview(f.input,request),rows=[...preview.rows],cursor=preview.nextCursor;
  assert.equal(preview.rows.length,100);assert.ok(cursor);
  while(cursor){const page=await s.preview(f.input,request,{token:preview.token,cursor});assert.equal(page.token,preview.token);assert.ok(page.rows.length<=100);rows.push(...page.rows);cursor=page.nextCursor;}
  assert.equal(rows.length,preview.binding.rowCount);assert.equal(wholeHash(rows),preview.binding.rowsHash);
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM team_publication_operations')).rows[0].n,before);
  assert.equal(preview.generations[0].sequence,2);assert.equal(preview.generations[0].previousHash,await publicationHash('header',f.out.readerProjection.header));
  await assert.rejects(s.preview(f.input,{...request,vaults:[]}),/publication_participating_vaults/);
  await assert.rejects(s.preview({...f.input,sessionID:uuid()},request),/publication_session_invalid/);
  await assert.rejects(s.preview(f.input,request,{token:preview.token,cursor:cursor??'unsigned'}),/invalid_access_page/);
}));
test('Owner/Admin ceiling, exact session and restart are fail closed',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),s=storeFor(pool,f),request=requestFor(f),p=await s.preview(f.input,request);
  await assert.rejects(storeFor(pool,f).preview(f.input,request,{token:p.token}),/preview_invalidated/);
  for(const role of ['editor','viewer']){
    await pool.query('UPDATE team_memberships SET role=$2 WHERE id=$1',[f.recipient.membershipID,role]);
    await assert.rejects(s.preview(f.input,request),/team_access_denied/);
  }
  await pool.query("UPDATE team_memberships SET role='owner' WHERE id=$1",[f.recipient.membershipID]);
  await pool.query("UPDATE sessions SET expires_at=now()-interval '1 second' WHERE id=$1",[f.sessionID]);
  await assert.rejects(s.preview(f.input,request),/publication_session_invalid/);
}));
test('repair binds fresh current read-set and only the same surviving custodian wrapper',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),s=storeFor(pool,f),request=requestFor(f);
  // A real policy phantom makes ordinary reads fail; repair never removes that guard.
  await pool.query("INSERT INTO team_access_groups(id,team_id,name,created_by_user_id) VALUES($1,$2,'new group',$3)",[uuid(),f.input.teamID,f.accountID]);
  await assert.rejects(new VaultPublicationStore(pool,f.config).header(f.input),/publication_repair_required/);
  const p=await s.preview(f.input,request),page=await s.repairDirectory(f.input,p.token,{request,vaultID:f.input.vaultID});
  assert.equal(page.descriptors.length,1);assert.equal(page.generationID,f.scope.attemptID);
  const r=f.out.resources[0],part=await s.repairPart(f.input,p.token,{request,vaultID:f.input.vaultID,resourceID:r.id,part:'GENERAL'});
  assert.equal(part.entry.wrapper.context.deviceID,f.deviceID);assert.equal(part.headerHash,await publicationHash('header',f.out.readerProjection.header));
  const sidecar=await s.repairPart(f.input,p.token,{request,vaultID:f.input.vaultID,resourceID:f.out.administrativeSidecar.resourceID,part:'ADMINISTRATIVE'});
  assert.equal(sidecar.wrappers,undefined);assert.equal(sidecar.entry.wrapper.context.deviceID,f.deviceID);
  await pool.query("INSERT INTO team_access_groups(id,team_id,name,created_by_user_id) VALUES($1,$2,'second change',$3)",[uuid(),f.input.teamID,f.accountID]);
  await assert.rejects(s.repairPart(f.input,p.token,{request,vaultID:f.input.vaultID,resourceID:r.id,part:'GENERAL'}),/preview_invalidated/);
}));
test('repair survives another device revocation but denies own revoke, expiry and new admission',{skip:!database},()=>withDB(async pool=>{
  const base=await seedMigration(pool),others=await addSyntheticDevices(pool,base,1);
  base.recipient.checkpoint=(await pool.query("SELECT directory_json FROM device_trust_directories_v1 WHERE account_id=$1 ORDER BY version DESC LIMIT 1",[base.accountID])).rows[0].directory_json;
  const f=await seedPublishedVault(pool,{base});
  let now=Date.now();const s=storeFor(pool,f,{clock:()=>now,ttlMS:5000}),request=requestFor(f);
  await pool.query('UPDATE devices SET revoked_at=now() WHERE id=$1',[others[0].deviceID]);
  await assert.rejects(new VaultPublicationStore(pool,f.config).header(f.input),/publication_repair_required/);
  const p=await s.preview(f.input,request),r=f.out.resources[0];
  const part=await s.repairPart(f.input,p.token,{request,vaultID:f.input.vaultID,resourceID:r.id,part:'GENERAL'});
  assert.equal(part.entry.wrapper.context.deviceID,f.deviceID);
  now+=5000;await assert.rejects(s.repairDirectory(f.input,p.token,{request,vaultID:f.input.vaultID}),/preview_expired/);
  const fresh=await s.preview(f.input,request);await pool.query('DELETE FROM team_membership_device_admissions WHERE device_id=$1',[f.deviceID]);
  await assert.rejects(s.repairDirectory(f.input,fresh.token,{request,vaultID:f.input.vaultID}),/migration_device_admission_required/);
}));
test('group CREATE projects exact timestamps/versions without writing reusable Team rows',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),s=storeFor(pool,f),request=requestFor(f),groupID=uuid();request.groupMutation={action:'CREATE',groupID,name:'Operators'};
  const p=await s.preview(f.input,request),snapshot=p.generations[0].snapshot,group=snapshot.raw.groups.find(g=>g.id===groupID);
  assert.equal(group.created_at,p.binding.effectiveAt);assert.equal(group.version,1);assert.equal(snapshot.raw.teamPolicy[0].revision,1);
  assert.equal((await pool.query('SELECT id FROM team_access_groups WHERE id=$1',[groupID])).rows.length,0);
}));
test('direct SQL policy-version change remains typed repair-required for ordinary reads',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool);await pool.query('UPDATE shared_vaults SET access_policy_version=access_policy_version+1 WHERE id=$1',[f.input.vaultID]);
  await assert.rejects(new VaultPublicationStore(pool,f.config).header(f.input),/publication_repair_required/);
  const s=storeFor(pool,f),p=await s.preview(f.input,requestFor(f));assert.equal(p.generations[0].scope.policyVersion,3);
}));
