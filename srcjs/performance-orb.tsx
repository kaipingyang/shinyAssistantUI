import { useEffect, useId, useState } from "react";
import type { MemoryGuardState, MemoryMonitorSample } from "./memory-monitor-addon";

export type PerformanceOrbSnapshot = {
  expanded: boolean;
  severity: "healthy" | "warning" | "unknown";
  frameCount: number;
  p95IntervalMs: number | null;
  maxIntervalMs: number | null;
  jankCount: number;
  longTaskCount: number;
  heapState: "unknown" | "supported" | "unsupported";
  pageJsHeapBytes: number | null;
};
type EntryList = { getEntries(): ArrayLike<{ duration?: number; startTime?: number }> };
type Observer = { observe(options: unknown): void; disconnect(): void };
type ObserverConstructor = new (callback: (entries: EntryList) => void) => Observer;
type Environment = {
  document?: Document;
  performance?: { memory?: { usedJSHeapSize?: number } };
  PerformanceObserver?: ObserverConstructor;
  requestAnimationFrame?: (callback: FrameRequestCallback) => number;
  cancelAnimationFrame?: (id: number) => void;
  now?: () => number;
  diagnosticsEnabled?: boolean;
  observeLongTasks?: boolean;
  onFrameSummary?: (metrics: { count: number; p95IntervalUs: number; maxIntervalUs: number; jankCount: number }) => void;
  onLongTaskSummary?: (metrics: { count: number; durationUs: number; maxUs: number }) => void;
  onPageHeap?: (bytes: number) => void;
};
export type PerformanceOrbController = {
  snapshot(): PerformanceOrbSnapshot;
  subscribe(handler: (snapshot: PerformanceOrbSnapshot) => void): () => void;
  setExpanded(expanded: boolean): void;
  sampleSemanticTerminal(): void;
  dispose(): void;
};
const MAX_SAFE = Number.MAX_SAFE_INTEGER;
const p95 = (values: readonly number[]) => values.length
  ? [...values].sort((a, b) => a - b)[Math.ceil(values.length * 0.95) - 1]
  : null;

