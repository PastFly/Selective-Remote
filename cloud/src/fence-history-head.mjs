import {createHash} from 'node:crypto';
import {validateFenceEvent} from './migration-fence-journal.mjs';

const domain=Buffer.from('selective-remote/fence-history/v1\0');
export function fenceHistoryHead(events){
 let digest=createHash('sha256').update(domain).digest(),position=0;
 for(const raw of events){
  const event=validateFenceEvent(raw);position++;
  if(!Number.isSafeInteger(position))throw Error('deployment_anchor_invalid');
  const ordinal=Buffer.alloc(8);ordinal.writeBigUInt64BE(BigInt(position));
  digest=createHash('sha256').update(domain).update(digest).update(ordinal)
   .update(JSON.stringify(event)+'\n','utf8').digest();
 }
 return {position,digest:digest.toString('hex')};
}
export function sameFenceHistoryHead(left,right){
 return Number.isSafeInteger(left?.position)&&left.position>=0&&/^[a-f0-9]{64}$/u.test(left?.digest??'')
  &&left.position===right?.position&&left.digest===right?.digest;
}
