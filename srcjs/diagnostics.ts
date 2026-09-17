import { DIAGNOSTICS_EVENT_SPEC, DIAGNOSTICS_FORBIDDEN_NAMES } from "./diagnostics-schema.generated";

export type DiagnosticsConfig = {
  version: 2; enabled: true; schema: 1;
  batchMax: number; queueMax: number; batchMaxBytes: number; eventMaxBytes: number;
};
export type DiagnosticsMetric = number | string;
export type DiagnosticsEvent = { schema: 1; event: keyof typeof DIAGNOSTICS_EVENT_SPEC; ts: number; metrics: Record<string, DiagnosticsMetric> };
export type DiagnosticsBatch = { version: 2; schema: 1; rows: DiagnosticsEvent[] };
export interface DiagnosticsMonitor {
  record(event: string, metrics?: unknown): void;
  recordOwnedMarkdownPreprocess(durationUs: number): void;
  samplePageHeap(): "supported" | "unsupported";
  flush(): void;
  close(): void;
}
type PerformanceEntryListLike = { getEntries(): ArrayLike<{ duration?: number; startTime?: number }> };
type PerformanceObserverLike = { observe(options: unknown): void; disconnect(): void };
type PerformanceObserverConstructor = new (callback: (entries: PerformanceEntryListLike) => void) => PerformanceObserverLike;
type DiagnosticsEnvironment = {
  window?: Window;
  document?: Document;
  performance?: { memory?: { usedJSHeapSize?: number } };
  PerformanceObserver?: PerformanceObserverConstructor;
  requestAnimationFrame?: (callback: FrameRequestCallback) => number;
  requestIdleCallback?: (callback: () => void, options?: { timeout: number }) => number;
  cancelIdleCallback?: (id: number) => void;
  nowEpochSeconds?: () => number;
};
const CONFIG_KEYS = ["version", "enabled", "schema", "batchMax", "queueMax", "batchMaxBytes", "eventMaxBytes"];
const MAX_SAFE = Number.MAX_SAFE_INTEGER;
const encoder = new TextEncoder();
const isRecord = (value: unknown): value is Record<string, unknown> => value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value: Record<string, unknown>, expected: readonly string[]) => {
  const actual = Object.keys(value).sort(); const target = [...expected].sort();
  return actual.length === target.length && actual.every((key, index) => key === target[index]);
};
const safeInt = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
const byteLength = (value: unknown) => encoder.encode(JSON.stringify(value)).byteLength;
const saturatingAdd = (left: number, right: number) => Math.min(MAX_SAFE, Math.max(0, left) + Math.max(0, right));
const nowSeconds = () => Math.floor(Date.now() / 1000);

export function parseDiagnosticsConfig(value: unknown): DiagnosticsConfig | null {
  if (!isRecord(value) || !exactKeys(value, CONFIG_KEYS) || value.version !== 2 || value.enabled !== true || value.schema !== 1 ||
      !safeInt(value.batchMax) || value.batchMax < 1 || value.batchMax > 100 ||
      !safeInt(value.queueMax) || value.queueMax < value.batchMax || value.queueMax > 1000 ||
      !safeInt(value.batchMaxBytes) || value.batchMaxBytes < 4096 || value.batchMaxBytes > 262144 ||
      !safeInt(value.eventMaxBytes) || value.eventMaxBytes < 512 || value.eventMaxBytes > 8192 ||
      value.eventMaxBytes > value.batchMaxBytes) return null;
  return value as DiagnosticsConfig;
}
export function diagnosticsConfigKey(value: unknown): string {
  const parsed = parseDiagnosticsConfig(value);
  return parsed ? CONFIG_KEYS.map((key) => String(parsed[key as keyof DiagnosticsConfig])).join("|") : "";
}

const hasForbiddenName = (value: unknown): boolean => {
  if (!isRecord(value)) return false;
  for (const [key, nested] of Object.entries(value)) {
    if (DIAGNOSTICS_FORBIDDEN_NAMES.has(key) || hasForbiddenName(nested)) return true;
  }
  return false;
};
export function sanitizeDiagnosticsEvent(event: unknown, metrics: unknown = {}, ts = nowSeconds()): DiagnosticsEvent | null {
  if (typeof event !== "string" || !(event in DIAGNOSTICS_EVENT_SPEC) || !safeInt(ts) || !isRecord(metrics) || hasForbiddenName(metrics)) return null;
  const spec = DIAGNOSTICS_EVENT_SPEC[event as keyof typeof DIAGNOSTICS_EVENT_SPEC] as Record<string, "safe-int" | readonly string[]>;
  if (!exactKeys(metrics, Object.keys(spec))) return null;
  const safe: Record<string, DiagnosticsMetric> = {};
  for (const [key, rule] of Object.entries(spec)) {
    const value = metrics[key];
    if (rule === "safe-int") { if (!safeInt(value)) return null; safe[key] = value; }
    else { if (typeof value !== "string" || !rule.includes(value)) return null; safe[key] = value; }
  }
  return { schema: 1, event: event as DiagnosticsEvent["event"], ts, metrics: safe };
}