export function createPerformanceOrbController(environment: Environment = {}): PerformanceOrbController {
  const doc = environment.document ?? (typeof document === "undefined" ? undefined : document);
  const perf = environment.performance ?? (typeof performance === "undefined" ? undefined : performance as unknown as Environment["performance"]);
  const raf = environment.requestAnimationFrame ?? (typeof requestAnimationFrame === "undefined" ? undefined : requestAnimationFrame);
  const cancelRaf = environment.cancelAnimationFrame ?? (typeof cancelAnimationFrame === "undefined" ? undefined : cancelAnimationFrame);
  const Observer = environment.PerformanceObserver ?? (typeof PerformanceObserver === "undefined" ? undefined : PerformanceObserver as unknown as ObserverConstructor);
  const listeners = new Set<(snapshot: PerformanceOrbSnapshot) => void>();
  const intervals: number[] = [];
  const longtaskKeys = new Set<string>();
  const longtaskOrder: string[] = [];
  let expanded = false; let disposed = false; let frameId: number | undefined; let generation = 0;
  let refreshTimer: ReturnType<typeof setTimeout> | undefined;
  let previousFrame: number | undefined; let observer: Observer | undefined;
  let longTaskCount = 0; let longTaskDurationUs = 0; let longTaskMaxUs = 0;
  let heapState: PerformanceOrbSnapshot["heapState"] = "unknown"; let pageJsHeapBytes: number | null = null;
  const visible = () => !doc || doc.visibilityState !== "hidden";
  const snapshot = (): PerformanceOrbSnapshot => {
    const percentile = p95(intervals);
    const maximum = intervals.length ? Math.max(...intervals) : null;
    const requiredSupported = percentile !== null && heapState === "supported";
    const warning = (maximum ?? 0) > 50 || intervals.filter((value) => value > 50).length > 0 || longTaskCount > 0;
    return {
      expanded, severity: requiredSupported ? (warning ? "warning" : "healthy") : "unknown",
      frameCount: intervals.length, p95IntervalMs: percentile, maxIntervalMs: maximum,
      jankCount: intervals.filter((value) => value > 50).length, longTaskCount, heapState, pageJsHeapBytes,
    };
  };
  const notify = () => { const value = snapshot(); for (const listener of listeners) listener(value); };
  const cancelRefresh = () => {
    if (refreshTimer !== undefined) clearTimeout(refreshTimer);
    refreshTimer = undefined;
  };
  const markDirty = () => {
    if (!expanded || disposed || refreshTimer !== undefined) return;
    refreshTimer = setTimeout(() => { refreshTimer = undefined; if (expanded && !disposed) notify(); }, 1000);
  };
  const sampleHeap = () => {
    const value = perf?.memory?.usedJSHeapSize;
    if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) {
      heapState = "supported"; pageJsHeapBytes = value; environment.onPageHeap?.(value);
    } else { heapState = "unsupported"; pageJsHeapBytes = null; }
  };
  const stopFrames = () => {
    generation += 1;
    if (frameId !== undefined) { try { cancelRaf?.(frameId); } catch { /* fail open */ } }
    frameId = undefined; previousFrame = undefined;
  };
  const startFrames = () => {
    if (!expanded || disposed || !visible() || !raf || frameId !== undefined) return;
    const ownGeneration = generation;
    const frame = (timestamp: number) => {
      frameId = undefined;
      if (disposed || !expanded || !visible() || ownGeneration !== generation) return;
      if (previousFrame !== undefined) intervals.push(Math.max(0, timestamp - previousFrame));
      previousFrame = timestamp;
      markDirty();
      frameId = raf(frame);
    };
    frameId = raf(frame);
  };
  const stopObserver = () => {
    if (environment.diagnosticsEnabled || expanded) return;
    try { observer?.disconnect(); } catch { /* fail open */ }
    observer = undefined;
  };
  const startObserver = () => {
    if (observer || !Observer || environment.observeLongTasks === false ||
        (!environment.diagnosticsEnabled && !expanded)) return;
    try {
      observer = new Observer((entries) => {
        for (const entry of Array.from(entries.getEntries())) {
          if (typeof entry.duration !== "number" || !Number.isFinite(entry.duration) || entry.duration < 0) continue;
          const key = `${entry.startTime ?? "x"}:${entry.duration}`;
          if (longtaskKeys.has(key)) continue;
          longtaskKeys.add(key); longtaskOrder.push(key);
          if (longtaskOrder.length > 256) longtaskKeys.delete(longtaskOrder.shift()!);
          const durationUs = Math.min(MAX_SAFE, Math.round(entry.duration * 1000));
          longTaskCount = Math.min(MAX_SAFE, longTaskCount + 1);
          longTaskDurationUs = Math.min(MAX_SAFE, longTaskDurationUs + durationUs);
          longTaskMaxUs = Math.max(longTaskMaxUs, durationUs);
        }
        markDirty();
      });
      observer.observe({ type: "longtask", buffered: true });
    } catch { try { observer?.disconnect(); } catch { /* fail open */ } observer = undefined; }
  };
  const onVisibility = () => { if (visible()) startFrames(); else stopFrames(); };
  if (typeof doc?.addEventListener === "function") doc.addEventListener("visibilitychange", onVisibility);
  startObserver();
  return {
    snapshot,
    subscribe(handler) { listeners.add(handler); return () => listeners.delete(handler); },
    setExpanded(next) {
      if (disposed || expanded === next) return;
      expanded = next;
      if (expanded) {
        intervals.length = 0; longTaskCount = 0; longTaskDurationUs = 0; longTaskMaxUs = 0;
        sampleHeap(); startObserver(); startFrames();
      } else {
        stopFrames();
        cancelRefresh();
        const current = snapshot();
        if (current.frameCount > 0) environment.onFrameSummary?.({
          count: current.frameCount, p95IntervalUs: Math.round((current.p95IntervalMs ?? 0) * 1000),
          maxIntervalUs: Math.round((current.maxIntervalMs ?? 0) * 1000), jankCount: current.jankCount,
        });
        if (longTaskCount > 0) environment.onLongTaskSummary?.({ count: longTaskCount, durationUs: longTaskDurationUs, maxUs: longTaskMaxUs });
        stopObserver();
      }
      notify();
    },
    sampleSemanticTerminal() { if (!disposed) { sampleHeap(); if (expanded) notify(); } },
    dispose() {
      if (disposed) return;
      disposed = true; expanded = false; stopFrames(); cancelRefresh();
      try { observer?.disconnect(); } catch { /* fail open */ }
      observer = undefined;
      if (typeof doc?.removeEventListener === "function") doc.removeEventListener("visibilitychange", onVisibility);
      listeners.clear();
    },
  };
}

