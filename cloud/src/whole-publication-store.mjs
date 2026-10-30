// Separate staging-only fix-forward operator. Never a fallback for ordinary reads.
import {createHash,createHmac,randomUUID,timingSafeEqual} from 'node:crypto';
import {VaultMigrationStore,migrationLockTables} from './vault-migration-store.mjs';
import {canonicalMigrationJSON,migrationHash,migrationRecipients} from './migration-policy.mjs';
import {deriveWholePublicationPlan,validateWholePublicationRequest,WholePublicationPreviewTokens,survivingPublicationPolicy} from './whole-publication-policy.mjs';
import {projectPublicationSnapshot,publicationUUID,wholeHash} from './whole-publication-snapshot.mjs';
import {isUUID} from './security.mjs';
import {prepareAdministrativeSidecarCommitment} from '../public/vault-publication-v1.js';
import {VaultPublicationStore} from './vault-publication-store.mjs';
import {createPublicationFenceTransaction} from './publication-fence-coordinator.mjs';
const same=(a,b)=>canonicalMigrationJSON(a)===canonicalMigrationJSON(b);
function fail(code){const e=Error(code);e.code=code;throw e;}
export class WholePublicationStore extends VaultMigrationStore{
  constructor(pool,config={}){super(pool,config);this.clock=config.clock??Date.now;this.previewSecret=config.previewSecret;
    // Disabled production/default configuration requires no preview secret.
    this.tokens=this.enabled?new WholePublicationPreviewTokens({secret:this.previewSecret,clock:this.clock,ttlMS:config.ttlMS??300000}):null;}
  gate(input){
    if(!this.enabled)fail('publication_staging_only');
    if(input?.schemaVersion!==2||input?.capability!=='resource_acl_v2')fail('vault_upgrade_required');
    if(['teamID','actorUserID','actorDeviceID','sessionID'].some(k=>!isUUID(input[k])))fail('invalid_access_request');
  }
  async authenticate(c,input){
    const row=(await c.query(`SELECT s.id FROM sessions s JOIN users u ON u.id=s.user_id AND u.disabled_at IS NULL
      JOIN devices d ON d.id=s.device_id AND d.user_id=s.user_id AND d.revoked_at IS NULL
      WHERE s.id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.revoked_at IS NULL AND s.expires_at>clock_timestamp()`,[input.sessionID,input.actorUserID,input.actorDeviceID])).rows[0];
    if(!row)fail('publication_session_invalid');
  }
  async transaction(input,work,{write=true}={}){
    this.gate(input);
    for(let retry=0;;retry++){
      const c=await this.pool.connect();
      const fenced=createPublicationFenceTransaction({query:(text,values)=>c.query(text,values),fence:this.fence,coordinator:this.fenceCoordinator});
      try{
        await c.query(write?'BEGIN':'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');await this.authenticate(c,input);
        if(write){
          await c.query('SELECT id FROM teams WHERE id=$1 AND archived_at IS NULL FOR UPDATE',[input.teamID]);
          await c.query("SELECT id FROM shared_vaults WHERE team_id=$1 AND format_state='V2_ACTIVE' AND archived_at IS NULL ORDER BY id FOR UPDATE",[input.teamID]);
          await c.query(`LOCK TABLE ${[...migrationLockTables,'sessions','team_publication_operations','team_publication_generations','team_publication_receipts','team_publication_outbox','team_publication_upload_chunks','team_publication_operation_keys','team_publication_cancellations'].join(',')} IN SHARE ROW EXCLUSIVE MODE`);
          await this.authenticate(c,input);
        }
        const result=await work(c,fenced);await this.authenticate(c,input);
        if(fenced.intentID)await this.faultAt('before_commit');
        await fenced.commit();if(fenced.intentID)await this.faultAt('after_commit');await fenced.confirm();return result;
      }catch(e){let rollbackError;try{await fenced.rollback();}catch(error){rollbackError=error;}
        if(fenced.commitDispatched)throw e;if(rollbackError&&fenced.intentID)throw rollbackError;
        if(rollbackError||retry>=3||!['40P01','40001'].includes(e.code))throw e;}
      finally{c.release();}
      await new Promise(resolve=>setTimeout(resolve,20*(retry+1)));
    }
  }
  async operation(c,input,operationID,{optional=false}={}){
    if(!isUUID(operationID))fail('invalid_access_request');
    const op=(await c.query('SELECT *,to_jsonb(effective_at) AS effective_time FROM team_publication_operations WHERE id=$1',[operationID])).rows[0];
    if(!op){if(optional)return null;fail('publication_operation_not_found');}
    if(op.team_id!==input.teamID||op.actor_user_id!==input.actorUserID||op.actor_device_id!==input.actorDeviceID)fail('publication_operation_not_found');
    return op;
  }
  async current(c,input,operationID){
    const rows=(await c.query(`SELECT a.*,p.projection,p.header_hash,p.administrative_sidecar FROM shared_vaults v
      JOIN vault_migration_attempts a ON a.id=v.active_publication_attempt_id AND a.team_id=v.team_id AND a.vault_id=v.id
      JOIN vault_publication_projections p ON p.attempt_id=a.id
      WHERE v.team_id=$1 AND v.archived_at IS NULL AND v.format_state='V2_ACTIVE' ORDER BY v.id`,[input.teamID])).rows;
    const count=Number((await c.query("SELECT count(*) AS n FROM shared_vaults WHERE team_id=$1 AND archived_at IS NULL AND format_state='V2_ACTIVE'",[input.teamID])).rows[0].n);
    if(!count||count!==rows.length)fail('publication_unavailable');
    if(count>10){const e=Error('publication_limit');e.counts={vaults:count};throw e;}
    if(rows.some(a=>!this.allowed.has(a.vault_id)))fail('publication_staging_only');
    if((await c.query(`SELECT id FROM vault_migration_attempts a WHERE team_id=$1 AND state='V2_READY'
      AND NOT EXISTS(SELECT 1 FROM team_publication_generations g WHERE g.attempt_id=a.id AND g.operation_id=$2) LIMIT 1`,[input.teamID,operationID])).rows.length)fail('publication_ready_attempt_exists');
    const current=[],snapshots={},attempts={};
    for(const a of rows){
      const snapshot=await this.snapshot(c,{...input,vaultID:a.vault_id},{active:true});
      if(a.state!=='V2_ACTIVE'||snapshot.raw.vault.rotation_required||Number(snapshot.raw.vault.access_policy_version)<a.scope.policyVersion)fail('publication_repair_required');
      if(!Number.isSafeInteger(snapshot.policyVersion)||snapshot.policyVersion<1||!Number.isSafeInteger(a.projection.header.payload.sequence))fail('publication_limit');
      const actor=snapshot.devices.find(d=>d.accountID===input.actorUserID&&d.deviceID===input.actorDeviceID);
      const old=a.snapshot.devices.find(d=>d.accountID===input.actorUserID&&d.deviceID===input.actorDeviceID);
      if(!actor||!old||actor.membershipID!==old.membershipID||actor.membershipEpoch!==old.membershipEpoch
        ||!same(actor.publicKey,old.publicKey)||!same(actor.certificate,old.certificate)
        ||!a.manifest?.payload?.reader?.custodianDeviceIDs.includes(input.actorDeviceID))fail('publication_custodian_unavailable');
      const ids=(await c.query('SELECT id,kind,deleted_at FROM vault_resource_identity_reservations WHERE team_id=$1 AND vault_id=$2 AND id=ANY($3::uuid[])',[input.teamID,a.vault_id,a.resources.map(r=>r.id)])).rows;
      if(ids.length!==a.resources.length||ids.some(i=>i.deleted_at||!a.resources.some(r=>r.id===i.id&&r.kind===i.kind)))fail('publication_repair_required');
      current.push({teamID:input.teamID,vaultID:a.vault_id,generationID:a.id,sequence:a.projection.header.payload.sequence,headerHash:a.header_hash,
        resources:a.resources,policy:a.policy,custodianDeviceIDs:a.manifest.payload.reader.custodianDeviceIDs});
      snapshots[a.vault_id]=snapshot;attempts[a.vault_id]=a;
    }
    return {current,snapshots,attempts};
  }
  async plan(c,input,request,token=null){
    if(!isUUID(request?.operationID))fail('invalid_publication_request');
    if((await c.query('SELECT operation_id FROM team_publication_cancellations WHERE operation_id=$1',[request.operationID])).rows.length)fail('publication_discarded');
    const loaded=await this.current(c,input,request?.operationID),canonical=validateWholePublicationRequest(request,loaded.current);
    const op=await this.operation(c,input,request.operationID,{optional:true});
    if(op&&!same(op.request,canonical))fail('publication_replay_conflict');
    if(op?.state==='DISCARDED')fail('publication_discarded');
    const claims=token?this.tokens.claims(token):null;
    const effectiveAt=op?.effective_time??claims?.binding.effectiveAt??(await c.query('SELECT to_jsonb($1::timestamptz) AS time',[new Date(this.clock()).toISOString()])).rows[0].time;
    const foundationGrants=request.groupMutation?.action==='DELETE'?(await c.query("SELECT to_jsonb(g) AS data FROM vault_access_grants g WHERE team_id=$1 AND principal_kind='GROUP' AND principal_id=$2 AND revoked_at IS NULL ORDER BY id",[input.teamID,request.groupMutation.groupID])).rows.map(r=>r.data):[];
    if(request.groupMutation?.action==='DELETE'){
      const fanout=new Set([...foundationGrants.map(g=>g.id),...loaded.current.flatMap(v=>v.policy.filter(g=>g.principalKind==='GROUP'&&g.principalID===request.groupMutation.groupID).map(g=>g.id))]);
      if(fanout.size>1000){const e=Error('group_grants_must_be_revoked_first');e.code=e.message;e.remainingGrantCount=fanout.size;throw e;}
    }
    const pairs={};for(const v of canonical.vaults)pairs[v.vaultID]={current:loaded.snapshots[v.vaultID],successor:projectPublicationSnapshot(loaded.snapshots[v.vaultID],{request:canonical,effectiveAt,actorUserID:input.actorUserID,foundationGrants})};
    const plan=await deriveWholePublicationPlan({request:canonical,current:loaded.current,snapshots:pairs,actorRole:loaded.snapshots[canonical.vaults[0].vaultID].actorRole});
    // Group deletion can also revoke dormant grants in nonparticipating V1/
    // PREPARING Vaults. Bind this complete read-set, not only ACTIVE grants.
    plan.readSetHash=wholeHash({readSetHash:plan.readSetHash,foundationGrants});
    const generations=canonical.vaults.map(v=>{
      const old=loaded.current.find(x=>x.vaultID===v.vaultID),snapshot=pairs[v.vaultID].successor;
      return {vaultID:v.vaultID,generationID:publicationUUID(canonical.operationID,v.vaultID),sequence:old.sequence+1,previousHash:old.headerHash,
        scope:{teamID:input.teamID,vaultID:v.vaultID,attemptID:publicationUUID(canonical.operationID,v.vaultID),sourceRevision:snapshot.sourceRevision,
          sourceHash:wholeHash({operationID:canonical.operationID,requestHash:plan.requestHash,readSetHash:plan.readSetHash,predecessor:old.headerHash}),snapshotHash:wholeHash(snapshot),policyVersion:snapshot.policyVersion},snapshot};
    });
    const rows=[];
    for(const r of plan.recipients){const snapshot=pairs[r.vaultID].successor;
      const target=d=>structuredClone(snapshot.devices.find(x=>x.deviceID===d.deviceID));
      for(const part of r.parts)rows.push({type:'PART',vaultID:r.vaultID,resourceID:part.resourceID,part:part.part,devices:part.devices.map(target)});
      rows.push({type:'CUSTODY',vaultID:r.vaultID,devices:r.custodians.map(target)});
    }
    rows.push(...plan.effectiveDeltas.map(d=>({type:'DELTA',...d})));
    if(rows.length>22010||Buffer.byteLength(canonicalMigrationJSON({generations,rows}))>64*1024*1024)fail('publication_limit');
    const actor=pairs[canonical.vaults[0].vaultID].current.devices.find(d=>d.deviceID===input.actorDeviceID);
    const binding={version:1,teamID:input.teamID,operationID:canonical.operationID,actorAccountID:input.actorUserID,sessionID:input.sessionID,actorDeviceID:input.actorDeviceID,
      keyVersion:actor.certificate.payload.keyVersion,...Object.fromEntries(['requestHash','readSetHash','successorHash','policyHash','recipientHash','predecessors','counts'].map(k=>[k,plan[k]])),effectiveAt,rowsHash:wholeHash(rows),rowCount:rows.length};
    if(token)this.tokens.open(token,binding);
    if(op&&!same({...op.prepared.binding,sessionID:binding.sessionID},binding))fail('publication_stale');
    return {...loaded,plan,generations,pairs,rows,binding,foundationGrants};
  }
  signPage(token,kind,offset,vaultID=null){
    const body=Buffer.from(canonicalMigrationJSON({tokenHash:wholeHash(token),kind,offset,vaultID})).toString('base64url');
    return body+'.'+createHmac('sha256',this.previewSecret).update('whole-publication-page-v1\0'+body).digest('base64url');
  }
  pageOffset(token,kind,cursor,count,vaultID=null){
    if(!cursor)return 0;
    if(typeof cursor!=='string'||cursor.length>1024)fail('invalid_access_page');
    const [body,sig,...rest]=cursor.split('.');let v;
    try{v=JSON.parse(Buffer.from(body,'base64url').toString());}catch{fail('invalid_access_page');}
    if(rest.length||!/^[A-Za-z0-9_-]{43}$/.test(sig??'')||!Number.isSafeInteger(v.offset)||v.offset<0||v.offset>=count
      ||!same(Object.keys(v).sort(),['kind','offset','tokenHash','vaultID'])||v.tokenHash!==wholeHash(token)||v.kind!==kind||v.vaultID!==vaultID
      ||!timingSafeEqual(Buffer.from(sig),Buffer.from(this.signPage(token,kind,v.offset,vaultID).split('.')[1])))fail('invalid_access_page');
    return v.offset;
  }
  preview(input,request,{token=null,cursor=null}={}){
    return this.transaction(input,async c=>{
      const p=await this.plan(c,input,request,token);const signed=token??this.tokens.issue(p.binding),offset=this.pageOffset(signed,'preview',cursor,p.rows.length);
      return {token:signed,binding:p.binding,request:p.plan.request,generations:p.generations,rows:p.rows.slice(offset,offset+100),
        nextCursor:offset+100<p.rows.length?this.signPage(signed,'preview',offset+100):null};
    },{write:false});
  }
  context(input,operationID=null){return this.transaction(input,async c=>{
    const op=operationID!==null?await this.operation(c,input,operationID):null;
    if(op?.state==='COMMITTED'){
      // A receipt remains recoverable after mutation authority/custody loss.
      // This context grants no policy access or publication authority; ordinary
      // read-back still verifies current recipient entitlement independently.
      const receipt=await this.committedReceipt(c,input,op);
      const keyVersion=Number(op.actor_key_version);if(!Number.isSafeInteger(keyVersion)||keyVersion<1)fail('publication_receipt_invalid');
      return {teamID:input.teamID,publicationAvailable:true,environment:'staging',sessionID:input.sessionID,
        actorKeyVersion:keyVersion,operationState:'COMMITTED',recoveryOnly:true,actorRole:null,
        groups:[],edges:[],memberships:[],current:receipt.vaults.map(v=>({...v,teamID:input.teamID,resources:[],policy:[],custodianDeviceIDs:[]}))};
    }
    const loaded=await this.current(c,input,operationID??randomUUID()),snapshot=loaded.snapshots[loaded.current[0].vaultID];
    const actor=snapshot.devices.find(d=>d.deviceID===input.actorDeviceID);
    return {teamID:input.teamID,publicationAvailable:true,environment:'staging',sessionID:input.sessionID,actorKeyVersion:actor.certificate.payload.keyVersion,...(op?{operationState:op.state}:{}),
      current:loaded.current,groups:snapshot.raw.groups.filter(g=>!g.deleted_at).map(g=>({id:g.id,name:g.name,version:g.version})),
      edges:snapshot.raw.edges.filter(e=>!e.removed_at).map(e=>({id:e.id,version:Number(e.version),groupID:e.group_id,userID:e.user_id,membershipID:e.membership_id,membershipEpoch:Number(e.membership_epoch)})),memberships:snapshot.memberships,actorRole:snapshot.actorRole};
  },{write:false});}
  start(input,token,request){
    return this.transaction(input,async c=>{
      const p=await this.plan(c,input,request,token),existing=await this.operation(c,input,request.operationID,{optional:true});
      if(existing)return {operationID:existing.id,state:existing.state,generations:p.generations};
      const prepared={binding:p.binding,plan:p.plan,generations:p.generations,foundationGrants:p.foundationGrants};
      if(Buffer.byteLength(canonicalMigrationJSON(prepared))>64*1024*1024)fail('publication_limit');
      await c.query(`INSERT INTO team_publication_operations(id,team_id,actor_user_id,actor_device_id,session_id,actor_key_version,
        request_hash,request,prepared,counts,effective_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
        [request.operationID,input.teamID,input.actorUserID,input.actorDeviceID,input.sessionID,p.binding.keyVersion,p.plan.requestHash,p.plan.request,prepared,p.plan.counts,p.binding.effectiveAt]);
      for(const g of p.generations){
        const v=p.plan.request.vaults.find(v=>v.vaultID===g.vaultID),old=p.plan.predecessors.find(v=>v.vaultID===g.vaultID);
        await c.query(`INSERT INTO vault_migration_attempts(id,team_id,vault_id,actor_user_id,actor_device_id,source_revision,source_hash,snapshot_hash,snapshot,policy,resources,scope)
          VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,[g.generationID,input.teamID,g.vaultID,input.actorUserID,input.actorDeviceID,
          g.scope.sourceRevision,g.scope.sourceHash,g.scope.snapshotHash,g.snapshot,JSON.stringify(v.policy),JSON.stringify(v.resources),g.scope]);
        await c.query(`INSERT INTO team_publication_generations(operation_id,team_id,vault_id,attempt_id,predecessor_id,predecessor_hash,sequence,policy_version)
          VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,[request.operationID,input.teamID,g.vaultID,g.generationID,old.generationID,old.headerHash,g.sequence,g.scope.policyVersion]);
        for(const r of v.resources)await c.query(`INSERT INTO vault_migration_resources(id,attempt_id,team_id,vault_id,kind,parent_folder_id,source_ordinal)
          VALUES($1,$2,$3,$4,$5,$6,$7)`,[r.id,g.generationID,input.teamID,g.vaultID,r.kind,r.parentFolderID,r.sourceOrdinal]);
      }
      await this.faultAt('operation_started');return {operationID:request.operationID,state:'PREPARING',generations:p.generations};
    });
  }
  async prepared(c,input,operationID,vaultID=null){
    const op=await this.operation(c,input,operationID);
    if(!['PREPARING','READY'].includes(op.state))fail('publication_not_preparing');
    const p=await this.plan(c,input,op.request);
    if(vaultID===null)return {op,p};
    const a=(await c.query(`SELECT a.*,g.sequence,g.predecessor_hash FROM team_publication_generations g JOIN vault_migration_attempts a ON a.id=g.attempt_id
      WHERE g.operation_id=$1 AND g.team_id=$2 AND g.vault_id=$3`,[operationID,input.teamID,vaultID])).rows[0];
    if(!a)fail('publication_scope_mismatch');
    a.generationSequence=Number(a.sequence);a.generationPreviousHash=a.predecessor_hash;
    if(!same(a.snapshot,p.pairs[vaultID].successor)||a.snapshot_hash!==wholeHash(a.snapshot))fail('publication_stale');
    return {op,p,a,s:p.pairs[vaultID].successor};
  }
  async aggregateBudget(c,operationID){
    const row=(await c.query(`SELECT COALESCE((SELECT sum(octet_length(p.object::text)) FROM vault_migration_parts p JOIN team_publication_generations g ON g.attempt_id=p.attempt_id WHERE g.operation_id=$1),0)
      +COALESCE((SELECT sum(octet_length(p.administrative_sidecar::text)) FROM vault_publication_projections p JOIN team_publication_generations g ON g.attempt_id=p.attempt_id WHERE g.operation_id=$1),0) AS bytes`,[operationID])).rows[0];
    if(Number(row.bytes)>128*1024*1024)fail('publication_limit');
  }
  putPart(input,operationID,vaultID,object){
    if(Buffer.byteLength(canonicalMigrationJSON({object}))>1024*1024)fail('publication_limit');
    return this.transaction(input,async c=>{
      const {op,p,a,s}=await this.prepared(c,input,operationID,vaultID);await this.checkObject(object,a,s);
      const predecessor=p.attempts[vaultID];
      const prior=(await c.query('SELECT object FROM vault_migration_parts WHERE attempt_id=$1 AND resource_id=$2 AND part=$3',[predecessor.id,object.resourceID,object.part])).rows[0]?.object;
      if(prior&&prior.envelope.nonce===object.envelope.nonce)fail('publication_crypto_reuse');
      const old=(await c.query('SELECT object FROM vault_migration_parts WHERE attempt_id=$1 AND resource_id=$2 AND part=$3',[a.id,object.resourceID,object.part])).rows[0]?.object;
      if(old){if(!same(old,object))fail('publication_replay_conflict');return old;}
      if(op.state!=='PREPARING'||a.state!=='V2_PREPARING')fail('publication_not_preparing');
      await c.query('INSERT INTO vault_migration_parts(attempt_id,resource_id,part,object,sha256) VALUES($1,$2,$3,$4,$5)',[a.id,object.resourceID,object.part,object,object.sha256]);
      await this.aggregateBudget(c,operationID);await this.faultAt('part_uploaded');return object;
    });
  }
  checkpoint(value){
    if(!value||!same(Object.keys(value).sort(),['ciphertext','nonce','version'])||value.version!==1||!/^[A-Za-z0-9_-]{16}$/.test(value.nonce??'')
      ||typeof value.ciphertext!=='string'||value.ciphertext.length<22
      ||value.ciphertext.length>64*1024*1024-Buffer.byteLength(canonicalMigrationJSON({...value,ciphertext:''}))
      ||/[^A-Za-z0-9_-]/.test(value.ciphertext))fail('invalid_migration_checkpoint');
  }
  putProjection(input,operationID,vaultID,projection,sidecar,checkpoint){
    return this.transaction(input,c=>this.saveProjection(c,input,operationID,vaultID,projection,sidecar,checkpoint));
  }
  async saveProjection(c,input,operationID,vaultID,projection,sidecar,checkpoint){
    if(Buffer.byteLength(canonicalMigrationJSON(sidecar))>1024*1024||Buffer.byteLength(canonicalMigrationJSON(projection))>64*1024*1024)fail('publication_limit');
    if(checkpoint!==undefined)this.checkpoint(checkpoint);
      const {op,p,a,s}=await this.prepared(c,input,operationID,vaultID),checked=await this.checkReader(c,a,s,projection,sidecar);
      if(!same(checked.reader.custodianDeviceIDs,p.plan.request.vaults.find(v=>v.vaultID===vaultID).custodianDeviceIDs))fail('publication_custodian_unavailable');
      if(sidecar.envelope.nonce===p.attempts[vaultID].administrative_sidecar.envelope.nonce)fail('publication_crypto_reuse');
      const old=(await c.query('SELECT * FROM vault_publication_projections WHERE attempt_id=$1',[a.id])).rows[0];
      if(old){if(!same(old.projection,projection)||!same(old.administrative_sidecar,sidecar))fail('publication_replay_conflict');return {headerHash:old.header_hash};}
      if(op.state!=='PREPARING'||a.state!=='V2_PREPARING')fail('publication_not_preparing');
      await c.query('INSERT INTO vault_publication_projections(attempt_id,team_id,vault_id,projection,administrative_sidecar,header_hash) VALUES($1,$2,$3,$4,$5,$6)',[a.id,input.teamID,vaultID,projection,sidecar,checked.headerHash]);
      if(checkpoint!==undefined){const checkpoints={...(op.checkpoint??{}),[vaultID]:checkpoint};if(Buffer.byteLength(canonicalMigrationJSON(checkpoints))>64*1024*1024)fail('publication_limit');await c.query('UPDATE team_publication_operations SET checkpoint=$2 WHERE id=$1',[operationID,checkpoints]);}
      await this.aggregateBudget(c,operationID);await this.faultAt('projection_uploaded');return {headerHash:checked.headerHash};
  }
  putProjectionChunk(input,operationID,vaultID,chunk){
    if(!chunk||!same(Object.keys(chunk).sort(),['count','data','index','sha256','version'])||chunk.version!==1
      ||!Number.isInteger(chunk.index)||!Number.isInteger(chunk.count)||chunk.count<1||chunk.count>256||chunk.index<0||chunk.index>=chunk.count
      ||!/^[a-f0-9]{64}$/.test(chunk.sha256??'')||typeof chunk.data!=='string'||!/^[A-Za-z0-9_-]+$/.test(chunk.data)
      ||Buffer.byteLength(canonicalMigrationJSON(chunk))>1024*1024)fail('invalid_publication_request');
    const data=Buffer.from(chunk.data,'base64url');if(!data.length||data.length>512*1024||data.toString('base64url')!==chunk.data)fail('publication_limit');
    return this.transaction(input,async c=>{
      const {op,a}=await this.prepared(c,input,operationID,vaultID);
      const old=(await c.query('SELECT * FROM team_publication_upload_chunks WHERE operation_id=$1 AND vault_id=$2 AND chunk_index=$3',[operationID,vaultID,chunk.index])).rows[0];
      if(old){if(old.chunk_count!==chunk.count||old.payload_hash!==chunk.sha256||!old.chunk_data.equals(data))fail('publication_replay_conflict');}
      else{
        if(op.state!=='PREPARING'||a.state!=='V2_PREPARING')fail('publication_not_preparing');
        if((await c.query('SELECT 1 FROM team_publication_upload_chunks WHERE operation_id=$1 AND vault_id=$2 AND (chunk_count<>$3 OR payload_hash<>$4) LIMIT 1',[operationID,vaultID,chunk.count,chunk.sha256])).rows.length)fail('publication_replay_conflict');
        await c.query('INSERT INTO team_publication_upload_chunks(operation_id,team_id,vault_id,chunk_index,chunk_count,payload_hash,chunk_data) VALUES($1,$2,$3,$4,$5,$6,$7)',[operationID,input.teamID,vaultID,chunk.index,chunk.count,chunk.sha256,data]);
      }
      if(Number((await c.query('SELECT sum(octet_length(chunk_data)) AS bytes FROM team_publication_upload_chunks WHERE operation_id=$1',[operationID])).rows[0].bytes)>128*1024*1024)fail('publication_limit');
      const rows=(await c.query('SELECT chunk_index,chunk_data FROM team_publication_upload_chunks WHERE operation_id=$1 AND vault_id=$2 ORDER BY chunk_index',[operationID,vaultID])).rows;
      if(rows.length!==chunk.count)return {complete:false};
      const encoded=Buffer.concat(rows.map(r=>r.chunk_data));if(createHash('sha256').update(encoded).digest('hex')!==chunk.sha256)fail('publication_upload_invalid');
      let body;try{const text=encoded.toString('utf8');if(!Buffer.from(text).equals(encoded))fail('publication_upload_invalid');body=JSON.parse(text);}catch{fail('publication_upload_invalid');}
      if(!same(Object.keys(body).sort(),['projection','sidecar',...(body.checkpoint===undefined?[]:['checkpoint'])].sort()))fail('publication_upload_invalid');
      const result=await this.saveProjection(c,input,operationID,vaultID,body.projection,body.sidecar,body.checkpoint);
      return {complete:true,...result};
    });
  }
  validate(input,operationID,manifests){
    return this.transaction(input,async c=>{
      const {op,p}=await this.prepared(c,input,operationID);
      if(!Array.isArray(manifests)||manifests.length!==p.generations.length||new Set(manifests.map(m=>m.vaultID)).size!==p.generations.length
        ||manifests.some(m=>!same(Object.keys(m).sort(),['manifest','vaultID'])||!p.generations.some(g=>g.vaultID===m.vaultID)))fail('publication_incomplete');
      const nonces=new Set();
      for(const g of p.generations){
        const {a,s}=await this.prepared(c,input,operationID,g.vaultID),manifest=manifests.find(m=>m.vaultID===g.vaultID).manifest;
        if(!manifest?.payload?.reader?.sidecarCommitment)fail('publication_incomplete');
        const hash=await migrationHash(manifest);if(a.state==='V2_READY'&&a.manifest_hash!==hash)fail('publication_replay_conflict');
        await this.verify(c,a,s,manifest);
        const objects=await this.parts(c,a),sidecar=(await c.query('SELECT administrative_sidecar FROM vault_publication_projections WHERE attempt_id=$1',[a.id])).rows[0]?.administrative_sidecar;
        if(!sidecar)fail('publication_incomplete');
        for(const o of [...objects,sidecar]){if(nonces.has(o.envelope.nonce))fail('publication_crypto_reuse');nonces.add(o.envelope.nonce);}
        if(a.state==='V2_PREPARING')await c.query("UPDATE vault_migration_attempts SET state='V2_READY',manifest=$2,manifest_hash=$3 WHERE id=$1",[a.id,manifest,hash]);
      }
      await this.aggregateBudget(c,operationID);await this.faultAt('generations_ready');
      if(op.state==='PREPARING')await c.query("UPDATE team_publication_operations SET state='READY' WHERE id=$1",[operationID]);
      return {operationID,state:'READY'};
    });
  }
  discard(input,operationID){return this.transaction(input,async c=>{
    const op=await this.operation(c,input,operationID,{optional:true});
    if(!op){
      const cancelled=(await c.query('SELECT * FROM team_publication_cancellations WHERE operation_id=$1',[operationID])).rows[0];
      if(cancelled){if(cancelled.team_id!==input.teamID||cancelled.actor_user_id!==input.actorUserID||cancelled.actor_device_id!==input.actorDeviceID)fail('publication_operation_not_found');}
      else {
        await this.current(c,input,operationID);
        await c.query('INSERT INTO team_publication_cancellations(operation_id,team_id,actor_user_id,actor_device_id,confirmed_by_session) VALUES($1,$2,$3,$4,$5)',[operationID,input.teamID,input.actorUserID,input.actorDeviceID,input.sessionID]);
      }
      return {operationID,state:'DISCARDED'};
    }
    if(op.state==='COMMITTED')fail('publication_already_committed');
    if(op.state!=='DISCARDED'){
      await c.query("UPDATE vault_migration_attempts SET state='DISCARDED' WHERE id IN(SELECT attempt_id FROM team_publication_generations WHERE operation_id=$1)",[operationID]);
      await c.query("UPDATE team_publication_operations SET state='DISCARDED' WHERE id=$1",[operationID]);
    }
    // Keep reserved IDs/tombstones and immutable operation artifacts for scoped recovery.
    return {operationID,state:'DISCARDED'};
  });}
  async committedReceipt(c,input,op){
    if(op.state!=='COMMITTED')return null;
    const body=(await c.query('SELECT body FROM team_publication_receipts WHERE operation_id=$1 AND team_id=$2',[op.id,input.teamID])).rows[0]?.body;
    if(!body||body.actorAccountID!==input.actorUserID||body.actorDeviceID!==input.actorDeviceID||body.requestHash!==op.request_hash)fail('publication_receipt_invalid');
    return body;
  }
  receipt(input,operationID){return this.transaction(input,async c=>{
    const op=await this.operation(c,input,operationID,{optional:true});return op?this.committedReceipt(c,input,op):null;
  },{write:false});}
  readback(input,operationID,vaultID){return this.transaction(input,async c=>{
    const op=await this.operation(c,input,operationID),receipt=await this.committedReceipt(c,input,op),v=receipt?.vaults.find(v=>v.vaultID===vaultID);
    if(!v||!this.allowed.has(vaultID))fail('publication_receipt_not_found');
    const {a}=await VaultPublicationStore.prototype.selected.call(this,c,{...input,vaultID,generationID:v.generationID,headerHash:v.headerHash});
    return {vaultID,header:a.projection.header,headerHash:a.header_hash,manifest:a.manifest};
  },{write:false});}
  async installMutation(c,input,p){
    const m=p.plan.request.groupMutation,time=p.binding.effectiveAt;
    if(!m)return;
    if(m.action==='CREATE')await c.query(`INSERT INTO team_access_groups(id,team_id,name,created_by_user_id,created_at,updated_at)
      VALUES($1,$2,$3,$4,$5,$5)`,[m.groupID,input.teamID,m.name,input.actorUserID,time]);
    else if(m.action==='RENAME')await c.query('UPDATE team_access_groups SET name=$3,updated_at=$4,version=version+1 WHERE id=$1 AND team_id=$2',[m.groupID,input.teamID,m.name,time]);
    else if(m.action==='ADD_MEMBER')await c.query(`INSERT INTO team_access_group_members(id,team_id,group_id,user_id,membership_id,membership_epoch,created_by_user_id,created_at)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,[publicationUUID(p.plan.request.operationID,m.groupID,m.userID,m.membershipEpoch),input.teamID,m.groupID,m.userID,m.membershipID,m.membershipEpoch,input.actorUserID,time]);
    else if(m.action==='REMOVE_MEMBER')await c.query('UPDATE team_access_group_members SET removed_at=$6,version=version+1 WHERE team_id=$1 AND group_id=$2 AND user_id=$3 AND membership_id=$4 AND membership_epoch=$5 AND removed_at IS NULL',[input.teamID,m.groupID,m.userID,m.membershipID,m.membershipEpoch,time]);
    else if(m.action==='DELETE'){
      for(const g of p.foundationGrants)await c.query('UPDATE vault_access_grants SET revoked_at=$2,updated_at=$2,version=version+1 WHERE id=$1 AND revoked_at IS NULL',[g.id,time]);
      await c.query('UPDATE team_access_group_members SET removed_at=$3,version=version+1 WHERE team_id=$1 AND group_id=$2 AND removed_at IS NULL',[input.teamID,m.groupID,time]);
      await c.query('UPDATE team_access_groups SET deleted_at=$3,updated_at=$3,version=version+1 WHERE team_id=$1 AND id=$2',[input.teamID,m.groupID,time]);
    }
  }
  commit(input,operationID,token,request){
    return this.transaction(input,async(c,fenced)=>{
      const op=await this.operation(c,input,operationID);
      if(request?.operationID!==operationID)fail('publication_replay_conflict');
      // Receipt recovery remains possible after preview expiry, session renewal
      // or lost mutation authority. It cannot mutate or grant any new access.
      if(op.state==='COMMITTED'){
        const current=op.prepared.generations.map(g=>({teamID:op.team_id,vaultID:g.vaultID,generationID:g.generationID,sequence:g.sequence,headerHash:g.previousHash,
          resources:op.request.vaults.find(v=>v.vaultID===g.vaultID).resources}));
        let canonical;try{canonical=validateWholePublicationRequest(request,current);}catch{fail('publication_replay_conflict');}
        if(!same(canonical,op.request))fail('publication_replay_conflict');return this.committedReceipt(c,input,op);
      }
      if(op.state!=='READY')fail('publication_not_ready');
      const p=await this.plan(c,input,request,token),generations=[];
      for(const g of p.generations){
        const {a,s}=await this.prepared(c,input,operationID,g.vaultID);
        if(a.state!=='V2_READY')fail('publication_not_ready');
        await this.verify(c,a,s,a.manifest);generations.push({g,a});
      }
      await this.faultAt('commit_precondition');
      const fenceVaults=[];
      for(const {g,a} of generations){
        const projection=(await c.query('SELECT header_hash FROM vault_publication_projections WHERE attempt_id=$1',[a.id])).rows[0];
        if(!projection)fail('publication_invalid');
        fenceVaults.push({teamID:input.teamID,vaultID:g.vaultID,generationID:a.id,sequence:g.sequence,headerHash:projection.header_hash,manifestHash:a.manifest_hash});
      }
      if(typeof this.activationGuard==='function'){
        const vaultMetadata=(await c.query('SELECT id,team_id,name,format_state FROM shared_vaults WHERE team_id=$1 AND id=ANY($2::uuid[]) ORDER BY id',[input.teamID,fenceVaults.map(v=>v.vaultID)])).rows;
        await this.activationGuard({kind:'PUBLICATION',input,operationID,vaults:fenceVaults,
          manifests:generations.map(({g,a})=>({vaultID:g.vaultID,manifest:a.manifest})),snapshots:generations.map(({g})=>({vaultID:g.vaultID,snapshot:g.snapshot})),vaultMetadata});
      }
      await fenced.beforeCommit({kind:'PUBLICATION',operationID,schemaFloor:22,vaults:fenceVaults});
      await this.installMutation(c,input,p);
      for(const {g} of generations)await c.query('UPDATE shared_vaults SET access_policy_version=$3 WHERE id=$1 AND team_id=$2',[g.vaultID,input.teamID,g.scope.policyVersion]);
      await this.faultAt('policy_installed');
      // The database's exact committed successor, including group trigger
      // versions/timestamps, must match what every custodian signed beforehand.
      for(const {g} of generations){
        const actual=await this.snapshot(c,{...input,vaultID:g.vaultID},{active:true});actual.policyVersion=g.scope.policyVersion;
        if(!same(actual,g.snapshot)||wholeHash(actual)!==g.scope.snapshotHash)fail('publication_successor_mismatch');
      }
      await this.faultAt('successor_validated');
      for(const {g,a} of generations){
        await c.query("UPDATE vault_migration_attempts SET state='V2_ACTIVE' WHERE id=$1",[a.id]);
        await c.query('UPDATE shared_vaults SET active_publication_attempt_id=$3 WHERE id=$1 AND team_id=$2',[g.vaultID,input.teamID,a.id]);
        const desired=new Set(p.plan.request.vaults.find(v=>v.vaultID===g.vaultID).resources.map(r=>r.id));
        const removed=p.attempts[g.vaultID].resources.filter(r=>!desired.has(r.id)).map(r=>r.id);
        if(removed.length)await c.query('UPDATE vault_resource_identity_reservations SET deleted_at=$3 WHERE team_id=$1 AND vault_id=$2 AND id=ANY($4::uuid[]) AND deleted_at IS NULL',[input.teamID,g.vaultID,p.binding.effectiveAt,removed]);
        await this.faultAt('pointer_swapped');
      }
      // Recheck expiry/session after all possible lock waits and validation work.
      this.tokens.open(token,p.binding);await this.authenticate(c,input);
      const committedAt=(await c.query("UPDATE team_publication_operations SET state='COMMITTED',committed_at=$2 WHERE id=$1 RETURNING to_jsonb(committed_at) AS time",[operationID,new Date(this.clock()).toISOString()])).rows[0].time;
      await this.faultAt('operation_committed');
      for(const d of p.plan.effectiveDeltas)await c.query(`INSERT INTO team_publication_outbox(operation_id,team_id,vault_id,resource_id,membership_id,user_id,membership_epoch,before_mask,after_mask)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`,[operationID,input.teamID,d.vaultID,d.resourceID,d.membershipID,d.accountID,d.membershipEpoch,d.beforeMask,d.afterMask]);
      await this.faultAt('outbox_inserted');
      await c.query(`INSERT INTO team_audit_events(team_id,actor_user_id,action,metadata) VALUES($1,$2,'vault_publication_committed',$3)`,[input.teamID,input.actorUserID,
        {operationID,requestHash:p.plan.requestHash,counts:p.plan.counts,effectiveDeltaCount:p.plan.effectiveDeltas.length}]);
      await this.faultAt('audit_inserted');
      const vaults=[];for(const {g} of generations){const row=(await c.query('SELECT header_hash FROM vault_publication_projections WHERE attempt_id=$1',[g.generationID])).rows[0];vaults.push({vaultID:g.vaultID,generationID:g.generationID,sequence:g.sequence,headerHash:row.header_hash});}
      const receipt={operationID,teamID:input.teamID,requestHash:p.plan.requestHash,actorAccountID:input.actorUserID,actorDeviceID:input.actorDeviceID,vaults,committedAt};
      await c.query('INSERT INTO team_publication_receipts(operation_id,team_id,body) VALUES($1,$2,$3)',[operationID,input.teamID,receipt]);
      await this.faultAt('receipt_inserted');return receipt;
    });
  }
  async repairSelection(c,input,token,request,vaultID){
    const p=await this.plan(c,input,request,token),a=p.attempts[vaultID];if(!a)fail('publication_scope_mismatch');
    const snapshot=p.snapshots[vaultID],actor=snapshot.devices.find(d=>d.deviceID===input.actorDeviceID),recipients=migrationRecipients({resources:a.resources,policy:survivingPublicationPolicy(a.policy,snapshot),snapshot,actorRole:'owner',requireDevices:false});
    const row=a.projection.recipients.find(r=>['accountID','deviceID','membershipID','membershipEpoch'].every(k=>r.inventory.payload[k]===actor[k]));
    const allowed=new Set();
    if(row)for(const proof of row.proofs)if(recipients[proof.resourceID]?.[proof.part]?.some(d=>d.deviceID===actor.deviceID&&d.accountID===actor.accountID))allowed.add(proof.resourceID+'/'+proof.part);
    const old=a.snapshot.devices.find(d=>d.accountID===a.actor_user_id&&d.deviceID===a.actor_device_id);
    const current=snapshot.devices.find(d=>d.accountID===a.actor_user_id&&d.deviceID===a.actor_device_id
      &&d.certificate.payload.keyVersion===a.projection.header.payload.publisherKeyVersion&&d.rootPublicKey===old?.rootPublicKey);
    if(!old)fail('publisher_trust_unverified');
    const publisher={...(current??old),historical:!current,keyVersion:a.projection.header.payload.publisherKeyVersion,headerHash:a.header_hash,generationID:a.id};
    return {a,row,allowed,publisher};
  }
  repairDirectory(input,token,{request,vaultID,cursor=null}){
    return this.transaction(input,async c=>{
      const {a,row,allowed,publisher}=await this.repairSelection(c,input,token,request,vaultID),descriptors=a.projection.descriptors.filter(d=>allowed.has(d.payload.resourceID+'/'+d.payload.part));
      const offset=this.pageOffset(token,'repair',cursor,descriptors.length,vaultID);
      return {header:a.projection.header,headerHash:a.header_hash,generationID:a.id,manifest:a.manifest,scope:a.scope,
        publisher,administrativeResourceID:a.administrative_sidecar.resourceID,
        inventory:row?.inventory??null,descriptors:descriptors.slice(offset,offset+100),
        nextCursor:offset+100<descriptors.length?this.signPage(token,'repair',offset+100,vaultID):null};
    },{write:false});
  }
  repairPart(input,token,{request,vaultID,resourceID,part}){
    return this.transaction(input,async c=>{
      const {a,row,allowed,publisher}=await this.repairSelection(c,input,token,request,vaultID);
      if(part==='ADMINISTRATIVE'){
        if(resourceID!==a.administrative_sidecar.resourceID)fail('publication_access_denied');
        if(!a.manifest.payload.reader.sidecarCommitment)fail('publication_custodian_unavailable');
        const {commitment,items}=await prepareAdministrativeSidecarCommitment(a.administrative_sidecar,a.snapshot.devices);
        if(!same(commitment,a.manifest.payload.reader.sidecarCommitment))fail('publication_invalid');
        const own=items.find(i=>i.entry.wrapper.context.deviceID===input.actorDeviceID);if(!own)fail('publication_custodian_unavailable');
        return {resourceID,part:'SECRET',envelope:a.administrative_sidecar.envelope,...own,headerHash:a.header_hash,generationID:a.id,manifest:a.manifest,scope:a.scope,
          publisher};
      }
      if(!allowed.has(resourceID+'/'+part))fail('publication_access_denied');
      const descriptor=a.projection.descriptors.find(d=>d.payload.resourceID===resourceID&&d.payload.part===part),proof=row.proofs.find(d=>d.resourceID===resourceID&&d.part===part);
      const object=(await c.query('SELECT object FROM vault_migration_parts WHERE attempt_id=$1 AND resource_id=$2 AND part=$3',[a.id,resourceID,part])).rows[0]?.object;
      if(!object||!descriptor||!proof)fail('publication_unavailable');
      return {headerHash:a.header_hash,generationID:a.id,descriptor,envelope:object.envelope,entry:proof.entry,proof:proof.proof};
    },{write:false});
  }
}
