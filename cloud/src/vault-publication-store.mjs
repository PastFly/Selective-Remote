// Ordinary recipient transport only. Runtime configuration cannot activate a Vault.
import { createHmac, timingSafeEqual } from 'node:crypto';
import { VaultMigrationStore } from './vault-migration-store.mjs';
import { canonicalMigrationJSON, migrationRecipients } from './migration-policy.mjs';
import { isUUID } from './security.mjs';
const coherentKeys=['memberships','teams','users','groups','edges','devices','admissions','roots','certificates','directories','revocations','teamPolicy','grants','registry','pointers','rotation'];
const subjectKeys=['accountID','deviceID','membershipID','membershipEpoch'];
const identity=p=>p.resourceID+'/'+p.part;

export class VaultPublicationStore extends VaultMigrationStore {
  constructor(pool,config={}) {
    super(pool,config);
    this.cursorSecret=config.cursorSecret;
    this.clock=config.clock??Date.now;
  }
  gate(input) {
    if(!this.enabled||!this.allowed.has(input?.vaultID))throw Error('team_not_found');
    if(!isUUID(input.teamID)||!isUUID(input.vaultID)||!isUUID(input.actorUserID)||!isUUID(input.actorDeviceID))throw Error('invalid_access_request');
  }
  async selected(c,input,{pinned=true,entitled=true}={}) {
    let snapshot;
    try {snapshot=await this.snapshot(c,input,{active:true,mutation:false});}
    catch(e){if(e.message==='team_not_found')throw e;throw Error('publication_access_denied');}
    const a=(await c.query(`SELECT a.*,p.projection,p.header_hash FROM shared_vaults v
      JOIN vault_migration_attempts a ON a.id=v.active_publication_attempt_id AND a.team_id=v.team_id AND a.vault_id=v.id
      JOIN vault_publication_projections p ON p.attempt_id=a.id AND p.team_id=a.team_id AND p.vault_id=a.vault_id
      WHERE v.team_id=$1 AND v.id=$2 AND v.format_state='V2_ACTIVE' AND v.format_schema_version=2
      AND a.state='V2_ACTIVE' AND a.manifest->'payload'->'reader' IS NOT NULL`,[input.teamID,input.vaultID])).rows[0];
    if(!a)throw Error('publication_unavailable');
    if(snapshot.raw.vault.rotation_required||Number(snapshot.raw.vault.access_policy_version)!==a.scope.policyVersion)throw Error('publication_repair_required');
    const identities=(await c.query('SELECT id,kind,deleted_at FROM vault_resource_identity_reservations WHERE team_id=$1 AND vault_id=$2 AND id=ANY($3::uuid[])',[a.team_id,a.vault_id,a.resources.map(r=>r.id)])).rows;
    if(identities.length!==a.resources.length||identities.some(i=>i.deleted_at||!a.resources.some(r=>r.id===i.id&&r.kind===i.kind)))throw Error('publication_repair_required');
    if(coherentKeys.some(k=>canonicalMigrationJSON(snapshot.raw[k])!==canonicalMigrationJSON(a.snapshot.raw[k])))throw Error('publication_repair_required');
    if(pinned){
      if(!isUUID(input.generationID)||!/^[a-f0-9]{64}$/.test(input.headerHash??''))throw Error('invalid_access_request');
      if(input.generationID!==a.id||input.headerHash!==a.header_hash)throw Error('publication_changed');
    }
    const actor=snapshot.devices.find(d=>d.deviceID===input.actorDeviceID&&d.accountID===input.actorUserID);
    if(!actor)throw Error('publication_access_denied');
    const subject={accountID:actor.accountID,deviceID:actor.deviceID,membershipID:actor.membershipID,membershipEpoch:actor.membershipEpoch};
    if(!entitled)return {a,snapshot,subject};
    const row=a.projection.recipients.find(r=>subjectKeys.every(k=>r.inventory.payload[k]===subject[k]));
    const recipients=migrationRecipients({resources:a.resources,policy:a.policy,snapshot,actorRole:'owner'});
    const allowed=new Set();
    for(const [resourceID,parts]of Object.entries(recipients))for(const [part,list]of Object.entries(parts))
      if(list.some(d=>d.accountID===actor.accountID&&d.deviceID===actor.deviceID))allowed.add(resourceID+'/'+part);
    // A zero inventory is usable only for explicit signed custody of an empty generation.
    const empty=a.resources.length===0&&row?.inventory.payload.count===0
      &&a.manifest.payload.reader.custodianDeviceIDs.includes(actor.deviceID);
    if(!row||(!allowed.size&&!empty)||row.proofs.some(p=>!allowed.has(identity(p)))
      ||row.proofs.length!==allowed.size)throw Error('team_access_denied');
    return {a,snapshot,subject,row,allowed};
  }
  async read(input,work,options) {
    return this.transaction(input,async c=>work(c,await this.selected(c,input,options)),{write:false});
  }
  header(input) {
    return this.read(input,async(c,{a,subject,row})=>({header:a.projection.header,headerHash:a.header_hash,subject,inventory:row.inventory}),{pinned:false});
  }
  publisher(input) {
    return this.read(input,async(c,{a,snapshot})=>{
      const h=a.projection.header.payload;
      const publisher=snapshot.devices.find(d=>d.accountID===h.publisherAccountID&&d.deviceID===h.publisherDeviceID
        &&d.certificate.payload.keyVersion===h.publisherKeyVersion);
      if(!publisher)throw Error('publication_repair_required');
      return {headerHash:a.header_hash,generationID:a.id,accountID:publisher.accountID,deviceID:publisher.deviceID,
        keyVersion:h.publisherKeyVersion,rootPublicKey:publisher.rootPublicKey,certificate:publisher.certificate,checkpoint:publisher.checkpoint};
    },{entitled:false});
  }
  cursorBinding(input,a) {
    return {accountID:input.actorUserID,sessionID:input.sessionID,deviceID:input.actorDeviceID,teamID:input.teamID,
      vaultID:input.vaultID,generationID:a.id,headerHash:a.header_hash,filter:null};
  }
  signCursor(value) {
    if(typeof this.cursorSecret!=='string'||Buffer.byteLength(this.cursorSecret)<32)throw Error('publication_unavailable');
    const body=Buffer.from(canonicalMigrationJSON(value)).toString('base64url');
    return body+'.'+createHmac('sha256',this.cursorSecret).update('publication-directory-v1\0'+body).digest('base64url');
  }
  openCursor(cursor,binding) {
    if(typeof cursor!=='string'||cursor.length>2048)throw Error('invalid_access_page');
    const [body,signature,...extra]=cursor.split('.');
    if(extra.length||!body||!/^[A-Za-z0-9_-]{43}$/.test(signature??''))throw Error('invalid_access_page');
    let value;try{value=JSON.parse(Buffer.from(body,'base64url').toString('utf8'));}catch{throw Error('invalid_access_page');}
    const expected=this.signCursor(value).split('.')[1];
    if(!timingSafeEqual(Buffer.from(signature),Buffer.from(expected))
      ||Object.keys(value).sort().join(',')!==Object.keys({...binding,after:'',expires:0}).sort().join(',')
      ||Object.keys(binding).some(k=>value[k]!==binding[k])||!isUUID(value.after)
      ||!Number.isSafeInteger(value.expires)||value.expires<=this.clock()||value.expires>this.clock()+300000)throw Error('invalid_access_page');
    return value.after;
  }
  directory(input) {
    const limit=input.limit??100;
    if(!Number.isInteger(limit)||limit<1||limit>100||input.kind!==undefined&&input.kind!==null)throw Error('invalid_access_page');
    return this.read(input,async(c,{a,row,allowed})=>{
      const binding=this.cursorBinding(input,a);
      if(!isUUID(input.sessionID))throw Error('invalid_access_request');
      const after=input.cursor?this.openCursor(input.cursor,binding):null;
      const ids=[...new Set([...allowed].map(k=>k.split('/')[0]))].sort();
      if(after&&!ids.includes(after))throw Error('invalid_access_page');
      const remaining=ids.filter(id=>!after||id>after),counts=new Map();
      for(const key of allowed){const id=key.split('/')[0];counts.set(id,(counts.get(id)??0)+1);}
      // Keep each resource's parts together while enforcing the signed-descriptor
      // budget. The resource-ID cursor remains unchanged for Credential pairs.
      const page=[];let descriptorCount=0;
      for(const id of remaining){
        const count=counts.get(id);
        if(page.length>=limit||descriptorCount+count>100)break;
        page.push(id);descriptorCount+=count;
      }
      const selected=new Set(page);
      const descriptors=a.projection.descriptors.filter(d=>selected.has(d.payload.resourceID)&&allowed.has(identity(d.payload)));
      const nextCursor=remaining.length>page.length?this.signCursor({...binding,after:page.at(-1),expires:this.clock()+300000}):null;
      return {headerHash:a.header_hash,generationID:a.id,inventory:row.inventory,descriptors,nextCursor};
    });
  }
  part(input) {
    if(!isUUID(input.resourceID)||!['GENERAL','METADATA','SECRET'].includes(input.part))throw Error('invalid_access_request');
    return this.read(input,async(c,{a,row,allowed})=>{
      if(!allowed.has(identity(input)))throw Error('team_access_denied');
      const descriptor=a.projection.descriptors.find(d=>identity(d.payload)===identity(input));
      const item=row.proofs.find(p=>identity(p)===identity(input));
      const object=(await c.query('SELECT object FROM vault_migration_parts WHERE attempt_id=$1 AND resource_id=$2 AND part=$3',[a.id,input.resourceID,input.part])).rows[0]?.object;
      if(!descriptor||!item||!object)throw Error('publication_unavailable');
      return {headerHash:a.header_hash,generationID:a.id,descriptor,envelope:object.envelope,entry:item.entry,proof:item.proof};
    });
  }
}
