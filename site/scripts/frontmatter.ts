// Frontmatter values are prose, and prose contains colons. Unquoted, a
// `description: Produces: goal, decisions` is a nested mapping and the YAML
// parser rejects the whole page. Always quote generated values.

export function yamlValue(text: string): string {
  return `"${text.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

/** Same problem one layer up: a quote in a <Card description="…"> ends the attribute. */
export function jsxAttr(text: string): string {
  return text.replace(/"/g, '&quot;').replace(/[{}]/g, (brace) => `&#${brace.charCodeAt(0)};`);
}
