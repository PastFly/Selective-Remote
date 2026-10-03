import {createHash} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {readFile,writeFile,lstat,realpath,mkdtemp,mkdir,rm} from 'node:fs/promises';
import {dirname,join,resolve,isAbsolute} from 'node:path';
import {fileURLToPath} from 'node:url';
import {stagingRegistrationEmails} from '../src/staging-registration.mjs';

const execute=promisify(execFile);
export const controllerRoot='/opt/selective-remote-controller';
export const controllerState='/var/lib/selective-remote-controller';
export const publicationFenceOverlayDigest='170dd70074fb4735fc15b17d1609101cb283961fb2b1bdbe1d83a16c7b8d9576';
const nodeImage='node@sha256:1b2479dd35a99687d6638f5976fd235e26c5b37e8122f786fcd5fe231d63de5b';
const digest=value=>createHash('sha256').update(value).digest('hex');
const validHash=value=>typeof value==='string'&&/^[a-f0-9]{64}$/.test(value);
const contains=(parent,path)=>path===parent||path.startsWith(parent+'/');
function fail(code){throw Error(code);}

export function validateControllerSettings(s){
  if(!s||s.version!==1||!/^[a-f0-9]{40}$/.test(s.sourceSHA)||!/^sha256:[a-f0-9]{64}$/.test(s.imageDigest)
    ||!validHash(s.controllerDigest)||!validHash(s.envDigest)||s.cloudDirectory!=='/opt/selective-remote/cloud'
    ||s.envPath!==s.cloudDirectory+'/.env'||s.network!=='cloud_private'
    ||s.fencePath!==controllerState+'/publication/journal'||!isAbsolute(s.backupDirectory??'')
    ||!Array.isArray(s.composeFiles)||!s.composeFiles.length||s.composeFiles.length>10
    ||new Set(s.composeFiles.map(f=>f.path)).size!==s.composeFiles.length
    ||s.composeFiles.some(f=>!isAbsolute(f.path??'')||!validHash(f.sha256))
    ||s.composeFiles.filter(f=>f.sha256===publicationFenceOverlayDigest).length!==1
    ||!s.storage||['POSTGRES_DATA_MOUNT_ROOT','POSTGRES_DATA_HOST_PATH','POSTGRES_DATA_EXPECTED_SOURCE','POSTGRES_DATA_EXPECTED_FSTYPE','POSTGRES_DATA_UID','POSTGRES_DATA_GID'].some(k=>typeof s.storage[k]!=='string'||!s.storage[k]))fail('invalid_deployment_settings');
  for(const path of [s.cloudDirectory,s.backupDirectory,s.storage.POSTGRES_DATA_MOUNT_ROOT,s.storage.POSTGRES_DATA_HOST_PATH]){
    if(!isAbsolute(path)||resolve(path)!==path||contains(path,controllerRoot)||contains(controllerRoot,path)
      ||contains(path,controllerState)||contains(controllerState,path))fail('deployment_fence_not_independent');
  }
  return s;
}
export function validateCandidateIdentity(settings,image){
  if(image?.Id!==settings.imageDigest||image.Config?.Labels?.['org.opencontainers.image.revision']!==settings.sourceSHA)
    fail('deployment_candidate_digest');
}
export function validateCandidateCapabilities(candidate){
  const expected={version:1,fenceVersion:2,maxSchemaVersion:22,readerProjectionVersion:1,wholePublicationVersion:1};
  if(!candidate||Object.keys(candidate).length!==5||Object.entries(expected).some(([k,v])=>candidate[k]!==v))fail('deployment_code_floor');
}
function safeBind(bind){
  return bind!==null&&typeof bind==='object'&&!Array.isArray(bind)
    &&Object.keys(bind).every(key=>key==='create_host_path')
    &&(!Object.hasOwn(bind,'create_host_path')||bind.create_host_path===false);
}
function environmentMap(values){
  if(!Array.isArray(values))fail('deployment_environment_mismatch');
  const result=Object.create(null);
  for(const entry of values){
    if(typeof entry!=='string'||/[\r\n\0]/.test(entry))fail('deployment_environment_mismatch');
    const index=entry.indexOf('='),key=entry.slice(0,index);
    if(index<1||!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)||Object.hasOwn(result,key))fail('deployment_environment_mismatch');
    result[key]=entry.slice(index+1);
  }
  return result;
}
function effectiveEnvironment(cloud,{imageEnvironment,dockerEnvironment}={}){
  const base=environmentMap(imageEnvironment),expected=environmentMap(dockerEnvironment),actual={...base};
  if(!cloud.environment||Array.isArray(cloud.environment)||typeof cloud.environment!=='object')fail('deployment_environment_mismatch');
  for(const [key,value] of Object.entries(cloud.environment)){
    if(!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)||!['string','boolean','number'].includes(typeof value)||/[\r\n\0]/.test(String(value)))fail('deployment_environment_mismatch');
    actual[key]=String(value);
  }
  const overrides={PUBLICATION_FENCE_PATH:'/publication-fence/journal',ALLOW_REGISTRATION:'false',UV_THREADPOOL_SIZE:'1',NODE_OPTIONS:'--max-old-space-size=96'};
  for(const key of new Set([...Object.keys(expected),...Object.keys(actual)]))
    if(actual[key]!==expected[key]&&!(Object.hasOwn(overrides,key)&&actual[key]===overrides[key]))fail('deployment_environment_mismatch');
  if(actual.ALLOW_REGISTRATION!=='false'){
    if(actual.ALLOW_REGISTRATION!=='true'||expected.ALLOW_REGISTRATION!=='true')fail('deployment_registration_scope');
    try{if(!stagingRegistrationEmails(actual.STAGING_REGISTRATION_EMAIL_ALLOWLIST,actual.PUBLICATION_ENVIRONMENT))fail('deployment_registration_scope');}
    catch{fail('deployment_registration_scope');}
  }
  return actual;
}
export function validateControllerProject(network,containers){
  if(network?.Name!=='cloud_private'||network.Labels?.['com.docker.compose.project']!=='cloud'
    ||network.Labels?.['com.docker.compose.network']!=='private'||!Array.isArray(containers))fail('deployment_project_mismatch');
  const seen=new Set();
  for(const container of containers){
    const labels=container.Config?.Labels??{},service=labels['com.docker.compose.service'],managed=labels['com.docker.compose.project']==='cloud';
    const attached=Object.hasOwn(container.NetworkSettings?.Networks??{},'cloud_private');
    const published=Object.values(container.NetworkSettings?.Ports??{}).flatMap(value=>value??[]);
    const publicListener=published.some(binding=>['80','443'].includes(binding.HostPort));
    if((attached||managed||publicListener)&&(!container.State?.Running||!managed||!['cloud','caddy','postgres'].includes(service)||!attached))fail('deployment_project_mismatch');
    if(managed){if(seen.has(service)||publicListener&&service!=='caddy')fail('deployment_project_mismatch');seen.add(service);}
  }
  if(!seen.has('postgres'))fail('deployment_project_mismatch');
}
export function validateControllerCompose(model,settings,environment){
  if(model?.name!=='cloud')fail('deployment_project_mismatch');
  const envFiles=environment?.envFiles;
  if(!Array.isArray(envFiles)||envFiles.length!==1)fail('deployment_environment_mismatch');
  const input=envFiles[0];
  if(typeof input==='string'?input!==settings.envPath:
    !input||input.path!==settings.envPath||Object.keys(input).some(key=>!['path','required'].includes(key))||input.required===false)fail('deployment_environment_mismatch');
  const services=model?.services??{},cloud=services.cloud,postgres=services.postgres;
  if(!cloud||!postgres||!services.caddy||Object.keys(services).sort().join(',')!=='caddy,cloud,postgres'
    ||cloud.image!==settings.imageDigest||cloud.build!=null||cloud.command!=null||cloud.entrypoint!=null
    ||cloud.pull_policy!=='never'||cloud.environment?.PUBLICATION_FENCE_PATH!=='/publication-fence/journal')fail('deployment_compose_mismatch');
  if([cloud,postgres].some(s=>(s.ports??[]).length)||[cloud,postgres,services.caddy].some(s=>s.restart!=='on-failure:3'))fail('deployment_compose_mismatch');
  const mounts=cloud.volumes??[];
  if(mounts.length!==1||mounts[0].type!=='bind'||mounts[0].source!==dirname(settings.fencePath)
    ||mounts[0].target!=='/publication-fence'||mounts[0].read_only===true||!safeBind(mounts[0].bind))
    fail('deployment_fence_mount');
  // The independent history may never enter a DB volume/backup or another service.
  for(const service of [postgres,services.caddy])for(const m of service.volumes??[])
    if(m.source&&contains(controllerState,resolve(m.source)))fail('deployment_fence_mount');
  const pg=(postgres.volumes??[]).filter(m=>m.target==='/var/lib/postgresql/data');
  if(pg.length!==1||pg[0].type!=='bind'||pg[0].source!==settings.storage.POSTGRES_DATA_HOST_PATH||!safeBind(pg[0].bind))
    fail('deployment_storage_mount');
  const privateNetwork=model.networks?.private;
  if(privateNetwork?.name!==settings.network||Object.values(services).some(s=>!s.networks||Object.keys(s.networks).join(',')!=='private'))
    fail('deployment_network_mismatch');
  if(cloud.privileged||cloud.network_mode||cloud.pid||cloud.devices?.length||cloud.volumes_from?.length)fail('deployment_compose_mismatch');
  return effectiveEnvironment(cloud,environment);
}

