import assert from 'node:assert/strict';
import test from 'node:test';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {fileURLToPath} from 'node:url';
import * as operator from '../scripts/staging-migration-operator-helper.mjs';

const script=fileURLToPath(new URL('../scripts/vault-v2-migration-staging.mjs',import.meta.url));
async function deniedWithoutStdin(command,args,env){
 const child=spawn(command,args,{env,stdio:['pipe','pipe','pipe']});
 let stdout='',stderr='';child.stdout.on('data',bytes=>stdout+=bytes);child.stderr.on('data',bytes=>stderr+=bytes);
 const timeout=setTimeout(()=>child.kill(),3000);
 try{const [code,signal]=await once(child,'exit');assert.equal(signal,null,'must reject before waiting on open stdin');assert.notEqual(code,0);assert.equal(stdout,'');return stderr.trim();}
 finally{clearTimeout(timeout);child.stdin.destroy();}
}
test('host-only fault flag accepts exactly two fixed points and only activate requests',()=>{
 assert.equal(typeof operator.operatorActivationFault,'function');
 assert.equal(operator.operatorActivationFault([]),undefined);
 for(const point of ['before_commit','after_commit']){
  const args=['--activation-fault',point];assert.equal(operator.operatorActivationFault(args),point);
  assert.equal(operator.operatorActivationFault(args,{operation:'activate'}),point);
  for(const request of [{operation:'preview'},{operation:'reconcile-fence'},null])assert.throws(()=>operator.operatorActivationFault(args,request),/staging_operator_/);
 }
 for(const args of [['--activation-fault'],['--activation-fault','active_pointer'],['--activation-fault','after_commit','extra'],['--other','before_commit']])
  assert.throws(()=>operator.operatorActivationFault(args),/staging_operator_arguments/);
});
test('ordinary migration CLI rejects fault/unknown argv before reading stdin',async()=>{
 for(const args of [['--activation-fault','before_commit'],['--other']])
  assert.equal(await deniedWithoutStdin(process.execPath,[script,...args],{MIGRATION_ENVIRONMENT:'staging',MIGRATION_SYNTHETIC_ENABLED:'YES'}),'invalid_migration_arguments');
});
test('nonstaging CLI and unprivileged/uninstalled host helper reject before stdin',async()=>{
 assert.equal(await deniedWithoutStdin(process.execPath,[script],{MIGRATION_ENVIRONMENT:'production',MIGRATION_SYNTHETIC_ENABLED:'YES'}),'migration_staging_only');
 assert.equal(await deniedWithoutStdin(process.execPath,[fileURLToPath(new URL('../scripts/staging-migration-operator-helper.mjs',import.meta.url)),'--activation-fault','before_commit'],{}),'staging_operator_owner');
});

test('internal stdin adapter rejects invalid fault and nonstaging environment before awaiting input',async()=>{
 for(const [option,environment,want] of [
  [{activationFault:'active_pointer'},'staging','invalid_migration_activation_fault'],
  [{activationFault:'after_commit',extra:true},'staging','invalid_migration_activation_fault'],
  [{activationFault:'after_commit'},'production','migration_staging_only'],
 ]){
  const code="try{const {runStagingMigrationInput}=await import("+JSON.stringify(new URL('../scripts/vault-v2-migration-staging.mjs',import.meta.url).href)+");await runStagingMigrationInput("+JSON.stringify(option)+");}catch(error){process.stderr.write(error.message+'\\n');process.exitCode=1;}";
  assert.equal(await deniedWithoutStdin(process.execPath,['--input-type=module','-e',code],{MIGRATION_ENVIRONMENT:environment,MIGRATION_SYNTHETIC_ENABLED:'YES'}),want);
 }
});
test('retained host shell rejects unsupported points and extra args before stdin or installed-file access',async()=>{
 const wrapper=fileURLToPath(new URL('../scripts/staging-migration-operator.sh',import.meta.url));
 for(const args of [['--activation-fault','active_pointer'],['--activation-fault','before_commit','extra']])
  assert.equal(await deniedWithoutStdin('/bin/bash',[wrapper,...args],{}),'staging_operator_arguments');
});
