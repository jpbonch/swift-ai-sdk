// Generates content/docs/reference/*.mdx from two inputs:
//
//   lib/api-index.json  signatures, extracted from Sources/AI
//   reference-prose.ts  hand-written prose, one entry per function
//
// The .mdx files are build artifacts. Edit prose in reference-prose.ts, then
// `pnpm api:reference`. Every page uses the same template so the section reads
// consistently at 46 pages.
//
//   bun scripts/build-reference.ts

import { mkdir, readdir, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import type { ApiIndex, FunctionEntry, TypeEntry } from './api-types';
import { formatSignature } from './format-signature';
import { jsxAttr, yamlValue } from './frontmatter';
import { groups, prose, type ReferenceEntry } from './reference-prose';
import { typeGroups, typeProse, type TypeProse } from './type-prose';

const SITE = resolve(import.meta.dirname, '..');

// Function pages sit directly under reference/ rather than a core/ subfolder.
// One nested folder for a single group bought nothing, and the sidebar renders
// separators cleanly where it mangles a lone folder trigger.
const OUT = join(SITE, 'content/docs/reference');

// Hand-written pages in this directory that the generator must never delete.
const KEEP = new Set(['errors.mdx']);

const REFERENCE_DESCRIPTION =
  'Every public function and type, with signatures generated from the source.';

const index: ApiIndex = await Bun.file(join(SITE, 'lib/api-index.json')).json();

/**
 * generateText -> generate-text
 * readUIMessageStream -> read-ui-message-stream  (acronym runs split correctly)
 * encodePCM16 -> encode-pcm16                    (trailing digits stay attached)
 */
export function slugify(name: string): string {
  return name
    .replace(/([a-z0-9])([A-Z])/g, '$1-$2')
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1-$2')
    .toLowerCase();
}

const missingTypes = Object.keys(typeProse).filter(
  (name) => !index.types.some((type) => type.name === name),
);
if (missingTypes.length) {
  console.error(`Type prose for types not in the API: ${missingTypes.join(', ')}`);
  process.exit(1);
}

const missingProse = index.functions.filter((fn) => !prose[fn.name]).map((fn) => fn.name);
const orphanProse = Object.keys(prose).filter(
  (name) => !index.functions.some((fn) => fn.name === name),
);

if (missingProse.length) {
  console.error(`Missing prose for: ${missingProse.join(', ')}`);
  process.exitCode = 1;
}
if (orphanProse.length) {
  console.error(`Prose for symbols not in the API: ${orphanProse.join(', ')}`);
  process.exitCode = 1;
}
if (process.exitCode) process.exit(1);

function page(fn: FunctionEntry, entry: ReferenceEntry): string {
  const parts = [
    '---',
    `title: ${yamlValue(fn.name)}`,
    `description: ${yamlValue(entry.summary)}`,
    '---',
    '',
    entry.body,
    '',
    '```swift',
    entry.example,
    '```',
    '',
    '## Signature',
    '',
    '```swift',
    formatSignature(fn),
    '```',
    '',
    `Defined in \`${fn.file}\`.`,
  ];

  if (fn.parameters.length) {
    parts.push('', '## Parameters', '', `<Parameters name="${fn.name}" />`);
  }

  if (fn.overloads.length) {
    const count = fn.overloads.length;
    parts.push(
      '',
      '## Overloads',
      '',
      `${count} other ${count === 1 ? 'form' : 'forms'} of this function ${count === 1 ? 'exists' : 'exist'}:`,
      '',
      ...fn.overloads.flatMap((overload) => [
        '```swift',
        formatSignature({ ...overload, name: fn.name }),
        '```',
        '',
      ]),
    );
  }

  parts.push('', '## Returns', '', entry.returns);

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

function typePage(type: TypeEntry, entry: TypeProse): string {
  const parts = [
    '---',
    `title: ${yamlValue(type.name)}`,
    `description: ${yamlValue(entry.summary)}`,
    '---',
    '',
    entry.body,
    '',
    '```swift',
    entry.example,
    '```',
    '',
    '## Declaration',
    '',
    '```swift',
    `public ${type.kind} ${type.name}`,
    '```',
    '',
    `Defined in \`${type.file}\`.`,
  ];

  if (type.cases.length) {
    parts.push(
      '',
      '## Cases',
      '',
      '```swift',
      ...type.cases.map((entry) => `case ${entry.name}${entry.associated ?? ''}`),
      '```',
    );
  }

  if (type.initializers.length) {
    parts.push(
      '',
      `## Initializer${type.initializers.length === 1 ? '' : 's'}`,
      '',
      ...type.initializers.flatMap((init) => ['```swift', formatSignature(init), '```', '']),
    );
    parts.pop();
  }

  if (type.properties.length) {
    parts.push(
      '',
      '## Properties',
      '',
      '| Property | Type | Default |',
      '| --- | --- | --- |',
      // `var`/`let` rides in the name cell rather than taking a column of its
      // own, since most types have no stored defaults to show.
      ...type.properties.map(
        (property) =>
          `| \`${property.mutable ? 'var' : 'let'} ${property.name}\` | \`${property.type}\` | ${
            property.default ? `\`${property.default}\`` : '—'
          } |`,
      ),
    );
  }

  if (type.methods.length) {
    parts.push(
      '',
      '## Methods',
      '',
      ...type.methods.flatMap((method) => ['```swift', formatSignature(method), '```', '']),
    );
    parts.pop();
  }

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

// index.mdx and errors.mdx live here and are hand-written, so clear only the
// generated pages rather than the whole directory.
await mkdir(OUT, { recursive: true });
for (const file of await readdir(OUT)) {
  if (file.endsWith('.mdx') && !KEEP.has(file)) await rm(join(OUT, file));
}

type Listing = { slug: string; name: string; summary: string };

const byGroup = new Map<string, Listing[]>(groups.map((group) => [group.slug, []]));
const writes: Promise<unknown>[] = [];

for (const fn of index.functions) {
  const entry = prose[fn.name]!;
  const slug = slugify(fn.name);
  writes.push(Bun.write(join(OUT, `${slug}.mdx`), page(fn, entry)));
  byGroup.get(entry.group)!.push({ slug, name: fn.name, summary: entry.summary });
}

const byTypeGroup = new Map<string, Listing[]>(typeGroups.map((group) => [group.slug, []]));

for (const [name, entry] of Object.entries(typeProse)) {
  const type = index.types.find((candidate) => candidate.name === name)!;
  const slug = slugify(name);
  writes.push(Bun.write(join(OUT, `${slug}.mdx`), typePage(type, entry)));
  byTypeGroup.get(entry.group)!.push({ slug, name, summary: entry.summary });
}

for (const entries of [...byGroup.values(), ...byTypeGroup.values()]) {
  entries.sort((a, b) => a.slug.localeCompare(b.slug));
}

const cards = (entries: Listing[]) => [
  '<Cards>',
  ...entries.map(
    (e) =>
      `  <Card title="${jsxAttr(e.name)}" href="/docs/reference/${e.slug}" description="${jsxAttr(e.summary)}" />`,
  ),
  '</Cards>',
  '',
];

const indexPage = [
  '---',
  `title: ${yamlValue('API reference')}`,
  `description: ${yamlValue(REFERENCE_DESCRIPTION)}`,
  'icon: BookOpen',
  '---',
  '',
  'Each page documents one symbol: what it does, when to reach for it, and its',
  'exact signature.',
  '',
  'Signatures here are extracted from `Sources/AI` on every build, so they cannot',
  'drift from the code. The prose around them is written by hand. Everything else',
  'in the docs teaches a concept or walks a task; this section is for looking',
  'something up.',
  '',
  '## Functions',
  '',
  ...groups.flatMap((group) => {
    const entries = byGroup.get(group.slug)!;
    return entries.length ? [`### ${group.title}`, '', ...cards(entries)] : [];
  }),
  '## Types',
  '',
  'The types you construct or inspect directly. Everything else in the public',
  'API is plumbing these hand back to you.',
  '',
  ...typeGroups.flatMap((group) => {
    const entries = byTypeGroup.get(group.slug)!;
    return entries.length ? [`### ${group.title}`, '', ...cards(entries)] : [];
  }),
  '## Conventions',
  '',
  'Swift argument labels are shown as written, so `_` means the parameter is',
  'called positionally. A parameter with no default is **required**; everything',
  'else can be omitted.',
  '',
  '`any LanguageModel` and `any AIToolProtocol` appear throughout because the SDK',
  'takes existentials rather than generics on those positions, which is what lets',
  'you swap a provider without changing a call site.',
  '',
  'Type pages list stored properties, initializers, and methods, including any',
  'added in a `public extension`. Computed properties and protocol conformances',
  'are left out.',
  '',
  'For the error cases these functions throw, see the',
  '[errors reference](/docs/reference/errors).',
  '',
].join('\n');

writes.push(Bun.write(join(OUT, 'index.mdx'), indexPage));

// Group headings keep 60+ entries navigable instead of one flat alphabetical run.
const pages: string[] = ['index'];
for (const group of groups) {
  const entries = byGroup.get(group.slug)!;
  if (!entries.length) continue;
  pages.push(`---${group.title}---`, ...entries.map((e) => e.slug));
}
for (const group of typeGroups) {
  const entries = byTypeGroup.get(group.slug)!;
  if (!entries.length) continue;
  pages.push(`---${group.title}---`, ...entries.map((e) => e.slug));
}
pages.push('---Errors---', 'errors');

// `root: true` makes this its own sidebar section, the way guides/ and
// providers/ do. Without it fumadocs nests it inside whatever tree is showing
// and the title renders twice.
writes.push(
  Bun.write(
    join(OUT, 'meta.json'),
    JSON.stringify(
      {
        title: 'API reference',
        root: true,
        description: REFERENCE_DESCRIPTION,
        icon: 'BookOpen',
        pages,
      },
      null,
      2,
    ) + '\n',
  ),
);

await Promise.all(writes);

// A prose link into this section that names a slug we did not emit is a typo.
// Catch it here rather than shipping a 404.
const emitted = new Set([
  'errors',
  ...index.functions.map((fn) => slugify(fn.name)),
  ...Object.keys(typeProse).map(slugify),
]);
const broken: string[] = [];

const linkSources: [string, string][] = [
  ...Object.entries(prose).map(
    ([name, entry]): [string, string] => [
      name,
      [entry.body, entry.returns, ...(entry.seeAlso ?? []).map(([, href]) => href)].join('\n'),
    ],
  ),
  ...Object.entries(typeProse).map(
    ([name, entry]): [string, string] => [
      name,
      [entry.body, ...(entry.seeAlso ?? []).map(([, href]) => href)].join('\n'),
    ],
  ),
];

for (const [name, text] of linkSources) {
  for (const match of text.matchAll(/\/docs\/reference\/([a-z0-9-]+)/g)) {
    if (emitted.has(match[1]!)) continue;
    broken.push(`${name} -> /docs/reference/${match[1]}`);
  }
}

if (broken.length) {
  console.error(`Broken reference links:\n  ${broken.join('\n  ')}`);
  process.exit(1);
}

console.log(
  `wrote ${index.functions.length} function and ${Object.keys(typeProse).length} type ` +
    `reference pages to content/docs/reference`,
);
