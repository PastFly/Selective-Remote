import test from 'node:test';
import assert from 'node:assert/strict';
import {validateRunningPostgres} from '../scripts/staging-reviewed-installer.mjs';
const image='postgres:16.6-alpine@sha256:1d04b9ba1d4996401f2552b51beda8187f175c0645c091e4781134fc9c9a3eef';
const env={POSTGRES_USER:'u',POSTGRES_DB:'db',POSTGRES_PASSWORD:'secret',DATABASE_URL:'postgres://u:secret@postgres:5432/db'};
const storage={POSTGRES_DATA_HOST_PATH:'/var/lib/postgresql/selective-remote'};
const container=()=>({State:{Running:true},Image:'sha256:'+'a'.repeat(64),Config:{Image:image,Env:['POSTGRES_USER=u','POSTGRES_DB=db','POSTGRES_PASSWORD=secret','PGDATA=/var/lib/postgresql/data']},Mounts:[{Type:'bind',Source:storage.POSTGRES_DATA_HOST_PATH,Destination:'/var/lib/postgresql/data',RW:true}]});
test('actual Postgres binding rejects different mount despite valid planned directory',()=>{
 assert.equal(validateRunningPostgres(container(),storage,env,{Id:'sha256:'+'a'.repeat(64),RepoDigests:[image]}),true);
 for(const mutate of [c=>c.Mounts[0].Source='/other',c=>c.Config.Image='postgres:17',c=>c.Config.Env.push('PGDATA=/other'),c=>c.Mounts[0].RW=false]){const c=container();mutate(c);assert.throws(()=>validateRunningPostgres(c,storage,env,{Id:c.Image,RepoDigests:[image]}));}
});
