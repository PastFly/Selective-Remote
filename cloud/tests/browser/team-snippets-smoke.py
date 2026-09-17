"""Offline Chromium smoke test; real workspace DOM/handlers, mocked Vault and API.

Requires Python Playwright and a Chromium installation. No network navigation,
credentials, live server, or real cryptographic synchronization is used.
Run: python cloud/tests/browser/team-snippets-smoke.py [output-directory]
"""
from pathlib import Path
from urllib.parse import quote
import json, sys, re, shutil, tempfile
from playwright.sync_api import sync_playwright
ROOT=Path(__file__).resolve().parents[2]/"public"
OUT=Path(sys.argv[1]) if len(sys.argv)>1 else Path(tempfile.mkdtemp(prefix="team-snippet-smoke-"))
OUT.mkdir(parents=True,exist_ok=True)
APP=(ROOT/'app.js').read_text().replace('if (typeof document !== "undefined") {', 'if (false) {').replace('from "./team-vault-sync.js";', 'from "./qa-sync.js";')
MOCK='''
export function createIndexedDBTeamVaultRepository(scope) { return scope; }
export function createTeamVaultController({ scope }) {
 const bucket=window.qaData[scope.vaultID] ??= [];
 return {document:()=>({records:structuredClone(bucket)}),lock(){},
 async syncState(){return {keyGeneration:1};},
 async upsert({id=crypto.randomUUID(),type,data}) {const record={id,type,data,modifiedAt:new Date().toISOString()}; const i=bucket.findIndex(v=>v.id===id);if(i>=0)bucket[i]=record;else bucket.push(record);window.qaWrites++;return id;},
 async delete(id){const i=bucket.findIndex(v=>v.id===id);if(i>=0)bucket.splice(i,1);window.qaWrites++;}
 };
}
export async function synchronizeTeamVault(){return {status:'downloaded',revision:1,conflicts:[]};}
export async function provisionTeamVaultWrappers(){return {granted:0};}
export async function rotateTeamVault(){throw Error('rotation not part of this test');}
'''
# Offline DOM fixture: no localhost/network navigation is required or attempted.
modules={path.name:path.read_text() for path in ROOT.glob('*.js')}
modules['app.js']=APP
modules['qa-sync.js']=MOCK
mapping={}
for name, content in modules.items():
 content=re.sub(r'(from\s+["\'])\./([^"\']+)(["\'])', lambda m:m[1]+'qa/'+m[2].split('?')[0]+m[3],content)
 mapping['qa/'+name]='data:text/javascript;charset=utf-8,'+quote(content,safe='')
