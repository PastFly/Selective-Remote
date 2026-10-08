import {createHash} from 'node:crypto';
import {execFile,spawn} from 'node:child_process';
import {promisify} from 'node:util';
import {createReadStream,createWriteStream} from 'node:fs';
import {readFile,writeFile,lstat,realpath,mkdir,readdir,copyFile,cp,chmod,chown,rename,open} from 'node:fs/promises';
import {dirname,join,resolve,isAbsolute} from 'node:path';
import {fileURLToPath} from 'node:url';
import {pipeline} from 'node:stream/promises';
const execute=promisify(execFile),cloud='/opt/selective-remote/cloud',root='/opt/selective-remote-controller',state='/var/lib/selective-remote-controller';
const archiveSHA='c1bfeecf1d7404fa74728f9db72e697decbd8119ccc6f5a294d795756dfcfca7';
const hash=value=>createHash('sha256').update(value).digest('hex'),hex=(value,n)=>typeof value==='string'&&new RegExp('^[a-f0-9]{'+n+'}$').test(value);
const fail=code=>{throw Error('staging_install_'+code);};
const same=(a,b)=>a&&b&&['sourceSHA','tree','imageDigest','controllerDigest'].every(key=>a[key]===b[key]);
function identity(value){return value&&hex(value.sourceSHA,40)&&hex(value.tree,40)&&/^sha256:[a-f0-9]{64}$/.test(value.imageDigest)&&hex(value.controllerDigest,64);}
export function validateInstallationPlan(plan){
 if(!plan||plan.version!==1||plan.environment!=='staging'||!/^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$/.test(plan.runID)
  ||!hex(plan.sourceSHA,40)||!hex(plan.tree,40)||!/^refs\/heads\/[A-Za-z0-9][A-Za-z0-9_./-]*$/.test(plan.ref)||plan.ref.includes('..')
  ||plan.backupDirectory!=='/var/backups/selective-remote'||!plan.expected||!hex(plan.expected.sourceSHA,40)||!hex(plan.expected.tree,40)
  ||!hex(plan.expected.envDigest,64)||!/^sha256:[a-f0-9]{64}$/.test(plan.expected.imageDigest)||plan.expected.schema!==12
  ||plan.sourceSHA===plan.expected.sourceSHA||!Array.isArray(plan.composeFiles)||plan.composeFiles.join(',')!=='compose.yaml,compose.443-only.yaml,compose.small-host.yaml,compose.publication-fence.yaml,compose.postgres-bind.yaml'
  ||!plan.storage||['POSTGRES_DATA_MOUNT_ROOT','POSTGRES_DATA_HOST_PATH','POSTGRES_DATA_EXPECTED_SOURCE','POSTGRES_DATA_EXPECTED_FSTYPE','POSTGRES_DATA_UID','POSTGRES_DATA_GID'].some(key=>typeof plan.storage[key]!=='string'||!plan.storage[key]))fail('plan');
 if(plan.reviewedIdentity!==undefined&&(!identity(plan.reviewedIdentity)||plan.reviewedIdentity.sourceSHA!==plan.sourceSHA||plan.reviewedIdentity.tree!==plan.tree))fail('identity');
 return plan;
}
function verifyFacts(plan,facts){
 if(!facts||!facts.clean||facts.controllerExists||facts.stateExists||!Number.isSafeInteger(facts.rootFreeBytes)||facts.rootFreeBytes<1024**3||facts.platform!=='linux'||facts.arch!=='x64'||facts.nodeVersion!=='v22.18.0'
  ||['sourceSHA','tree','envDigest','imageDigest','schema'].some(key=>facts[key]!==plan.expected[key]))fail('preflight');
}
export async function runReviewedInstallation({phase,plan,runCommand,dryRun=false,report=()=>{}}){
 validateInstallationPlan(plan);if(!['prepare','backup','install'].includes(phase))fail('arguments');
 const step=async(stage,extra={})=>{report({phase,stage});return runCommand({stage,plan,...extra});};
 verifyFacts(plan,await step('inspect'));
 if(phase==='prepare'){const ref=await step('candidate-ref');if(ref?.sourceSHA!==plan.sourceSHA||ref.tree!==plan.tree)fail('candidate_source');}
 let prepared;
 if(phase!=='prepare'){
  if(!identity(plan.reviewedIdentity))fail('identity');
  prepared=await step('prepared');
  if(!identity(prepared?.identity)||!same(prepared.identity,plan.reviewedIdentity))fail('identity');
 }
 if(phase==='install'){
  const proof=await step('backup-proof');if(proof?.verified!==true||proof.baselineVerified!==true)fail('backup_required');
 }
 if(dryRun)return {dryRun:true,phase};
 if(phase==='prepare')return step('prepare');
 let closed=false;
 try{
  // Set before dispatch: even a lost stop reply must never trigger reopening.
  closed=true;await step('close-traffic');await step('assert-closed');
  if(phase==='backup')return await step('backup');
  await step('install');await step('activate-controller');await step('acceptance');
  return {installed:true,...prepared.identity};
 }catch(error){if(closed)await step('keep-closed').catch(()=>{});throw error;}
}
async function exists(path){try{await lstat(path);return true;}catch(e){if(e.code==='ENOENT')return false;throw e;}}
async function protectedDirectory(path,{privateMode=false}={}){
 if(await realpath(path)!==path)fail('permissions');
 for(let current=path;;current=dirname(current)){
  const st=await lstat(current);
  if(!st.isDirectory()||st.isSymbolicLink()||st.uid!==0||(st.mode&0o022)!==0||(current===path&&privateMode&&(st.mode&0o777)!==0o700))fail('permissions');
  if(current==='/')break;
 }
}
async function privateFile(path){
 if(!isAbsolute(path)||await realpath(path)!==path)fail('permissions');
 const st=await lstat(path),parent=await lstat(dirname(path));
 if(!st.isFile()||st.uid!==0||(st.mode&0o777)!==0o600||parent.uid!==0||(parent.mode&0o022)!==0)fail('permissions');
 return readFile(path);
}
async function json(path){try{return JSON.parse((await privateFile(path)).toString('utf8'));}catch(e){if(e.message.startsWith('staging_install_'))throw e;fail('evidence');}}
async function save(path,value){const file=await open(path,'wx',0o600);try{await file.writeFile(typeof value==='string'?value:JSON.stringify(value));await file.sync();}finally{await file.close();}const dir=await open(dirname(path),'r');try{await dir.sync();}finally{await dir.close();}}
async function command(file,args,options={}){
 try{return await execute(file,args,{encoding:'utf8',timeout:300000,maxBuffer:4*1024*1024,env:{PATH:'/usr/bin:/bin'},...options});}
 catch{fail('command_failed');}
}
async function streamDocker(args,{input,output}){
 const child=spawn('/usr/bin/docker',args,{env:{PATH:'/usr/bin:/bin'},stdio:['pipe',output?'pipe':'ignore','ignore']});
 const done=new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',code=>code===0?resolve():reject(Error('staging_install_command_failed')));});
 try{await Promise.all([done,input?pipeline(createReadStream(input),child.stdin):Promise.resolve(child.stdin.end()),output?pipeline(child.stdout,createWriteStream(output,{flags:'wx',mode:0o600})):Promise.resolve()]);}
 catch{child.kill('SIGTERM');fail('command_failed');}
}
async function bundleManifest(directory){
 const files=[];
 const walk=async path=>{for(const entry of await readdir(path,{withFileTypes:true})){const full=join(path,entry.name);if(entry.isSymbolicLink())fail('bundle_symlink');if(entry.isDirectory())await walk(full);else if(entry.isFile())files.push(full);else fail('bundle_file');}};
 await walk(directory);files.sort();
 return (await Promise.all(files.map(async file=>hash(await readFile(file))+'  '+file.slice(directory.length+1)))).join('\n')+'\n';
}
function parseEnvironment(list){
 if(!Array.isArray(list))fail('environment');const env={};
 for(const entry of list){const pos=entry.indexOf('=');if(pos<1||/[\r\n\0]/.test(entry))fail('environment');const key=entry.slice(0,pos);if(!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)||Object.hasOwn(env,key))fail('environment');env[key]=entry.slice(pos+1);}
 return env;
}
const envText=env=>Object.entries(env).map(([key,value])=>key+'='+value).join('\n')+'\n';
export function validateRunningPostgres(container,storage,env,image){
 const expected='postgres:16.6-alpine@sha256:1d04b9ba1d4996401f2552b51beda8187f175c0645c091e4781134fc9c9a3eef';
 const actual=parseEnvironment(container?.Config?.Env);
 let url;try{url=new URL(env.DATABASE_URL);}catch{fail('postgres_binding');}
 const mounts=container?.Mounts?.filter(m=>m.Destination==='/var/lib/postgresql/data');
 if(container?.State?.Running!==true||container.Config.Image!==expected||image?.Id!==container.Image
  ||!image.RepoDigests?.some(ref=>ref.split('@')[1]===expected.split('@')[1])||mounts?.length!==1||mounts[0].Type!=='bind'||mounts[0].Source!==storage.POSTGRES_DATA_HOST_PATH||mounts[0].RW!==true
  ||actual.PGDATA!=='/var/lib/postgresql/data'||['POSTGRES_USER','POSTGRES_DB','POSTGRES_PASSWORD'].some(k=>!env[k]||actual[k]!==env[k])
  ||!['postgres:','postgresql:'].includes(url.protocol)||url.hostname!=='postgres'||url.port&&url.port!=='5432'
  ||decodeURIComponent(url.username)!==env.POSTGRES_USER||decodeURIComponent(url.password)!==env.POSTGRES_PASSWORD||decodeURIComponent(url.pathname)!=='/'+env.POSTGRES_DB||url.search||url.hash)fail('postgres_binding');
 return true;
}
async function runHost(phase,planPath,archivePath,dryRun){
 if(process.getuid?.()!==0)fail('owner');
 const plan=validateInstallationPlan(await json(planPath));
 if(hash(await readFile(archivePath))!==archiveSHA)fail('runtime_digest');
 const run=join(plan.backupDirectory,'pr-c-'+plan.runID),bundle=join(run,'bundle'),candidate=join(run,'candidate'),preparedPath=join(run,'prepared.json');
 const docker=(args,options)=>command('/usr/bin/docker',args,options);
 const git=(args,options)=>command('/usr/bin/git',args,options);
 const pg=(sql,db)=>docker(['exec','cloud-postgres-1','sh','-ceu',
  'exec psql --no-psqlrc --tuples-only --no-align --username="$POSTGRES_USER" --dbname="${1:-$POSTGRES_DB}" --command="$2"','sh',db??'',sql]);
 const basePlan={...plan};delete basePlan.reviewedIdentity;const planDigest=hash(JSON.stringify(basePlan));
 const verifyPostgres=async()=>{const c=JSON.parse((await docker(['inspect','--format','{{json .}}','cloud-postgres-1'])).stdout);const image=JSON.parse((await docker(['image','inspect','--format','{{json .}}',c.Image])).stdout);const env=parseEnvironment((await privateFile(cloud+'/.env')).toString().trimEnd().split('\n'));validateRunningPostgres(c,plan.storage,env,image);const actual=(await pg('SHOW data_directory')).stdout.trim();if(actual!=='/var/lib/postgresql/data')fail('postgres_binding');};
 const stop=()=>docker(['stop','cloud-cloud-1','cloud-caddy-1']);
 const closed=async()=>{for(const name of ['cloud-cloud-1','cloud-caddy-1'])if((await docker(['inspect','--format','{{.State.Running}}',name])).stdout.trim()!=='false')fail('traffic_open');};
 let prepared;
 const loadPrepared=async()=>{
  const value=await json(preparedPath);if(value.planDigest!==planDigest||!identity(value.identity))fail('identity');
  if(hash(await privateFile(join(run,'effective.env')))!==value.envDigest||hash(await readFile(join(bundle,'bundle.sha256')))!==value.identity.controllerDigest)fail('identity');
  await command('/usr/bin/sha256sum',['--strict','--status','-c','bundle.sha256'],{cwd:bundle});
  const image=JSON.parse((await docker(['image','inspect','--format','{{json .}}',value.identity.imageDigest])).stdout);
  if(image.Id!==value.identity.imageDigest||image.Config?.Labels?.['org.opencontainers.image.revision']!==value.identity.sourceSHA)fail('identity');
  prepared=value;return value;
 };
 const inventory=async(operation,databaseURL)=>{
  const envFile=join(run,'inventory-'+operation+(databaseURL?'-restore':'')+'.env');
  const env=parseEnvironment((await privateFile(join(run,'effective.env'))).toString().trimEnd().split('\n'));if(databaseURL)env.DATABASE_URL=databaseURL;env.MIGRATION_ENVIRONMENT='staging';
  if(await exists(envFile)){if((await privateFile(envFile)).toString()!==envText(env))fail('environment');}else await save(envFile,envText(env));
  const args=['run','--rm','-i','--pull=never','--network','cloud_private','--read-only','--user','0:0','--cap-drop','ALL','--security-opt','no-new-privileges','--env-file',envFile,
   '--mount',`type=bind,src=${run},dst=${run}`,'--entrypoint','node',prepared.identity.imageDigest,'scripts/staging-vault-inventory.mjs',operation,join(run,'ordinary.json')];
  const result=execute('/usr/bin/docker',args,{encoding:'utf8',timeout:120000,maxBuffer:65536,env:{PATH:'/usr/bin:/bin'}});
  result.child.stdin.end(operation==='verify'?JSON.stringify({allowedNewVaults:[],allowedNewPersonalVaults:[]}):'');
  try{return JSON.parse((await result).stdout);}catch{fail('ordinary_changed');}
 };
 return runReviewedInstallation({phase,plan,dryRun,report:event=>process.stdout.write(JSON.stringify(event)+'\n'),runCommand:async({stage})=>{
  if(stage==='inspect'){
   await verifyPostgres();
   if(await exists(plan.backupDirectory))await protectedDirectory(plan.backupDirectory,{privateMode:true});else await protectedDirectory(dirname(plan.backupDirectory));
   const sourceSHA=(await git(['-C','/opt/selective-remote','rev-parse','HEAD'])).stdout.trim(),tree=(await git(['-C','/opt/selective-remote','rev-parse','HEAD^{tree}'])).stdout.trim();
   const envDigest=hash(await privateFile(cloud+'/.env'));
   const containers=JSON.parse((await docker(['inspect','cloud-cloud-1','cloud-caddy-1','cloud-postgres-1'])).stdout);
   if(containers.length!==3)fail('scope');
   for(const [index,service] of ['cloud','caddy','postgres'].entries()){const c=containers[index];if(c.Config?.Labels?.['com.docker.compose.project']!=='cloud'||c.Config?.Labels?.['com.docker.compose.service']!==service||!c.NetworkSettings?.Networks?.cloud_private)fail('scope');}
   const running=containers[0];
   const rootFreeBytes=Number((await command('/bin/df',['-B1','--output=avail','/'])).stdout.trim().split(/\s+/).at(-1));
   return {sourceSHA,tree,envDigest,imageDigest:running.Image,platform:process.platform,arch:process.arch,nodeVersion:process.version,schema:Number((await pg('SELECT max(version) FROM schema_migrations')).stdout.trim()),
    clean:(await git(['-C','/opt/selective-remote','status','--porcelain'])).stdout.trim()==='',controllerExists:await exists(root),stateExists:await exists(state),rootFreeBytes};
  }
  if(stage==='candidate-ref'){
   const ref=(await git(['ls-remote','--exit-code','https://github.com/PastFly/Selective-Remote.git',plan.ref])).stdout.trim().split(/\s+/);
   if(ref.length!==2||ref[0]!==plan.sourceSHA||ref[1]!==plan.ref)fail('candidate_source');
   const commit=JSON.parse((await command('/usr/bin/curl',['--fail','--silent','--show-error','--max-time','20','https://api.github.com/repos/PastFly/Selective-Remote/git/commits/'+plan.sourceSHA])).stdout);
   return {sourceSHA:commit.sha,tree:commit.tree?.sha};
  }
  if(stage==='prepared')return loadPrepared();
  if(stage==='prepare'){
   if(await exists(run))fail('run_exists');if(!await exists(plan.backupDirectory))await mkdir(plan.backupDirectory,{mode:0o700});await protectedDirectory(plan.backupDirectory,{privateMode:true});await mkdir(run,{mode:0o700});
   await git(['clone','--filter=blob:none','--sparse','--no-checkout','--depth','1','--branch',plan.ref.slice('refs/heads/'.length),'https://github.com/PastFly/Selective-Remote.git',candidate]);
   if((await git(['-C',candidate,'rev-parse','HEAD'])).stdout.trim()!==plan.sourceSHA||(await git(['-C',candidate,'rev-parse','HEAD^{tree}'])).stdout.trim()!==plan.tree)fail('candidate_source');
   await git(['-C',candidate,'sparse-checkout','set','cloud']);await git(['-C',candidate,'checkout','--detach',plan.sourceSHA]);
   await command('/bin/bash',[join(candidate,'cloud/scripts/validate-postgres-storage.sh'),'--check'],{env:{PATH:'/usr/bin:/bin',...plan.storage}});
   await docker(['build','--label','org.opencontainers.image.revision='+plan.sourceSHA,'--iidfile',join(run,'image.id'),join(candidate,'cloud')],{timeout:1200000});
   const imageDigest=(await readFile(join(run,'image.id'),'utf8')).trim();if(!/^sha256:[a-f0-9]{64}$/.test(imageDigest))fail('candidate_image');
   const id=(await docker(['create','--network','none','--env-file',cloud+'/.env','--entrypoint','/bin/true',imageDigest])).stdout.trim();if(!/^[a-f0-9]{64}$/.test(id))fail('candidate_image');
   let env,passwd;
   try{env=parseEnvironment(JSON.parse((await docker(['inspect','--format','{{json .Config.Env}}',id])).stdout));await mkdir(bundle,{mode:0o700});await docker(['cp',id+':/app/.',bundle]);await docker(['cp',id+':/etc/passwd',join(run,'image.passwd')]);passwd=await readFile(join(run,'image.passwd'),'utf8');}
   finally{await docker(['rm',id]);}
   if(env.NODE_VERSION!=='22.18.0')fail('runtime');
   const capabilities=JSON.parse(await readFile(join(bundle,'deployment-compatibility.json'),'utf8'));
   if(Object.keys(capabilities).length!==5||capabilities.version!==1||capabilities.fenceVersion!==2||capabilities.maxSchemaVersion!==22||capabilities.readerProjectionVersion!==1||capabilities.wholePublicationVersion!==1)fail('candidate_code');
   for(const file of ['staging-controller.sh','verify-staging-controller.mjs','staging-migration-operator.sh','staging-migration-operator-helper.mjs','staging-vault-inventory.mjs'])if(!(await lstat(join(bundle,'scripts',file))).isFile())fail('candidate_code');
   Object.assign(env,{ALLOW_REGISTRATION:'false',PUBLICATION_ENVIRONMENT:'staging',PUBLICATION_READER_ENABLED:'false',WHOLE_PUBLICATION_ENABLED:'false',PUBLICATION_FENCE_PATH:'/publication-fence/journal'});
   delete env.STAGING_REGISTRATION_EMAIL_ALLOWLIST;delete env.PUBLICATION_ALLOWED_VAULT_IDS;
   await save(join(run,'effective.env'),envText(env));const envDigest=hash(await privateFile(join(run,'effective.env')));
   const account=passwd.split('\n').find(line=>line.startsWith('cloud:'))?.split(':');if(!account||!/^[0-9]+$/.test(account[2])||!/^[0-9]+$/.test(account[3]))fail('runtime_user');
   const runtime='runtime/node-v22.18.0-linux-x64/bin/node';await mkdir(dirname(join(bundle,runtime)),{recursive:true,mode:0o755});await copyFile(process.execPath,join(bundle,runtime));await chmod(join(bundle,runtime),0o755);
   await writeFile(join(bundle,'runtime-node.sha256'),hash(await readFile(join(bundle,runtime)))+'  '+runtime+'\n',{mode:0o600});
   const manifest=await bundleManifest(bundle);await save(join(bundle,'bundle.sha256'),manifest);
   const candidateIdentity={sourceSHA:plan.sourceSHA,tree:plan.tree,imageDigest,controllerDigest:hash(manifest)};
   const composeFiles=[];for(const file of plan.composeFiles)composeFiles.push({path:join(cloud,file),sha256:hash(await readFile(join(candidate,'cloud',file)))});
   const settings={version:1,...candidateIdentity,cloudDirectory:cloud,envPath:cloud+'/.env',envDigest,network:'cloud_private',fencePath:state+'/publication/journal',backupDirectory:run,composeFiles,storage:plan.storage};delete settings.tree;
   await save(preparedPath,{formatVersion:1,planDigest,identity:candidateIdentity,envDigest,uid:Number(account[2]),gid:Number(account[3]),settings});
   return {prepared:true,...candidateIdentity};
  }
  if(stage==='close-traffic'||stage==='keep-closed')return stop();
  if(stage==='assert-closed')return closed();
  if(stage==='backup'){
   if(await exists(join(run,'backup-proof.json')))fail('backup_exists');
   const baseline=await inventory('capture');const backup=join(run,'backup.dump');
   await streamDocker(['exec','cloud-postgres-1','sh','-ceu','exec pg_dump --format=custom --no-owner --no-privileges --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"'],{output:backup});
   const durableBackup=await open(backup,'r');try{await durableBackup.sync();}finally{await durableBackup.close();}
   await streamDocker(['exec','-i','cloud-postgres-1','pg_restore','--list'],{input:backup});const backupSHA256=hash(await privateFile(backup));await save(backup+'.sha256',backupSHA256+'  backup.dump\n');
   const restoreName='prc_restore_'+plan.runID.replaceAll('-','_').toLowerCase();if(!/^prc_restore_[a-z0-9_]{1,60}$/.test(restoreName)||restoreName.length>63)fail('restore_scope');
   const env=parseEnvironment((await privateFile(join(run,'effective.env'))).toString().trimEnd().split('\n')),url=new URL(env.DATABASE_URL);if(url.pathname.slice(1)===restoreName)fail('restore_scope');
   await docker(['exec','cloud-postgres-1','sh','-ceu','exec createdb --template=template0 --username="$POSTGRES_USER" "$1"','sh',restoreName]);
   try{await streamDocker(['exec','-i','cloud-postgres-1','sh','-ceu','exec pg_restore --exit-on-error --no-owner --no-privileges --username="$POSTGRES_USER" --dbname="$1"','sh',restoreName],{input:backup});
    if(Number((await pg('SELECT max(version) FROM schema_migrations',restoreName)).stdout.trim())!==12)fail('restore_schema');url.pathname='/'+restoreName;await inventory('verify',url.href);
   }finally{await docker(['exec','cloud-postgres-1','sh','-ceu','exec dropdb --username="$POSTGRES_USER" "$1"','sh',restoreName]);}
   const controllerIdentity={sourceSHA:prepared.identity.sourceSHA,imageDigest:prepared.identity.imageDigest,controllerDigest:prepared.identity.controllerDigest};
   await save(join(run,'restore-attestation.json'),{formatVersion:1,isolatedRestoreVerified:true,backupSHA256,controllerIdentity});
   await save(join(run,'backup-proof.json'),{formatVersion:1,identity:prepared.identity,verified:true,baselineVerified:true,backupSHA256,baselineSHA256:hash(await privateFile(join(run,'ordinary.json'))),baseline});
   return {backupVerified:true,ordinary:baseline};
  }
  if(stage==='backup-proof'){
   const proof=await json(join(run,'backup-proof.json')),attestation=await json(join(run,'restore-attestation.json'));
   if(!same(proof.identity,plan.reviewedIdentity)||hash(await privateFile(join(run,'backup.dump')))!==proof.backupSHA256||hash(await privateFile(join(run,'ordinary.json')))!==proof.baselineSHA256
    ||attestation.isolatedRestoreVerified!==true||attestation.backupSHA256!==proof.backupSHA256)fail('backup_required');
   await inventory('verify');return proof;
  }
  if(stage==='install'){
   await verifyPostgres();
   if(await exists(root)||await exists(state))fail('already_installed');await closed();
   await git(['-C','/opt/selective-remote','fetch','origin',plan.ref]);if((await git(['-C','/opt/selective-remote','rev-parse','FETCH_HEAD'])).stdout.trim()!==plan.sourceSHA)fail('candidate_source');
   await git(['-C','/opt/selective-remote','checkout','--detach',plan.sourceSHA]);if((await git(['-C','/opt/selective-remote','rev-parse','HEAD^{tree}'])).stdout.trim()!==plan.tree)fail('candidate_source');
   await cp(bundle,root,{recursive:true,errorOnExist:true,force:false});await chmod(root,0o700);
   const staged=cloud+'/.env.pr-c-new';await save(staged,(await privateFile(join(run,'effective.env'))).toString());await rename(staged,cloud+'/.env');
   await mkdir(state,{mode:0o700});await mkdir(state+'/publication',{mode:0o770});await chmod(state+'/publication',0o770);await chown(state+'/publication',0,prepared.gid);
   await save(state+'/publication/journal','');await chown(state+'/publication/journal',0,prepared.gid);await chmod(state+'/publication/journal',0o660);
   await mkdir(state+'/operator',{mode:0o700});const {sourceSHA,imageDigest,controllerDigest}=prepared.identity;
   await save(state+'/operator/controller-identity.json',{sourceSHA,imageDigest,controllerDigest});await save(root+'/settings.json',prepared.settings);
   return;
  }
  if(stage==='activate-controller')return command('/bin/bash',[root+'/scripts/staging-controller.sh','--maintenance-upgrade'],{timeout:600000});
  if(stage==='acceptance'){
   await inventory('verify');const env=parseEnvironment((await privateFile(join(run,'effective.env'))).toString().trimEnd().split('\n')),origin=new URL(env.CLOUD_PUBLIC_ORIGIN);
   if(origin.protocol!=='https:'||origin.username||origin.password||origin.pathname!=='/'||origin.search||origin.hash)fail('health_origin');
   for(const endpoint of ['healthz','readyz'])await command('/usr/bin/curl',['--fail','--silent','--show-error','--retry','12','--retry-delay','5','--retry-all-errors','--max-time','10',new URL(endpoint,origin).href],{timeout:180000});
   return;
  }
  fail('stage');
 }});
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 try{const args=process.argv.slice(2),phase=args.shift(),dryRun=args[0]==='--dry-run';if(dryRun)args.shift();if(args.length!==2||args.some(path=>!isAbsolute(path)))fail('arguments');const result=await runHost(phase,args[0],args[1],dryRun);process.stdout.write(JSON.stringify(result)+'\n');}
 catch(error){process.stderr.write(/^staging_install_[a-z_]+$/.test(error?.message??'')?error.message+'\n':'staging_install_failed\n');process.exitCode=1;}
}
