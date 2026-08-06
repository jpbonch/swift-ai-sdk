// Generates content/docs/troubleshooting/*.mdx from troubleshooting-prose.ts.
//
// Same arrangement as the reference: prose is hand-written in one place, the
// pages are build artifacts on a shared template so 15 of them read alike.
//
//   bun scripts/build-troubleshooting.ts

import { mkdir, readdir, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { jsxAttr, yamlValue } from './frontmatter';
import { groups, prose, type TroubleshootingEntry } from './troubleshooting-prose';

const SITE = resolve(import.meta.dirname, '..');
const OUT = join(SITE, 'content/docs/troubleshooting');

const TROUBLESHOOTING_DESCRIPTION = 'Specific symptoms, why they happen, and what to change.';

function page(entry: TroubleshootingEntry): string {
  const parts = [
    '---',
    `title: ${yamlValue(entry.title)}`,
    `description: ${yamlValue(entry.summary)}`,
    '---',
    '',
    '## Symptom',
    '',
    entry.symptom,
    '',
    '## Why it happens',
    '',
    entry.cause,
    '',
    '## Fix',
    '',
    entry.fix,
  ];

  if (entry.seeAlso?.length) {
    parts.push(
      '',
      '## See also',
      '',
      ...entry.seeAlso.map(([label, href]) => `- [${label}](${href})`),
    );
  }

  return parts.join('\n') + '\n';
}

await rm(OUT, { recursive: true, force: true });
await mkdir(OUT, { recursive: true });

const byGroup = new Map<string, string[]>(groups.map((group) => [group.slug, []]));
const writes: Promise<unknown>[] = [];

for (const [slug, entry] of Object.entries(prose)) {
  if (!byGroup.has(entry.group)) {
    console.error(`Unknown group "${entry.group}" on ${slug}`);
    process.exit(1);
  }
  writes.push(Bun.write(join(OUT, `${slug}.mdx`), page(entry)));
  byGroup.get(entry.group)!.push(slug);
}

const index = [
  '---',
  `title: ${yamlValue('Troubleshooting')}`,
  `description: ${yamlValue(TROUBLESHOOTING_DESCRIPTION)}`,
  'icon: TriangleAlert',
  '---',
  '',
  'Each page here covers one symptom: what you see, why it happens, and the fix.',
  'For the full list of error cases with their meanings, see the',
  '[errors reference](/docs/reference/errors).',
  '',
  ...groups.flatMap((group) => {
    const slugs = byGroup.get(group.slug)!;
    if (!slugs.length) return [];
    return [
      `## ${group.title}`,
      '',
      '<Cards>',
      ...slugs.map(
        (slug) =>
          `  <Card title="${jsxAttr(prose[slug]!.title)}" href="/docs/troubleshooting/${slug}" description="${jsxAttr(prose[slug]!.summary)}" />`,
      ),
      '</Cards>',
      '',
    ];
  }),
].join('\n');

writes.push(Bun.write(join(OUT, 'index.mdx'), index));

const pages: string[] = ['index'];
for (const group of groups) {
  const slugs = byGroup.get(group.slug)!;
  if (!slugs.length) continue;
  pages.push(`---${group.title}---`, ...slugs.sort());
}

// `root: true` makes this its own sidebar section, the way guides/ and
// providers/ do. Without it fumadocs nests the folder inside whatever tree is
// showing and the title renders twice.
writes.push(
  Bun.write(
    join(OUT, 'meta.json'),
    JSON.stringify(
      {
        title: 'Troubleshooting',
        root: true,
        description: TROUBLESHOOTING_DESCRIPTION,
        icon: 'TriangleAlert',
        pages,
      },
      null,
      2,
    ) + '\n',
  ),
);

await Promise.all(writes);

const count = (await readdir(OUT)).filter((f) => f.endsWith('.mdx')).length;
console.log(`wrote ${count} troubleshooting pages to content/docs/troubleshooting`);
