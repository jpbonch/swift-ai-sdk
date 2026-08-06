// Extracts public API signatures from Sources/AI into lib/api-index.json.
//
// Reference pages render their signature from this index instead of copying it,
// so a signature can never drift from the source. Prose stays hand-written in
// the .mdx files and is untouched by this script.
//
//   bun scripts/extract-api.mjs

import { join, relative, resolve } from 'node:path';
import type {
  ApiIndex,
  EnumCase,
  FunctionEntry,
  Overload,
  Parameter,
  Property,
  TypeEntry,
} from './api-types';

const ROOT = resolve(import.meta.dirname, '../..');
const SOURCES = join(ROOT, 'Sources/AI');
const OUT = resolve(import.meta.dirname, '../lib/api-index.json');

const swift = new Bun.Glob('**/*.swift');

async function swiftFiles(dir: string): Promise<string[]> {
  const found = [];
  for await (const path of swift.scan({ cwd: dir, absolute: true })) found.push(path);
  return found.sort();
}

/**
 * Split on commas that sit at bracket depth zero.
 *
 * `->` must not be read as a closing angle bracket, or every closure-typed
 * parameter silently truncates the rest of the list.
 */
function splitTopLevel(text: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let current = '';

  for (let i = 0; i < text.length; i++) {
    const ch = text[i];

    if (ch === '-' && text[i + 1] === '>') {
      current += '->';
      i++;
      continue;
    }
    if ('([<{'.includes(ch)) depth++;
    else if (')]>}'.includes(ch)) depth--;

    if (ch === ',' && depth === 0) {
      parts.push(current.trim());
      current = '';
      continue;
    }
    current += ch;
  }

  if (current.trim()) parts.push(current.trim());
  return parts;
}

/** Read from an open brace to its match, returning the body between them. */
function readBody(text: string, fromIndex: number): string {
  const open = text.indexOf('{', fromIndex);
  if (open === -1) return '';

  let depth = 0;
  for (let i = open; i < text.length; i++) {
    const ch = text[i];
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) return text.slice(open + 1, i);
    }
  }
  return text.slice(open + 1);
}

/** Read from an open paren to its match, returning [inner, indexAfterClose]. */
function readBalanced(text: string, openIndex: number): [string | null, number] {
  let depth = 0;
  for (let i = openIndex; i < text.length; i++) {
    const ch = text[i];
    if (ch === '(') depth++;
    else if (ch === ')') {
      depth--;
      if (depth === 0) return [text.slice(openIndex + 1, i), i + 1];
    }
  }
  return [null, openIndex];
}

function parseParameter(raw: string): Parameter | null {
  // `external internal: Type = default`  |  `label: Type`
  const colon = raw.indexOf(':');
  if (colon === -1) return null;

  const labels = raw.slice(0, colon).trim().split(/\s+/);
  const label = labels[0]!;
  const internal = labels[1] ?? null;

  let rest = raw.slice(colon + 1).trim();
  let fallback: string | null = null;

  // A default follows the first top-level `=`, skipping `->` arrows.
  let depth = 0;
  for (let i = 0; i < rest.length; i++) {
    const ch = rest[i];
    if (ch === '-' && rest[i + 1] === '>') {
      i++;
      continue;
    }
    if ('([<{'.includes(ch)) depth++;
    else if (')]>}'.includes(ch)) depth--;
    else if (ch === '=' && depth === 0 && rest[i + 1] !== '=' && rest[i - 1] !== '=') {
      fallback = rest.slice(i + 1).trim();
      rest = rest.slice(0, i).trim();
      break;
    }
  }

  return {
    label: label === '_' ? null : label,
    name: internal ?? (label === '_' ? null : label),
    type: rest,
    default: fallback,
    optional: fallback !== null || rest.endsWith('?'),
  };
}

/**
 * Parse `func` declarations matching `indent`.
 *
 * Top-level functions sit at column zero; a type's own methods sit one level
 * in. Anchoring on the exact indent keeps a nested type's members from being
 * read as its parent's.
 */
function parseFunctionsAt(
  source: string,
  file: string,
  indent: string,
  // Inside `public extension`, members are public without saying so.
  publicImplied = false,
): Overload[] {
  const results: Overload[] = [];
  const modifier = publicImplied ? '(?:public )?' : 'public ';
  const re = new RegExp(`^${indent}${modifier}func ([A-Za-z0-9_]+)(<[^>]*>)?\\s*\\(`, 'gm');
  let match;

  while ((match = re.exec(source))) {
    const [, name, generics] = match;
    const openIndex = source.indexOf('(', match.index + match[0].length - 1);
    const [inner, after] = readBalanced(source, openIndex);
    if (inner === null) continue;

    // Everything up to the body brace is the effects + return clause.
    const brace = source.indexOf('{', after);
    const tail = source.slice(after, brace === -1 ? after : brace).trim();
    const returns = tail.includes('->') ? tail.slice(tail.indexOf('->') + 2).trim() : 'Void';

    results.push({
      name: name!,
      generics: generics ? generics.slice(1, -1) : null,
      isAsync: /\basync\b/.test(tail),
      throws: /\bthrows\b/.test(tail),
      returns,
      parameters: splitTopLevel(inner)
        .map(parseParameter)
        .filter((parameter): parameter is Parameter => parameter !== null),
      file: relative(ROOT, file),
    });
  }
  return results;
}

const parseFunctions = (source: string, file: string) => parseFunctionsAt(source, file, '');

