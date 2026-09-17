declare const Shiny: {
  setInputValue: (id: string, value: unknown, opts?: { priority?: string }) => void;
  addCustomMessageHandler: (type: string, handler: (data: unknown) => void) => void;
};

export const SETTINGS_FIELDS = [
  "autoStartCopilotApi",
  "defaultPermissionMode",
  "modeVisibility",
  "composerDensity",
  "assistantTextSize",
  "runREnabled",
  "showClaudeEditsInRStudio",
  "diagnosticsEnabled",
  "showPerformanceOrb",
] as const;
export type DiagnosticsSettingField = typeof SETTINGS_FIELDS[number];
export type DiagnosticsSettingValue = boolean | string | { showBypass: boolean; showYolo: boolean };
export type DiagnosticsSettingsFields = {
  autoStartCopilotApi: { value: boolean; revision: number };
  defaultPermissionMode: { value: string; revision: number };
  modeVisibility: { value: { showBypass: boolean; showYolo: boolean }; revision: number };
  composerDensity: { value: "comfortable" | "compact"; revision: number };
  assistantTextSize: { value: "small" | "compact" | "medium"; revision: number };
  runREnabled: { value: boolean; revision: number };
  showClaudeEditsInRStudio: { value: boolean; revision: number };
  diagnosticsEnabled: { value: boolean; revision: number };
  showPerformanceOrb: { value: boolean; revision: number };
};
export type DiagnosticsSettingsBind = {
  version: 2;
  kind: "settings_bind";
  ownerSeed: number;
  ownerId: number;
  fields: DiagnosticsSettingsFields;
};
export type DiagnosticsSettingsCategory =
  | "ok" | "busy" | "malformed_document" | "migration_recovery_pending"
  | "stale_owner" | "duplicate_request" | "out_of_order" | "stale_revision"
  | "revision_exhausted" | "io_error" | "readback_mismatch" | "unsupported";
export type DiagnosticsSettingsResult = {
  version: 2;
  kind: "settings_result";
  field: DiagnosticsSettingField;
  ownerId: number;
  requestId: number;
  revision: number;
  ok: boolean;
  category: DiagnosticsSettingsCategory;
  value: DiagnosticsSettingValue;
};
export type DiagnosticsSettingsCanonical = {
  version: 2;
  kind: "settings_canonical";
  field: DiagnosticsSettingField;
  revision: number;
  value: DiagnosticsSettingValue;
};
export type DiagnosticsLaunchConfig = {
  version: 2;
  launchEnabled: boolean;
  environmentOverride: "none" | "on" | "off";
  launchKind: "job" | "foreground";
  writerStartup: "pending" | "started" | "off" | "failed";
};
export type DiagnosticsSettingsSnapshot = {
  ownerId: number;
  disabled: boolean;
  fields: Record<DiagnosticsSettingField, {
    value: DiagnosticsSettingValue;
    revision: number;
    pending: boolean;
    category?: DiagnosticsSettingsCategory;
  }>;
};

const MAX_SAFE = Number.MAX_SAFE_INTEGER;
const BIND_KEYS = ["version", "kind", "ownerSeed", "ownerId", "fields"];
const FIELD_VALUE_KEYS = ["value", "revision"];
const RESULT_KEYS = ["version", "kind", "field", "ownerId", "requestId", "revision", "ok", "category", "value"];
const CANONICAL_KEYS = ["version", "kind", "field", "revision", "value"];
const CATEGORIES = new Set<DiagnosticsSettingsCategory>([
  "ok", "busy", "malformed_document", "migration_recovery_pending", "stale_owner",
  "duplicate_request", "out_of_order", "stale_revision", "revision_exhausted",
  "io_error", "readback_mismatch", "unsupported",
]);
const PERMISSION_MODES = new Set(["default", "plan", "acceptEdits", "bypassPermissions", "askAll", "yolo"]);
const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value: Record<string, unknown>, expected: readonly string[]) => {
  const actual = Object.keys(value).sort();
  const target = [...expected].sort();
  return actual.length === target.length && actual.every((key, index) => key === target[index]);
};
const positiveSafe = (value: unknown): value is number =>
  typeof value === "number" && Number.isSafeInteger(value) && value > 0;
