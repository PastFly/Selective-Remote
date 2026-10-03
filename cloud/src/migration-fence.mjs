import {open, mkdir, rmdir, lstat} from 'node:fs/promises';
import {constants} from 'node:fs';
import {dirname, isAbsolute} from 'node:path';
import {FENCE_MAX_BYTES,validateFenceEvent,reduceFenceEvents} from './migration-fence-journal.mjs';

function verifySchemaFloor(schemaVersion,snapshot){
 if(!Number.isSafeInteger(schemaVersion)||schemaVersion<snapshot.schemaFloor)throw Error('deployment_schema_floor');
 return true;
}
export class MigrationFence{
 #recovery=null;
 #writes=Promise.resolve();
 constructor(path,{openFile=open}={}){
  if(!isAbsolute(path))throw Error('invalid_deployment_fence_path');
  this.path=path;this.openFile=openFile;
 }
 async records(file){
  const stat=await file.stat();
  if(!stat.isFile()||stat.size>FENCE_MAX_BYTES)throw Error('corrupt_deployment_fence');
  const bytes=await file.readFile();
  if(bytes.length>FENCE_MAX_BYTES||(bytes.length&&bytes.at(-1)!==10))throw Error('corrupt_deployment_fence');
  let parsed;try{parsed=bytes.length?bytes.toString('utf8').slice(0,-1).split('\n').map(line=>JSON.parse(line)):[];}
  catch{throw Error('corrupt_deployment_fence');}
  const records=parsed.map(validateFenceEvent);reduceFenceEvents(records);return records;
 }
 async intent(record){
  const validated=validateFenceEvent(record);
  if(validated.version)throw Error('invalid_deployment_fence');
  return this.#enqueue(()=>this.#writeRecord(validated));
 }
 async append(event){
  const validated=validateFenceEvent(event);
  if(validated.version!==2)throw Error('invalid_deployment_fence');
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
   const snapshot=reduceFenceEvents(await this.records(file));
   if(snapshot.pending.length)throw Error('deployment_fence_pending');
   await file.sync();
   const dir=await this.openFile(directory,constants.O_RDONLY|constants.O_NOFOLLOW);
   try{await dir.sync();}finally{await dir.close();}
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
  let file;
  try{
   // Provisioning is an explicit operator step. Missing retained history must
   // never be replaced with an empty journal after a successful earlier check.
   file=await this.openFile(this.path,constants.O_RDWR|constants.O_NOFOLLOW);
   const records=await this.records(file);reduceFenceEvents([...records,record]);
   if(!records.some(r=>JSON.stringify(r)===key)){
    const line=Buffer.from(key+'\n'),size=(await file.stat()).size;
    if(size+line.length>FENCE_MAX_BYTES)throw Error('deployment_fence_limit');
    // A failed write or barrier leaves the lock. Only this instance's exact
    // replay can re-confirm durability; restart requires deliberate recovery.
    retain=true;
    for(let offset=0;offset<line.length;){
     const {bytesWritten}=await file.write(line,offset,line.length-offset,size+offset);
     if(!Number.isSafeInteger(bytesWritten)||bytesWritten<=0||bytesWritten>line.length-offset)throw Error('deployment_fence_short_write');
     offset+=bytesWritten;
    }
   }
   retain=true;await file.sync();
   const dir=await this.openFile(directory,constants.O_RDONLY);
   try{await dir.sync();}finally{await dir.close();}
   retain=false;
  }finally{
   if(retain)this.#recovery={key,ino:identity.ino,dev:identity.dev};
   try{await file?.close();}finally{
    if(!retain){this.#recovery=null;await rmdir(lock);}
   }
  }
 }
 async assertUnlocked(){
  try{await lstat(this.path+'.lock');}catch(e){if(e.code==='ENOENT')return;throw e;}
  throw Error('deployment_fence_locked');
 }
 async readRecords(){
  await this.assertUnlocked();
  const file=await this.openFile(this.path,constants.O_RDONLY|constants.O_NOFOLLOW);
  try{const records=await this.records(file);await this.assertUnlocked();return records;}finally{await file.close();}
 }
 async snapshot(){return reduceFenceEvents(await this.readRecords());}
 async verifySchemaFloor(schemaVersion){return verifySchemaFloor(schemaVersion,await this.snapshot());}
 async verify({schemaVersion,publications}){
  const snapshot=await this.snapshot();verifySchemaFloor(schemaVersion,snapshot);
  if(snapshot.pending.length)throw Error('deployment_fence_pending');
  if(!Array.isArray(publications))throw Error('deployment_fence_mismatch');
  for(const r of snapshot.committed){
   const fields=r.sequence===undefined?['teamID','vaultID','attemptID','manifestHash']:['teamID','vaultID','generationID','sequence','headerHash','manifestHash'];
   if(!publications.some(p=>p&&fields.every(k=>p[k]===r[k])))throw Error('deployment_fence_mismatch');
  }
  return true;
 }
}
