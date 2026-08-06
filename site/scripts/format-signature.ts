// Renders one api-index.json function entry back into Swift source form.
//
// Shared so the reference generator and any consumer produce identical text.
// Signatures are emitted into the .mdx as ```swift fences rather than a custom
// component, which gets them the same highlighting and copy button as every
// other code block on the site.

import type { Overload } from './api-types';

export function formatSignature(entry: Overload): string {
  const generics = entry.generics ? `<${entry.generics}>` : '';
  const effects = [entry.isAsync && 'async', entry.throws && 'throws'].filter(Boolean).join(' ');
  const suffix = effects ? ` ${effects}` : '';

  // An initializer is spelled `init(...)`, not `func init(...)`, and its
  // failable form is `init?` rather than a return arrow.
  const isInit = entry.name === 'init';
  const keyword = isInit ? '' : 'func ';
  const name = isInit && entry.returns.endsWith('?') ? 'init?' : entry.name;
  const arrow = isInit || entry.returns === 'Void' ? '' : ` -> ${entry.returns}`;

  if (entry.parameters.length === 0) {
    return `${keyword}${name}${generics}()${suffix}${arrow}`;
  }

  const lines = entry.parameters.map((parameter) => {
    const label = parameter.label ?? '_';
    const name = parameter.name && parameter.name !== parameter.label ? ` ${parameter.name}` : '';
    const fallback = parameter.default ? ` = ${parameter.default}` : '';
    return `    ${label}${name}: ${parameter.type}${fallback}`;
  });

  return [`${keyword}${name}${generics}(`, lines.join(',\n'), `)${suffix}${arrow}`].join('\n');
}
