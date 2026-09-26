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

export default defineConfig({
  site,
  // the pages live in ../docs and the repo root (src/content.config.ts)
  vite: { server: { fs: { allow: ['..'] } } },
  markdown: { remarkPlugins: [remarkRepoLinks] },
  integrations: [
    starlight({
      title: 'BenchBar',
      description: 'Local Frappe and ERPNext development benches on macOS, in the background, with a menu bar app.',
      logo: { src: '../docs/images/app-icon.png', alt: 'BenchBar' },
      favicon: '/favicon.png',
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/askysh/benchbar' }],
      // entry.filePath is relative to site/, so "../docs/x.md" resolves to docs/x.md on main
      editLink: { baseUrl: 'https://github.com/askysh/benchbar/edit/main/site/' },
      lastUpdated: true,
      customCss: ['./src/styles/custom.css'],
      components: { SocialIcons: './src/components/TopNav.astro' },
      head: [
        { tag: 'meta', attrs: { property: 'og:image', content: `${site}/og.png` } },
        { tag: 'meta', attrs: { property: 'og:image:width', content: '1200' } },
        { tag: 'meta', attrs: { property: 'og:image:height', content: '630' } },
        { tag: 'meta', attrs: { property: 'og:image:alt', content: 'BenchBar: local Frappe benches on macOS' } },
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
          },
        },
      ],
      sidebar: [
        {
          label: 'Start',
          items: [
            { label: 'Introduction', slug: 'index' },
            { label: 'Install', slug: 'install' },
            { label: 'Quick start', slug: 'quick-start' },
            { label: 'The menu bar app', slug: 'app' },
          ],
        },
        {
          label: 'Guides',
          items: [
            { label: 'Benches and sites', slug: 'guides/benches-and-sites' },
            { label: 'Apps', slug: 'guides/apps' },
            { label: 'Doctor and repair', slug: 'guides/doctor-and-repair' },
            { label: 'Teams: profiles, lockfile and pull', slug: 'guides/teams' },
            { label: 'Coding agents and MCP', slug: 'guides/agents' },
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
                { label: 'site', slug: 'reference/cli/site' },
                { label: 'app', slug: 'reference/cli/app' },
                { label: 'profile', slug: 'reference/cli/profile' },
                { label: 'lock', slug: 'reference/cli/lock' },
                { label: 'pull', slug: 'reference/cli/pull' },
                { label: 'mcp', slug: 'reference/cli/mcp' },
                { label: 'report and other commands', slug: 'reference/cli/other' },
              ],
            },
            { label: 'JSON schema', slug: 'json-schema' },
            { label: 'Runners', slug: 'runners' },
            { label: 'Configuration', slug: 'reference/configuration' },
          ],
        },
        {
          label: 'Project',
          items: [
            { label: 'Troubleshooting', slug: 'troubleshooting' },
            { label: 'Decisions', slug: 'decisions' },
            ...rootPage('Roadmap', 'ROADMAP.md', 'roadmap'),
            { label: 'Releasing', slug: 'releasing' },
            ...rootPage('Contributing', 'CONTRIBUTING.md', 'contributing'),
            { label: 'Testing', slug: 'testing' },
          ],
        },
      ],
    }),
  ],
});
