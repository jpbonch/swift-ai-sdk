// The shape of lib/api-index.json, shared by the extractor that writes it, the
// generators that read it, and the Parameters component that renders it.

export type Parameter = {
  label: string | null;
  name: string | null;
  type: string;
  default: string | null;
  optional: boolean;
};

/** A function signature without its alternate forms. */
export type Overload = {
  name: string;
  generics: string | null;
  isAsync: boolean;
  throws: boolean;
  returns: string;
  parameters: Parameter[];
  file: string;
};

export type FunctionEntry = Overload & {
  overloads: Overload[];
};

export type Property = {
  name: string;
  type: string;
  /** `var` is settable, `let` is not. */
  mutable: boolean;
  default: string | null;
};

export type EnumCase = {
  name: string;
  /** The associated-value list, if the case carries one. */
  associated: string | null;
};

export type TypeEntry = {
  name: string;
  kind: string;
  file: string;
  properties: Property[];
  initializers: Overload[];
  methods: Overload[];
  cases: EnumCase[];
};

export type ApiIndex = {
  generatedFrom: string;
  functions: FunctionEntry[];
  types: TypeEntry[];
};

/** One section heading in a generated section's sidebar and index page. */
export type Group = {
  slug: string;
  title: string;
};