const revisionSafe = (value: unknown): value is number =>
  typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
const cloneValue = (value: DiagnosticsSettingValue): DiagnosticsSettingValue =>
  isRecord(value) ? { showBypass: value.showBypass as boolean, showYolo: value.showYolo as boolean } : value;

function parseFieldValue(field: DiagnosticsSettingField, value: unknown): DiagnosticsSettingValue | undefined {
  if (["autoStartCopilotApi", "runREnabled", "showClaudeEditsInRStudio", "diagnosticsEnabled", "showPerformanceOrb"].includes(field)) {
    return typeof value === "boolean" ? value : undefined;
  }
  if (field === "defaultPermissionMode") {
    return typeof value === "string" && PERMISSION_MODES.has(value) ? value : undefined;
  }
  if (field === "modeVisibility") {
    return isRecord(value) && exactKeys(value, ["showBypass", "showYolo"]) &&
      typeof value.showBypass === "boolean" && typeof value.showYolo === "boolean"
      ? { showBypass: value.showBypass, showYolo: value.showYolo }
      : undefined;
  }
  if (field === "composerDensity") return value === "comfortable" || value === "compact" ? value : undefined;
  if (field === "assistantTextSize") return value === "small" || value === "compact" || value === "medium" ? value : undefined;
  return undefined;
}

function parseFields(value: unknown): DiagnosticsSettingsFields | undefined {
  if (!isRecord(value) || !exactKeys(value, SETTINGS_FIELDS)) return undefined;
  const parsed: Partial<Record<DiagnosticsSettingField, { value: DiagnosticsSettingValue; revision: number }>> = {};
  for (const field of SETTINGS_FIELDS) {
    const entry = value[field];
    if (!isRecord(entry) || !exactKeys(entry, FIELD_VALUE_KEYS) || !revisionSafe(entry.revision)) return undefined;
    const fieldValue = parseFieldValue(field, entry.value);
    if (fieldValue === undefined) return undefined;
    parsed[field] = { value: fieldValue, revision: entry.revision };
  }
  return parsed as DiagnosticsSettingsFields;
}

export function parseDiagnosticsSettingsAddon(config: Record<string, unknown> | undefined): DiagnosticsSettingsBind | undefined {
  if (!isRecord(config?.addons)) return undefined;
  return parseDiagnosticsSettingsBind(config.addons.diagnosticsSettings);
}

function parseDiagnosticsSettingsBind(value: unknown): DiagnosticsSettingsBind | undefined {
  if (!isRecord(value) || !exactKeys(value, BIND_KEYS) || value.version !== 2 ||
      value.kind !== "settings_bind" || !positiveSafe(value.ownerSeed) ||
      value.ownerId !== value.ownerSeed) return undefined;
  const fields = parseFields(value.fields);
  return fields ? { version: 2, kind: "settings_bind", ownerSeed: value.ownerSeed, ownerId: value.ownerId as number, fields } : undefined;
}


