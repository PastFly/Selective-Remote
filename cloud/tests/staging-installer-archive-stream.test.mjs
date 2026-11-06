import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {execFile} from 'node:child_process';
import {mkdtemp,rm,stat,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname,join} from 'node:path';
import {promisify} from 'node:util';
import * as installer from '../scripts/staging-reviewed-installer.mjs';

const execute=promisify(execFile),database=process.env.TEST_DATABASE_URL;
const psql=process.env.PSQL_PATH??'psql',dump=process.env.PG_DUMP_PATH??'pg_dump',restore=process.env.PG_RESTORE_PATH??'pg_restore';

test('installer archive list drains a large PG16 dump but rejects bad archives, failed consumers and input errors',
 {skip:!database,timeout:120000},async t=>{
  const base=new URL(database);assert.ok(['127.0.0.1','localhost','[::1]'].includes(base.hostname));
  const name='prc_stream_'+randomUUID().replaceAll('-',''),directory=await mkdtemp(join(tmpdir(),'prc-stream-'));
  const archive=join(directory,'backup.dump'),bad=join(directory,'bad.dump');
  const env={...process.env,PGHOST:base.hostname,PGPORT:base.port,PGUSER:decodeURIComponent(base.username),PGPASSWORD:decodeURIComponent(base.password)};
  const streamEnv={PATH:[dirname(restore),process.env.PATH].filter(Boolean).join(':')};
  const run=(file,args)=>execute(file,args,{env,timeout:90000,maxBuffer:65536});
  let created=false;
  try{
    assert.match((await run(psql,['-X','-d','postgres','-At','-c','SHOW server_version'])).stdout,/^16\./);
    await run(psql,['-X','-v','ON_ERROR_STOP=1','-d','postgres','-c',`CREATE DATABASE "${name}" TEMPLATE template0`]);created=true;
    await run(psql,['-X','-v','ON_ERROR_STOP=1','-d',name,'-c',
      'CREATE TABLE archive_payload AS SELECT i, md5(i::text || random()::text) AS value FROM generate_series(1, 300000) AS i']);
    await run(dump,['--format=custom','--file',archive,'--dbname',name]);
    const bytes=(await stat(archive)).size;assert.ok(bytes>4*1024*1024);t.diagnostic(`synthetic_archive_bytes=${bytes}`);
    await run(restore,['--list',archive]);

    await assert.rejects(installer.streamProcess(restore,['--list'],{input:archive}),/staging_install_command_failed/);
    await installer.streamProcess('/bin/sh',['-ceu',installer.archiveListShell],{input:archive,env:streamEnv});
    await writeFile(bad,'not a PostgreSQL archive');
    await assert.rejects(installer.streamProcess('/bin/sh',['-ceu',installer.archiveListShell],{input:bad,env:streamEnv}),/staging_install_command_failed/);
    await assert.rejects(installer.streamProcess(process.execPath,['-e','process.exit(7)'],{input:archive}),/staging_install_command_failed/);
    await assert.rejects(installer.streamProcess('/bin/sh',['-ceu',installer.archiveListShell],{input:join(directory,'missing.dump'),env:streamEnv}),/staging_install_command_failed/);
    await assert.rejects(installer.streamProcess(process.execPath,['-e','process.exit(0)'],{input:join(directory,'missing.dump')}),/staging_install_command_failed/);
  }finally{
    if(created)await run(psql,['-X','-v','ON_ERROR_STOP=1','-d','postgres','-c',`DROP DATABASE "${name}"`]);
    await rm(directory,{recursive:true,force:true});
  }
});
