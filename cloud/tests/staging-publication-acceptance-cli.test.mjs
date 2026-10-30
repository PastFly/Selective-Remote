import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtemp,realpath,rm,access} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';

const cli=fileURLToPath(new URL('../scripts/staging-publication-acceptance.mjs',import.meta.url));

test('opted-in CLI reaches protected-config rejection without circular module deadlock or a profile',async t=>{
 const dir=await realpath(await mkdtemp(join(tmpdir(),'staging-acceptance-cli-')));
 t.after(()=>rm(dir,{recursive:true,force:true}));
 const missingConfig=join(dir,'missing-config.json'),run=join(dir,'lifecycle');
 const child=spawnSync(process.execPath,[cli,'--execute','--config',missingConfig,'--run-directory',run,'--phase','bootstrap'],{
  encoding:'utf8',timeout:10000,
  env:{PATH:process.env.PATH??'/usr/bin:/bin',TEST_SESSION_MODE:'FRESH_ANONYMOUS',PLAYWRIGHT_MODULE:join(dir,'never-imported.mjs'),CHROMIUM_PATH:'/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'}
 });
 assert.ifError(child.error);
 assert.equal(child.status,1,'CLI must reject the missing protected config, not exit 13 on an unsettled import');
 assert.match(child.stderr,/staging_real_lifecycle_stopped/);
 assert.doesNotMatch(child.stderr,/unsettled top-level await/i);
 await assert.rejects(access(run),{code:'ENOENT'},'rejection must precede browser/profile creation');
});
