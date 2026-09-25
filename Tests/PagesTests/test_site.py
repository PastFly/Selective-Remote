"""Release-safe and link-integrity checks for the static product site."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit, unquote
import hashlib
import unittest

ROOT = Path(__file__).resolve().parents[2] / 'docs'
PAGES = [ROOT / 'index.html', ROOT / 'ru' / 'index.html']
SECTIONS = ['product', 'workspace', 'tools', 'cloud', 'teams', 'security', 'guides', 'about']
RELEASE = 'https://github.com/PastFly/Selective-Remote/releases/tag/v0.31.0'

class Tags(HTMLParser):
    def __init__(self):
        super().__init__(); self.tags=[]
    def handle_starttag(self, tag, attrs):
        self.tags.append((tag, dict(attrs)))

class SiteTests(unittest.TestCase):
    def parsed(self, path):
        p=Tags(); p.feed(path.read_text()); return p

    def test_both_locales_have_full_story_and_local_switch(self):
        for page, lang, other in [(PAGES[0], 'en', '/Selective-Remote/ru/'), (PAGES[1], 'ru', '/Selective-Remote/')]:
            with self.subTest(page=page):
                tags=self.parsed(page).tags
                html=next(a for t,a in tags if t=='html')
                self.assertEqual(html.get('lang'),lang)
                ids=[a.get('id') for t,a in tags if a.get('id')]
                self.assertEqual([i for i in ids if i in SECTIONS],SECTIONS)
                self.assertTrue(any(t=='a' and a.get('href')==other and a.get('hreflang') for t,a in tags))
                self.assertTrue(any(t=='a' and a.get('href')=='#main' for t,a in tags))
                self.assertFalse(any(t=='a' and 'README' in a.get('href','') for t,a in tags))

    def test_release_target_and_future_label_are_separate(self):
        for page in PAGES:
            with self.subTest(page=page):
                tags=self.parsed(page).tags
                downloads=[a for t,a in tags if t=='a' and 'download' in a.get('class','').split()]
                self.assertGreaterEqual(len(downloads),2)
                self.assertTrue(all(a.get('href')==RELEASE for a in downloads))
                self.assertIn('0.32',page.read_text())
                self.assertNotIn('releases/download/v0.32',page.read_text())
                self.assertFalse(any(a.get('http-equiv','').lower()=='refresh' for t,a in tags))

    def test_local_links_images_and_alt_text(self):
        for page in PAGES:
            with self.subTest(page=page):
                tags=self.parsed(page).tags
                for tag, attrs in tags:
                    if tag=='img':
                        self.assertTrue(attrs.get('alt'))
                        self.assertTrue(attrs.get('width') and attrs.get('height'))
                    for key in ('href','src','poster'):
                        link=attrs.get(key,'')
                        if not link or link.startswith(('#','mailto:','tel:','http:','https:','data:')): continue
                        path=unquote(urlsplit(link).path)
                        target=(ROOT/path[len('/Selective-Remote/'):]) if path.startswith('/Selective-Remote/') else page.parent/path
                        self.assertTrue(target.exists(),f'{page}: broken {key}={link}')
                text=page.read_text()
                self.assertNotIn('images/connection-center.png',text)
                self.assertNotIn('images/forwarding-manager.png',text)

    def test_guides_and_accessibility_hooks(self):
        css=(ROOT/'site.css').read_text()
        self.assertIn('prefers-reduced-motion',css)
        self.assertIn(':focus-visible',css)
        for page in PAGES:
            tags=self.parsed(page).tags
            links=[a.get('href') for t,a in tags if t=='a']
            self.assertTrue(any('multi-monitor-rdp-macos.html' in (u or '') for u in links))
            self.assertTrue(any('server-to-server-sftp-macos.html' in (u or '') for u in links))
            self.assertTrue(any(t=='nav' and a.get('aria-label') for t,a in tags))
            self.assertTrue(any(t=='button' and a.get('aria-controls')=='site-menu' for t,a in tags))

    def test_real_capture_assets_are_present_and_distinct(self):
        digests = []
        for locale in ('en', 'ru'):
            for name in ('hosts', 'terminal', 'sftp', 'snippets'):
                path = ROOT / 'images' / f'demo-032-{locale}-{name}.webp'
                data = path.read_bytes()
                self.assertGreater(len(data), 20_000, f'{path}: capture is unexpectedly small')
                self.assertEqual(data[:4], b'RIFF', f'{path}: invalid WebP signature')
                self.assertEqual(data[8:12], b'WEBP', f'{path}: invalid WebP signature')
                digests.append(hashlib.sha256(data).digest())
        self.assertEqual(len(set(digests)), len(digests))

if __name__=='__main__': unittest.main()
