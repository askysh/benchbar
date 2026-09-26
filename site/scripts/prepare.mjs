// Runs before dev and build. Two jobs, both tolerant of missing files:
//
// 1. ROADMAP.md and CONTRIBUTING.md live at the repo root, where GitHub
//    shows them. They are copied into .generated/ with Starlight
//    frontmatter (title from their first "# " heading, the edit link and
//    last updated date of the root file), so the root stays the source of
//    truth and needs no frontmatter of its own.
// 2. docs/images/og-image.png becomes public/og.png, the social preview.
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const site = join(dirname(fileURLToPath(import.meta.url)), '..');
const root = join(site, '..');
const out = join(site, '.generated');

const rootPages = [
  { file: 'ROADMAP.md', slug: 'roadmap', description: 'Where BenchBar is and where it goes: released versions, later work, ideas and what is not planned.' },
  { file: 'CONTRIBUTING.md', slug: 'contributing', description: 'How to report a bug, run the tests and send a pull request to BenchBar.' },
];

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

function lastCommitDate(file) {
  try {
    return execFileSync('git', ['log', '-1', '--format=%cI', '--', file], { cwd: root, encoding: 'utf8' }).trim();
  } catch {
    return '';
  }
}

for (const page of rootPages) {
  const src = join(root, page.file);
  if (!existsSync(src)) {
    console.log(`prepare: ${page.file} not found, /${page.slug}/ is skipped`);
    continue;
  }
  let body = readFileSync(src, 'utf8');
  let title = page.slug;
  if (body.startsWith('---\n')) {
    // the file already has frontmatter: use it as it is
    writeFileSync(join(out, `${page.slug}.md`), body);
    continue;
  }
  const h1 = body.match(/^# (.+)\n+/);
  if (h1) {
    title = h1[1].trim();
    body = body.slice(h1[0].length);
  }
  const front = [
    '---',
    `title: ${JSON.stringify(title)}`,
    `description: ${JSON.stringify(page.description)}`,
    `editUrl: https://github.com/askysh/benchbar/edit/main/${page.file}`,
  ];
  const date = lastCommitDate(page.file);
  if (date) front.push(`lastUpdated: ${date}`);
  front.push('---', '');
  writeFileSync(join(out, `${page.slug}.md`), front.join('\n') + body);
}

const og = join(root, 'docs', 'images', 'og-image.png');
const ogOut = join(site, 'public', 'og.png');
if (existsSync(og)) {
  mkdirSync(dirname(ogOut), { recursive: true });
  copyFileSync(og, ogOut);
} else {
  console.log('prepare: docs/images/og-image.png not found, the site has no og:image file yet');
}
