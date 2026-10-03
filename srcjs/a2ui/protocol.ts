import {
  applyA2uiOperations,
  convertSurfaceToUISpec,
  surfaceToOperations,
  type A2uiState,
  type A2uiSurfaceState,
} from "@assistant-ui/react-generative-ui/a2ui";

export const A2UI_LIMITS = Object.freeze({
  envelopeBytes: 256 * 1024,
  operations: 64,
  surfaces: 16,
  components: 500,
  depth: 32,
  templateItems: 100,
  stringBytes: 16 * 1024,
  actionPayloadBytes: 64 * 1024,
  recentEventIds: 64,
  identifierBytes: 128,
  tombstones: 128,
  recoveryTimeoutMs: 5_000,
  imageBytes: 256 * 1024,
});

export const A2UI_CATALOG =
  "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json";

const INPUT_COMPONENTS = new Set([
  "Text", "Image", "Icon", "Row", "Column", "List", "Card", "Divider",
  "Button", "TextField", "CheckBox", "ChoicePicker", "DateTimeInput",
]);
const OUTPUT_COMPONENTS = new Set([
  "Header", "Text", "Caption", "Image", "Divider", "Button", "Select",
  "Input", "DatePicker", "Checkbox", "RadioGroup", "Card", "Col", "Row",
  "ListView", "ListViewItem", "Markdown", "Icon",
]);
const UNSAFE_SEGMENTS = new Set(["__proto__", "prototype", "constructor"]);
const IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9._:@/-]*$/;
const ACTION_NAME = /^[A-Za-z][A-Za-z0-9_.:-]{0,127}$/;
const HEX_256 = /^[a-f0-9]{64}$/;

export type JsonValue =
  | null | boolean | number | string
  | readonly JsonValue[]
  | { readonly [key: string]: JsonValue };

export interface A2uiEnvelope {
  readonly transportVersion: 1;
  readonly threadId: string;
  readonly runId: string;
  readonly eventId: string;
  readonly sequence: number;
  readonly operations: readonly unknown[];
}

export interface EventLedgerEntry {
  readonly eventId: string;
  readonly sequence: number;
  readonly digest: string;
}

export interface SurfaceLineage {
  readonly surfaceId: string;
  readonly epoch: number;
  readonly revision: number;
  readonly deletedAtSequence?: number;
}

export interface SurfaceAnchor {
  readonly runId: string;
  readonly messageId: string;
}

export interface CanonicalA2uiMarker {
  readonly kind: "surface";
  readonly schemaVersion: 1;
  readonly transportVersion: 1;
  readonly protocolVersion: "v0.9";
  readonly surfaceId: string;
  readonly epoch: number;
  readonly revision: number;
  readonly lastSequence: number;
  readonly recentEventIds: readonly string[];
  readonly snapshot: readonly unknown[];
  readonly snapshotDigest: string;
  readonly anchor: SurfaceAnchor;
}

export interface CanonicalA2uiPart {
  readonly type: "generative-ui";
  readonly spec: unknown;
  readonly a2ui: CanonicalA2uiMarker;
}

export interface SurfaceRecord {
  readonly surfaceId: string;
  readonly epoch: number;
  readonly revision: number;
  readonly anchor: SurfaceAnchor;
  readonly surface: A2uiSurfaceState;
  readonly part: CanonicalA2uiPart;
}

export interface RunSegment {
  readonly runId: string;
  readonly open: boolean;
  readonly messageId?: string;
}

export interface RecoveryState {
  readonly expectedSequence: number;
  readonly receivedSequence: number;
  readonly eventId: string;
  readonly digest: string;
  readonly startedAt: number;
}

export type ThreadMode = "active" | "recovering" | "recovery-failed" | "unconfirmed";

export interface A2uiCheckpoint {
  readonly transportVersion: 1;
  readonly protocolVersion: "v0.9";
  readonly schemaVersion: 1;
  readonly lastAcceptedSequence: number;
  readonly generation: number;
  readonly eventLedger: readonly EventLedgerEntry[];
  readonly lineage: readonly SurfaceLineage[];
}

export interface ThreadProtocolState {
  readonly threadId: string;
  readonly mode: ThreadMode;
  readonly lastAcceptedSequence: number;
  readonly generation: number;
  readonly ledger: readonly EventLedgerEntry[];
  readonly surfaces: ReadonlyMap<string, SurfaceRecord>;
  readonly lineage: ReadonlyMap<string, SurfaceLineage>;
  readonly runs: ReadonlyMap<string, RunSegment>;
  readonly activeRunId?: string;
  readonly recovery?: RecoveryState;
  readonly failure?: string;
  readonly checkpoint: A2uiCheckpoint;
}

export interface A2uiControllerState {
  readonly threads: ReadonlyMap<string, ThreadProtocolState>;
}

export interface MessagePatch {
  readonly upserts: readonly {
    readonly threadId: string;
    readonly messageId: string;
    readonly surfaceId: string;
    readonly part: CanonicalA2uiPart;
  }[];
  readonly deletes: readonly {
    readonly threadId: string;
    readonly surfaceId: string;
  }[];
}

export type MessagePartMap = ReadonlyMap<string, CanonicalA2uiPart>;

export interface ProtocolDependencies {
  readonly reducer: typeof applyA2uiOperations;
  readonly converter: typeof convertSurfaceToUISpec;
  readonly snapshot: typeof surfaceToOperations;
  readonly filter: (spec: unknown, surfaceId: string) => unknown;
}

interface PrepareOptions {
  readonly dependencies?: Partial<ProtocolDependencies>;
  readonly now?: () => number;
  readonly allocateMessageId?: (threadId: string, runId: string, generation: number) => string;
}

export type PreparedTransaction = {
  readonly status: "prepared";
  readonly nextController: A2uiControllerState;
  readonly patch: MessagePatch;
  readonly envelope: A2uiEnvelope;
  readonly diagnostics: readonly string[];
} | {
  readonly status: "duplicate";
  readonly diagnostics: readonly string[];
} | {
  readonly status: "recovery-requested";
  readonly nextController: A2uiControllerState;
  readonly recovery: RecoveryState;
  readonly diagnostics: readonly string[];
} | {
  readonly status: "rejected";
  readonly error: string;
  readonly failClosed?: boolean;
  readonly diagnostics: readonly string[];
};