export function parseDiagnosticsLaunchConfig(
  config: Record<string, unknown> | undefined,
): DiagnosticsLaunchConfig | undefined {
  if (!isRecord(config?.addons)) return undefined;
  const value = config.addons.diagnosticsLaunch;
  if (!isRecord(value) || !exactKeys(value, [
    "version", "launchEnabled", "environmentOverride", "launchKind", "writerStartup",
  ]) || value.version !== 2 || typeof value.launchEnabled !== "boolean" ||
      !["none", "on", "off"].includes(value.environmentOverride as string) ||
      !["job", "foreground"].includes(value.launchKind as string) ||
      !["pending", "started", "off", "failed"].includes(value.writerStartup as string)) {
    return undefined;
  }
  return value as DiagnosticsLaunchConfig;
}
export function parseDiagnosticsSettingsResult(value: unknown): DiagnosticsSettingsResult | undefined {
  if (!isRecord(value) || !exactKeys(value, RESULT_KEYS) || value.version !== 2 ||
      value.kind !== "settings_result" || !SETTINGS_FIELDS.includes(value.field as DiagnosticsSettingField) ||
      !positiveSafe(value.ownerId) || !positiveSafe(value.requestId) || !revisionSafe(value.revision) ||
      typeof value.ok !== "boolean" || !CATEGORIES.has(value.category as DiagnosticsSettingsCategory) ||
      value.ok !== (value.category === "ok")) return undefined;
  const field = value.field as DiagnosticsSettingField;
  const fieldValue = parseFieldValue(field, value.value);
  if (fieldValue === undefined) return undefined;
  return { version: 2, kind: "settings_result", field, ownerId: value.ownerId, requestId: value.requestId,
    revision: value.revision, ok: value.ok, category: value.category as DiagnosticsSettingsCategory, value: fieldValue };
}

export function parseDiagnosticsSettingsCanonical(value: unknown): DiagnosticsSettingsCanonical | undefined {
  if (!isRecord(value) || !exactKeys(value, CANONICAL_KEYS) || value.version !== 2 ||
      value.kind !== "settings_canonical" || !SETTINGS_FIELDS.includes(value.field as DiagnosticsSettingField) ||
      !revisionSafe(value.revision)) return undefined;
  const field = value.field as DiagnosticsSettingField;
  const fieldValue = parseFieldValue(field, value.value);
  return fieldValue === undefined ? undefined : {
    version: 2, kind: "settings_canonical", field, revision: value.revision, value: fieldValue,
  };
}

type Owner = {
  receiveBind(data: unknown): void;
  receiveResult(data: unknown): void;
  receiveCanonical(data: unknown): void;
};
type Dispatcher = { active: Owner | null };
const dispatchers = new Map<string, Dispatcher>();
function dispatcherFor(inputId: string): Dispatcher {
  const existing = dispatchers.get(inputId);
  if (existing) return existing;
  const dispatcher: Dispatcher = { active: null };
  dispatchers.set(inputId, dispatcher);
  try {
    Shiny.addCustomMessageHandler(`${inputId}:diagnostics-settings-bind`, (data) => dispatcher.active?.receiveBind(data));
    Shiny.addCustomMessageHandler(`${inputId}:diagnostics-settings-result`, (data) => dispatcher.active?.receiveResult(data));
    Shiny.addCustomMessageHandler(`${inputId}:diagnostics-settings-canonical`, (data) => dispatcher.active?.receiveCanonical(data));
  } catch { /* optional addin transport is fail-open */ }
  return dispatcher;
}

export type DiagnosticsSettingsBridge = {
  request(field: DiagnosticsSettingField, value: DiagnosticsSettingValue): { ownerId: number; requestId: number } | null;
  snapshot(): DiagnosticsSettingsSnapshot;
  subscribe(handler: (snapshot: DiagnosticsSettingsSnapshot) => void): () => void;
  dispose(): void;
};

