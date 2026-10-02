import {isUUID} from './security.mjs';
const limit=1024*1024;
export function wholePublicationRoute(path,method){
  const prefix=path.match(/^\/v1\/teams\/([^/]+)\/publication\/(.*)$/u);if(!prefix)return null;
  const [,teamID,tail]=prefix;if(!isUUID(teamID))throw Error('invalid_access_request');
  if(method==='GET'&&tail==='context')return {teamID,operation:'context'};
  if(method==='POST'&&['preview','start'].includes(tail))return {teamID,operation:tail};
  if(method==='POST'&&/^repair\/(directory|part)$/.test(tail))return {teamID,operation:tail==='repair/directory'?'repairDirectory':'repairPart'};
  const match=tail.match(/^operations\/([^/]+)\/(receipt|discard|validate|commit|parts\/([^/]+)|projections\/([^/]+)|projection-chunks\/([^/]+)|readback\/([^/]+))$/u);
  if(!match)return null;
  const operationID=match[1],vaultID=match[3]??match[4]??match[5]??match[6];
  if(!isUUID(operationID)||vaultID&&!isUUID(vaultID))throw Error('invalid_access_request');
  const operation=match[2].startsWith('parts/')?'putPart':match[2].startsWith('projections/')?'putProjection':match[2].startsWith('projection-chunks/')?'putProjectionChunk':match[2].startsWith('readback/')?'readback':match[2];
  if((['receipt','readback'].includes(operation)?'GET':'POST')!==method)return null;
  return {teamID,operation,operationID,...(vaultID?{vaultID}:{})};
}
export async function runWholePublicationRoute(request,url,session,service,route){
  if([...url.searchParams].length)throw Error('invalid_access_request');
  const client={schemaVersion:request.headers['x-vault-schema-version']==='2'?2:null,
    capability:request.headers['x-vault-capability'],publicationVersion:request.headers['x-publication-version']==='1'?1:null};
  let body={};
  if(request.method==='POST'){
    if(!(request.headers['content-type']??'').split(';')[0].trim().toLowerCase().match(/^application\/(?:json|[a-z0-9.+-]+\+json)$/u))throw Error('invalid_content_type');
    const chunks=[];let bytes=0;for await(const chunk of request){bytes+=chunk.length;if(bytes>limit)throw Error('request_too_large');chunks.push(chunk);}
    try{body=JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{throw Error('invalid_json');}
  }
  return service.wholePublication(session,route.teamID,route.operation,body,{...route,...client});
}