// Production uses this exact orchestration. Tests substitute command transport,
// then run the retained compatibility checker against a real disposable DB.
export async function verifyControllerFixture({candidate,runCommand,report=()=>{},maintenance=false}){
  const step=async(stage,extra={})=>{report({stage});return runCommand({stage,candidate,...extra});};
  await step('attest');
  const metadata=await step('candidate-metadata');
  validateCandidateCapabilities(metadata);
  await step('storage');
  await step('assert-project');
  // Ordinary startup denies a restored old schema without even stopping the
  // current deployment. Explicit initial maintenance closes traffic FIRST.
  if(!maintenance)await step('check',{metadata,mode:'traffic'});
  await step('close-traffic');
  await step('assert-closed');
  await step('check',{metadata,mode:'maintenance-upgrade'});
  await step('migrate');
  await step('check',{metadata,mode:'traffic'});
  await step('attest');
  await step('open-traffic');
  report({stage:'complete',trafficOpened:true});
  return {compatible:true,trafficOpened:true};
}

async function protectedPath(path,{directory=false}={}){
  if(!isAbsolute(path)||await realpath(path)!==path)fail('deployment_controller_permissions');
  for(let current=path;;current=dirname(current)){
    const stat=await lstat(current);
    if(stat.isSymbolicLink()||stat.uid!==0||(stat.mode&0o022)!==0
      ||(current===path&&(directory?!stat.isDirectory():!stat.isFile())))fail('deployment_controller_permissions');
    if(current==='/')break;
  }
}
async function pinnedFile(path,hash){await protectedPath(path);if(digest(await readFile(path))!==hash)fail('deployment_candidate_digest');}
async function invoke(file,args,options={}){
  try{return await execute(file,args,{encoding:'utf8',timeout:120000,maxBuffer:4*1024*1024,...options});}
  catch(error){
    const diagnostic=error.stderr?.trim();
    fail(/^[a-z_]+$/.test(diagnostic??'')?diagnostic:'deployment_controller_command_failed');
  }
}
export async function runController({maintenance=false}={}){
  if(process.getuid?.()!==0||resolve(dirname(fileURLToPath(import.meta.url)),'..')!==controllerRoot)fail('deployment_controller_owner');
  await protectedPath(join(controllerRoot,'settings.json'));
  const settings=validateControllerSettings(JSON.parse(await readFile(join(controllerRoot,'settings.json'),'utf8')));
  await protectedPath(controllerState,{directory:true});
  await protectedPath(settings.backupDirectory,{directory:true});
  const fenceDirectory=dirname(settings.fencePath);
  if(await realpath(fenceDirectory)!==fenceDirectory||!(await lstat(fenceDirectory)).isDirectory())fail('deployment_fence_mount');
  const lock=join(controllerState,'controller.lock');
  try{await mkdir(lock,{mode:0o700});}catch{fail('deployment_controller_locked');}
  let temp;
  try{
    temp=await mkdtemp(join(controllerState,'candidate-'));
    const env={PATH:'/usr/bin:/bin',...settings.storage,PUBLICATION_IMAGE_DIGEST:settings.imageDigest,PUBLICATION_FENCE_DIRECTORY:dirname(settings.fencePath)};
    const compose=['compose','--project-name','cloud','--project-directory',settings.cloudDirectory,'--env-file',settings.envPath,...settings.composeFiles.flatMap(f=>['-f',f.path])];
    const docker=(args,options={})=>invoke('/usr/bin/docker',args,{env,...options});
    let imageEnvironment,dockerEnvironment;
    const attest=async()=>{
      await protectedPath(join(controllerRoot,'bundle.sha256'));
      if(digest(await readFile(join(controllerRoot,'bundle.sha256')))!==settings.controllerDigest)fail('deployment_controller_digest');
      await invoke('/usr/bin/sha256sum',['--strict','--status','-c','bundle.sha256'],{cwd:controllerRoot,env});
      await pinnedFile(settings.envPath,settings.envDigest);
      for(const f of settings.composeFiles)await pinnedFile(f.path,f.sha256);
      const image=JSON.parse((await docker(['image','inspect','--format','{{json .}}',settings.imageDigest])).stdout);
      validateCandidateIdentity(settings,image);imageEnvironment=image.Config?.Env;
    };
    const inspectProject=async()=>{
      const network=JSON.parse((await docker(['network','inspect','--format','{{json .}}',settings.network])).stdout);
      const ids=(await docker(['ps','--quiet','--no-trunc'])).stdout.trim().split(/\s+/).filter(Boolean);
      if(ids.some(id=>!/^[a-f0-9]{64}$/.test(id)))fail('deployment_project_mismatch');
      const containers=ids.length?JSON.parse((await docker(['inspect',...ids])).stdout):[];
      validateControllerProject(network,containers);
    };
    return await verifyControllerFixture({candidate:settings,maintenance,report:event=>process.stdout.write(JSON.stringify(event)+'\n'),runCommand:async({stage,metadata,mode})=>{
      if(stage==='attest')return attest();
      if(stage==='candidate-metadata'){
        const id=(await docker(['create','--network','none','--env-file',settings.envPath,'--entrypoint','/bin/true',settings.imageDigest])).stdout.trim();
        if(!/^[a-f0-9]{64}$/.test(id))fail('deployment_candidate_metadata');
        try{
          dockerEnvironment=JSON.parse((await docker(['inspect','--format','{{json .Config.Env}}',id])).stdout);
          await docker(['cp',id+':/app/deployment-compatibility.json',join(temp,'candidate.json')]);
        }
        finally{await docker(['rm',id]);}
        const bytes=await readFile(join(temp,'candidate.json'));if(bytes.length>4096)fail('deployment_candidate_metadata');
        return JSON.parse(bytes);
      }
      if(stage==='storage'){
        await invoke('/bin/bash',[join(controllerRoot,'scripts/validate-postgres-storage.sh'),'--check'],{env});
        await invoke(process.execPath,[join(controllerRoot,'scripts/validate-postgres-bind-source.mjs'),...settings.composeFiles.map(f=>f.path)],{env});
        const unresolved=JSON.parse((await docker([...compose,'config','--no-env-resolution','--format','json'])).stdout);
        if(['postgres','caddy'].some(service=>unresolved.services?.[service]?.env_file?.length))fail('deployment_environment_mismatch');
        const model=JSON.parse((await docker([...compose,'config','--format','json'])).stdout);
        const effective=validateControllerCompose(model,settings,{imageEnvironment,dockerEnvironment,envFiles:unresolved.services?.cloud?.env_file});
        await writeFile(join(temp,'effective.env'),Object.entries(effective).map(([key,value])=>key+'='+value).join('\n')+'\n',{mode:0o600,flag:'wx'});return;
      }
      if(stage==='assert-project')return inspectProject();
      if(stage==='close-traffic')return docker([...compose,'stop','cloud','caddy']);
      if(stage==='assert-closed'){
        const running=(await docker([...compose,'ps','--status','running','--services'])).stdout.trim().split(/\s+/);
        if(running.some(name=>name==='cloud'||name==='caddy'))fail('deployment_traffic_not_closed');await inspectProject();return;
      }
      if(stage==='check'){
        // A fresh process reads the independently retained checker + journal.
        // Candidate code is never used to decide whether it is safe to start.
        return docker(['run','--rm','--pull=never','--network',settings.network,'--read-only','--cap-drop','ALL','--security-opt','no-new-privileges',
          '--env-file',join(temp,'effective.env'),
          '--mount',`type=bind,src=${controllerRoot},dst=/controller,readonly`,
          '--mount',`type=bind,src=${dirname(settings.fencePath)},dst=/publication-fence,readonly`,
          '--mount',`type=bind,src=${join(temp,'candidate.json')},dst=/candidate.json,readonly`,
          nodeImage,'node','/controller/scripts/check-deployment-compatibility.mjs','--candidate','/candidate.json',...(mode==='maintenance-upgrade'?['--maintenance-upgrade']:[])]);
      }
      if(stage==='migrate')return docker(['run','--rm','--pull=never','--network',settings.network,'--read-only','--cap-drop','ALL','--security-opt','no-new-privileges',
        '--env-file',join(temp,'effective.env'),'--entrypoint','node',settings.imageDigest,'scripts/migrate.mjs']);
      if(stage==='open-traffic')return docker([...compose,'up','-d','--no-build','--pull','never','--no-deps','cloud','caddy']);
      fail('invalid_deployment_stage');
    }});
  }finally{if(temp)await rm(temp,{recursive:true,force:true});await rm(lock,{recursive:true});}
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  try{
    const args=process.argv.slice(2);
    if(args.length>1||args.length===1&&args[0]!=='--maintenance-upgrade')fail('invalid_deployment_arguments');
    await runController({maintenance:args.length===1});
  }catch(error){process.stderr.write(/^[a-z_]+$/.test(error?.message??'')?error.message+'\n':'deployment_controller_failed\n');process.exitCode=1;}
}