type PerformanceOrbMemory = {
  state: MemoryGuardState | "waiting";
  sample: MemoryMonitorSample | null;
  setVisible(visible: boolean): void;
};
const formatBytes = (value: number | null | undefined): string => {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) return "Unavailable";
  const mib = value / 1024 ** 2;
  return mib >= 1024 ? `${(mib / 1024).toFixed(2)} GiB` : `${mib.toFixed(mib >= 100 ? 0 : 1)} MiB`;
};
const titleState = (value: string) => value === "waiting"
  ? "Waiting" : value.charAt(0).toUpperCase() + value.slice(1);

export function PerformanceOrb({
  controller,
  memoryMonitor,
  activity = "Idle",
}: {
  controller: PerformanceOrbController;
  memoryMonitor?: PerformanceOrbMemory;
  activity?: string;
}) {
  const [state, setState] = useState(controller.snapshot);
  const contentId = useId();
  useEffect(() => {
    const unsubscribe = controller.subscribe(setState);
    return () => {
      unsubscribe();
      memoryMonitor?.setVisible(false);
      controller.setExpanded(false);
    };
  }, [controller, memoryMonitor?.setVisible]);
  return (
    <div className="aui-performance-orb absolute bottom-3 end-3 z-30" data-slot="aui_performance_orb" data-severity={state.severity}>
      <button type="button" aria-label="Performance diagnostics" aria-expanded={state.expanded}
        aria-controls={contentId} onClick={() => {
          const next = !state.expanded;
          memoryMonitor?.setVisible(next);
          controller.setExpanded(next);
        }}
        className="border-border bg-background text-foreground size-9 rounded-full border text-xs shadow">
        <span aria-hidden="true">◉</span>
      </button>
      {state.expanded && (() => {
        const memory = memoryMonitor?.sample;
        const cgroupPercent = memory?.cgroupLimited && memory.cgroupMaxBytes > 0
          ? Math.round(memory.cgroupCurrentBytes / memory.cgroupMaxBytes * 100)
          : null;
        return (
        <div id={contentId} role="status" aria-live="polite" className="bg-popover text-popover-foreground absolute end-0 bottom-11 w-64 rounded-lg border p-3 text-xs shadow-lg">
          <p className="font-medium">Performance</p>
          <p data-slot="aui_performance_activity">Chat {activity}</p>
          <div className="border-border/60 mt-2 border-t pt-2" data-slot="aui_backend_memory">
            <p className="font-medium">Backend memory</p>
            <p>Guard {titleState(memoryMonitor?.state ?? "waiting")}</p>
            <p>PSS {formatBytes(memory?.pssBytes)} · RSS {formatBytes(memory?.rssBytes)}</p>
            <p>Session {formatBytes(memory?.cgroupCurrentBytes)} / {memory?.cgroupLimited ? formatBytes(memory.cgroupMaxBytes) : "Unlimited"}{cgroupPercent == null ? "" : ` (${cgroupPercent}%)`}</p>
          </div>
          <div className="border-border/60 mt-2 border-t pt-2" data-slot="aui_browser_performance">
            <p className="font-medium">Browser UI</p>
            <p>Frame p95 {state.p95IntervalMs == null ? "Waiting" : `${state.p95IntervalMs.toFixed(1)} ms`}</p>
            <p>Jank {state.jankCount} · Long tasks {state.longTaskCount}</p>
            <p>Page JS heap {state.heapState === "supported" ? formatBytes(state.pageJsHeapBytes) : state.heapState}</p>
          </div>
          <p className="text-muted-foreground mt-2 text-[10px]">Privacy-filtered metrics only. No prompts, paths, IDs, or error text.</p>
        </div>
        );
      })()}
    </div>
  );
}
