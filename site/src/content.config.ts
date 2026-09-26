import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { docsSchema } from '@astrojs/starlight/schema';

// The pages are the markdown files in the repo's docs/ folder, where
// contributors edit them, plus ROADMAP.md and CONTRIBUTING.md, which
// scripts/prepare.mjs copies from the repo root into .generated/.
// docs/README.md explains how to run this site and is not a page.
export const collections = {
  docs: defineCollection({
    loader: glob({
      base: '..',
      pattern: ['docs/**/*.md', '!docs/README.md', 'site/.generated/*.md'],
      generateId: ({ entry }) =>
        entry
          .replace(/^docs\//, '')
          .replace(/^site\/\.generated\//, '')
          .replace(/\.md$/, '')
          .toLowerCase(),
    }),
    schema: docsSchema(),
  }),
};
