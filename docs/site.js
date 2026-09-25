(() => {
  const sections = new Set(['product', 'workspace', 'tools', 'cloud', 'teams', 'security', 'guides', 'about']);
  document.querySelectorAll('a[hreflang]').forEach(link => {
    const base = link.getAttribute('href');
    link.addEventListener('click', () => {
      const section = window.location.hash.slice(1);
      link.setAttribute('href', sections.has(section) ? `${base}#${section}` : base);
    });
  });
  const button = document.querySelector('[aria-controls="site-menu"]');
  const menu = document.getElementById('site-menu');
  if (!button || !menu) return;
  const close = () => { button.setAttribute('aria-expanded', 'false'); menu.dataset.open = 'false'; };
  button.addEventListener('click', () => {
    const open = button.getAttribute('aria-expanded') !== 'true';
    button.setAttribute('aria-expanded', String(open));
    menu.dataset.open = String(open);
    if (open) menu.querySelector('a')?.focus();
  });
  menu.addEventListener('click', event => { if (event.target.closest('a')) close(); });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && button.getAttribute('aria-expanded') === 'true') {
      close(); button.focus();
    }
  });
  window.matchMedia('(min-width: 851px)').addEventListener('change', event => { if (event.matches) close(); });
})();
