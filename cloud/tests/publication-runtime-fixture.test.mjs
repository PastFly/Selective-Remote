import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {stopPublicationRuntime} from './publication-runtime-fixture.mjs';

test('HTTP fixture waits for server process closure before deleting its isolated database', async t => {
  const child=spawn(process.execPath,['-e',`
    process.on('SIGTERM',()=>setTimeout(()=>process.exit(0),80));
    setInterval(()=>{},1000); process.stdout.write('ready');
  `],{stdio:['ignore','pipe','pipe']});
  t.after(()=>{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');});
  await once(child.stdout,'data');
  let fixtureCleaned=false;
  await stopPublicationRuntime({child,cleanup:async()=>{fixtureCleaned=true;}});
  assert.notEqual(child.exitCode,null,'database cleanup must not race a live server');
  assert.equal(fixtureCleaned,true,'fence cleanup must be awaited too');
});
