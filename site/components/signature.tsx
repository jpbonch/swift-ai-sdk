import apiIndex from '@/lib/api-index.json';
import type { FunctionEntry } from '@/scripts/api-types';

const functions = apiIndex.functions as unknown as FunctionEntry[];

/**
 * A table of a function's parameters, with types and defaults, read from
 * lib/api-index.json — which is regenerated from Sources/AI on every build.
 *
 * Signatures themselves are not a component: the generator writes them into
 * each page as a ```swift fence so they get the same highlighting and copy
 * button as every other code block.
 */
export function Parameters({ name }: { name: string }) {
  const entry = functions.find((candidate) => candidate.name === name);

  if (!entry) {
    return (
      <div className="my-4 rounded-lg border border-red-500/40 bg-red-500/10 p-3 text-sm">
        No API entry for <code>{name}</code>. Run <code>pnpm api:extract</code>, or check the
        spelling against <code>Sources/AI</code>.
      </div>
    );
  }

  if (entry.parameters.length === 0) return null;

  return (
    <div className="my-4 overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr>
            <th className="text-left">Parameter</th>
            <th className="text-left">Type</th>
            <th className="text-left">Default</th>
          </tr>
        </thead>
        <tbody>
          {entry.parameters.map((parameter) => (
            <tr key={parameter.name ?? parameter.type}>
              <td>
                <code>{parameter.label ?? '_'}</code>
              </td>
              <td>
                <code>{parameter.type}</code>
              </td>
              <td>
                {parameter.default ? (
                  <code>{parameter.default}</code>
                ) : (
                  <span className="text-fd-muted-foreground">required</span>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
