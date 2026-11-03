import {createHash} from 'node:crypto';
import {validateFenceEvent} from './migration-fence-journal.mjs';

const domain=Buffer.from('selective-remote/fence-history/v1\0');
export function sameFenceHistoryHead(left,right){
 return Number.isSafeInteger(left?.position)&&left.position>=0&&/^[a-f0-9]{64}$/u.test(left?.digest??'')
  &&left.position===right?.position&&left.digest===right?.digest;
}
export function nextFenceHistoryHead(previous,raw){
 if(!sameFenceHistoryHead(previous,previous)||!Number.isSafeInteger(previous.position+1))throw Error('deployment_anchor_invalid');
 const event=validateFenceEvent(raw),position=previous.position+1,ordinal=Buffer.alloc(8);
 ordinal.writeBigUInt64BE(BigInt(position));
 const digest=createHash('sha256').update(domain).update(Buffer.from(previous.digest,'hex')).update(ordinal)
  .update(JSON.stringify(event)+'\n','utf8').digest('hex');
 return {position,digest};
}
export function fenceHistoryHead(events){
 let head={position:0,digest:createHash('sha256').update(domain).digest('hex')};
 for(const event of events)head=nextFenceHistoryHead(head,event);
 return head;
}
