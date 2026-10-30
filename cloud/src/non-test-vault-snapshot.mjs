// Operator-local evidence. Capture BEFORE creating any test accounts/Vaults.
// Every original ID remains protected, including names that look like test data.
// The supplied query must belong to one REPEATABLE READ READ ONLY transaction.
import {constants} from 'node:fs';
import {open,lstat,realpath} from 'node:fs/promises';
import {dirname,isAbsolute} from 'node:path';
import {createHash} from 'node:crypto';

const fail=code=>{throw Error(`non_test_snapshot_${code}`);};
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const hash=/^[a-f0-9]{64}$/;
const object=value=>value!==null && typeof value==='object' && !Array.isArray(value);
const isUUID=value=>typeof value==='string' && uuid.test(value);
const digest=values=>createHash('sha256').update(JSON.stringify(values)).digest('hex');
const direct=(name,scope='shared',field='vault_id')=>({name,scope,where:`t.${field}=ANY($1::uuid[])`});
const tables=[
  direct('users','users','id'),direct('personal_vaults','personal','id'),direct('vault_revisions','personal'),
  direct('devices','users','user_id'),direct('teams','teams','id'),
  ...['team_memberships','team_invitations','team_policy_revisions','team_access_groups','team_access_group_members'].map(name=>direct(name,'teams','team_id')),
  {name:'team_membership_device_admissions',scope:'teams',where:'EXISTS (SELECT 1 FROM public.team_memberships m WHERE m.id=t.membership_id AND m.team_id=ANY($1::uuid[]))'},
  ...['device_trust_roots_v1','device_trust_certificates_v1','device_trust_directories_v1',
    'device_trust_revocations_v1','device_trust_requests_v1','device_trust_challenges_v1'].map(name=>direct(name,'users','account_id')),
  direct('shared_vaults','shared','id'),
  ...['shared_vault_revisions','shared_vault_key_wrappers','shared_vault_rotation_tasks',
    'team_invitation_wrapper_vaults','team_invitation_vault_wrappers','vault_resource_registry',
    'vault_resource_identity_reservations','vault_access_grants','vault_migration_attempts',
    'vault_migration_resources','vault_resource_ciphertext_versions','vault_resource_key_wrappers_v2',
    'vault_resource_manifest_pointers_v2','vault_publication_projections',
    'team_publication_generations','team_publication_outbox'].map(name=>direct(name)),
  {name:'vault_migration_parts',scope:'shared',where:'EXISTS (SELECT 1 FROM public.vault_migration_attempts a WHERE a.id=t.attempt_id AND a.vault_id=ANY($1::uuid[]))'},
  ...['team_publication_operations','team_publication_receipts','team_publication_operation_keys'].map(name=>({name,scope:'shared',
    where:`EXISTS (SELECT 1 FROM public.team_publication_generations g WHERE g.operation_id=t.${name==='team_publication_operations'?'id':'operation_id'} AND g.vault_id=ANY($1::uuid[]))`})),
];
const publicationTables=new Set(['vault_resource_ciphertext_versions','vault_resource_key_wrappers_v2',
  'vault_resource_manifest_pointers_v2','vault_publication_projections','team_publication_generations','team_publication_outbox']);