/** `public init(...) throws` declarations one level into a type body. */
function parseInitializers(body: string, name: string, file: string): Overload[] {
  const results: Overload[] = [];
  const re = /^ {4}public init(\?)?\s*\(/gm;
  let match;

  while ((match = re.exec(body))) {
    const openIndex = body.indexOf('(', match.index + match[0].length - 1);
    const [inner, after] = readBalanced(body, openIndex);
    if (inner === null) continue;

    const brace = body.indexOf('{', after);
    const tail = body.slice(after, brace === -1 ? after : brace).trim();

    results.push({
      name: 'init',
      generics: null,
      isAsync: /\basync\b/.test(tail),
      throws: /\bthrows\b/.test(tail),
      // An initializer returns its own type; `Void` renders no arrow.
      returns: match[1] ? `${name}?` : 'Void',
      parameters: splitTopLevel(inner)
        .map(parseParameter)
        .filter((parameter): parameter is Parameter => parameter !== null),
      file: relative(ROOT, file),
    });
  }
  return results;
}

/** Stored properties one level into a type body, skipping computed ones. */
function parseProperties(body: string, publicImplied = false): Property[] {
  const results: Property[] = [];
  const modifier = publicImplied ? '(?:public )?' : 'public ';
  const re = new RegExp(
    `^ {4}${modifier}(?:private\\(set\\) )?(var|let) ([A-Za-z0-9_]+):\\s*([^\\n=]+?)\\s*(?:=\\s*(.+?))?\\s*$`,
    'gm',
  );
  let match;

  while ((match = re.exec(body))) {
    const type = match[3]!.trim();
    // A trailing `{` means the declaration continues into a computed body.
    if (type.endsWith('{')) continue;
    results.push({
      name: match[2]!,
      type,
      mutable: match[1] === 'var',
      default: match[4]?.trim() ?? null,
    });
  }
  return results;
}

/** Enum cases one level into a type body, including associated values. */
function parseCases(body: string): EnumCase[] {
  const results: EnumCase[] = [];
  const re = /^ {4}case ([A-Za-z0-9_]+)(\([^\n]*\))?/gm;
  let match;

  while ((match = re.exec(body))) {
    results.push({ name: match[1]!, associated: match[2] ?? null });
  }
  return results;
}

function parseTypes(source: string, file: string): TypeEntry[] {
  const results: TypeEntry[] = [];
  const re = /^public (struct|enum|actor|final class|class|protocol) ([A-Za-z0-9_]+)/gm;
  let match;

  while ((match = re.exec(source))) {
    const name = match[2]!;
    const body = readBody(source, match.index);

    results.push({
      name,
      kind: match[1] === 'final class' ? 'class' : match[1]!,
      file: relative(ROOT, file),
      properties: parseProperties(body),
      initializers: parseInitializers(body, name, file),
      methods: parseFunctionsAt(body, file, '    '),
      cases: parseCases(body),
    });
  }
  return results;
}

/**
 * Members added to a type in a `public extension` block, keyed by type name.
 *
 * `Agent.asTool` and friends live here rather than in the type body, so a page
 * built from the body alone would silently omit them.
 */
function parseExtensions(source: string, file: string): Map<string, Partial<TypeEntry>> {
  const found = new Map<string, Partial<TypeEntry>>();
  const re = /^public extension ([A-Za-z0-9_]+)\s*\{/gm;
  let match;

  while ((match = re.exec(source))) {
    const name = match[1]!;
    const body = readBody(source, match.index);
    const existing = found.get(name) ?? { properties: [], methods: [], cases: [] };

    existing.properties!.push(...parseProperties(body, true));
    existing.methods!.push(...parseFunctionsAt(body, file, '    ', true));
    existing.cases!.push(...parseCases(body));
    found.set(name, existing);
  }
  return found;
}

const files = await swiftFiles(SOURCES);
const functions: Overload[] = [];
const types: TypeEntry[] = [];

// Bun.file() reads are lazy, so kick them all off before awaiting any.
const sources = await Promise.all(files.map((file) => Bun.file(file).text()));

// A type's extensions can live in any file, so collect them across all of them
// before folding them in.
const extensions = new Map<string, Partial<TypeEntry>>();

files.forEach((file, i) => {
  functions.push(...parseFunctions(sources[i]!, file));
  types.push(...parseTypes(sources[i]!, file));

  for (const [name, members] of parseExtensions(sources[i]!, file)) {
    const existing = extensions.get(name);
    if (!existing) extensions.set(name, members);
    else {
      existing.properties!.push(...members.properties!);
      existing.methods!.push(...members.methods!);
      existing.cases!.push(...members.cases!);
    }
  }
});

for (const type of types) {
  const extra = extensions.get(type.name);
  if (!extra) continue;
  type.properties.push(...extra.properties!);
  type.methods.push(...extra.methods!);
  type.cases.push(...extra.cases!);
}

// Overloads share a name; keep the one with the most parameters as canonical
// and record the rest so a page can mention them.
const byName = new Map<string, FunctionEntry>();
for (const fn of functions) {
  const existing = byName.get(fn.name);
  if (!existing) byName.set(fn.name, { ...fn, overloads: [] });
  else if (fn.parameters.length > existing.parameters.length) {
    byName.set(fn.name, { ...fn, overloads: [...existing.overloads, existing] });
  } else {
    existing.overloads.push(fn);
  }
}

const index: ApiIndex = {
  generatedFrom: 'Sources/AI',
  functions: [...byName.values()].sort((a, b) => a.name.localeCompare(b.name)),
  types: types.sort((a, b) => a.name.localeCompare(b.name)),
};

await Bun.write(OUT, JSON.stringify(index, null, 2) + '\n');
console.log(
  `wrote ${relative(process.cwd(), OUT)}: ` +
    `${index.functions.length} functions, ${index.types.length} types`,
);
