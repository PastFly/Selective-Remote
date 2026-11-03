import {open, mkdir, rmdir, lstat, rename} from 'node:fs/promises';
import {constants} from 'node:fs';
import {dirname, isAbsolute} from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {FENCE_MAX_BYTES,validateFenceEvent,reduceFenceEvents} from './migration-fence-journal.mjs';
import {fenceHistoryHead,sameFenceHistoryHead} from './fence-history-head.mjs';

// Bound replay BEFORE parsing archives. This is a fail-closed operational cap,
// not unlimited retention; the controller must monitor capacity and preserve
// the external anchor and archives when this cap is reached.
export const FENCE_MAX_REPLAY_BYTES=8*1024*1024;
export const FENCE_MAX_REPLAY_RECORDS=25000;
function verifySchemaFloor(schemaVersion,snapshot){
 if(!Number.isSafeInteger(schemaVersion)||schemaVersion<snapshot.schemaFloor)throw Error('deployment_schema_floor');
 return true;
}
export class MigrationFence{
 #recovery=null;
 #writes=Promise.resolve();
 constructor(path,{openFile=open,anchor=null}={}){
  if(!isAbsolute(path))throw Error('invalid_deployment_fence_path');
  if(anchor!==null&&(typeof anchor?.read!=='function'||typeof anchor?.advance!=='function'))throw Error('invalid_deployment_anchor');
  this.path=path;this.openFile=openFile;this.anchor=anchor;
 }
 async assertAnchor(records){
  if(!this.anchor)return;
  const current=await this.anchor.read();
  if(!sameFenceHistoryHead(current,fenceHistoryHead(records)))throw Error('deployment_anchor_mismatch');
 }
 async #segment(file,budget={bytes:0,records:0}){
  const stat=await file.stat();
  if(!stat.isFile()||stat.size>FENCE_MAX_BYTES)throw Error('corrupt_deployment_fence');
  if(stat.size+budget.bytes>FENCE_MAX_REPLAY_BYTES)throw Error('deployment_fence_history_limit');
  const bytes=await file.readFile();
  if(bytes.length>FENCE_MAX_BYTES||(bytes.length&&bytes.at(-1)!==10))throw Error('corrupt_deployment_fence');
  if(bytes.length+budget.bytes>FENCE_MAX_REPLAY_BYTES)throw Error('deployment_fence_history_limit');
  budget.bytes+=bytes.length;
  const content=bytes.toString('utf8'),parsed=[];let at=0;
  while(at<content.length){
   const end=content.indexOf('\n',at);if(end<0)throw Error('corrupt_deployment_fence');
   if(++budget.records>FENCE_MAX_REPLAY_RECORDS)throw Error('deployment_fence_history_limit');
   let value;try{value=JSON.parse(content.slice(at,end));}catch{throw Error('corrupt_deployment_fence');}
   parsed.push(parsed.length===0&&value?.version===3?value:validateFenceEvent(value));at=end+1;
  }
  return {bytes,parsed};
 }
 async records(file,{validateHistory=true,withBudget=false}={}){
  const budget={bytes:0,records:0};let {parsed}=await this.#segment(file,budget);
  const segments=[],seen=new Set();
  while(parsed[0]?.version===3){
   const marker=parsed[0];
   if(Object.keys(marker).sort().join(',')!=='archiveDigest,type,version'||marker.type!=='ARCHIVE_CHECKPOINT'
    ||typeof marker.archiveDigest!=='string'||!/^[a-f0-9]{64}$/u.test(marker.archiveDigest)||seen.has(marker.archiveDigest))throw Error('corrupt_deployment_fence');
   seen.add(marker.archiveDigest);segments.push(parsed.slice(1));
   const directory=this.path+'.archives',stat=await lstat(directory).catch(()=>null);
   if(!stat?.isDirectory()||stat.isSymbolicLink())throw Error('corrupt_deployment_fence');
   const archive=await this.openFile(directory+'/'+marker.archiveDigest,constants.O_RDONLY|constants.O_NOFOLLOW).catch(()=>{throw Error('corrupt_deployment_fence');});
   try{const segment=await this.#segment(archive,budget);if(createHash('sha256').update(segment.bytes).digest('hex')!==marker.archiveDigest)throw Error('corrupt_deployment_fence');parsed=segment.parsed;}
   finally{await archive.close();}
  }
  segments.push(parsed);const records=segments.reverse().flat().map(validateFenceEvent);
  // Armed V1 history must never be read or extended through a caller that has
  // not configured the independent high-water anchor (including CLIs).
  const state=reduceFenceEvents(records);
  if(state.writerFloor===1&&!this.anchor)throw Error('deployment_anchor_required');
  return withBudget?{records,budget}:records;
 }
 // No production cutover may call this until the independent high-water anchor
 // validates the complete logical history before and after checkpoint recovery.
 async compact(){return this.#enqueue(async()=>{
  const directory=dirname(this.path),dirStat=await lstat(directory);
  if(!dirStat.isDirectory()||dirStat.isSymbolicLink())throw Error('invalid_deployment_fence_directory');
  const lock=this.path+'.lock';let acquired=false,retain=false,file;
  for(let n=0;n<100;n++){
   try{await mkdir(lock,{mode:0o700});acquired=true;break;}
   catch(e){if(e.code!=='EEXIST')throw e;await new Promise(r=>setTimeout(r,10));}
  }
  if(!acquired)throw Error('deployment_fence_locked');
  try{
   if(!this.anchor)throw Error('deployment_anchor_required');
   file=await this.openFile(this.path,constants.O_RDWR|constants.O_NOFOLLOW);
   const {records:events,budget}=await this.records(file,{withBudget:true}),state=reduceFenceEvents(events);
   await this.assertAnchor(events);
   if(state.pending.length||state.v1Pending?.length)throw Error('deployment_fence_pending');
   await file.sync();
   await file.close();file=await this.openFile(this.path,constants.O_RDONLY|constants.O_NOFOLLOW);
   const {bytes,parsed}=await this.#segment(file);
   if(!bytes.length||(parsed.length===1&&parsed[0]?.version===3))throw Error('deployment_fence_empty');
   const digest=createHash('sha256').update(bytes).digest('hex'),archiveDir=this.path+'.archives';
   const marker=Buffer.from(JSON.stringify({version:3,type:'ARCHIVE_CHECKPOINT',archiveDigest:digest})+'\n');
   if(budget.bytes+marker.length>FENCE_MAX_REPLAY_BYTES||budget.records+1>FENCE_MAX_REPLAY_RECORDS)throw Error('deployment_fence_history_limit');
   try{await mkdir(archiveDir,{mode:0o700});retain=true;const parent=await this.openFile(directory,constants.O_RDONLY|constants.O_NOFOLLOW);try{await parent.sync();}finally{await parent.close();}}
   catch(e){if(e.code!=='EEXIST')throw e;}
   const aStat=await lstat(archiveDir);if(!aStat.isDirectory()||aStat.isSymbolicLink())throw Error('invalid_deployment_fence_directory');
   let archive;
   try{
    try{archive=await this.openFile(archiveDir+'/'+digest,constants.O_RDWR|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,0o600);retain=true;
     for(let at=0;at<bytes.length;){const {bytesWritten}=await archive.write(bytes,at,bytes.length-at,at);if(!Number.isSafeInteger(bytesWritten)||bytesWritten<=0)throw Error('deployment_fence_short_write');at+=bytesWritten;}}
    catch(e){if(e.code!=='EEXIST')throw e;archive=await this.openFile(archiveDir+'/'+digest,constants.O_RDONLY|constants.O_NOFOLLOW);const stored=await archive.readFile();if(!stored.equals(bytes))throw Error('corrupt_deployment_fence');}
    await archive.sync();
   }finally{await archive?.close();}
   const archives=await this.openFile(archiveDir,constants.O_RDONLY|constants.O_NOFOLLOW);try{await archives.sync();}finally{await archives.close();}
   const temp=this.path+'.checkpoint-'+randomUUID();let staged;
   try{staged=await this.openFile(temp,constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,0o600);retain=true;
    for(let at=0;at<marker.length;){const {bytesWritten}=await staged.write(marker,at,marker.length-at,at);if(!Number.isSafeInteger(bytesWritten)||bytesWritten<=0)throw Error('deployment_fence_short_write');at+=bytesWritten;}
    await staged.sync();
   }finally{await staged?.close();}
   await rename(temp,this.path);
   const parent=await this.openFile(directory,constants.O_RDONLY|constants.O_NOFOLLOW);try{await parent.sync();}finally{await parent.close();}
   const current=await this.openFile(this.path,constants.O_RDONLY|constants.O_NOFOLLOW);
   try{await this.assertAnchor(await this.records(current));}finally{await current.close();}
   retain=false;return {originalBytes:bytes.length,archiveDigest:digest};
  }finally{await file?.close();if(!retain)await rmdir(lock);}
 });}
 async intent(record){
  const validated=validateFenceEvent(record);
  if(validated.version)throw Error('invalid_deployment_fence');
  return this.#enqueue(()=>this.#writeRecord(validated));
 }
 async append(event){
  const validated=validateFenceEvent(event);
  if(validated.version!==2)throw Error('invalid_deployment_fence');
  if(validated.type==='V1_WRITER_FLOOR'&&!this.anchor)throw Error('deployment_anchor_required');
  return this.#enqueue(()=>this.#writeRecord(validated));
 }
 #enqueue(work){
  // Exact recovery replays share this instance's retained lock; serialize them
  // so one replay cannot release the lock while another still owns a barrier.
  const running=this.#writes.then(work);this.#writes=running.catch(()=>{});return running;
 }
 async assertWritable(){return this.#enqueue(async()=>{
  const directory=dirname(this.path),stat=await lstat(directory);
  if(!stat.isDirectory()||stat.isSymbolicLink())throw Error('invalid_deployment_fence_directory');
  await this.assertUnlocked();
  const file=await this.openFile(this.path,constants.O_RDWR|constants.O_NOFOLLOW);
  try{
   const before=await file.stat(),records=await this.records(file);
   await this.assertAnchor(records);
   const snapshot=reduceFenceEvents(records);
   if(snapshot.pending.length||snapshot.v1Pending?.length)throw Error('deployment_fence_pending');
   await file.sync();
   const dir=await this.openFile(directory,constants.O_RDONLY|constants.O_NOFOLLOW);
   try{await dir.sync();}finally{await dir.close();}
   const after=await file.stat(),current=await lstat(this.path);
   if(before.dev!==after.dev||before.ino!==after.ino||before.size!==after.size||before.mtimeMs!==after.mtimeMs||before.ctimeMs!==after.ctimeMs
      ||current.dev!==after.dev||current.ino!==after.ino)throw Error('deployment_fence_changed');
   await this.assertUnlocked();return true;
  }finally{await file.close();}
 });}
 async #writeRecord(record){
  const directory=dirname(this.path),stat=await lstat(directory);
  if(!stat.isDirectory()||stat.isSymbolicLink())throw Error('invalid_deployment_fence_directory');
  const lock=this.path+'.lock',key=JSON.stringify(record);
  let acquired=false,identity,retain=false;
  if(this.#recovery){
   if(this.#recovery.key!==key)throw Error('deployment_fence_locked');
   const current=await lstat(lock).catch(()=>null);
   if(!current||current.ino!==this.#recovery.ino||current.dev!==this.#recovery.dev)throw Error('deployment_fence_locked');
   identity=current;acquired=true;retain=true;
  }else{
   for(let n=0;n<100;n++){
    try{await mkdir(lock,{mode:0o700});identity=await lstat(lock);acquired=true;break;}
    catch(e){if(e.code!=='EEXIST')throw e;await new Promise(r=>setTimeout(r,10));}
   }
  }
  if(!acquired)throw Error('deployment_fence_locked');
  let file,anchorPrevious,anchorNext;
  try{
   // Provisioning is an explicit operator step. Missing retained history must
   // never be replaced with an empty journal after a successful earlier check.
   file=await this.openFile(this.path,constants.O_RDWR|constants.O_NOFOLLOW);
   const {records,budget}=await this.records(file,{withBudget:true});
   if(this.anchor){
    const local=fenceHistoryHead(records),remote=await this.anchor.read();
    if(!sameFenceHistoryHead(remote,local)){
     if(!this.#recovery||!sameFenceHistoryHead(remote,this.#recovery.anchorPrevious)
       ||!sameFenceHistoryHead(local,this.#recovery.anchorNext))throw Error('deployment_anchor_mismatch');
     anchorPrevious=remote;anchorNext=local;
    }else anchorPrevious=remote;
   }
   if(!records.some(r=>JSON.stringify(r)===key)){
    const snapshot=reduceFenceEvents([...records,record]);
    const line=Buffer.from(key+'\n'),size=(await file.stat()).size;
    if(size+line.length>FENCE_MAX_BYTES)throw Error('deployment_fence_limit');
    if(budget.bytes+line.length>FENCE_MAX_REPLAY_BYTES||budget.records+1>FENCE_MAX_REPLAY_RECORDS)throw Error('deployment_fence_history_limit');
    if(!record.version||record.type==='PENDING_INTENT'||record.type==='V1_PENDING_INTENT'||record.type==='V1_WRAPPER_BATCH_PENDING_INTENT'){
     // Reserve the larger terminal outcome for every pending intent, including
     // legacy IDs. New work must not consume another intent's resolution space.
     const reserved=snapshot.pending.reduce((bytes,pending)=>bytes+Buffer.byteLength(JSON.stringify({
      version:2,type:'CONFIRMED_COMMIT',intentID:pending.intentID,intentDigest:pending.intentDigest,
     })+'\n'),0)+(snapshot.v1Pending??[]).reduce((bytes,pending)=>bytes+Buffer.byteLength(JSON.stringify({
      version:2,type:'V1_CONFIRMED_COMMIT',intentID:pending.intentID,intentDigest:pending.intentDigest,
     })+'\n'),0);
     if(size+line.length+reserved>FENCE_MAX_BYTES)throw Error('deployment_fence_limit');
     const terminalCount=snapshot.pending.length+(snapshot.v1Pending??[]).length;
     if(budget.bytes+line.length+reserved>FENCE_MAX_REPLAY_BYTES||budget.records+1+terminalCount>FENCE_MAX_REPLAY_RECORDS)throw Error('deployment_fence_history_limit');
    }
    // A failed write or barrier leaves the lock. Only this instance's exact
    // replay can re-confirm durability; restart requires deliberate recovery.
    retain=true;
    for(let offset=0;offset<line.length;){
     const {bytesWritten}=await file.write(line,offset,line.length-offset,size+offset);
     if(!Number.isSafeInteger(bytesWritten)||bytesWritten<=0||bytesWritten>line.length-offset)throw Error('deployment_fence_short_write');
     offset+=bytesWritten;
    }
    if(this.anchor)anchorNext=fenceHistoryHead([...records,record]);
   }
   retain=true;await file.sync();
   const dir=await this.openFile(directory,constants.O_RDONLY);
   try{await dir.sync();}finally{await dir.close();}
   if(this.anchor&&anchorNext&&!sameFenceHistoryHead(anchorPrevious,anchorNext))
    await this.anchor.advance(anchorPrevious,anchorNext,record);
   retain=false;
  }finally{
   if(retain)this.#recovery={key,ino:identity.ino,dev:identity.dev,anchorPrevious,anchorNext};
   try{await file?.close();}finally{
    if(!retain){this.#recovery=null;await rmdir(lock);}
   }
  }
 }
 async assertUnlocked(){
  try{await lstat(this.path+'.lock');}catch(e){if(e.code==='ENOENT')return;throw e;}
  throw Error('deployment_fence_locked');
 }
 async #readStable(){
  await this.assertUnlocked();
  const file=await this.openFile(this.path,constants.O_RDONLY|constants.O_NOFOLLOW);
  try{
   const before=await file.stat(),records=await this.records(file);
   await this.assertAnchor(records);
   const after=await file.stat(),current=await lstat(this.path);
   if(before.dev!==after.dev||before.ino!==after.ino||before.size!==after.size||before.mtimeMs!==after.mtimeMs||before.ctimeMs!==after.ctimeMs
      ||current.dev!==after.dev||current.ino!==after.ino)throw Error('deployment_fence_changed');
   await this.assertUnlocked();return records;
  }finally{await file.close();}
 }
 async readRecords(){
  return this.#readStable();
 }
 async snapshot(){
  return reduceFenceEvents(await this.#readStable());
 }
 async verifySchemaFloor(schemaVersion){return verifySchemaFloor(schemaVersion,await this.snapshot());}
 async verify({schemaVersion,publications}){
  const snapshot=await this.snapshot();verifySchemaFloor(schemaVersion,snapshot);
  if(snapshot.pending.length||snapshot.v1Pending?.length)throw Error('deployment_fence_pending');
  if(!Array.isArray(publications))throw Error('deployment_fence_mismatch');
  for(const r of snapshot.committed){
   const fields=r.sequence===undefined?['teamID','vaultID','attemptID','manifestHash']:['teamID','vaultID','generationID','sequence','headerHash','manifestHash'];
   if(!publications.some(p=>p&&fields.every(k=>p[k]===r[k])))throw Error('deployment_fence_mismatch');
  }
  return true;
 }
}
