import assert from 'node:assert/strict';
import test from 'node:test';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {readControllerComposeEnvironment} from '../scripts/verify-staging-controller.mjs';

const execute=promisify(execFile);
const settings={imageDigest:'sha256:'+'b'.repeat(64),envPath:'/opt/selective-remote/cloud/.env',
 network:'cloud_private',fencePath:'/var/lib/selective-remote-controller/publication/journal',
 storage:{POSTGRES_DATA_HOST_PATH:'/mnt/pg/data'}};
const compose=['compose','--project-name','cloud','--project-directory','/opt/selective-remote/cloud',
 '--env-file',settings.envPath,'-f','/opt/selective-remote/cloud/compose.yaml'];
const evidence={imageEnvironment:['NODE_ENV=production'],dockerEnvironment:[
 'NODE_ENV=production','DATABASE_URL=postgres://synthetic@postgres/checked','SESSION_TOKEN_PEPPER=synthetic-protected-value']};
function fixture(){
 return {
  // Compose 2.40.3's raw model retains env_file and the environment list.
  raw:{name:'cloud',services:{
   cloud:{env_file:[{path:settings.envPath,required:true}],environment:['DATABASE_URL=${DATABASE_URL}','ALLOW_REGISTRATION=false']},
   postgres:{},caddy:{},
  }},
  resolved:{name:'cloud',networks:{private:{name:'cloud_private'}},services:{
   cloud:{image:settings.imageDigest,pull_policy:'never',restart:'on-failure:3',networks:{private:{}},
    environment:{DATABASE_URL:'postgres://synthetic@postgres/checked',SESSION_TOKEN_PEPPER:'synthetic-protected-value',
     PUBLICATION_FENCE_PATH:'/publication-fence/journal',ALLOW_REGISTRATION:'false'},
    volumes:[{type:'bind',source:'/var/lib/selective-remote-controller/publication',target:'/publication-fence',bind:{create_host_path:false}}]},
   postgres:{restart:'on-failure:3',networks:{private:{}},volumes:[
    {type:'bind',source:'/mnt/pg/data',target:'/var/lib/postgresql/data',bind:{create_host_path:false}}]},
   caddy:{restart:'on-failure:3',networks:{private:{}}},
  }},
 };
}
async function withDocker(input,check){
 const directory=await mkdtemp(join(tmpdir(),'controller-compose-env-files-'));
 try{
  const script=join(directory,'docker.mjs'),data=join(directory,'models.json'),log=join(directory,'calls.jsonl');
  await writeFile(data,JSON.stringify(input));
  await writeFile(script,`import {readFile,appendFile} from 'node:fs/promises';
const [data,log,...args]=process.argv.slice(2);
await appendFile(log,JSON.stringify(args)+'\\n');
if(args[0]!=='compose'||!args.includes('config')||args.at(-2)!=='--format'||args.at(-1)!=='json')process.exit(2);
const models=JSON.parse(await readFile(data,'utf8'));
// Observed Compose 2.40.3 behavior: --no-env-resolution alone still loses env_file.
process.stdout.write(JSON.stringify(args.includes('--no-interpolate')?models.raw:models.resolved));
`);
  const docker=args=>execute(process.execPath,['--',script,data,log,...args],{encoding:'utf8',timeout:5000});
  await check(docker,async()=>JSON.parse('['+(await readFile(log,'utf8')).trim().split('\n').join(',')+']'));
 }finally{await rm(directory,{recursive:true,force:true});}
}

test('controller retains Compose env_file metadata and validates the separately resolved environment',async()=>{
 await withDocker(fixture(),async(docker,calls)=>{
  const effective=await readControllerComposeEnvironment(docker,compose,settings,evidence);
  assert.equal(effective.DATABASE_URL,'postgres://synthetic@postgres/checked');
  assert.equal(effective.SESSION_TOKEN_PEPPER,'synthetic-protected-value');
  assert.equal(effective.NODE_ENV,'production');
  assert.deepEqual((await calls()).map(args=>args.slice(compose.length)),[
   ['config','--no-env-resolution','--no-interpolate','--format','json'],
   ['config','--format','json'],
  ]);
 });
});

test('missing, alternate and variable env_file metadata stays denied',async t=>{
 for(const [name,envFiles] of [
  ['missing',undefined],['empty',[]],['alternate',[{path:'/opt/unpinned.env',required:true}]],
  ['variable',[{path:'${CONTROLLER_ENV_PATH}',required:true}]],
  ['additional',[{path:settings.envPath,required:true},{path:'/opt/unpinned.env',required:true}]],
  ['optional',[{path:settings.envPath,required:false}]],
 ])await t.test(name,async()=>{
  const input=fixture();input.raw.services.cloud.env_file=envFiles;
  await withDocker(input,async docker=>{
   await assert.rejects(readControllerComposeEnvironment(docker,compose,settings,evidence),/deployment_environment_mismatch/);
  });
 });
});

test('PostgreSQL and Caddy env_file injections stay denied before reading resolved configuration',async t=>{
 for(const service of ['postgres','caddy'])await t.test(service,async()=>{
  const input=fixture();input.raw.services[service].env_file=[{path:settings.envPath,required:true}];
  await withDocker(input,async(docker,calls)=>{
   await assert.rejects(readControllerComposeEnvironment(docker,compose,settings,evidence),/deployment_environment_mismatch/);
   assert.equal((await calls()).length,1);
  });
 });
});

test('retained metadata cannot hide a resolved environment or mount mismatch',async t=>{
 for(const [name,mutate,error] of [
  ['database URL',model=>model.services.cloud.environment.DATABASE_URL='postgres://synthetic@postgres/unchecked',/deployment_environment_mismatch/],
  ['fence mount',model=>model.services.cloud.volumes[0].source='/tmp/unreviewed',/deployment_fence_mount/],
 ])await t.test(name,async()=>{
  const input=fixture();mutate(input.resolved);
  await withDocker(input,async docker=>{
   await assert.rejects(readControllerComposeEnvironment(docker,compose,settings,evidence),error);
  });
 });
});
