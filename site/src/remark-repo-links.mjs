// Links in docs/ are written for GitHub: relative paths to other .md files
// and to files elsewhere in the repo. This remark plugin turns them into
// site links at build time, so the same markdown works in both places.
//
//   install.md, ../install.md#flags   -> /install/, /install/#flags
//   ../ROADMAP.md, ../CONTRIBUTING.md -> /roadmap/, /contributing/
//   any other repo file or folder     -> its page on GitHub (main)
import { existsSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const docs = join(repo, 'docs');
const generated = join(repo, 'site', '.generated');
const github = 'https://github.com/askysh/benchbar';
const rootPages = { 'ROADMAP.md': '/roadmap/', 'CONTRIBUTING.md': '/contributing/' };

function visit(node, fn) {
  fn(node);
  if (node.children) for (const child of node.children) visit(child, fn);
}

function slugFor(docPath) {
  const id = relative(docs, docPath).split(sep).join('/').replace(/\.md$/, '').toLowerCase();
  if (id === 'index') return '/';
  return `/${id.replace(/\/index$/, '')}/`;
}

export default function remarkRepoLinks() {
  return (tree, file) => {
    const from = file.path ? resolve(file.path) : '';
    if (!from) return;
    // the copies of root files resolve their links from the repo root
    const baseDir = from.startsWith(generated) ? repo : dirname(from);
    visit(tree, (node) => {
      if (node.type !== 'link' && node.type !== 'definition') return;
      const url = node.url;
      if (!url || /^[a-z]+:/i.test(url) || url.startsWith('#') || url.startsWith('/')) return;
      const [path, hash = ''] = url.split('#');
      const target = resolve(baseDir, path);
      const anchor = hash ? `#${hash}` : '';
      const rel = relative(repo, target).split(sep).join('/');
      if (rel.startsWith('..')) return;
      if (rootPages[rel]) {
        node.url = rootPages[rel] + anchor;
      } else if (target.startsWith(docs + sep) && target.endsWith('.md') && !rel.endsWith('docs/README.md')) {
        node.url = slugFor(target) + anchor;
      } else {
        const kind = existsSync(target) && statSync(target).isDirectory() ? 'tree' : 'blob';
        node.url = `${github}/${kind}/main/${rel}${anchor}`;
      }
    });
  };
}
