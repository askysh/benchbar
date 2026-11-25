// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import { existsSync } from 'node:fs';
import remarkRepoLinks from './src/remark-repo-links.mjs';

const site = 'https://benchbar.akashmishra.com';

// ROADMAP.md and CONTRIBUTING.md come from the repo root (scripts/prepare.mjs);
// a page whose file is not there yet is left out of the sidebar
const rootPage = (label, file, slug) =>
  existsSync(new URL(`../${file}`, import.meta.url)) ? [{ label, slug }] : [];

const repoMaintainers = 'https://github.com/askysh/benchbar/blob/main/maintainers';

export default defineConfig({
  site,
  // the maintainer pages are in maintainers/, not on this site (DOC-17); the
  // old addresses go to the files on GitHub
  redirects: {
    '/decisions': `${repoMaintainers}/DECISIONS.md`,
    '/releasing': `${repoMaintainers}/releasing.md`,
  },
  // the pages live in ../docs and the repo root (src/content.config.ts)
  vite: { server: { fs: { allow: ['..'] } } },
  markdown: { remarkPlugins: [remarkRepoLinks] },
  integrations: [
    starlight({
      title: 'BenchBar',
      description: 'Local Frappe and ERPNext development benches on macOS, Linux and Windows (WSL), run in the background, with a menu bar app and a Windows tray.',
      logo: { src: '../docs/images/app-icon.png', alt: 'BenchBar' },
      favicon: '/favicon.png',
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/askysh/benchbar' }],
      // entry.filePath is relative to site/, so "../docs/x.md" resolves to docs/x.md; the edit link opens
      // next-release, where every pull request goes (the site itself is built from main)
      editLink: { baseUrl: 'https://github.com/askysh/benchbar/edit/next-release/site/' },
      lastUpdated: true,
      customCss: ['./src/styles/custom.css'],
      components: {
        SocialIcons: './src/components/TopNav.astro',
        ThemeSelect: './src/components/ThemeToggle.astro',
        Footer: './src/components/Footer.astro',
      },
      // code blocks take the page's surface colours (src/styles/custom.css);
      // shell snippets get a plain frame instead of a terminal window
      expressiveCode: {
        themes: ['vitesse-dark', 'vitesse-light'],
        useStarlightUiThemeColors: true,
        defaultProps: { frame: 'code' },
        styleOverrides: { borderRadius: '6px', frames: { frameBoxShadowCssValue: 'none' } },
      },
      head: [
        { tag: 'meta', attrs: { property: 'og:image', content: `${site}/og.png` } },
        { tag: 'meta', attrs: { property: 'og:image:width', content: '1200' } },
        { tag: 'meta', attrs: { property: 'og:image:height', content: '630' } },
        { tag: 'meta', attrs: { property: 'og:image:alt', content: 'BenchBar: local Frappe benches on macOS, Linux and Windows' } },
        { tag: 'meta', attrs: { name: 'twitter:card', content: 'summary_large_image' } },
        { tag: 'meta', attrs: { name: 'twitter:image', content: `${site}/og.png` } },
        // Umami analytics at analytics.akashmishra.com, only counted on benchbar.akashmishra.com
        {
          tag: 'script',
          attrs: {
            defer: true,
            src: 'https://analytics.akashmishra.com/script.js',
            'data-website-id': '44b22d77-3180-41e4-adff-bf868420c142',
            'data-domains': 'benchbar.akashmishra.com',
            // a browser with Do Not Track on is not counted (docs/privacy.md says so)
            'data-do-not-track': 'true',
            // the query string of a page view is not sent (docs/privacy.md says so)
            'data-exclude-search': 'true',
          },
        },
        // custom events (copied commands, downloads, outbound links): public/analytics-events.js
        { tag: 'script', attrs: { defer: true, src: '/analytics-events.js' } },
      ],
      // The sidebar groups pages by what the reader wants to do. A page's URL
      // follows its file, not its group, so moving a page between groups
      // breaks no link. tests/test-docs.sh checks that every page is listed.
      sidebar: [
        {
          label: 'Start',
          items: [
            { label: 'Introduction', slug: 'index' },
            { label: "What's new", slug: 'whats-new' },
            { label: 'Features', slug: 'features' },
            { label: 'Install', slug: 'install' },
            { label: 'Quick start', slug: 'quick-start' },
          ],
        },
        {
          label: 'Platforms',
          items: [
            { label: 'macOS', slug: 'macos' },
            { label: 'Linux', slug: 'linux' },
            { label: 'Windows', slug: 'windows' },
            { label: 'The BenchBar tray on Windows', slug: 'windows-tray' },
            { label: 'The menu bar app', slug: 'app' },
          ],
        },
        {
          label: 'Guides',
          items: [
            { label: 'Benches and sites', slug: 'guides/benches-and-sites' },
            { label: 'Apps', slug: 'guides/apps' },
            { label: 'Teams: profiles, lockfile and pull', slug: 'guides/teams' },
            { label: 'Coding agents and MCP', slug: 'guides/agents' },
            { label: 'Share a site on your network', slug: 'guides/share-on-your-network' },
            { label: 'Labs', slug: 'guides/labs' },
            { label: 'Quick Switch', slug: 'guides/quick-switch' },
            { label: 'Draw your own runner', slug: 'runners' },
          ],
        },
        {
          label: 'Concepts',
          items: [
            { label: 'Compared with other ways to run a bench', slug: 'concepts/alternatives' },
            { label: 'Port blocks', slug: 'concepts/port-blocks' },
            { label: 'How sharing keeps your bench safe', slug: 'concepts/sharing-safety' },
          ],
        },
        {
          label: 'Reference',
          items: [
            {
              label: 'CLI',
              items: [
                { label: 'install and adopt', slug: 'reference/cli/install' },
                { label: 'up, down, restart, status, logs', slug: 'reference/cli/running' },
                { label: 'doctor and repair', slug: 'reference/cli/doctor' },
                { label: 'ports', slug: 'reference/cli/ports' },
                { label: 'scan and register', slug: 'reference/cli/scan' },
                { label: 'site', slug: 'reference/cli/site' },
                { label: 'bench', slug: 'reference/cli/bench' },
                { label: 'app', slug: 'reference/cli/app' },
                { label: 'profile', slug: 'reference/cli/profile' },
                { label: 'lock', slug: 'reference/cli/lock' },
                { label: 'pull', slug: 'reference/cli/pull' },
                { label: 'run', slug: 'reference/cli/run' },
                { label: 'mcp', slug: 'reference/cli/mcp' },
                { label: 'lease', slug: 'reference/cli/lease' },
                { label: 'labs (experiments)', slug: 'reference/cli/labs' },
                { label: 'share and lan-guard', slug: 'reference/cli/share' },
                { label: 'report and other commands', slug: 'reference/cli/other' },
              ],
            },
            { label: 'Doctor checks', slug: 'guides/doctor-and-repair' },
            { label: 'JSON schema', slug: 'json-schema' },
            { label: 'Configuration', slug: 'reference/configuration' },
            { label: 'URL scheme', slug: 'reference/url-scheme' },
          ],
        },
        {
          label: 'Help',
          items: [
            { label: 'Troubleshooting', slug: 'troubleshooting' },
            { label: 'First run problems', slug: 'first-run-problems' },
            { label: 'FAQ', slug: 'faq' },
            { label: 'Glossary', slug: 'glossary' },
            { label: 'Update and migrate', slug: 'upgrade' },
            { label: 'Uninstall', slug: 'uninstall' },
            { label: 'Test a build', slug: 'testing' },
            { label: 'Privacy of this site', slug: 'privacy' },
          ],
        },
        {
          label: 'For contributors',
          items: [
            ...rootPage('Contributing', 'CONTRIBUTING.md', 'contributing'),
            ...rootPage('Roadmap', 'ROADMAP.md', 'roadmap'),
          ],
        },
      ],
    }),
  ],
});