async function requireTransaction(query){
  if(typeof query!=='function')fail('transaction_required');
  const isolation=(await query('SHOW transaction_isolation')).rows[0]?.transaction_isolation;
  const readonly=(await query('SHOW transaction_read_only')).rows[0]?.transaction_read_only;
  if(!['repeatable read','serializable'].includes(isolation) || readonly!=='on')fail('transaction_required');
  // Timestamp JSON must not depend on an operator's session time zone.
  await query("SET LOCAL TIME ZONE 'UTC'");
}
async function columns(query,name){
  return (await query("SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name=$1 ORDER BY ordinal_position",[name])).rows.map(row=>row.column_name);
}
async function rowsDigest(query,table,ids,selectedColumns){
  // Hash on the server: neither ciphertext nor ordinary row plaintext leaves
  // PostgreSQL. jsonb text preserves integer precision and stable key order.
  const rows=(await query(`SELECT encode(digest((SELECT jsonb_object_agg(j.key,j.value)
    FROM jsonb_each(to_jsonb(t)) AS j WHERE j.key=ANY($2::text[]))::text,'sha256'),'hex') AS hash
    FROM public.${table.name} t WHERE ${table.where} ORDER BY hash`,[ids,selectedColumns])).rows;
  return {count:rows.length,sha256:digest(rows.map(row=>row.hash))};
}
async function requireV1(query,ids,currentColumns,originalColumns){
  const checks=[];
  if(currentColumns.includes('format_state'))checks.push("format_state IS DISTINCT FROM 'V1_ACTIVE'");
  if(currentColumns.includes('format_schema_version'))checks.push('format_schema_version IS DISTINCT FROM 1');
  if(currentColumns.includes('active_publication_attempt_id'))checks.push('active_publication_attempt_id IS NOT NULL');
  if(currentColumns.includes('access_policy_version') && originalColumns && !originalColumns.includes('access_policy_version'))checks.push('access_policy_version IS DISTINCT FROM 0');
  if(checks.length && (await query(`SELECT count(*)::int AS count FROM public.shared_vaults WHERE id=ANY($1::uuid[]) AND (${checks.join(' OR ')})`,[ids])).rows[0].count!==0)fail('changed');
}
async function inspect(query,scope,baseline){
  const result={};
  for(const table of tables){
    const actual=await columns(query,table.name),previous=baseline?.[table.name];
    if(table.name==='shared_vaults')await requireV1(query,scope.shared,actual,previous?.columns);
    if(!actual.length){
      if(previous?.present || ['users','personal_vaults','vault_revisions','shared_vaults'].includes(table.name))fail('changed');
      result[table.name]={present:false,columns:[],count:0,sha256:digest([])};continue;
    }
    if(previous?.present && previous.columns.some(column=>!actual.includes(column)))fail('changed');
    const selected=previous?.present?previous.columns:actual;
    const evidence=await rowsDigest(query,table,scope[table.scope],selected);
    if(publicationTables.has(table.name) && evidence.count!==0)fail('changed');
    if(previous && (evidence.count!==previous.count || evidence.sha256!==previous.sha256))fail('changed');
    result[table.name]={present:true,columns:selected,...evidence};
  }
  return result;
}
async function privateDirectory(path){
  if(typeof path!=='string' || !isAbsolute(path))fail('file_invalid');
  const parent=dirname(path);
  if(await realpath(parent)!==parent)fail('file_invalid');
  const stat=await lstat(parent);
  if(!stat.isDirectory() || stat.isSymbolicLink() || stat.uid!==process.getuid() || (stat.mode&0o777)!==0o700)fail('file_invalid');
}
async function save(path,snapshot){
  let file,dir;
  try{
    await privateDirectory(path);
    file=await open(path,constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,0o600);
    await file.writeFile(JSON.stringify(snapshot));await file.sync();await file.close();file=null;
    dir=await open(dirname(path),constants.O_RDONLY|constants.O_NOFOLLOW);await dir.sync();
  }catch{fail('file_invalid');}finally{await file?.close();await dir?.close();}
}
async function load(path){
  let file,value;
  try{
    await privateDirectory(path);
    file=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW);const before=await file.stat();
    if(!before.isFile() || before.uid!==process.getuid() || (before.mode&0o777)!==0o600 || before.size>16*1024*1024)fail('file_invalid');
    value=await file.readFile('utf8');
    const after=await file.stat(),current=await lstat(path);
    if(current.isSymbolicLink() || ['dev','ino','size','mtimeMs','ctimeMs'].some(key=>before[key]!==after[key]) || current.dev!==before.dev || current.ino!==before.ino)fail('file_invalid');
  }catch{fail('file_invalid');}finally{await file?.close();}
  try{value=JSON.parse(value);}catch{fail('invalid');}
  if(!object(value) || value.formatVersion!==1 || !object(value.scope) || !object(value.tables)
    || Object.keys(value.tables).length!==tables.length)fail('invalid');
  if(Object.keys(value.scope).length!==4)fail('invalid');
  for(const kind of ['shared','personal','users','teams']){
    const ids=value.scope[kind];
    if(!Array.isArray(ids) || ids.some(id=>!isUUID(id)) || new Set(ids).size!==ids.length)fail('invalid');
  }
  for(const {name} of tables){
    const table=value.tables[name];
    if(!object(table) || typeof table.present!=='boolean' || !Array.isArray(table.columns)
      || table.columns.some(column=>typeof column!=='string' || !/^[a-z_][a-z0-9_]*$/.test(column))
      || new Set(table.columns).size!==table.columns.length || !Number.isSafeInteger(table.count) || table.count<0 || typeof table.sha256!=='string' || !hash.test(table.sha256)
      || (table.present && !table.columns.length) || (!table.present && (table.columns.length || table.count!==0 || table.sha256!==digest([]))))fail('invalid');
  }
  return value;
}
function summary(snapshot){
  return {vaultCount:snapshot.scope.shared.length,personalVaultCount:snapshot.scope.personal.length,
    userCount:snapshot.scope.users.length,sha256:digest(snapshot)};
}

