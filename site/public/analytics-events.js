// Custom Umami events for the docs site. The Umami script itself is added in
// astro.config.mjs and only counts on benchbar.akashmishra.com.
//
//   command-copy    a code block's copy button      { command, from }
//   download-click  a link to a GitHub release      { path, from }
//   outbound-click  any other link off the site     { host, path, from }
//
// Query strings are never sent.
(() => {
  const track = (name, data) => window.umami?.track(name, data);
  const RELEASES = /^\/askysh\/benchbar\/releases(\/|$)/;

  const onLink = (link) => {
    let url;
    try {
      url = new URL(link.getAttribute('href'), location.href);
    } catch {
      return;
    }
    if (!/^https?:$/.test(url.protocol) || url.origin === location.origin) return;
    const from = location.pathname;
    if (url.host === 'github.com' && RELEASES.test(url.pathname)) {
      track('download-click', { path: url.pathname, from });
    } else {
      track('outbound-click', { host: url.host, path: url.pathname, from });
    }
  };

  const onClick = (event) => {
    if (!(event.target instanceof Element)) return;
    const copy = event.target.closest('.expressive-code .copy button');
    if (copy && event.type === 'click') {
      // Expressive Code keeps the code in data-code, lines joined by U+007F.
      const first = (copy.getAttribute('data-code') || '').split('\u007f')[0].trim();
      track('command-copy', { command: first.slice(0, 80), from: location.pathname });
      return;
    }
    const link = event.target.closest('a[href]');
    if (link) onLink(link);
  };

  document.addEventListener('click', onClick);
  // a middle click opens the link in a new tab
  document.addEventListener('auxclick', onClick);
})();
