// Test-only in-memory anchor. This is not durable or independent and is never
// accepted as evidence for installed-controller/anti-rollback deployment.
import {MigrationFence} from '../src/migration-fence.mjs';
import {fenceHistoryHead,sameFenceHistoryHead} from '../src/fence-history-head.mjs';
const anchors=new Map();
export function syntheticV1Anchor(initial=fenceHistoryHead([])){
 let head=structuredClone(initial);
 return {async read(){return structuredClone(head);},async advance(before,after){
  if(sameFenceHistoryHead(head,after))return;
  if(!sameFenceHistoryHead(head,before)||after.position!==before.position+1)throw Error('deployment_anchor_conflict');
  head=structuredClone(after);
 }};
}
export async function syntheticAnchoredFence(path){
 let anchor=anchors.get(path);
 if(!anchor){const events=await new MigrationFence(path).readRecords();anchor=syntheticV1Anchor(fenceHistoryHead(events));anchors.set(path,anchor);}
 return new MigrationFence(path,{anchor});
}
