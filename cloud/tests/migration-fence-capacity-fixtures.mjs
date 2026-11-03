import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile,rm,stat,open} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {MigrationFence} from '../src/migration-fence.mjs';
import {FENCE_MAX_BYTES} from '../src/migration-fence-journal.mjs';

export const eventBytes=event=>Buffer.byteLength(JSON.stringify(event)+'\n');

// Virtual-file boundary fixture: retain only a few real records. The adapter
// reports historical bytes through stat and maps append offsets to the small
// real file. This tests admission arithmetic, not a full-history/service run.
export async function capacityFixture(t,{events=[],remaining}){
 const directory=await mkdtemp(join(tmpdir(),'fence-capacity-'));
 t.after(()=>rm(directory,{recursive:true,force:true}));
 const path=join(directory,'fence'),initial=events.map(event=>JSON.stringify(event)+'\n').join('');
 await writeFile(path,initial,{mode:0o600});
 const historicalBytes=FENCE_MAX_BYTES-remaining-Buffer.byteLength(initial);
 assert.ok(historicalBytes>=0);
 const calls={writes:0,fileSyncs:0,directorySyncs:0};
 const openFile=async(...args)=>{
  const handle=await open(...args),isFile=args[0]===path;
  return new Proxy(handle,{get(target,key){
   if(isFile&&key==='stat')return async()=>{const value=await target.stat();value.size+=historicalBytes;return value;};
   if(isFile&&key==='write')return (buffer,offset,length,position)=>{
    assert.ok(position>=historicalBytes);calls.writes++;
    return target.write(buffer,offset,length,position-historicalBytes);
   };
   if(key==='sync')return async()=>{isFile?calls.fileSyncs++:calls.directorySyncs++;return target.sync();};
   const value=target[key];return typeof value==='function'?value.bind(target):value;
  }});
 };
 return {path,openFile,calls,fence:new MigrationFence(path,{openFile}),
  bytes:()=>readFile(path),size:async()=>historicalBytes+(await stat(path)).size};
}