const utf8Bytes = (value: string): number => new TextEncoder().encode(value).length;
const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const isPlainRecord = (value: unknown): value is Record<string, unknown> => {
  if (!isRecord(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
};
const exactKeys = (value: Record<string, unknown>, allowed: readonly string[], required = allowed): boolean => {
  const keys = Object.keys(value);
  return keys.every((key) => allowed.includes(key)) && required.every((key) => keys.includes(key));
};
const validIdentifier = (value: unknown): value is string =>
  typeof value === "string" && value.length > 0 && utf8Bytes(value) <= A2UI_LIMITS.identifierBytes && IDENTIFIER.test(value);
const validSequence = (value: unknown): value is number =>
  typeof value === "number" && Number.isSafeInteger(value) && value > 0;

function stableSerialize(value: unknown, stack = new Set<object>()): string {
  if (value === null) return "null";
  if (typeof value === "string" || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("Value is not finite JSON.");
    return JSON.stringify(value);
  }
  if (typeof value !== "object") throw new Error("Value is not JSON.");
  if (!isPlainRecord(value) && !Array.isArray(value)) throw new Error("Value is not plain JSON.");
  if (stack.has(value)) throw new Error("Cyclic value is not JSON.");
  stack.add(value);
  try {
    if (Array.isArray(value)) return `[${value.map((entry) => stableSerialize(entry, stack)).join(",")}]`;
    const keys = Object.keys(value).sort();
    return `{${keys.map((key) => `${JSON.stringify(key)}:${stableSerialize(value[key], stack)}`).join(",")}}`;
  } finally {
    stack.delete(value);
  }
}


function cloneJson<T>(value: T, seen = new Map<object, unknown>()): T {
  if (value === null || typeof value !== "object") return value;
  const cached = seen.get(value);
  if (cached !== undefined) return cached as T;
  if (Array.isArray(value)) {
    const result: unknown[] = [];
    seen.set(value, result);
    for (const entry of value) result.push(cloneJson(entry, seen));
    return result as T;
  }
  if (!isPlainRecord(value)) throw new Error("Cannot clone a non-JSON value.");
  const result: Record<string, unknown> = {};
  seen.set(value, result);
  for (const [key, entry] of Object.entries(value)) {
    Object.defineProperty(result, key, {
      value: cloneJson(entry, seen), enumerable: true, configurable: true, writable: true,
    });
  }
  return result as T;
}

function cloneSurfaceState(surface: A2uiSurfaceState): A2uiSurfaceState {
  const clone: A2uiSurfaceState = {
    ...(surface.catalogId !== undefined ? { catalogId: surface.catalogId } : {}),
    components: new Map([...surface.components].map(([id, component]) => [id, cloneJson(component)])),
    dataModel: cloneJson(surface.dataModel),
  };
  for (const symbol of Object.getOwnPropertySymbols(surface)) {
    const descriptor = Object.getOwnPropertyDescriptor(surface, symbol);
    if (descriptor) Object.defineProperty(clone, symbol, descriptor);
  }
  return clone;
}
const SHA256_K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);
const rotateRight = (value: number, amount: number): number => (value >>> amount) | (value << (32 - amount));

function sha256(text: string): string {
  const input = new TextEncoder().encode(text);
  const bitLength = input.length * 8;
  const size = Math.ceil((input.length + 9) / 64) * 64;
  const bytes = new Uint8Array(size);
  bytes.set(input);
  bytes[input.length] = 0x80;
  const view = new DataView(bytes.buffer);
  const high = Math.floor(bitLength / 0x1_0000_0000);
  const low = bitLength >>> 0;
  view.setUint32(size - 8, high, false);
  view.setUint32(size - 4, low, false);
  const hash = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  const words = new Uint32Array(64);
  for (let offset = 0; offset < size; offset += 64) {
    for (let index = 0; index < 16; index++) words[index] = view.getUint32(offset + index * 4, false);
    for (let index = 16; index < 64; index++) {
      const a = words[index - 15]!;
      const b = words[index - 2]!;
      const s0 = rotateRight(a, 7) ^ rotateRight(a, 18) ^ (a >>> 3);
      const s1 = rotateRight(b, 17) ^ rotateRight(b, 19) ^ (b >>> 10);
      words[index] = (words[index - 16]! + s0 + words[index - 7]! + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, h] = hash;
    for (let index = 0; index < 64; index++) {
      const s1 = rotateRight(e!, 6) ^ rotateRight(e!, 11) ^ rotateRight(e!, 25);
      const choice = (e! & f!) ^ (~e! & g!);
      const t1 = (h! + s1 + choice + SHA256_K[index]! + words[index]!) >>> 0;
      const s0 = rotateRight(a!, 2) ^ rotateRight(a!, 13) ^ rotateRight(a!, 22);
      const majority = (a! & b!) ^ (a! & c!) ^ (b! & c!);
      const t2 = (s0 + majority) >>> 0;
      h = g; g = f; f = e; e = (d! + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    hash[0] = (hash[0]! + a!) >>> 0; hash[1] = (hash[1]! + b!) >>> 0;
    hash[2] = (hash[2]! + c!) >>> 0; hash[3] = (hash[3]! + d!) >>> 0;
    hash[4] = (hash[4]! + e!) >>> 0; hash[5] = (hash[5]! + f!) >>> 0;
    hash[6] = (hash[6]! + g!) >>> 0; hash[7] = (hash[7]! + h!) >>> 0;
  }
  return [...hash].map((word) => word.toString(16).padStart(8, "0")).join("");
}

export const sha256Utf8 = (text: string): string => sha256(text);
export const stableJsonSha256 = (value: unknown): string => sha256(stableSerialize(value));

function validateJson(value: unknown, depth = 0, seen = new Set<object>()): string | undefined {
  if (depth > A2UI_LIMITS.depth) return `JSON depth exceeds ${A2UI_LIMITS.depth}.`;
  if (value === null || typeof value === "boolean") return undefined;
  if (typeof value === "number") return Number.isFinite(value) ? undefined : "JSON number must be finite.";
  if (typeof value === "string") return utf8Bytes(value) <= A2UI_LIMITS.stringBytes
    ? undefined : `String exceeds ${A2UI_LIMITS.stringBytes} bytes.`;
  if (typeof value !== "object") return "Payload contains a non-JSON value.";
  if (!isPlainRecord(value) && !Array.isArray(value)) return "Payload must contain only plain JSON objects.";
  if (seen.has(value)) return "Payload contains a cycle.";
  seen.add(value);
  try {
    if (Array.isArray(value)) {
      if (value.length > 1_000) return "JSON collection is too wide.";
      for (const entry of value) {
        const error = validateJson(entry, depth + 1, seen);
        if (error) return error;
      }
      return undefined;
    }
    for (const [key, entry] of Object.entries(value)) {
      if (UNSAFE_SEGMENTS.has(key)) return `Unsafe object key "${key}".`;
      if (utf8Bytes(key) > A2UI_LIMITS.stringBytes) return "JSON object key is too long.";
      const error = validateJson(entry, depth + 1, seen);
      if (error) return error;
    }
    return undefined;
  } finally {
    seen.delete(value);
  }
}

function decodePointer(path: string): string[] | undefined {
  if (!path.startsWith("/")) return undefined;
  if (path === "/") return [];
  const result: string[] = [];
  for (const raw of path.slice(1).split("/")) {
    if (/~(?:[^01]|$)/.test(raw)) return undefined;
    result.push(raw.replace(/~1/g, "/").replace(/~0/g, "~"));
  }
  return result;
}

function validatePointer(path: unknown): string | undefined {
  if (typeof path !== "string") return "JSON Pointer must be a string.";
  const segments = decodePointer(path);
  if (!segments) return "JSON Pointer must be a standard absolute path.";
  if (segments.some((segment) => UNSAFE_SEGMENTS.has(segment))) return "JSON Pointer contains an unsafe segment.";
  return undefined;
}

function validateEmbeddedPointers(value: unknown): string | undefined {
  if (Array.isArray(value)) {
    for (const entry of value) {
      const error = validateEmbeddedPointers(entry);
      if (error) return error;
    }
  } else if (isPlainRecord(value)) {
    for (const [key, entry] of Object.entries(value)) {
      if (key === "path") {
        const error = validatePointer(entry);
        if (error) return error;
      } else {
        const error = validateEmbeddedPointers(entry);
        if (error) return error;
      }
    }
  }
  return undefined;
}

function componentReferences(component: Record<string, unknown>): string[] {
  const refs: string[] = [];
  if (Array.isArray(component.children)) {
    for (const child of component.children) if (typeof child === "string") refs.push(child);
  } else if (isPlainRecord(component.children) && isPlainRecord(component.children.template)) {
    const id = component.children.template.componentId;
    if (typeof id === "string") refs.push(id);
  }
  return refs;
}

function validateComponents(components: unknown): string | undefined {
  if (!Array.isArray(components)) return "components must be an array.";
  if (components.length > A2UI_LIMITS.components) return `Surface exceeds ${A2UI_LIMITS.components} components.`;
  const byId = new Map<string, Record<string, unknown>>();
  for (const component of components) {
    if (!isPlainRecord(component)) return "Component must be a plain object.";
    if (!validIdentifier(component.id) || typeof component.component !== "string") return "Component id/type is invalid.";
    if (!INPUT_COMPONENTS.has(component.component)) return `Unknown A2UI component "${component.component}".`;
    if (byId.has(component.id)) return `Duplicate component id "${component.id}".`;
    byId.set(component.id, component);
    const pointerError = validateEmbeddedPointers(component);
    if (pointerError) return pointerError;
  }
  const visit = (id: string, depth: number, active: Set<string>): string | undefined => {
    if (depth > A2UI_LIMITS.depth) return `Component tree exceeds depth ${A2UI_LIMITS.depth}.`;
    if (active.has(id)) return `Component cycle at "${id}".`;
    const component = byId.get(id);
    if (!component) return undefined;
    const next = new Set(active).add(id);
    for (const child of componentReferences(component)) {
      const error = visit(child, depth + 1, next);
      if (error) return error;
    }
    return undefined;
  };
  for (const id of byId.keys()) {
    const error = visit(id, 0, new Set());
    if (error) return error;
  }
  return undefined;
}

type OperationKind = "createSurface" | "updateComponents" | "updateDataModel" | "deleteSurface";
const OPERATION_KINDS: readonly OperationKind[] = [
  "createSurface", "updateComponents", "updateDataModel", "deleteSurface",
];

function validateOperations(operations: unknown, snapshot = false): { error?: string; kinds?: Map<string, Set<OperationKind>> } {
  if (!Array.isArray(operations)) return { error: "operations must be an array." };
  if (operations.length > A2UI_LIMITS.operations) return { error: `Envelope exceeds ${A2UI_LIMITS.operations} operations.` };
  const kinds = new Map<string, Set<OperationKind>>();
  for (let index = 0; index < operations.length; index++) {
    const operation = operations[index];
    if (!isPlainRecord(operation) || operation.version !== "v0.9") return { error: `Operation ${index} must use exact raw v0.9.` };
    const operationKeys = Object.keys(operation).filter((key) => key !== "version");
    if (Object.keys(operation).length !== 2 || operationKeys.length !== 1 || !OPERATION_KINDS.includes(operationKeys[0] as OperationKind)) {
      return { error: `Operation ${index} must contain exactly one standard operation key.` };
    }
    const kind = operationKeys[0] as OperationKind;
    if (snapshot && kind === "deleteSurface") return { error: "Snapshot cannot delete a surface." };
    const payload = operation[kind];
    if (!isPlainRecord(payload) || !validIdentifier(payload.surfaceId)) return { error: `Operation ${index} has an invalid surfaceId.` };
    const surfaceId = payload.surfaceId;
    const touched = kinds.get(surfaceId) ?? new Set<OperationKind>();
    touched.add(kind);
    kinds.set(surfaceId, touched);
    if (kind === "createSurface") {
      if (!exactKeys(payload, ["surfaceId", "catalogId", "theme", "attachDataModel"], ["surfaceId"])) return { error: "createSurface has unsupported fields." };
      if (payload.catalogId !== undefined && payload.catalogId !== A2UI_CATALOG) return { error: "catalogId is not the canonical v0.9 catalog." };
    } else if (kind === "updateComponents") {
      if (!exactKeys(payload, ["surfaceId", "components"])) return { error: "updateComponents has unsupported fields." };
      const error = validateComponents(payload.components);
      if (error) return { error };
    } else if (kind === "updateDataModel") {
      if (!exactKeys(payload, ["surfaceId", "path", "contents", "value", "data"], ["surfaceId"])) return { error: "updateDataModel has unsupported fields." };
      const values = ["contents", "value", "data"].filter((key) => Object.prototype.hasOwnProperty.call(payload, key));
      if (values.length !== 1) return { error: "updateDataModel needs exactly one value field." };
      const error = validatePointer(payload.path ?? "/");
      if (error) return { error };
    } else if (!exactKeys(payload, ["surfaceId"])) {
      return { error: "deleteSurface has unsupported fields." };
    }
  }
  return { kinds };
}

export type ValidationResult =
  | { readonly ok: true; readonly value: A2uiEnvelope; readonly digest: string }
  | { readonly ok: false; readonly error: string };

export function validateA2uiEnvelope(raw: unknown): ValidationResult {
  try {
    if (!isPlainRecord(raw) || !exactKeys(raw, [
      "transportVersion", "threadId", "runId", "eventId", "sequence", "operations",
    ])) return { ok: false, error: "Envelope shape is invalid." };
    if (raw.transportVersion !== 1) return { ok: false, error: "Unsupported transportVersion." };
    if (!validIdentifier(raw.threadId) || !validIdentifier(raw.runId) || !validIdentifier(raw.eventId)) {
      return { ok: false, error: "Envelope identifier is invalid." };
    }
    if (!validSequence(raw.sequence)) return { ok: false, error: "Envelope sequence is invalid." };
    const jsonError = validateJson(raw);
    if (jsonError) return { ok: false, error: jsonError };
    const operationResult = validateOperations(raw.operations);
    if (operationResult.error) return { ok: false, error: operationResult.error };
    const serialized = stableSerialize(raw);
    if (utf8Bytes(serialized) > A2UI_LIMITS.envelopeBytes) return { ok: false, error: "Envelope exceeds 256 KiB." };
    return { ok: true, value: raw as unknown as A2uiEnvelope, digest: sha256(serialized) };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : "Envelope validation failed." };
  }
}

const INVALID_PROP = Symbol("invalid-a2ui-prop");
type SanitizedProp = unknown | typeof INVALID_PROP;
type RuntimePropSchema = {
  readonly required: ReadonlySet<string>;
  readonly props: Readonly<Record<string, (value: unknown) => SanitizedProp>>;
  readonly forced?: Readonly<Record<string, unknown>>;
};

const TEXT_SIZES = new Set(["sm", "md", "lg", "xl", "2xl", "3xl"]);
const WEIGHTS = new Set(["normal", "medium", "semibold", "bold"]);
const COLORS = new Set(["emphasis", "secondary", "alpha-70", "white", "white-70", "white-50"]);
const IMAGE_SIZES = new Set(["sm", "md", "lg"]);
const ALIGNS = new Set(["start", "center", "end"]);
const JUSTIFIES = new Set(["start", "center", "end", "between"]);
const BUTTON_STYLES = new Set(["primary", "secondary", "outline", "ghost", "danger"]);
const ICON_NAMES = new Set([
  "sun", "moon", "cloud", "rain", "snow", "wind", "play", "pause", "check", "x",
  "star", "heart", "arrow-right", "arrow-up-right", "chevron-right", "calendar", "clock",
  "map-pin", "plane", "truck", "credit-card", "user", "search", "bell",
]);

const stringProp = (value: unknown): SanitizedProp =>
  typeof value === "string" && utf8Bytes(value) <= A2UI_LIMITS.stringBytes ? value : INVALID_PROP;
const booleanProp = (value: unknown): SanitizedProp => typeof value === "boolean" ? value : INVALID_PROP;
const enumProp = (allowed: ReadonlySet<string>) => (value: unknown): SanitizedProp =>
  typeof value === "string" && allowed.has(value) ? value : INVALID_PROP;
const boundedNumberProp = (minimum: number, maximum: number) => (value: unknown): SanitizedProp =>
  typeof value === "number" && Number.isFinite(value) && value >= minimum && value <= maximum
    ? value
    : INVALID_PROP;

function dateProp(value: unknown): SanitizedProp {
  const safe = stringProp(value);
  if (safe === INVALID_PROP) return INVALID_PROP;
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(safe as string);
  if (!match) return INVALID_PROP;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (month < 1 || month > 12) return INVALID_PROP;
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day >= 1 && day <= days[month - 1]! ? safe : INVALID_PROP;
}

function optionsProp(value: unknown): SanitizedProp {
  if (!Array.isArray(value) || value.length > A2UI_LIMITS.templateItems) return INVALID_PROP;
  const result: Array<{ label: string; value: string }> = [];
  for (const option of value) {
    if (!isPlainRecord(option)) return INVALID_PROP;
    const label = stringProp(option.label);
    const optionValue = stringProp(option.value);
    if (label === INVALID_PROP || optionValue === INVALID_PROP) return INVALID_PROP;
    result.push({ label: label as string, value: optionValue as string });
  }
  return result;
}

function imageSourceProp(value: unknown): SanitizedProp {
  return safeImageSource(value) ? value : INVALID_PROP;
}

const RUNTIME_PROP_SCHEMAS: Readonly<Record<string, RuntimePropSchema>> = {
  Header: { required: new Set(["text"]), props: { text: stringProp, size: enumProp(TEXT_SIZES) } },
  Text: { required: new Set(["value"]), props: {
    value: stringProp, size: enumProp(TEXT_SIZES), weight: enumProp(WEIGHTS), color: enumProp(COLORS),
  } },
  Caption: { required: new Set(["value"]), props: { value: stringProp } },
  Image: { required: new Set(["src", "alt"]), props: {
    src: imageSourceProp, alt: stringProp,
    size: (value) => typeof value === "string" ? enumProp(IMAGE_SIZES)(value) : boundedNumberProp(16, 1024)(value),
    round: booleanProp,
  } },
  Divider: { required: new Set(), props: { flush: booleanProp } },
  Button: { required: new Set(["label"]), props: {
    label: stringProp, buttonStyle: enumProp(BUTTON_STYLES), block: booleanProp, submit: booleanProp,
  } },
  Select: { required: new Set(["options"]), props: {
    options: optionsProp, placeholder: stringProp, label: stringProp, name: stringProp,
  } },
  Input: { required: new Set(), props: {
    placeholder: stringProp, multiline: booleanProp, label: stringProp, name: stringProp,
  } },
  DatePicker: { required: new Set(), props: {
    value: dateProp, min: dateProp, max: dateProp, label: stringProp, name: stringProp,
  } },
  Checkbox: { required: new Set(["label"]), props: {
    label: stringProp, name: stringProp, defaultChecked: booleanProp,
  } },
  RadioGroup: { required: new Set(["options"]), props: {
    options: optionsProp, label: stringProp, name: stringProp, defaultValue: stringProp,
  } },
  Card: { required: new Set(), props: { title: stringProp, padding: boundedNumberProp(0, 8) } },
  Col: { required: new Set(), props: { gap: boundedNumberProp(0, 8), align: enumProp(ALIGNS) } },
  Row: { required: new Set(), props: {
    gap: boundedNumberProp(0, 8), align: enumProp(ALIGNS), justify: enumProp(JUSTIFIES),
  } },
  ListView: { required: new Set(), props: {} },
  ListViewItem: { required: new Set(), props: {} },
  Markdown: { required: new Set(["value"]), props: { value: stringProp } },
  Icon: { required: new Set(["name"]), props: { name: enumProp(ICON_NAMES), size: enumProp(IMAGE_SIZES) } },
};

function safeImageSource(value: unknown): value is string {
  if (typeof value !== "string") return false;
  if (/^data:image\/(png|jpeg|gif|webp);base64,/.test(value)) {
    const body = value.slice(value.indexOf(",") + 1);
    if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(body)) return false;
    const padding = body.endsWith("==") ? 2 : body.endsWith("=") ? 1 : 0;
    return body.length / 4 * 3 - padding <= A2UI_LIMITS.imageBytes;
  }
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.username === "" && url.password === "";
  } catch {
    return false;
  }
}

function safeAction(value: unknown, surfaceId: string): Record<string, unknown> | undefined {
  if (!isPlainRecord(value) || value.type !== "a2ui:action" || !ACTION_NAME.test(String(value.name ?? ""))) return undefined;
  if (value.surfaceId !== surfaceId || !validIdentifier(value.sourceComponentId)) return undefined;
  const result: Record<string, unknown> = {
    type: "a2ui:action", name: value.name, surfaceId, sourceComponentId: value.sourceComponentId,
  };
  if (value.context !== undefined && !validateJson(value.context)) result.context = value.context;
  if (value.$input !== undefined && !validateJson(value.$input) && utf8Bytes(stableSerialize(value.$input)) <= A2UI_LIMITS.actionPayloadBytes) {
    result.$input = value.$input;
  }
  return result;
}

export function filterA2uiSpec(spec: unknown, surfaceId: string): unknown {
  let emitted = 0;
  const visit = (value: unknown, depth: number): unknown => {
    if (!isPlainRecord(value) || depth > A2UI_LIMITS.depth || emitted >= A2UI_LIMITS.components * 10) return null;
    const type = value.$type;
    if (typeof type !== "string" || !OUTPUT_COMPONENTS.has(type)) return null;
    emitted++;
    const schema = RUNTIME_PROP_SCHEMAS[type];
    if (!schema) return null;
    const output: Record<string, unknown> = { $type: type };
    if ((typeof value.$key === "string" || typeof value.$key === "number") && !validateJson(value.$key)) output.$key = value.$key;
    for (const [key, sanitize] of Object.entries(schema.props)) {
      const entry = value[key];
      if (entry === undefined) {
        if (schema.required.has(key)) return null;
        continue;
      }
      const sanitized = sanitize(entry);
      if (sanitized === INVALID_PROP) {
        if (schema.required.has(key)) return null;
        continue;
      }
      output[key] = sanitized;
    }
    if (schema.forced) Object.assign(output, schema.forced);
    const action = safeAction(value.$action, surfaceId);
    if (action) output.$action = action;
    const rawChildren = Array.isArray(value.children) ? value.children : value.children === undefined ? [] : [value.children];
    const children = rawChildren.slice(0, A2UI_LIMITS.templateItems).map((child) => visit(child, depth + 1)).filter((child) => child !== null);
    if (children.length) output.children = children;
    return output;
  };
  return visit(spec, 0);
}

function messageKey(threadId: string, messageId: string, surfaceId: string): string {
  return `${threadId}\u001f${messageId}\u001f${surfaceId}`;
}

export function applyMessagePatch(messages: MessagePartMap, patch: MessagePatch): MessagePartMap {
  const next = new Map(messages);
  for (const deletion of patch.deletes) {
    const prefix = `${deletion.threadId}\u001f`;
    const suffix = `\u001f${deletion.surfaceId}`;
    for (const key of next.keys()) if (key.startsWith(prefix) && key.endsWith(suffix)) next.delete(key);
  }
  for (const upsert of patch.upserts) next.set(messageKey(upsert.threadId, upsert.messageId, upsert.surfaceId), upsert.part);
  return next;
}

function makeCheckpoint(lastAcceptedSequence = 0, generation = 0, ledger: readonly EventLedgerEntry[] = [], lineage: Iterable<SurfaceLineage> = []): A2uiCheckpoint {
  return {
    transportVersion: 1, protocolVersion: "v0.9", schemaVersion: 1,
    lastAcceptedSequence, generation,
    eventLedger: ledger.slice(-A2UI_LIMITS.recentEventIds),
    lineage: [...lineage].map((entry) => ({ ...entry })),
  };
}
function newThread(threadId: string): ThreadProtocolState {
  return {
    threadId, mode: "active", lastAcceptedSequence: 0, generation: 0, ledger: [],
    surfaces: new Map(), lineage: new Map(), runs: new Map(), checkpoint: makeCheckpoint(),
  };
}
export function createControllerState(): A2uiControllerState { return { threads: new Map() }; }
function replaceThread(state: A2uiControllerState, thread: ThreadProtocolState): A2uiControllerState {
  const threads = new Map(state.threads);
  threads.set(thread.threadId, thread);
  return { threads };
}
function cloneThread(thread: ThreadProtocolState): ThreadProtocolState {
  return {
    ...thread, ledger: thread.ledger.map((entry) => ({ ...entry })),
    surfaces: new Map(thread.surfaces), lineage: new Map(thread.lineage), runs: new Map(thread.runs),
    checkpoint: {
      ...thread.checkpoint,
      eventLedger: thread.checkpoint.eventLedger.map((entry) => ({ ...entry })),
      lineage: thread.checkpoint.lineage.map((entry) => ({ ...entry })),
    },
    recovery: thread.recovery ? { ...thread.recovery } : undefined,
  };
}
function dependencies(overrides?: Partial<ProtocolDependencies>): ProtocolDependencies {
  return {
    reducer: overrides?.reducer ?? applyA2uiOperations,
    converter: overrides?.converter ?? convertSurfaceToUISpec,
    snapshot: overrides?.snapshot ?? surfaceToOperations,
    filter: overrides?.filter ?? filterA2uiSpec,
  };
}
function operationInfo(operations: readonly unknown[]): Map<string, Set<OperationKind>> {
  return validateOperations(operations).kinds ?? new Map();
}
function currentA2uiState(thread: ThreadProtocolState): A2uiState {
  return new Map([...thread.surfaces].map(([id, record]) => [id, cloneSurfaceState(record.surface)]));
}

function boundedLineage(lineage: Map<string, SurfaceLineage>, ledger: readonly EventLedgerEntry[]): Map<string, SurfaceLineage> {
  const live = [...lineage.values()].filter((entry) => entry.deletedAtSequence === undefined);
  let deleted = [...lineage.values()].filter((entry) => entry.deletedAtSequence !== undefined)
    .sort((left, right) => right.deletedAtSequence! - left.deletedAtSequence!);
  if (deleted.length > A2UI_LIMITS.tombstones) {
    const replayFloor = ledger[0]?.sequence ?? Number.POSITIVE_INFINITY;
    const protectedCount = deleted.filter((entry) => entry.deletedAtSequence! >= replayFloor).length;
    if (protectedCount > A2UI_LIMITS.tombstones) throw new Error("Checkpoint compaction is required before creating another surface.");
    deleted = deleted.slice(0, A2UI_LIMITS.tombstones);
  }
  return new Map([...live, ...deleted].map((entry) => [entry.surfaceId, entry]));
}

function canonicalPart(
  deps: ProtocolDependencies,
  surfaceId: string,
  surface: A2uiSurfaceState,
  lineage: SurfaceLineage,
  anchor: SurfaceAnchor,
  sequence: number,
  ledger: readonly EventLedgerEntry[],
): CanonicalA2uiPart {
  const converted = deps.converter(surface, { keepUnknownComponents: false });
  const spec = deps.filter(converted.spec, surfaceId);
  const snapshot = deps.snapshot(surface, surfaceId);
  const snapshotCheck = validateOperations(snapshot, true);
  if (snapshotCheck.error) throw new Error(`Generated snapshot is invalid: ${snapshotCheck.error}`);
  const snapshotDigest = stableJsonSha256(snapshot);
  return {
    type: "generative-ui", spec,
    a2ui: {
      kind: "surface", schemaVersion: 1, transportVersion: 1, protocolVersion: "v0.9",
      surfaceId, epoch: lineage.epoch, revision: lineage.revision, lastSequence: sequence,
      recentEventIds: ledger.map((entry) => entry.eventId).slice(-A2UI_LIMITS.recentEventIds),
      snapshot, snapshotDigest, anchor,
    },
  };
}

export function prepareEnvelopeTransaction(
  current: A2uiControllerState,
  rawEnvelope: unknown,
  options: PrepareOptions = {},
): PreparedTransaction {
  const validation = validateA2uiEnvelope(rawEnvelope);
  if (!validation.ok) return { status: "rejected", error: validation.error, diagnostics: [] };
  const envelope = validation.value;
  const digest = validation.digest;
  const original = current.threads.get(envelope.threadId) ?? newThread(envelope.threadId);
  if (original.mode !== "active") return { status: "rejected", error: `Thread is ${original.mode}.`, diagnostics: [] };
  const byEvent = original.ledger.find((entry) => entry.eventId === envelope.eventId);
  if (byEvent) {
    if (byEvent.sequence === envelope.sequence && byEvent.digest === digest) return { status: "duplicate", diagnostics: [] };
    return { status: "rejected", error: "eventId digest conflict.", failClosed: true, diagnostics: [] };
  }
  const bySequence = original.ledger.find((entry) => entry.sequence === envelope.sequence);
  if (bySequence) return { status: "rejected", error: "sequence eventId conflict.", failClosed: true, diagnostics: [] };
  const expected = original.lastAcceptedSequence + 1;
  if (envelope.sequence < expected) return { status: "rejected", error: "Stale non-duplicate sequence.", failClosed: true, diagnostics: [] };
  if (envelope.sequence > expected) {
    const recovery: RecoveryState = {
      expectedSequence: expected, receivedSequence: envelope.sequence, eventId: envelope.eventId,
      digest, startedAt: (options.now ?? Date.now)(),
    };
    const thread = { ...cloneThread(original), mode: "recovering" as const, recovery, failure: undefined };
    return {
      status: "recovery-requested", nextController: replaceThread(current, thread), recovery,
      diagnostics: [`Sequence gap: expected ${expected}, received ${envelope.sequence}.`],
    };
  }

  try {
    const deps = dependencies(options.dependencies);
    let thread = cloneThread(original);
    const info = operationInfo(envelope.operations);
    const creates = [...info.values()].some((kinds) => kinds.has("createSurface"));
    let activeRun = thread.activeRunId ? thread.runs.get(thread.activeRunId) : undefined;
    if (creates && (!activeRun || !activeRun.open || activeRun.runId !== envelope.runId)) {
      return { status: "rejected", error: "createSurface requires the active matching run.", diagnostics: [] };
    }
    if (creates && !activeRun!.messageId) {
      const allocate = options.allocateMessageId ?? ((threadId: string, runId: string, generation: number) =>
        `a2ui-${threadId}-${runId}-${generation}`);
      const messageId = allocate(envelope.threadId, envelope.runId, thread.generation + 1);
      if (!validIdentifier(messageId)) throw new Error("Allocated anchor message id is invalid.");
      activeRun = { ...activeRun!, messageId };
      const runs = new Map(thread.runs);
      runs.set(activeRun.runId, activeRun);
      thread = { ...thread, runs };
    }

    const reduced = deps.reducer(currentA2uiState(thread), envelope.operations);
    if (reduced.state.size > A2UI_LIMITS.surfaces) throw new Error(`Thread exceeds ${A2UI_LIMITS.surfaces} surfaces.`);
    for (const surface of reduced.state.values()) {
      if (surface.components.size > A2UI_LIMITS.components) throw new Error(`Surface exceeds ${A2UI_LIMITS.components} components.`);
    }
    const ledger = [...thread.ledger, { eventId: envelope.eventId, sequence: envelope.sequence, digest }]
      .slice(-A2UI_LIMITS.recentEventIds);
    const surfaces = new Map(thread.surfaces);
    const lineage = new Map(thread.lineage);
    const upserts: MessagePatch["upserts"][number][] = [];
    const deletes: MessagePatch["deletes"][number][] = [];

    for (const [surfaceId, kinds] of info) {
      const before = thread.surfaces.get(surfaceId);
      const after = reduced.state.get(surfaceId);
      const hasCreate = kinds.has("createSurface");
      const hasDelete = kinds.has("deleteSurface");
      if (after) {
        let entry: SurfaceLineage;
        if (hasCreate) entry = { surfaceId, epoch: envelope.sequence, revision: envelope.sequence };
        else {
          const previous = lineage.get(surfaceId);
          if (!previous || previous.deletedAtSequence !== undefined) continue;
          entry = { surfaceId, epoch: previous.epoch, revision: envelope.sequence };
        }
        lineage.set(surfaceId, entry);
        const anchor = before?.anchor ?? { runId: envelope.runId, messageId: activeRun!.messageId! };
        const part = canonicalPart(deps, surfaceId, after, entry, anchor, envelope.sequence, ledger);
        const record: SurfaceRecord = {
          surfaceId, epoch: entry.epoch, revision: entry.revision, anchor, surface: after, part,
        };
        surfaces.set(surfaceId, record);
        upserts.push({ threadId: envelope.threadId, messageId: anchor.messageId, surfaceId, part });
      } else if (hasDelete && (before || hasCreate || lineage.has(surfaceId))) {
        const previous = lineage.get(surfaceId);
        const entry: SurfaceLineage = {
          surfaceId, epoch: hasCreate ? envelope.sequence : (previous?.epoch ?? envelope.sequence),
          revision: envelope.sequence, deletedAtSequence: envelope.sequence,
        };
        lineage.set(surfaceId, entry);
        surfaces.delete(surfaceId);
        deletes.push({ threadId: envelope.threadId, surfaceId });
      }
    }

    const compacted = boundedLineage(lineage, ledger);
    const generation = thread.generation + 1;
    const checkpoint = makeCheckpoint(envelope.sequence, generation, ledger, compacted.values());
    thread = {
      ...thread, mode: "active", lastAcceptedSequence: envelope.sequence, generation,
      ledger, surfaces, lineage: compacted, checkpoint, recovery: undefined, failure: undefined,
    };
    return {
      status: "prepared", nextController: replaceThread(current, thread),
      patch: { upserts, deletes }, envelope, diagnostics: reduced.warnings,
    };
  } catch (error) {
    return {
      status: "rejected", error: error instanceof Error ? error.message : "Envelope preparation failed.", diagnostics: [],
    };
  }
}

export function commitPreparedTransaction(
  ref: { current: A2uiControllerState },
  prepared: Extract<PreparedTransaction, { status: "prepared" }>,
  messages: MessagePartMap,
  patcher: (messages: MessagePartMap, patch: MessagePatch) => MessagePartMap = applyMessagePatch,
): { readonly status: "committed"; readonly messages: MessagePartMap } | { readonly status: "patch-failed"; readonly error: string; readonly messages: MessagePartMap } {
  const previous = ref.current;
  ref.current = prepared.nextController;
  try {
    const isolatedMessages = new Map([...messages].map(([key, part]) => [key, cloneJson(part)]));
    const nextMessages = patcher(isolatedMessages, prepared.patch);
    if (!(nextMessages instanceof Map)) throw new Error("Message patcher must return a Map.");
    return { status: "committed", messages: nextMessages };
  } catch (error) {
    ref.current = previous;
    return { status: "patch-failed", error: error instanceof Error ? error.message : "Message patch failed.", messages };
  }
}

function validateLedger(value: unknown): value is EventLedgerEntry[] {
  return Array.isArray(value) && value.length <= A2UI_LIMITS.recentEventIds && value.every((entry) =>
    isPlainRecord(entry) && exactKeys(entry, ["eventId", "sequence", "digest"]) &&
    validIdentifier(entry.eventId) && validSequence(entry.sequence) && typeof entry.digest === "string" && HEX_256.test(entry.digest));
}
function validateLineage(value: unknown): value is SurfaceLineage[] {
  return Array.isArray(value) && value.length <= A2UI_LIMITS.surfaces + A2UI_LIMITS.tombstones && value.every((entry) =>
    isPlainRecord(entry) && exactKeys(entry, ["surfaceId", "epoch", "revision", "deletedAtSequence"], ["surfaceId", "epoch", "revision"]) &&
    validIdentifier(entry.surfaceId) && validSequence(entry.epoch) && validSequence(entry.revision) &&
    (entry.deletedAtSequence === undefined || validSequence(entry.deletedAtSequence)));
}
function validateCheckpoint(value: unknown): value is A2uiCheckpoint {
  if (!(isPlainRecord(value) && exactKeys(value, [
    "transportVersion", "protocolVersion", "schemaVersion", "lastAcceptedSequence", "generation", "eventLedger", "lineage",
  ]) && value.transportVersion === 1 && value.protocolVersion === "v0.9" && value.schemaVersion === 1 &&
    typeof value.lastAcceptedSequence === "number" && Number.isSafeInteger(value.lastAcceptedSequence) && value.lastAcceptedSequence >= 0 &&
    typeof value.generation === "number" && Number.isSafeInteger(value.generation) && value.generation >= 0 &&
    validateLedger(value.eventLedger) && validateLineage(value.lineage))) return false;
  const lastAcceptedSequence = value.lastAcceptedSequence;
  return value.eventLedger.every((entry) => entry.sequence <= lastAcceptedSequence) &&
    value.lineage.every((entry) => entry.epoch <= entry.revision && entry.revision <= lastAcceptedSequence &&
      (entry.deletedAtSequence === undefined ||
        (entry.deletedAtSequence === entry.revision && entry.deletedAtSequence <= lastAcceptedSequence)));
}

function validateMarker(value: unknown): value is CanonicalA2uiMarker {
  try {
    if (validateJson(value) || utf8Bytes(stableSerialize(value)) > A2UI_LIMITS.envelopeBytes) return false;
  if (!isPlainRecord(value) || !exactKeys(value, [
    "kind", "schemaVersion", "transportVersion", "protocolVersion", "surfaceId",
    "epoch", "revision", "lastSequence", "recentEventIds", "snapshot",
    "snapshotDigest", "anchor",
  ]) || value.kind !== "surface" || value.schemaVersion !== 1 ||
      value.transportVersion !== 1 || value.protocolVersion !== "v0.9" || !validIdentifier(value.surfaceId) ||
      !validSequence(value.epoch) || !validSequence(value.revision) || !validSequence(value.lastSequence) ||
      value.epoch > value.revision || value.revision > value.lastSequence ||
      !Array.isArray(value.recentEventIds) || value.recentEventIds.length > A2UI_LIMITS.recentEventIds ||
      !value.recentEventIds.every(validIdentifier) || !Array.isArray(value.snapshot) ||
      typeof value.snapshotDigest !== "string" || !HEX_256.test(value.snapshotDigest) ||
      !isPlainRecord(value.anchor) || !exactKeys(value.anchor, ["runId", "messageId"]) ||
      !validIdentifier(value.anchor.runId) || !validIdentifier(value.anchor.messageId)) return false;
  const operationResult = validateOperations(value.snapshot, true);
  if (operationResult.error || operationResult.kinds?.size !== 1 || !operationResult.kinds.has(value.surfaceId)) return false;
    return stableJsonSha256(value.snapshot) === value.snapshotDigest;
  } catch {
    return false;
  }
}

export function classifyCanonicalPart(part: unknown): "legacy" | "valid" | "invalid" {
  if (!isPlainRecord(part) || !Object.prototype.hasOwnProperty.call(part, "a2ui")) return "legacy";
  if (part.type !== "generative-ui" || !validateMarker(part.a2ui)) return "invalid";
  return "valid";
}

export interface RecoveryResponse {
  readonly transportVersion: 1;
  readonly threadId: string;
  readonly fromSequence: number;
  readonly toSequence: number;
  readonly envelopes: readonly unknown[];
}

export class A2uiProtocolController {
  private ref: { current: A2uiControllerState };
  private readonly deps: Partial<ProtocolDependencies>;
  private readonly now: () => number;
  private readonly allocateMessageId?: PrepareOptions["allocateMessageId"];
  private readonly patcher: (messages: MessagePartMap, patch: MessagePatch) => MessagePartMap;
  public messageParts: MessagePartMap = new Map();

  constructor(options: {
    readonly initialState?: A2uiControllerState;
    readonly dependencies?: Partial<ProtocolDependencies>;
    readonly now?: () => number;
    readonly allocateMessageId?: PrepareOptions["allocateMessageId"];
    readonly patcher?: (messages: MessagePartMap, patch: MessagePatch) => MessagePartMap;
  } = {}) {
    this.ref = { current: options.initialState ?? createControllerState() };
    this.deps = options.dependencies ?? {};
    this.now = options.now ?? Date.now;
    this.allocateMessageId = options.allocateMessageId;
    this.patcher = options.patcher ?? applyMessagePatch;
  }

  get state(): A2uiControllerState { return this.ref.current; }
  getThread(threadId: string): ThreadProtocolState | undefined { return this.ref.current.threads.get(threadId); }
  getSurface(threadId: string, surfaceId: string): SurfaceRecord | undefined {
    return this.getThread(threadId)?.surfaces.get(surfaceId);
  }
  canonicalParts(threadId: string): CanonicalA2uiPart[] {
    return [...(this.getThread(threadId)?.surfaces.values() ?? [])].map((record) => record.part);
  }
  exportCheckpoint(threadId: string): A2uiCheckpoint | undefined {
    const checkpoint = this.getThread(threadId)?.checkpoint;
    return checkpoint ? {
      ...checkpoint,
      eventLedger: checkpoint.eventLedger.map((entry) => ({ ...entry })),
      lineage: checkpoint.lineage.map((entry) => ({ ...entry })),
    } : undefined;
  }

  activateRun(threadId: string, runId: string, messageId?: string): void {
    if (!validIdentifier(threadId) || !validIdentifier(runId) || (messageId !== undefined && !validIdentifier(messageId))) {
      throw new Error("Run identifiers are invalid.");
    }
    const current = cloneThread(this.getThread(threadId) ?? newThread(threadId));
    const runs = new Map(current.runs);
    runs.set(runId, { runId, open: true, ...(messageId ? { messageId } : {}) });
    this.ref.current = replaceThread(this.ref.current, {
      ...current, mode: current.mode === "unconfirmed" ? "unconfirmed" : "active", activeRunId: runId, runs,
    });
  }

  closeRun(threadId: string, runId: string): void {
    const current = this.getThread(threadId);
    if (!current) return;
    const run = current.runs.get(runId);
    if (!run) return;
    const runs = new Map(current.runs);
    runs.set(runId, { ...run, open: false });
    this.ref.current = replaceThread(this.ref.current, {
      ...cloneThread(current), runs, activeRunId: current.activeRunId === runId ? undefined : current.activeRunId,
    });
  }

  private markFailed(threadId: string, reason: string, base = this.ref.current): void {
    const previous = base.threads.get(threadId) ?? newThread(threadId);
    this.ref.current = replaceThread(base, {
      ...cloneThread(previous), mode: "recovery-failed", recovery: undefined, failure: reason,
    });
  }

  acceptEnvelope(raw: unknown): {
    readonly status: "accepted" | "duplicate" | "rejected" | "recovery-requested" | "recovery-failed";
    readonly diagnostics?: readonly string[];
    readonly recovery?: RecoveryState;
    readonly error?: string;
  } {
    const prepared = prepareEnvelopeTransaction(this.ref.current, raw, {
      dependencies: this.deps, now: this.now, allocateMessageId: this.allocateMessageId,
    });
    if (prepared.status === "prepared") {
      const committed = commitPreparedTransaction(this.ref, prepared, this.messageParts, this.patcher);
      if (committed.status === "committed") {
        this.messageParts = committed.messages;
        return { status: "accepted", diagnostics: prepared.diagnostics };
      }
      this.markFailed(prepared.envelope.threadId, committed.error);
      return { status: "recovery-failed", error: committed.error };
    }
    if (prepared.status === "recovery-requested") {
      this.ref.current = prepared.nextController;
      return { status: "recovery-requested", recovery: prepared.recovery, diagnostics: prepared.diagnostics };
    }
    if (prepared.status === "duplicate") return { status: "duplicate", diagnostics: prepared.diagnostics };
    const threadId = isRecord(raw) && typeof raw.threadId === "string" ? raw.threadId : undefined;
    if (prepared.failClosed && threadId) this.markFailed(threadId, prepared.error);
    return { status: "rejected", error: prepared.error, diagnostics: prepared.diagnostics };
  }

  acceptRecovery(raw: unknown): { readonly status: "recovered" | "recovery-failed"; readonly error?: string } {
    const fail = (threadId: string, error: string) => {
      this.markFailed(threadId, error);
      return { status: "recovery-failed" as const, error };
    };
    if (!isPlainRecord(raw) || !exactKeys(raw, [
      "transportVersion", "threadId", "fromSequence", "toSequence", "envelopes",
    ]) || raw.transportVersion !== 1 || !validIdentifier(raw.threadId) || !validSequence(raw.fromSequence) ||
      !validSequence(raw.toSequence) || !Array.isArray(raw.envelopes)) {
      return fail(typeof raw === "object" && raw && "threadId" in raw && typeof raw.threadId === "string" ? raw.threadId : "invalid-recovery", "Recovery response is malformed.");
    }
    const threadId = raw.threadId;
    const originalState = this.ref.current;
    const original = originalState.threads.get(threadId);
    const recovery = original?.recovery;
    if (!original || original.mode !== "recovering" || !recovery || raw.fromSequence !== recovery.expectedSequence || raw.toSequence !== recovery.receivedSequence) {
      return fail(threadId, "Recovery range does not match the pending gap.");
    }
    const count = raw.toSequence - raw.fromSequence + 1;
    if (raw.envelopes.length !== count) return fail(threadId, "Recovery range is incomplete.");
    let working = replaceThread(originalState, { ...cloneThread(original), mode: "active", recovery: undefined });
    const touchedSurfaces = new Set<string>();
    let lastDigest = "";
    let lastEventId = "";
    for (let index = 0; index < raw.envelopes.length; index++) {
      const inner = raw.envelopes[index];
      const validation = validateA2uiEnvelope(inner);
      const expectedSequence = raw.fromSequence + index;
      if (!validation.ok || validation.value.threadId !== threadId || validation.value.sequence !== expectedSequence) {
        this.ref.current = originalState;
        return fail(threadId, `Recovery envelope ${expectedSequence} is invalid or discontinuous.`);
      }
      const prepared = prepareEnvelopeTransaction(working, inner, {
        dependencies: this.deps, now: this.now, allocateMessageId: this.allocateMessageId,
      });
      if (prepared.status !== "prepared") {
        this.ref.current = originalState;
        return fail(threadId, `Recovery envelope ${expectedSequence} could not be prepared.`);
      }
      working = prepared.nextController;
      for (const deletion of prepared.patch.deletes) touchedSurfaces.add(deletion.surfaceId);
      for (const upsert of prepared.patch.upserts) touchedSurfaces.add(upsert.surfaceId);
      lastDigest = validation.digest;
      lastEventId = validation.value.eventId;
    }
    if (lastDigest !== recovery.digest || lastEventId !== recovery.eventId) {
      this.ref.current = originalState;
      return fail(threadId, "Recovery terminal event does not match the rejected event.");
    }
    const finalThread = working.threads.get(threadId)!;
    const combined: MessagePatch = {
      deletes: [...touchedSurfaces].map((surfaceId) => ({ threadId, surfaceId })),
      upserts: [...touchedSurfaces].flatMap((surfaceId) => {
        const record = finalThread.surfaces.get(surfaceId);
        return record ? [{
          threadId, messageId: record.anchor.messageId, surfaceId, part: record.part,
        }] : [];
      }),
    };
    const lastEnvelope = raw.envelopes[raw.envelopes.length - 1] as A2uiEnvelope;
    const prepared: Extract<PreparedTransaction, { status: "prepared" }> = {
      status: "prepared", nextController: working, patch: combined, envelope: lastEnvelope, diagnostics: [],
    };
    this.ref.current = originalState;
    const committed = commitPreparedTransaction(this.ref, prepared, this.messageParts, this.patcher);
    if (committed.status === "patch-failed") return fail(threadId, committed.error);
    this.messageParts = committed.messages;
    return { status: "recovered" };
  }

  failRecovery(threadId: string, reason: string): void { this.markFailed(threadId, reason); }
  checkRecoveryTimeouts(now = this.now()): string[] {
    const failed: string[] = [];
    for (const [threadId, thread] of this.ref.current.threads) {
      if (thread.mode === "recovering" && thread.recovery && now - thread.recovery.startedAt >= A2UI_LIMITS.recoveryTimeoutMs) {
        this.markFailed(threadId, "A2UI recovery timed out after 5 seconds.");
        failed.push(threadId);
      }
    }
    return failed;
  }

  canDispatchAction(threadId: string, surfaceId: string, epoch: number, revision: number): boolean {
    const thread = this.getThread(threadId);
    const surface = thread?.surfaces.get(surfaceId);
    const lineage = thread?.lineage.get(surfaceId);
    return thread?.mode === "active" && lineage?.deletedAtSequence === undefined &&
      surface?.epoch === epoch && surface.revision === revision &&
      lineage?.epoch === surface.epoch && lineage.revision === surface.revision;
  }

  hydrateThread(
    threadId: string,
    parts: readonly unknown[],
    checkpoint?: unknown,
    options: { readonly authoritative?: boolean } = {},
  ): { readonly status: "hydrated" | "unconfirmed" | "recovery-failed"; readonly error?: string } {
    const authoritative = options.authoritative === true && validateCheckpoint(checkpoint);
    if (checkpoint !== undefined && !validateCheckpoint(checkpoint)) {
      this.markFailed(threadId, "Authoritative A2UI checkpoint is invalid.");
      return { status: "recovery-failed", error: "Invalid checkpoint." };
    }
    const cp = validateCheckpoint(checkpoint) ? checkpoint : undefined;
    const deps = dependencies(this.deps);
    const lineage = new Map<string, SurfaceLineage>((cp?.lineage ?? []).map((entry) => [entry.surfaceId, { ...entry }]));
    const surfaces = new Map<string, SurfaceRecord>();
    const prefix = `${threadId}\u001f`;
    const messages = authoritative
      ? new Map([...this.messageParts].filter(([key]) => !key.startsWith(prefix)))
      : new Map(this.messageParts);
    try {
      for (const rawPart of parts) {
        if (classifyCanonicalPart(rawPart) !== "valid") throw new Error("Canonical A2UI marker or snapshot is invalid.");
        const part = rawPart as CanonicalA2uiPart;
        const marker = part.a2ui;
        const checkpointLineage = lineage.get(marker.surfaceId);
        if (authoritative) {
          if (marker.lastSequence > cp!.lastAcceptedSequence) {
            throw new Error("Canonical A2UI part is newer than its authoritative checkpoint.");
          }
          if (!checkpointLineage) {
            throw new Error("Canonical A2UI part has no authoritative checkpoint lineage.");
          }
          if (checkpointLineage.deletedAtSequence !== undefined) {
            if (marker.epoch <= checkpointLineage.epoch && marker.revision <= checkpointLineage.deletedAtSequence) continue;
            throw new Error("Canonical A2UI part conflicts with an authoritative tombstone.");
          }
          if (marker.epoch !== checkpointLineage.epoch || marker.revision !== checkpointLineage.revision) {
            throw new Error("Canonical A2UI part does not match authoritative live lineage.");
          }
        } else if (checkpointLineage?.deletedAtSequence !== undefined && marker.revision <= checkpointLineage.deletedAtSequence) {
          continue;
        }
        const existing = surfaces.get(marker.surfaceId);
        if (existing) {
          if (marker.epoch < existing.epoch || (marker.epoch === existing.epoch && marker.revision < existing.revision)) continue;
          if (marker.epoch === existing.epoch && marker.revision === existing.revision && marker.snapshotDigest !== existing.part.a2ui.snapshotDigest) {
            throw new Error("Equal A2UI lineage has conflicting snapshot digests.");
          }
        }
        const reduced = deps.reducer(new Map(), marker.snapshot);
        const surface = reduced.state.get(marker.surfaceId);
        if (!surface || reduced.state.size !== 1 || surface.components.size > A2UI_LIMITS.components) throw new Error("Snapshot did not hydrate exactly one surface.");
        const derived = canonicalPart(
          deps, marker.surfaceId, surface,
          { surfaceId: marker.surfaceId, epoch: marker.epoch, revision: marker.revision },
          marker.anchor, marker.lastSequence,
          marker.recentEventIds.map((eventId, index) => ({ eventId, sequence: Math.max(1, marker.lastSequence - marker.recentEventIds.length + index + 1), digest: "0".repeat(64) })),
        );
        const canonical: CanonicalA2uiPart = { ...derived, a2ui: { ...derived.a2ui, recentEventIds: marker.recentEventIds } };
        const record: SurfaceRecord = {
          surfaceId: marker.surfaceId, epoch: marker.epoch, revision: marker.revision,
          anchor: marker.anchor, surface, part: canonical,
        };
        surfaces.set(marker.surfaceId, record);
        if (!checkpointLineage || marker.epoch > checkpointLineage.epoch || marker.revision > checkpointLineage.revision) {
          lineage.set(marker.surfaceId, { surfaceId: marker.surfaceId, epoch: marker.epoch, revision: marker.revision });
        }
        const suffix = `\u001f${marker.surfaceId}`;
        for (const key of messages.keys()) {
          if (key.startsWith(prefix) && key.endsWith(suffix)) messages.delete(key);
        }
        messages.set(messageKey(threadId, marker.anchor.messageId, marker.surfaceId), canonical);
      }
      if (authoritative) {
        for (const checkpointEntry of cp!.lineage) {
          if (checkpointEntry.deletedAtSequence !== undefined) continue;
          const record = surfaces.get(checkpointEntry.surfaceId);
          if (!record || record.epoch !== checkpointEntry.epoch || record.revision !== checkpointEntry.revision) {
            throw new Error("Authoritative live A2UI lineage is missing its canonical part.");
          }
        }
      }
      const ledger = cp?.eventLedger.map((entry) => ({ ...entry })) ?? [];
      const lastAcceptedSequence = authoritative ? cp!.lastAcceptedSequence : 0;
      const generation = authoritative ? cp!.generation : 0;
      const mode: ThreadMode = authoritative ? "active" : "unconfirmed";
      const thread: ThreadProtocolState = {
        threadId, mode, lastAcceptedSequence, generation, ledger, surfaces, lineage,
        runs: new Map(), checkpoint: cp ?? makeCheckpoint(),
      };
      this.ref.current = replaceThread(this.ref.current, thread);
      this.messageParts = messages;
      return { status: authoritative ? "hydrated" : "unconfirmed" };
    } catch (error) {
      this.markFailed(threadId, error instanceof Error ? error.message : "A2UI hydrate failed.");
      const prefix = `${threadId}\u001f`;
      this.messageParts = new Map([...this.messageParts].filter(([key]) => !key.startsWith(prefix)));
      return { status: "recovery-failed", error: error instanceof Error ? error.message : "A2UI hydrate failed." };
    }
  }
}
