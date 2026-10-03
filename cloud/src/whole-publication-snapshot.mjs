// Exact, read-only projection. Timestamps/row versions match the later SQL writes.
import {createHash} from 'node:crypto';
import {canonicalMigrationJSON} from './migration-policy.mjs';
import {requireAccessMutation} from './team-policy.mjs';
export const wholeHash=value=>createHash('sha256').update(canonicalMigrationJSON(value)).digest('hex');
export function publicationUUID(...values){const h=wholeHash(values);return h.slice(0,8)+'-'+h.slice(8,12)+'-5'+h.slice(13,16)+'-a'+h.slice(17,20)+'-'+h.slice(20,32);}
const sorted=rows=>rows.sort((a,b)=>a.id.localeCompare(b.id));
function fail(code,count){const e=Error(code);e.code=code;if(count!==undefined)e.remainingGrantCount=count;throw e;}
export function projectPublicationSnapshot(current,{request,effectiveAt,actorUserID,foundationGrants=[]}){
  const next=structuredClone(current),raw=next.raw,m=request.groupMutation;
  let teamWrites=0,grantWrites=0;
  const grantsToRevoke=m?.action==='DELETE'?foundationGrants.filter(g=>!g.revoked_at&&g.principal_kind==='GROUP'&&g.principal_id===m.groupID):[];
  if(grantsToRevoke.length>1000)fail('group_grants_must_be_revoked_first',grantsToRevoke.length);
  if(m){
    const group=raw.groups.find(g=>g.id===m.groupID&&!g.deleted_at);
    if(m.action==='CREATE'){
      if(raw.groups.some(g=>g.id===m.groupID))fail('access_group_conflict');
      raw.groups.push({id:m.groupID,team_id:request.teamID,name:m.name,created_by_user_id:actorUserID,created_at:effectiveAt,updated_at:effectiveAt,version:1,deleted_at:null});teamWrites++;
    }else{
      if(!group)fail('access_group_not_found');
      if(m.action==='RENAME'){group.name=m.name;group.updated_at=effectiveAt;group.version++;teamWrites++;}
      else if(m.action==='ADD_MEMBER'||m.action==='REMOVE_MEMBER'){
        const member=next.memberships.find(x=>x.id===m.membershipID&&x.userID===m.userID&&x.epoch===m.membershipEpoch);
        if(!member)fail('access_group_member_scope_or_epoch_invalid');
        requireAccessMutation(current.actorRole,member.role);
        const edge=raw.edges.find(e=>e.group_id===m.groupID&&e.user_id===m.userID&&!e.removed_at);
        if(m.action==='ADD_MEMBER'){
          if(edge)fail('access_group_conflict');
          raw.edges.push({id:publicationUUID(request.operationID,m.groupID,m.userID,m.membershipEpoch),team_id:request.teamID,group_id:m.groupID,user_id:m.userID,membership_id:m.membershipID,membership_epoch:m.membershipEpoch,created_by_user_id:actorUserID,created_at:effectiveAt,version:1,removed_at:null});
        }else{if(!edge||edge.membership_id!==m.membershipID||Number(edge.membership_epoch)!==m.membershipEpoch)fail('access_group_conflict');edge.removed_at=effectiveAt;edge.version++;}
        teamWrites++;
      }else if(m.action==='DELETE'){
        for(const edge of raw.edges.filter(e=>e.group_id===m.groupID&&!e.removed_at)){
          const member=current.memberships.find(x=>x.id===edge.membership_id&&x.epoch===Number(edge.membership_epoch));
          if(member)requireAccessMutation(current.actorRole,member.role);
          edge.removed_at=effectiveAt;edge.version++;teamWrites++;
        }
        group.deleted_at=effectiveAt;group.updated_at=effectiveAt;group.version++;teamWrites++;
        for(const g of raw.grants.filter(g=>grantsToRevoke.some(r=>r.id===g.id))){g.revoked_at=effectiveAt;g.updated_at=effectiveAt;g.version++;grantWrites++;}
      }
    }
    const names=new Set();for(const g of raw.groups.filter(g=>!g.deleted_at)){const name=g.name.toLowerCase();if(names.has(name))fail('access_group_conflict');names.add(name);}
  }
  if(teamWrites){if(!raw.teamPolicy.length)raw.teamPolicy=[{team_id:request.teamID,revision:0}];raw.teamPolicy[0].revision+=teamWrites;}
  raw.groups=sorted(raw.groups);raw.edges=sorted(raw.edges);
  raw.vault.access_policy_version=String(Number(raw.vault.access_policy_version)+grantWrites+1);
  next.policyVersion=Number(raw.vault.access_policy_version);
  next.groups=raw.groups.filter(g=>!g.deleted_at).map(g=>({id:g.id}));
  next.edges=raw.edges.filter(e=>!e.removed_at).map(e=>({groupID:e.group_id,userID:e.user_id,membershipID:e.membership_id,membershipEpoch:Number(e.membership_epoch)}));
  return next;
}
