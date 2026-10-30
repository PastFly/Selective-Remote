import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp,writeFile,readFile,lstat,chmod,chown,copyFile,cp,rm,symlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import * as installer from '../scripts/staging-reviewed-installer.mjs';

test('copied foreign-owned runtime is normalized before bundle attestation',async()=>{
 const directory=await mkdtemp(join(tmpdir(),'prc-runtime-owner-'));
 const source=join(directory,'source'),runtime=join(directory,'runtime');
 let uid=1001,gid=1001,ownerCalls=0;
 const inspect=async path=>{const st=await lstat(path);return {...st,uid,gid,isFile:()=>st.isFile(),isSymbolicLink:()=>st.isSymbolicLink()};};
 try{
  await writeFile(source,'synthetic runtime',{mode:0o755});
  await installer.installRuntimeBinary(source,runtime,{inspect,setOwner:async(path,newUID,newGID)=>{
   assert.equal(path,runtime);assert.deepEqual([newUID,newGID],[0,0]);ownerCalls++;uid=newUID;gid=newGID;
  },setMode:chmod});
  assert.equal(ownerCalls,1);
  assert.equal((await readFile(runtime,'utf8')),'synthetic runtime');
  assert.equal((await lstat(runtime)).mode&0o777,0o755);
  await installer.verifyRootRuntimeBinary(runtime,{inspect});
 }finally{await rm(directory,{recursive:true,force:true});}
});

test('missing ownership normalization and pre-existing symlink both fail closed',async()=>{
 const directory=await mkdtemp(join(tmpdir(),'prc-runtime-deny-'));
 const source=join(directory,'source'),runtime=join(directory,'runtime');
 const inspect=async path=>{const st=await lstat(path);return {...st,uid:1001,gid:1001,isFile:()=>st.isFile(),isSymbolicLink:()=>st.isSymbolicLink()};};
 try{
  await writeFile(source,'synthetic runtime');
  await assert.rejects(installer.installRuntimeBinary(source,runtime,{inspect,setOwner:async()=>{},setMode:chmod}),/staging_install_runtime_owner/);
  await rm(runtime);
  await symlink(source,runtime);
  await assert.rejects(installer.installRuntimeBinary(source,runtime,{inspect,setOwner:async()=>{},setMode:chmod}),/staging_install_runtime_owner/);
  assert.equal((await readFile(source,'utf8')),'synthetic runtime');
 }finally{await rm(directory,{recursive:true,force:true});}
});

test('Linux root copy of a foreign-owned runtime is normalized and stays root-owned after install copy',
 {skip:process.platform!=='linux'||process.getuid?.()!==0},async()=>{
  const directory=await mkdtemp(join(tmpdir(),'prc-runtime-linux-root-'));
  const source=join(directory,'source'),raw=join(directory,'raw'),runtime=join(directory,'runtime'),installed=join(directory,'installed');
  try{
   await writeFile(source,'synthetic runtime',{mode:0o755});await chown(source,1001,1001);
   await copyFile(source,raw);assert.deepEqual([(await lstat(raw)).uid,(await lstat(raw)).gid],[1001,1001]);
   await installer.installRuntimeBinary(source,runtime);await installer.verifyRootRuntimeBinary(runtime);
   await cp(runtime,installed);await installer.verifyRootRuntimeBinary(installed);
   assert.equal((await readFile(installed,'utf8')),'synthetic runtime');
  }finally{await rm(directory,{recursive:true,force:true});}
 });