export async function captureNonTestVaultSnapshot({query,path}){
  await requireTransaction(query);
  const scope={};
  for(const [kind,table] of [['shared','shared_vaults'],['personal','personal_vaults'],['users','users']])
    scope[kind]=(await query(`SELECT id FROM public.${table} ORDER BY id`)).rows.map(row=>row.id);
  scope.teams=(await query('SELECT id FROM public.teams ORDER BY id')).rows.map(row=>row.id);
  const snapshot={formatVersion:1,scope,tables:await inspect(query,scope)};
  await save(path,snapshot);
  return summary(snapshot);
}

export async function verifyNonTestVaultSnapshot({query,path,allowedNewVaults=[],allowedNewPersonalVaults=[]}){
  await requireTransaction(query);
  const snapshot=await load(path);
  if(!Array.isArray(allowedNewVaults) || !Array.isArray(allowedNewPersonalVaults))fail('scope_changed');
  if(new Set(allowedNewVaults.map(entry=>entry?.vaultID)).size!==allowedNewVaults.length
    || new Set(allowedNewPersonalVaults.map(entry=>entry?.vaultID)).size!==allowedNewPersonalVaults.length)fail('scope_changed');
  for(const entry of allowedNewVaults)
    if(!object(entry) || !isUUID(entry.teamID) || !isUUID(entry.vaultID) || typeof entry.name!=='string' || !entry.name.startsWith('TEST-ONLY-CODEX-'))fail('scope_changed');
  for(const entry of allowedNewPersonalVaults)
    if(!object(entry) || !isUUID(entry.userID) || !isUUID(entry.vaultID))fail('scope_changed');
  const shared=(await query('SELECT id,team_id,name FROM public.shared_vaults ORDER BY id')).rows;
  for(const row of shared)if(!snapshot.scope.shared.includes(row.id)
    && !allowedNewVaults.some(entry=>entry.vaultID===row.id && entry.teamID===row.team_id && entry.name===row.name))fail('scope_changed');
  const personal=(await query('SELECT id,user_id FROM public.personal_vaults ORDER BY id')).rows;
  for(const row of personal)if(!snapshot.scope.personal.includes(row.id)
    && !allowedNewPersonalVaults.some(entry=>entry.vaultID===row.id && entry.userID===row.user_id))fail('scope_changed');
  await inspect(query,snapshot.scope,snapshot.tables);
  return {unchanged:true,...summary(snapshot)};
}
