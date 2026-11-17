// Local browser regression only. Never counted as real staging acceptance.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,rm,realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {launchLifecycleBrowser,openLifecycleExecutionPage,invokeLifecycleCommand} from './staging-real-lifecycle.mjs';
import * as lifecycle from './staging-real-lifecycle.mjs';
const {chromium}=await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE));
const directory=await realpath(await mkdtemp(join(tmpdir(),'prc-page-isolation-'))),profile=join(directory,'edge');await mkdir(profile,{mode:0o700});
let startupWrites=0,logins=0,browser;
const server=createServer((request,response)=>{
 if(request.url==='/healthz'){response.setHeader('Content-Type','application/json');response.end('{"ready":true}');return;}
 if(request.url==='/v1/auth/login'){logins++;response.end('{}');return;}
 if(request.url==='/startup-write'){startupWrites++;response.end('{}');return;}
 response.setHeader('Content-Type','text/html');
 response.end('<!doctype html><script>Promise.allSettled([fetch("/startup-write",{method:"POST"}),fetch("/v1/auth/login",{method:"POST"})]).then(()=>document.body.dataset.started="yes")</script><body>GUI with background initialization</body>');
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const origin='http://127.0.0.1:'+server.address().port;
try{
 browser=await launchLifecycleBrowser({chromium,profile,headless:true});
 const gui=await browser.context.newPage();await gui.goto(origin);await gui.waitForFunction(()=>document.body.dataset.started==='yes');assert.equal(startupWrites,1);
 // The actual browser proves the fixture has a real startup side effect.
 const page=await openLifecycleExecutionPage(browser.context,origin);
 await page.evaluate(async()=>{await fetch('/healthz');});
 assert.equal(startupWrites,1,'execution startup must not load the application GUI');
 assert.equal(browser.context.pages().length,1,'restored pages must not run alongside the fixture');
 assert.equal(page.url(),origin+'/healthz');
 await page.evaluate(()=>{globalThis.__prcLifecycle=async()=>{throw Error('local_team_vault_exists');};});
 await assert.rejects(invokeLifecycleCommand(page,'recover-bootstrap'),{message:'local_team_vault_exists'});
 await page.evaluate(()=>{globalThis.__prcLifecycle=async()=>{throw Error('secret@example.test token=abc');};});
 await assert.rejects(invokeLifecycleCommand(page,'recover-bootstrap'),{message:'unknown_failure'});
 assert.equal(typeof lifecycle.openContinuationLoginPage,'function');
 await lifecycle.openContinuationLoginPage({context:browser.context,page},origin);
 await page.waitForFunction(()=>document.body.dataset.started==='yes');
 assert.equal(logins,2,'existing same-origin authentication remains usable');
 assert.equal(startupWrites,1,'temporary login GUI cannot perform its startup mutation');
 console.log(JSON.stringify({loginAllowsOnlyAuthentication:true,kind:'LOCAL_BROWSER_REGRESSION',executionPageInert:true,restoredPagesClosed:true,safeErrorsPreserved:true,stagingAcceptance:false}));
}finally{
 if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));await rm(directory,{recursive:true});
}
