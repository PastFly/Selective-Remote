// Exact source identity is encrypted client metadata, never a server search index.
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const kinds={host:'HOST',credential:'CREDENTIAL',snippet:'SNIPPET',forwarding:'FORWARDING'};
const encoder=new TextEncoder();
const byteKey=value=>{let s='';for(const b of encoder.encode(value))s+=String.fromCharCode(b);return btoa(s).replaceAll('+','-').replaceAll('/','_').replace(/=+$/u,'');};
export const folderSourceKey=(type,path)=>'folder:'+type+':'+byteKey(path);
function folderPath(key,prefix){const value=key.slice(prefix.length);return new TextDecoder('utf-8',{fatal:true}).decode(Uint8Array.from(atob(value.replaceAll('-','+').replaceAll('_','/')+'='.repeat((4-value.length%4)%4)),x=>x.charCodeAt(0)));}
export function canonicalFolderComponents(path) {
  if(typeof path!=='string'||path.length===0)throw Error('invalid_folder');
  const pieces=path.split('/');
  if(pieces.length>32||pieces.some(p=>!p.trim()||p==='.'||p==='..'||/[\u0000-\u001f\u007f]/u.test(p)))throw Error('invalid_folder');
  return pieces; // Never normalize Unicode, case or surrounding spaces.
}
function embeddedSecret(value) {
  if(!value||typeof value!=='object')return false;
  return Object.entries(value).some(([key,item])=>
    (/password|secret|private.?key|passphrase|token/iu.test(key)&&item!==null&&item!==''&&item!==false)
    ||embeddedSecret(item));
}
export function inspectLegacyResources(document,existingIDs=[]) {
  if(document?.schemaVersion!==1||!Array.isArray(document.records)||!Array.isArray(document.tombstones)
    ||document.records.length>1000||encoder.encode(JSON.stringify(document)).length>24*1024*1024)throw Error('invalid_legacy_document');
  const blockers=[],seen=new Set(),occurrences=new Map(),folders=new Map(),items=[];
  const tombstones=new Set(document.tombstones.map(t=>String(t?.id).toLowerCase()));let missingIDs=0;
  for(const [ordinal,r] of document.records.entries()){
    if(!r||!kinds[r.type]||!r.data||typeof r.data!=='object'||Array.isArray(r.data)){blockers.push('unsupported_record');continue;}
    const original=String(r.id??''),normalized=original.toLowerCase(),valid=uuid.test(normalized);
    if(valid){if(seen.has(normalized))blockers.push('duplicate_source_id');seen.add(normalized);
      if(tombstones.has(normalized))blockers.push('tombstoned_source_id');
      if(existingIDs.includes(normalized))blockers.push('resource_id_collision');
    }else missingIDs++;
    if(['host','forwarding'].includes(r.type)){
      if(embeddedSecret(r.data))blockers.push('embedded_secret_requires_conversion');
      for(const key of ['profile','configuration'])if(r.data[key]!==undefined){
        try{if(typeof r.data[key]!=='string')throw Error();const decoded=JSON.parse(r.data[key]);
          if(!decoded||typeof decoded!=='object'||Array.isArray(decoded))throw Error();
          if(embeddedSecret(decoded))blockers.push('embedded_secret_requires_conversion');
        }catch{blockers.push('opaque_profile_requires_conversion');}
      }
    }
    let parentKey=null;
    if(['host','snippet'].includes(r.type)&&r.data.folder!==undefined&&r.data.folder!==''){
      let pieces;try{pieces=canonicalFolderComponents(r.data.folder);}catch{blockers.push('invalid_folder');continue;}
      for(let n=1;n<=pieces.length;n++){
        const path=pieces.slice(0,n).join('/'),key=folderSourceKey(r.type,path);
        if(!folders.has(key))folders.set(key,{key,path,type:r.type,component:pieces[n-1],parentKey});
        parentKey=key;
      }
    }
    const originalKey=r.type+':'+JSON.stringify(r.id??null),duplicateOrdinal=occurrences.get(originalKey)??0;
    occurrences.set(originalKey,duplicateOrdinal+1);
    const key=valid?'record:'+r.type+':'+normalized:'record:'+r.type+':invalid:'+byteKey(JSON.stringify(r.id??null))+':'+duplicateOrdinal;
    items.push({key,ordinal,kind:kinds[r.type],parentKey,record:r,id:valid?normalized:null});
  }
  if(items.length+folders.size>1000)blockers.push('resource_limit');
  return {items,folders:[...folders.values()],blockers:[...new Set(blockers)],missingIDs};
}
export function mapLegacyResources({document,scope,previous=null,reservations=[],folderMoves=[],cryptoValue=globalThis.crypto}) {
  if(!scope||!uuid.test(scope.teamID)||!uuid.test(scope.vaultID))throw Error('invalid_mapping_scope');
  const i=inspectLegacyResources(document);if(i.blockers.length)throw Error(i.blockers[0]);
  if(previous&&(previous.version!==2||previous.scope?.teamID!==scope.teamID||previous.scope?.vaultID!==scope.vaultID))throw Error('mapping_scope_mismatch');
  const mapping={...(previous?.mapping??{})};
  if(Object.values(mapping).some(v=>typeof v!=='string'||!uuid.test(v))||new Set(Object.values(mapping)).size!==Object.values(mapping).length)throw Error('invalid_resource_mapping');
  for(const move of folderMoves){
    if(!['host','snippet'].includes(move.type))throw Error('invalid_folder');
    canonicalFolderComponents(move.from);canonicalFolderComponents(move.to);
    const prefix='folder:'+move.type+':';
    const moving=Object.keys(mapping).filter(k=>k.startsWith(prefix)).map(k=>({key:k,path:folderPath(k,prefix)}))
      .filter(r=>r.path===move.from||r.path.startsWith(move.from+'/'));
    const changes=moving.map(r=>[folderSourceKey(move.type,move.to+r.path.slice(move.from.length)),mapping[r.key]]);
    if(!moving.length||changes.some(([k])=>mapping[k]!==undefined&&!moving.some(r=>r.key===k)))throw Error('folder_mapping_conflict');
    moving.forEach(r=>delete mapping[r.key]);
    changes.forEach(([k,v])=>mapping[k]=v);
  }
  const reserved=new Map(reservations.map(r=>[r.id,r]));
  for(const entry of [...i.folders,...i.items]){
    let selected=mapping[entry.key]??entry.id??cryptoValue.randomUUID();
    const r=reserved.get(selected);
    if(r&&(r.tombstoned||r.teamID!==scope.teamID||r.vaultID!==scope.vaultID||(r.kind&&r.kind!==(entry.kind??'FOLDER'))))throw Error(r.tombstoned?'resource_identity_tombstoned':'resource_id_collision');
    if(!mapping[entry.key]&&Object.values(mapping).includes(selected))throw Error('resource_id_collision');
    mapping[entry.key]=selected;
  }
  const resources=[...i.items.map(r=>({id:mapping[r.key],kind:r.kind,parentFolderID:r.parentKey?mapping[r.parentKey]:null,sourceOrdinal:r.ordinal})),
    ...i.folders.map((r,n)=>({id:mapping[r.key],kind:'FOLDER',parentFolderID:r.parentKey?mapping[r.parentKey]:null,sourceOrdinal:document.records.length+n}))];
  return {version:2,scope:{teamID:scope.teamID,vaultID:scope.vaultID},mapping,resources};
}
export function legacyAdministrativeMetadata({document,mapping,sourceFingerprint}) {
  if(!/^[a-f0-9]{64}$/u.test(sourceFingerprint))throw Error('invalid_source_fingerprint');
  const allowed=new Set(['schemaVersion','records','tombstones','vectorClock']);
  const validClock=value=>value&&typeof value==='object'&&!Array.isArray(value)
    &&Object.entries(value).every(([key,count])=>uuid.test(key)&&Number.isSafeInteger(count)&&count>=0);
  if(Object.keys(document).some(key=>!allowed.has(key))
    ||(document.vectorClock!==undefined&&!validClock(document.vectorClock))
    ||document.tombstones.some(t=>!t||typeof t!=='object'||Array.isArray(t)||!uuid.test(t.id)
      ||Object.keys(t).some(key=>!['id','version','deletedAt'].includes(key))
      ||!(Number.isSafeInteger(t.version)&&t.version>0||validClock(t.version))
      ||(t.deletedAt!==undefined&&(typeof t.deletedAt!=='string'||!Number.isFinite(Date.parse(t.deletedAt))))))
    throw Error('unsupported_source_metadata');
  const {records:ignored,...sourceMetadata}=document;
  return {version:1,scope:mapping.scope,sourceFingerprint,mapping:mapping.mapping,
    sourceMetadata:structuredClone(sourceMetadata)};
}