html=re.sub(r'<script\b[^>]*>.*?</script>', '', (ROOT/'index.html').read_text(),flags=re.S)
html=re.sub(r'<link[^>]+(?:stylesheet|preconnect|icon)[^>]*>', '', html)
setup='''async () => {
 window.qaWrites=0;
 const s=(id,folder,title=id,body='printf hello')=>({id,type:'snippet',data:{title,body,folder},modifiedAt:'2026-09-01T00:00:00.000Z'});
 window.qaData={'vault-1':[s('root',''),s('parent','Prod'),s('a','Prod/Deploy','Deploy 10'),s('b','Prod/Deploy','Deploy 2','kubectl rollout'),s('c','Prod/Logs','Logs'),s('other','Production','Other')], 'vault-2':[s('second','OtherTeam','Isolated')]};
 window.qaRole='editor';
 const teams=()=>[{id:'team-1',membershipID:'member-1',name:'Demo Team',role:window.qaRole},{id:'team-2',membershipID:'member-2',name:'Other Team',role:window.qaRole}];
 const client={listDevices:async()=>[],listPendingTeamInvitations:async()=>[],listTeams:async()=>teams(), listTeamMembersPage:async()=>({members:[],total:0,nextCursor:null}),listSharedVaults:async(id)=>[{id:id==='team-1'?'vault-1':'vault-2',name:'Shared Commands',revision:1,keyGeneration:1,rotationRequired:false}],getTeamDeviceAdmissionPolicy:async()=>({automaticDeviceAdmission:true,editable:false}),listTeamInvitations:async()=>[]};
 const {initializeModernSelects}=await import('qa/modern-select.js');initializeModernSelects();
 const {initializeTeamWorkspace,finishPortalBootstrap}=await import('qa/app.js');
 window.qa=initializeTeamWorkspace({documentValue:document,client,backgroundSyncIntervalMilliseconds:0,workspaceRefreshIntervalMilliseconds:0,setIntervalValue:()=>0,clearIntervalValue:()=>{}});
 document.querySelector('#cloud-workspace').hidden=false;
 document.querySelector('#team-vault').hidden=false;
 document.body.dataset.portalView='workspace';
 for (const el of document.querySelectorAll('[data-workspace-panel]'))el.hidden=el.id!=='team-vault';
 qa.setView('hosts','snippet');
 await qa.activate({deviceID:'demo-device'});
 finishPortalBootstrap();
}'''
with sync_playwright() as p:
 browser=p.chromium.launch(executable_path=shutil.which('chromium'),headless=True,args=['--no-sandbox'])
 page=browser.new_page(viewport={'width':1440,'height':1100},locale='ru-RU')
 errors=[]; page.on('pageerror',lambda e:errors.append(str(e)))
 page.set_default_timeout(8000)
 page.set_content(html)
 page.add_style_tag(content=(ROOT/'styles.css').read_text())
 page.add_script_tag(type='importmap',content=json.dumps({'imports':mapping}))
 page.add_script_tag(content=(ROOT/'i18n.js').read_text())
 page.evaluate("document.dispatchEvent(new Event('DOMContentLoaded')); if(!crypto.randomUUID)crypto.randomUUID=()=>String(Math.random()).slice(2)")
 page.evaluate(setup)
 page.locator('#team-snippet-browser').wait_for(state='visible')
 assert page.locator('#team-vault-records article').count()==6
 assert page.locator('#team-vault-records article:visible').count()==6
 prod=page.locator('[data-snippet-folder="Prod"] > .snippet-folder-toolbar > .vault-folder-heading')
 prod.click();assert page.locator('#team-vault-records article:visible').count()==2
 page.locator('#team-snippet-search').fill('kubectl');assert page.locator('#team-vault-records article:visible').count()==1
 page.locator('#team-snippet-search').fill('');assert page.locator('#team-vault-records article:visible').count()==2
 # Re-render keeps collapse state; expansion state is not written to the Vault.
 page.locator('#team-snippet-sort').select_option('modified-desc',force=True);assert page.locator('#team-vault-records article:visible').count()==2
 assert page.evaluate('qaWrites')==0
 page.locator('[data-snippet-expand="true"]').click()
 # Checkbox remains exactly 18px, and a title click opens the details rather than selection.
 card=page.locator('#team-vault-records article').filter(has=page.locator('h4',has_text='Deploy 2'))
 box=card.locator('input[type=checkbox]').bounding_box();assert box['width']==18 and box['height']==18,box
 card.locator('h4').click();assert page.locator('#resource-detail-dialog').evaluate('(e)=>e.open')
 assert not card.locator('input[type=checkbox]').is_checked()
 page.locator('#resource-detail-dialog').evaluate('(e)=>e.close()')
 # Move an existing record while retaining any future fields.
 page.evaluate("qaData['vault-1'].find(v=>v.id==='b').data.future={targets:['demo-host']}")
 page.locator('#team-snippet-sort').select_option('title-asc',force=True)
 card.locator('.record-edit').click()
 assert page.locator('#team-snippet-folder').input_value()=='Prod/Deploy'
 page.locator('#team-snippet-folder').fill('Prod/Operations')
 page.locator('#team-vault-record-form button[type=submit]').click()
 page.wait_for_function("!document.querySelector('#team-record-editor').open")
 assert page.evaluate("qaData['vault-1'].find(v=>v.id==='b').data.future.targets[0]")=='demo-host'
 # Explicit child group selection, followed by a first snippet, with no fake empty record.
 page.locator('[data-snippet-create-child="Prod"]').click()
 assert page.locator('#team-snippet-group-parent').input_value()=='Prod'
 writes=page.evaluate('qaWrites')
 page.locator('#team-snippet-group-name').fill('New child')
 page.locator('#team-snippet-group-form button[type=submit]').click()
 assert page.locator('#team-snippet-folder').input_value()=='Prod/New child'
 assert page.evaluate('qaWrites')==writes
 page.locator('#team-record-title').fill('Fresh command');page.locator('#team-record-secret').fill('echo demo')
 page.locator('#team-vault-record-form button[type=submit]').click()
 page.wait_for_function("!document.querySelector('#team-record-editor').open")
 assert page.evaluate("qaData['vault-1'].some(v=>v.data.folder==='Prod/New child')")
 page.locator('#team-snippet-folder-filter').select_option('folder:Prod',force=True)
 assert 'Other' not in page.locator('#team-vault-records').inner_text()
 page.locator('#team-snippet-search').fill('not found')
 assert 'Ничего не найдено' in page.locator('#team-vault-records').inner_text()
 page.evaluate("qa.setView('hosts','credential');qa.setView('hosts','snippet')")
 assert page.locator('#team-snippet-search').input_value()==''
 assert page.locator('#team-snippet-folder-filter').input_value()=='all'
 # Scope changes discard editor fields and previous-team paths.
 page.locator('#team-snippet-group-create').click();page.locator('#team-snippet-group-name').fill('Private draft')
 page.evaluate("const s=document.querySelector('#team-select');s.value='team-2';s.dispatchEvent(new Event('change'))")
 page.wait_for_function("document.querySelector('#team-vault-workspace-title').textContent.startsWith('Other Team')")
 assert not page.locator('#team-snippet-group-editor').evaluate('(e)=>e.open')
 assert page.locator('#team-snippet-group-name').input_value()==''
 assert 'Prod' not in page.locator('#team-snippet-folder-options').inner_html()
 # Viewers can search and expand/collapse, but cannot create or edit.
 page.evaluate("qaRole='viewer';qa.deactivate()")
 page.evaluate("qa.activate({deviceID:'demo-device'})")
 page.locator('#team-snippet-browser').wait_for(state='visible')
 assert page.locator('#team-snippet-create').is_disabled()
 assert page.locator('#team-snippet-group-create').is_disabled()
 assert page.locator('#team-vault-records .record-edit').first.is_disabled()
 assert page.locator('#team-vault-records .vault-folder-heading').first.is_enabled()
 page.locator('#team-vault-records .vault-folder-heading').first.click()
 page.locator('#team-snippet-search').fill('kubectl')
 assert page.locator('#team-vault-records article:visible').count()==1
 # Fresh editor session for screenshots.
 page.evaluate("qaRole='editor';qa.deactivate()")
 page.evaluate("qa.activate({deviceID:'demo-device'})")
 page.wait_for_timeout(100)
 for theme in ['graphite','light','emerald']:
  page.evaluate('(theme)=>document.documentElement.dataset.theme=theme',theme)
  page.locator('#team-vault').screenshot(path=str(OUT/f'{theme}.png'))
 page.set_viewport_size({'width':390,'height':844})
 page.locator('#team-vault').screenshot(path=str(OUT/'mobile.png'))
 assert not errors, errors
 print(json.dumps({'status':'passed','checks':['nested folders','search/reveal/restore','collapse survives rerender','checkbox hitbox/card details','edit/move/extension preservation','new child/first snippet','folder descendants','empty results','section reset','team isolation/draft cleanup','viewer read-only navigation','three themes/mobile'],'writes':page.evaluate('qaWrites'),'errors':errors},ensure_ascii=False))
 browser.close()
