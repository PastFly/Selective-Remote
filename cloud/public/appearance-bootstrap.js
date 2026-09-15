(() => {
  const match = String(document.cookie).match(/(?:^|;\s*)sr_theme=(graphite|emerald|light)(?:;|$)/u);
  document.documentElement.dataset.theme = match?.[1] ?? "graphite";
})();
