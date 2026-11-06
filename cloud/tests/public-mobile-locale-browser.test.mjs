import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';

test('mobile public menu switches RU/EN in both themes without losing the page',
 {skip:!process.env.PLAYWRIGHT_MODULE||!process.env.CHROMIUM_PATH,timeout:30000},async()=>{
  const {chromium}=await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE));
  const html=(await readFile(new URL('../public/index.html',import.meta.url),'utf8'))
   .replace(/<script\b[^>]*>.*?<\/script>/gsu,'').replace(/<link[^>]+(?:stylesheet|preconnect|icon)[^>]*>/gu,'');
  const css=await readFile(new URL('../public/styles.css',import.meta.url),'utf8'),i18n=await readFile(new URL('../public/i18n.js',import.meta.url),'utf8');
  const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH,args:['--no-sandbox']});
  try{
   for(const theme of ['graphite','light'])for(const width of [320,390,560]){
    const page=await browser.newPage({viewport:{width,height:844},locale:'ru-RU'});
    try{
     await page.route('**/*',route=>route.fulfill({status:200,contentType:'text/html',body:'<!doctype html><html><body></body></html>'}));
     await page.goto('https://mobile-fixture.invalid/');await page.setContent(html);await page.addStyleTag({content:css});await page.addScriptTag({content:i18n});
     await page.evaluate(theme=>{document.documentElement.classList.remove('app-booting');document.documentElement.dataset.theme=theme;document.dispatchEvent(new Event('DOMContentLoaded'));},theme);
     await page.locator('.site-more summary').click();
     const mobile=page.locator('[data-locale-switch="public-mobile"]');
     assert.equal(await mobile.isVisible(),true,'mobile language selector must be visible in settings');
     await mobile.locator('[data-locale="en"]').click();assert.equal(await page.locator('html').getAttribute('lang'),'en');
     assert.equal(await mobile.locator('[data-locale="en"]').getAttribute('aria-pressed'),'true');
     await mobile.locator('[data-locale="ru"]').click();assert.equal(await page.locator('html').getAttribute('lang'),'ru');
     assert.equal(await mobile.locator('[data-locale="ru"]').getAttribute('aria-pressed'),'true');
     assert.equal(await page.locator('#public-actions').isVisible(),true);
    }finally{await page.close();}
   }
   const desktop=await browser.newPage({viewport:{width:1440,height:900},locale:'ru-RU'});
   try{await desktop.route('**/*',route=>route.fulfill({status:200,contentType:'text/html',body:'<!doctype html><html><body></body></html>'}));await desktop.goto('https://desktop-fixture.invalid/');await desktop.setContent(html);await desktop.addStyleTag({content:css});await desktop.addScriptTag({content:i18n});await desktop.evaluate(()=>{document.documentElement.classList.remove('app-booting');document.dispatchEvent(new Event('DOMContentLoaded'));});
    assert.equal(await desktop.locator('[data-locale-switch="public"]').isVisible(),true);
    await desktop.locator('.site-more summary').click();assert.equal(await desktop.locator('[data-locale-switch="public-mobile"]').isVisible(),false);
   }finally{await desktop.close();}
  }finally{await browser.close();}
 });
