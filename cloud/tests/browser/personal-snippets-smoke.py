"""Offline Chromium Personal Snippet UI smoke with a substituted in-memory Vault boundary.
Requires Python Playwright and Chromium. No network navigation, live API or cryptographic synchronization is attempted.
Run: python cloud/tests/browser/personal-snippets-smoke.py [output-directory]
"""
from pathlib import Path
import json
import re
import shutil
import sys
import tempfile
from urllib.parse import quote
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2] / "public"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(tempfile.mkdtemp(prefix="personal-snippets-"))
OUT.mkdir(parents=True, exist_ok=True)
html = re.sub(r'<script\b[^>]*>.*?</script>', '', (ROOT / 'index.html').read_text(), flags=re.S)
setup = """async () => {
 let stored=null;
 const repository={load:async()=>stored&&structuredClone(stored),save:async(value)=>{stored=structuredClone(value)}};
 const {initializeLocalVault,finishPortalBootstrap}=await import('qa/app.js');
 const {initializeModernSelects}=await import('qa/modern-select.js');initializeModernSelects();
 window.qa=await initializeLocalVault({repository,documentValue:document});
 window.qaStored=()=>JSON.stringify(qa.controller.document());
 await qa.controller.create('synthetic browser test only');
 const id='22222222-2222-4222-8222-222222222222';
 const native={id,profileID:'11111111-1111-4111-8111-111111111111',title:'Deploy 2',command:'kubectl rollout',category:'Production/Deploy',groupID:'33333333-3333-4333-8333-333333333333',targets:[{kind:'localTerminal'}],isExplicitlyUngrouped:false,updatedAt:'2026-09-01T00:00:00Z',future:{keep:'yes'}};
 await qa.controller.upsert({id,type:'snippet',data:{title:native.title,body:native.command,category:native.category,template:btoa(JSON.stringify(native)),favorite:true}});
 for(const [title,category,body] of [['Deploy 10','Production/Deploy','printf deploy'],['Logs','Production/Logs','tail logs'],['Other','ProductionOther','printf other'],['Root','','pwd']]) {
  await qa.controller.upsert({type:'snippet',data:{title,category,body}});
 }
 await qa.controller.upsert({type:'host',data:{title:'Synthetic host',address:'fixture.invalid',folder:'HostsOnly'}});
 document.querySelector('#cloud-workspace').hidden=false;
 document.querySelector('#local-vault').hidden=false;
 document.body.dataset.portalView='workspace';
 for(const el of document.querySelectorAll('[data-workspace-panel]'))el.hidden=el.id!=='local-vault';
 qa.mode('unlocked');qa.setFilter('snippet');finishPortalBootstrap();
} """
with sync_playwright() as p:
    browser = p.chromium.launch(executable_path=shutil.which('chromium'), headless=True, args=['--no-sandbox'])
    page = browser.new_page(viewport={'width':1440,'height':1200}, locale='ru-RU')
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    mock = """
export function createIndexedDBVaultRepository(){return {};}
export function createLocalVaultController(){
 let records=[],locked=true;
 return {status:async()=>locked?'empty':'unlocked',create:async()=>{locked=false},lock(){locked=true},
 document(){if(locked)throw Error('locked');return {records:structuredClone(records)}},
 async upsert({id,type,data}){id??=crypto.randomUUID();const record={id,type,data:structuredClone(data),modifiedAt:new Date().toISOString()};const i=records.findIndex(v=>v.id===id);if(i<0)records.push(record);else records[i]=record;return id},
 async delete(id){records=records.filter(v=>v.id!==id)} };
}
"""
    modules = {path.name:path.read_text() for path in ROOT.glob('*.js')}
    modules['app.js'] = modules['app.js'].replace('if (typeof document !== "undefined") {', 'if (false) {').replace('from "./vault-local.js";', 'from "./qa-vault-local.js";')
    modules['qa-vault-local.js'] = mock
    mapping = {}
    for name, text in modules.items():
        text = re.sub(r'(from\s+["\'])\./([^"\']+)(["\'])', lambda m:m[1]+'qa/'+m[2].split('?')[0]+m[3], text)
        mapping['qa/'+name] = 'data:text/javascript;charset=utf-8,'+quote(text,safe='')
    page.set_content(re.sub(r'<link[^>]+(?:stylesheet|preconnect|icon)[^>]*>', '', html))
    page.add_style_tag(content=(ROOT/'styles.css').read_text())
    page.add_script_tag(type='importmap', content=json.dumps({'imports':mapping}))
    page.add_script_tag(content=(ROOT/'i18n.js').read_text())
    page.evaluate("document.dispatchEvent(new Event('DOMContentLoaded')); if(!crypto.randomUUID)crypto.randomUUID=()=> 'aaaaaaaa-aaaa-4aaa-8aaa-'+String(Math.floor(Math.random()*1e12)).padStart(12,'0')")
    page.evaluate(setup)
    page.set_default_timeout(7000)
    cards = page.locator('#local-vault-records article')
    assert cards.count() == 5
    assert page.locator('#personal-vault-folder-label').text_content() == 'Папка и вложенные'
    assert 'HostsOnly' not in page.locator('#personal-vault-folder-filter').inner_text()
    assert page.locator('#personal-snippet-group-create').is_visible()
    baseline = page.evaluate('qaStored()')
    prod = page.locator('#local-vault-records [data-snippet-folder="Production"] > .snippet-folder-toolbar > button.vault-folder-heading')
    prod.click(); assert page.locator('#local-vault-records article:visible').count() == 2
    page.locator('#personal-vault-search').fill('kubectl')
    assert page.locator('#local-vault-records article:visible').count() == 1
    page.locator('#personal-vault-search').fill('')
    assert page.locator('#local-vault-records article:visible').count() == 2
    page.locator('#personal-vault-sort').select_option('title-asc', force=True)
    assert page.locator('#local-vault-records article:visible').count() == 2
    assert page.evaluate('qaStored()') == baseline
    page.locator('[data-personal-snippet-expand="true"]').click()
    card = cards.filter(has=page.locator('h4', has_text='Deploy 2'))
    box = card.locator('input[type=checkbox]').bounding_box()
    assert box['width'] == 18 and box['height'] == 18, box
    card.locator('h4').click()
    assert page.locator('#resource-detail-dialog').evaluate('(e)=>e.open')
    assert not card.locator('input[type=checkbox]').is_checked()
    page.locator('#resource-detail-dialog').evaluate('(e)=>e.close()')
    card.locator('.record-edit').click()
    assert page.locator('#local-snippet-folder').input_value() == 'Production/Deploy'
    page.locator('#local-record-title').fill('Updated command')
    page.locator('#local-record-secret').fill('printf changed')
    page.locator('#local-snippet-folder').fill('Production/Changed')
    page.locator('#local-record-save').click()
    page.wait_for_function("!document.querySelector('#local-record-editor-dialog').open")
    saved = page.evaluate("qa.controller.document().records.find(v=>v.id==='22222222-2222-4222-8222-222222222222').data")
    import base64
    native = json.loads(base64.urlsafe_b64decode(saved['template'] + '=' * (-len(saved['template']) % 4)))
    assert saved['category'] == native['category'] == 'Production/Changed'
    assert saved['title'] == native['title'] == 'Updated command'
    assert saved['body'] == native['command'] == 'printf changed'
    assert native['future'] == {'keep':'yes'} and native['targets'] == [{'kind':'localTerminal'}]
    assert native['groupID'] == '00000000-0000-0000-0000-000000000000'
    assert 'folder' not in saved
    # Favorite actions operate on original records, never on the folder projection.
    cards.filter(has=page.locator('h4',has_text='Root')).locator('.record-favorite').click()
    assert page.evaluate("qa.controller.document().records.filter(v=>v.type==='snippet').every(v=>!Object.hasOwn(v.data,'folder'))")
    page.locator('#local-vault-records [data-snippet-create-child="Production"]').click()
    assert page.locator('#personal-snippet-group-parent').input_value() == 'Production'
    before_count = page.evaluate('qa.controller.document().records.length')
    page.locator('#personal-snippet-group-name').fill('New child')
    page.locator('#personal-snippet-group-form button[type=submit]').click()
    assert page.locator('#local-snippet-folder').input_value() == 'Production/New child'
    assert page.evaluate('qa.controller.document().records.length') == before_count
    page.locator('#local-record-title').fill('Brand new')
    page.locator('#local-record-secret').fill('printf new')
    page.locator('#local-record-save').click()
    page.wait_for_function("!document.querySelector('#local-record-editor-dialog').open")
    assert page.evaluate("qa.controller.document().records.some(v=>v.data.category==='Production/New child')")
    page.locator('#personal-vault-folder-filter').select_option('folder:Production', force=True)
    assert 'Other' not in page.locator('#local-vault-records').inner_text()
    page.locator('#personal-vault-search').fill('no match')
    assert 'Ничего не найдено' in page.locator('#local-vault-records').inner_text()
    page.evaluate("qa.setFilter('host')")
    assert page.locator('#personal-snippet-actions').is_hidden()
    assert page.locator('#personal-vault-folder-label').text_content() == 'Папка Hosts'
    assert page.locator('#personal-vault-search').input_value() == ''
    page.evaluate("qa.setFilter('snippet')")
    # Expand/collapse and select-visible remain scoped to visible snippet cards.
    page.locator('[data-personal-snippet-expand="false"]').click()
    assert page.locator('#local-vault-records article:visible').count() == 0
    page.locator('[data-personal-snippet-expand="true"]').click()
    page.evaluate('qa.setConflictMode(true)')
    assert page.locator('#personal-snippet-group-create').is_disabled()
    assert page.locator('#local-vault-records .vault-folder-heading').first.is_enabled()
    page.evaluate('qa.clearConflictUI()')
    # The Node regression tests cover the real encrypted controller separately.
    for theme in ['graphite', 'emerald', 'light']:
        page.evaluate('(theme)=>document.documentElement.dataset.theme=theme', theme)
        page.locator('#local-vault').screenshot(path=str(OUT / f'personal-{theme}.png'))
    page.set_viewport_size({'width':390,'height':844})
    page.locator('#local-vault').screenshot(path=str(OUT / 'personal-mobile.png'))
    page.locator('#personal-snippet-group-create').click()
    page.locator('#personal-snippet-group-name').fill('Private draft')
    page.evaluate("qa.closeEditor()")
    assert not page.locator('#personal-snippet-group-editor').evaluate('(e)=>e.open')
    assert page.locator('#personal-snippet-group-name').input_value() == ''
    page.evaluate("qa.controller.lock();qa.mode('waiting')")
    assert cards.count() == 0
    assert page.locator('#local-snippet-folder-options option').count() == 0
    assert page.locator('#personal-vault-folder-filter').inner_text() == 'Все папки'
    assert not errors, errors
    print(json.dumps({'status':'passed','mocked_vault_boundary':True,'live_api':False,'page_errors':errors,
        'checks':['native category tree','full body search','collapse restore','18px checkbox','template edit/move preservation',
                  'first-snippet group','descendant filter','Host separation','read-only conflict disclosure',
                  'scope/lock cleanup','three themes/390px']}, ensure_ascii=False))
    browser.close()