const NOOP_MONITOR: DiagnosticsMonitor = Object.freeze({
  record: () => {}, recordOwnedMarkdownPreprocess: () => {}, samplePageHeap: () => "unsupported" as const,
  flush: () => {}, close: () => {},
});
export function createDiagnosticsMonitor(candidate: unknown, send: (batch: DiagnosticsBatch) => void,
  environment: DiagnosticsEnvironment = {}): DiagnosticsMonitor {
  const parsedConfig = parseDiagnosticsConfig(candidate);
  if (!parsedConfig || typeof send !== "function") return NOOP_MONITOR;
  const config: DiagnosticsConfig = parsedConfig;
  const targetWindow = environment.window ?? (typeof window === "undefined" ? undefined : window);
  const targetDocument = environment.document ?? (typeof document === "undefined" ? undefined : document);
  const targetPerformance = environment.performance ?? (typeof performance === "undefined" ? undefined : performance as unknown as DiagnosticsEnvironment["performance"]);
  const Observer = environment.PerformanceObserver ?? (typeof PerformanceObserver === "undefined" ? undefined : PerformanceObserver as unknown as PerformanceObserverConstructor);
  const requestIdle = environment.requestIdleCallback ?? (typeof requestIdleCallback === "undefined" ? undefined : requestIdleCallback.bind(globalThis));
  const epoch = environment.nowEpochSeconds ?? nowSeconds;
  const queue: DiagnosticsEvent[] = [];
  const longtaskKeys = new Set<string>();
  const longtaskOrder: string[] = [];
  let longtaskCount = 0; let longtaskDurationUs = 0; let longtaskMaxUs = 0;
  let dropped = 0; let closed = false; let closing = false;
  let drainTimer: ReturnType<typeof setTimeout> | undefined;
  let drainIdleId: number | undefined;
  let observer: PerformanceObserverLike | undefined;
  const schedule = () => {
    if (closed || drainTimer !== undefined || drainIdleId !== undefined) return;
    if (requestIdle) {
      drainIdleId = requestIdle(() => { drainIdleId = undefined; drain(); }, { timeout: 2000 });
    } else {
      drainTimer = setTimeout(() => { drainTimer = undefined; drain(); }, 0);
    }
  };
  const noteDrop = (count = 1) => { dropped = saturatingAdd(dropped, count); schedule(); };
  const enqueue = (row: DiagnosticsEvent) => {
    const coalesced = new Set(["chunk_summary", "tool_delta_summary", "owned_markdown_preprocess_summary"]);
    if (coalesced.has(row.event)) {
      const current = queue.find((item) => item.event === row.event);
      if (current) {
        for (const [key, increment] of Object.entries(row.metrics)) {
          if (typeof increment !== "number") continue;
          current.metrics[key] = key === "maxUs"
            ? Math.max(current.metrics[key] as number, increment)
            : saturatingAdd(current.metrics[key] as number, increment);
        }
        return;
      }
    }
    if (queue.length >= config.queueMax) { noteDrop(); return; }
    queue.push(row); schedule();
  };
  const record = (event: string, metrics: unknown = {}) => {
    if (closed || closing) return;
    const row = sanitizeDiagnosticsEvent(event, metrics, epoch());
    if (!row) { noteDrop(); return; }
    enqueue(row);
  };
  const materialize = () => {
    if (longtaskCount > 0) {
      const row = sanitizeDiagnosticsEvent("longtask_summary", {
        count: longtaskCount, durationUs: longtaskDurationUs, maxUs: longtaskMaxUs,
      }, epoch());
      longtaskCount = 0; longtaskDurationUs = 0; longtaskMaxUs = 0;
      if (row) {
        if (queue.length < config.queueMax) queue.push(row);
        else dropped = saturatingAdd(dropped, 1);
      }
    }
    if (dropped > 0 && queue.length < config.queueMax) {
      const count = dropped; dropped = 0;
      const row = sanitizeDiagnosticsEvent("telemetry_batch_drop", { count, reason: "queue_full" }, epoch());
      if (row) queue.push(row);
    }
  };
  function drain() {
    if (drainTimer !== undefined) { clearTimeout(drainTimer); drainTimer = undefined; }
    materialize();
    if (queue.length === 0) {
      if (closing) closed = true;
      return;
    }
    const rows: DiagnosticsEvent[] = [];
    while (queue.length && rows.length < config.batchMax) {
      const row = queue[0];
      if (byteLength(row) > config.eventMaxBytes) {
        queue.shift();
        dropped = saturatingAdd(dropped, 1);
        continue;
      }
      const batch = { version: 2 as const, schema: 1 as const, rows: [...rows, row] };
      if (byteLength(batch) > config.batchMaxBytes) break;
      rows.push(row); queue.shift();
    }
    if (rows.length === 0 && queue.length) {
      queue.shift();
      dropped = saturatingAdd(dropped, 1);
    } else if (rows.length > 0) {
      try { send({ version: 2, schema: 1, rows }); }
      catch { dropped = saturatingAdd(dropped, rows.length); }
    }
    if (queue.length || dropped || longtaskCount) schedule();
    else if (closing) {
      closed = true;
      longtaskKeys.clear();
      longtaskOrder.length = 0;
    }
  }
  const onConnected = () => record("shiny_connected");
  const onDisconnected = () => record("shiny_disconnected");
  const onWindowError = (event: Event) => record("window_error_category", {
    category: typeof ErrorEvent !== "undefined" && event instanceof ErrorEvent ? "script" : "resource",
  });
  const onUnhandled = () => record("unhandled_rejection_category", { category: "promise" });
  targetWindow?.addEventListener("error", onWindowError);
  targetWindow?.addEventListener("unhandledrejection", onUnhandled);
  targetWindow?.addEventListener("shiny:connected", onConnected);
  targetWindow?.addEventListener("shiny:disconnected", onDisconnected);
  if (typeof targetDocument?.addEventListener === "function") {
    targetDocument.addEventListener("shiny:connected", onConnected);
    targetDocument.addEventListener("shiny:disconnected", onDisconnected);
  }
  if (Observer) {
    try {
      observer = new Observer((entries) => {
        for (const entry of Array.from(entries.getEntries())) {
          if (typeof entry.duration !== "number" || !Number.isFinite(entry.duration) || entry.duration < 0) continue;
          const key = `${entry.startTime ?? "x"}:${entry.duration}`;
          if (longtaskKeys.has(key)) continue;
          longtaskKeys.add(key); longtaskOrder.push(key);
          if (longtaskOrder.length > 256) longtaskKeys.delete(longtaskOrder.shift()!);
          const durationUs = Math.min(MAX_SAFE, Math.max(0, Math.round(entry.duration * 1000)));
          longtaskCount = saturatingAdd(longtaskCount, 1);
          longtaskDurationUs = saturatingAdd(longtaskDurationUs, durationUs);
          longtaskMaxUs = Math.max(longtaskMaxUs, durationUs);
        }
        schedule();
      });
      observer.observe({ type: "longtask", buffered: true });
    } catch { try { observer?.disconnect(); } catch { /* fail open */ } observer = undefined; }
  }
  record("frontend_mount");
  return {
    record,
    recordOwnedMarkdownPreprocess(durationUs) {
      const safe = Math.min(MAX_SAFE, Math.max(0, Math.round(durationUs)));
      record("owned_markdown_preprocess_summary", { count: 1, durationUs: safe, maxUs: safe });
    },
    samplePageHeap() {
      const heap = targetPerformance?.memory?.usedJSHeapSize;
      if (!safeInt(heap)) return "unsupported";
      record("page_js_heap_sample", { pageJsHeapBytes: heap });
      return "supported";
    },
    flush: schedule,
    close() {
      if (closed || closing) return;
      record("frontend_unmount");
      closing = true;
      try { observer?.disconnect(); } catch { /* fail open */ }
      observer = undefined;
      targetWindow?.removeEventListener("error", onWindowError);
      targetWindow?.removeEventListener("unhandledrejection", onUnhandled);
      targetWindow?.removeEventListener("shiny:connected", onConnected);
      targetWindow?.removeEventListener("shiny:disconnected", onDisconnected);
      if (typeof targetDocument?.removeEventListener === "function") {
        targetDocument.removeEventListener("shiny:connected", onConnected);
        targetDocument.removeEventListener("shiny:disconnected", onDisconnected);
      }
      schedule();
    },
  };
}
