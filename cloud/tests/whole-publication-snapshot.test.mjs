import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID as uuid} from 'node:crypto';
import {projectPublicationSnapshot} from '../src/whole-publication-snapshot.mjs';
test('group membership mutations use existing Owner/Admin target ceiling; Editor/Viewer denied by publication gate',()=>{
  for(const actorRole of ['owner','admin'])for(const role of ['owner','admin','editor','viewer']){
    const groupID=uuid(),member={id:uuid(),userID:uuid(),epoch:1,role},teamID=uuid();
    const current={actorRole,memberships:[member],raw:{groups:[{id:groupID,name:'group',version:1,deleted_at:null}],edges:[],grants:[],vault:{access_policy_version:'1'},teamPolicy:[{team_id:teamID,revision:0}]}};
    const request={teamID,operationID:uuid(),groupMutation:{action:'ADD_MEMBER',groupID,userID:member.userID,membershipID:member.id,membershipEpoch:1}};
    const run=()=>projectPublicationSnapshot(current,{request,effectiveAt:'2026-10-02T00:00:00Z',actorUserID:uuid()});
    if(actorRole==='admin'&&['owner','admin'].includes(role))assert.throws(run,/team_access_denied/);
    else {const projected=run();assert.equal(projected.raw.edges.length,1);assert.equal(projected.raw.teamPolicy[0].revision,1);assert.equal(current.raw.edges.length,0);}
  }
});