export function createDiagnosticsSettingsBridge(
  inputId: string,
  bind: DiagnosticsSettingsBind,
  initialRequestId = 0,
): DiagnosticsSettingsBridge {
  const dispatcher = dispatcherFor(inputId);
  let activeBind = bind;
  let disposed = false;
  let requestId = initialRequestId;
  let disabled = !positiveSafe(activeBind.ownerId) || !revisionSafe(initialRequestId) || initialRequestId >= MAX_SAFE;
  const listeners = new Set<(snapshot: DiagnosticsSettingsSnapshot) => void>();
  const pending = new Map<DiagnosticsSettingField, { ownerId: number; requestId: number }>();
  const state = Object.fromEntries(SETTINGS_FIELDS.map((field) => [field, {
    value: cloneValue(activeBind.fields[field].value), revision: activeBind.fields[field].revision, pending: false,
  }])) as DiagnosticsSettingsSnapshot["fields"];
  const snapshot = (): DiagnosticsSettingsSnapshot => ({
    ownerId: activeBind.ownerId, disabled,
    fields: Object.fromEntries(SETTINGS_FIELDS.map((field) => [field, {
      ...state[field], value: cloneValue(state[field].value),
    }])) as DiagnosticsSettingsSnapshot["fields"],
  });
  const notify = () => { const next = snapshot(); for (const listener of listeners) listener(next); };
  const applyCanonical = (canonical: DiagnosticsSettingsCanonical) => {
    const current = state[canonical.field];
    if (canonical.revision < current.revision) return false;
    if (canonical.revision === current.revision) {
      return JSON.stringify(canonical.value) === JSON.stringify(current.value);
    }
    state[canonical.field] = { ...current, value: cloneValue(canonical.value), revision: canonical.revision };
    notify();
    return true;
  };
  const sendReady = () => {
    try {
      Shiny.setInputValue(`${inputId}_diagnostics_settings_ready`, {
        version: 2, kind: "settings_ready", ownerId: activeBind.ownerId,
      }, { priority: "event" });
      return true;
    } catch {
      disabled = true;
      notify();
      return false;
    }
  };
  const owner: Owner = {
    receiveBind(data) {
      if (disposed || dispatcher.active !== owner) return;
      const rebound = parseDiagnosticsSettingsBind(data);
      if (!rebound || rebound.ownerId <= activeBind.ownerId) return;
      activeBind = rebound;
      requestId = 0;
      disabled = false;
      pending.clear();
      for (const field of SETTINGS_FIELDS) {
        state[field] = {
          value: cloneValue(rebound.fields[field].value),
          revision: rebound.fields[field].revision,
          pending: false,
        };
      }
      notify();
      sendReady();
    },
    receiveCanonical(data) {
      if (disposed || dispatcher.active !== owner) return;
      const canonical = parseDiagnosticsSettingsCanonical(data);
      if (canonical) applyCanonical(canonical);
    },
    receiveResult(data) {
      if (disposed || dispatcher.active !== owner) return;
      const result = parseDiagnosticsSettingsResult(data);
      if (!result || result.ownerId !== activeBind.ownerId) return;
      const expected = pending.get(result.field);
      if (!expected || expected.ownerId !== result.ownerId || expected.requestId !== result.requestId) return;
      if (!applyCanonical({ version: 2, kind: "settings_canonical", field: result.field,
        revision: result.revision, value: result.value })) return;
      pending.delete(result.field);
      state[result.field] = { ...state[result.field], pending: false, category: result.category };
      if (result.category === "revision_exhausted") disabled = true;
      notify();
    },
  };
  dispatcher.active = owner;
  sendReady();

  return {
    request(field, value) {
      if (disposed || dispatcher.active !== owner || disabled || pending.has(field)) return null;
      const parsedValue = parseFieldValue(field, value);
      if (parsedValue === undefined || requestId >= MAX_SAFE) { disabled = true; notify(); return null; }
      requestId += 1;
      const ids = { ownerId: activeBind.ownerId, requestId };
      pending.set(field, ids);
      state[field] = { ...state[field], pending: true, category: undefined };
      try {
        Shiny.setInputValue(`${inputId}_diagnostics_setting`, {
          version: 2, kind: "settings_request", field, ownerId: activeBind.ownerId, requestId,
          expectedRevision: state[field].revision, value: cloneValue(parsedValue),
        }, { priority: "event" });
      } catch {
        pending.delete(field);
        state[field] = { ...state[field], pending: false, category: "unsupported" };
        notify();
        return null;
      }
      notify();
      return ids;
    },
    snapshot,
    subscribe(handler) { listeners.add(handler); return () => listeners.delete(handler); },
    dispose() {
      if (disposed) return;
      disposed = true;
      listeners.clear();
      pending.clear();
      if (dispatcher.active === owner) dispatcher.active = null;
    },
  };
}
