import { useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import type { LongTaskObservation } from "./diagnostics";
import type { MemoryGuardState, MemoryMonitorSample } from "./memory-monitor-addon";

export type PerformanceOrbSnapshot = {
  expanded: boolean;
  severity: "healthy" | "warning" | "unknown";
  frameCount: number;
  p95IntervalMs: number | null;
  maxIntervalMs: number | null;
  jankCount: number;
  longTaskCount: number;
  longTaskState: LongTaskObservation["state"] | "unknown";
  heapState: "unknown" | "supported" | "unsupported";
  pageJsHeapBytes: number | null;
};
type EntryList = { getEntries(): ArrayLike<{ duration?: number; startTime?: number }> };
type Observer = { observe(options: unknown): void; disconnect(): void };
type ObserverConstructor = {
  new (callback: (entries: EntryList) => void): Observer;
  readonly supportedEntryTypes?: readonly string[];
};
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
  acceptLongTasks(observation: LongTaskObservation): void;
  dispose(): void;
};
const MAX_SAFE = Number.MAX_SAFE_INTEGER;
const MAX_FRAME_SAMPLES = 600;
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
  let intervalCursor = 0;
  const longtaskKeys = new Set<string>();
  const longtaskOrder: string[] = [];
  let expanded = false; let disposed = false; let frameId: number | undefined; let generation = 0;
  let refreshTimer: ReturnType<typeof setTimeout> | undefined;
  let previousFrame: number | undefined; let observer: Observer | undefined;
  let longTaskCount = 0; let longTaskDurationUs = 0; let longTaskMaxUs = 0;
  let longTaskState: PerformanceOrbSnapshot["longTaskState"] = "unknown";
  let heapState: PerformanceOrbSnapshot["heapState"] = "unknown"; let pageJsHeapBytes: number | null = null;
  const visible = () => !doc || doc.visibilityState !== "hidden";
  const snapshot = (): PerformanceOrbSnapshot => {
    const percentile = p95(intervals);
    const maximum = intervals.length ? Math.max(...intervals) : null;
    const requiredSupported = percentile !== null && heapState === "supported" && longTaskState === "supported";
    const jankCount = intervals.filter((value) => value > 50).length;
    const warning = jankCount > 0 || longTaskCount > 0;
    return {
      expanded, severity: warning ? "warning" : requiredSupported ? "healthy" : "unknown",
      frameCount: intervals.length, p95IntervalMs: percentile, maxIntervalMs: maximum,
      jankCount, longTaskCount, longTaskState, heapState, pageJsHeapBytes,
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
      if (previousFrame !== undefined) {
        intervals[intervalCursor] = Math.max(0, timestamp - previousFrame);
        intervalCursor = (intervalCursor + 1) % MAX_FRAME_SAMPLES;
      }
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
  const acceptLongTasks = (observation: LongTaskObservation) => {
    if (disposed) return;
    longTaskState = observation.state;
    if (expanded && observation.state === "supported") {
      longTaskCount = Math.min(MAX_SAFE, longTaskCount + observation.count);
      longTaskDurationUs = Math.min(MAX_SAFE, longTaskDurationUs + observation.durationUs);
      longTaskMaxUs = Math.max(longTaskMaxUs, observation.maxUs);
    }
    markDirty();
  };
  const startObserver = () => {
    if (observer || environment.observeLongTasks === false ||
        (!environment.diagnosticsEnabled && !expanded)) return;
    if (!Observer || (Observer.supportedEntryTypes && !Observer.supportedEntryTypes.includes("longtask"))) {
      longTaskState = "unsupported";
      return;
    }
    try {
      observer = new Observer((entries) => {
        if (disposed) return;
        const delta: LongTaskObservation = { state: "supported", count: 0, durationUs: 0, maxUs: 0 };
        for (const entry of Array.from(entries.getEntries())) {
          if (typeof entry.duration !== "number" || !Number.isFinite(entry.duration) || entry.duration < 0) continue;
          const key = `${entry.startTime ?? "x"}:${entry.duration}`;
          if (longtaskKeys.has(key)) continue;
          longtaskKeys.add(key); longtaskOrder.push(key);
          if (longtaskOrder.length > 256) longtaskKeys.delete(longtaskOrder.shift()!);
          const durationUs = Math.min(MAX_SAFE, Math.round(entry.duration * 1000));
          delta.count = Math.min(MAX_SAFE, delta.count + 1);
          delta.durationUs = Math.min(MAX_SAFE, delta.durationUs + durationUs);
          delta.maxUs = Math.max(delta.maxUs, durationUs);
        }
        acceptLongTasks(delta);
      });
      observer.observe({ type: "longtask", buffered: false });
      longTaskState = "supported";
    } catch {
      try { observer?.disconnect(); } catch { /* fail open */ }
      observer = undefined;
      longTaskState = "unsupported";
    }
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
        intervals.length = 0; intervalCursor = 0;
        longTaskCount = 0; longTaskDurationUs = 0; longTaskMaxUs = 0;
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
    acceptLongTasks,
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
  receivedAt?: number | null;
  refreshing?: boolean;
  setVisible(visible: boolean): void;
  refresh?: () => void;
};
const timeFormatter = new Intl.DateTimeFormat(undefined, {
  hour: "2-digit", minute: "2-digit", second: "2-digit",
});
const formatAge = (timestamp: number) => {
  const seconds = Math.floor((Date.now() - timestamp) / 1000);
  if (seconds < -1) return "clock ahead";
  if (seconds < 60) return `${Math.max(0, seconds)}s ago`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  return `${Math.floor(seconds / 3600)}h ago`;
};
function SnapshotTime({ label, timestamp, slot, age = true }: {
  label: string; timestamp?: number | null; slot: string; age?: boolean;
}) {
  const date = typeof timestamp === "number" && timestamp > 0 ? new Date(timestamp) : null;
  const valid = date !== null && Number.isFinite(date.getTime());
  return (
    <p className="text-muted-foreground text-[10px]" data-slot={slot}
      data-timestamp={valid ? timestamp : undefined}>
      {label} {valid
        ? <time dateTime={date.toISOString()} title={date.toLocaleString()}>
            {timeFormatter.format(date)}{age ? ` (${formatAge(date.getTime())})` : ""}
          </time>
        : "Unavailable"}
    </p>
  );
}
const formatBytes = (value: number | null | undefined): string => {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) return "Unavailable";
  const mib = value / 1024 ** 2;
  return mib >= 1024 ? `${(mib / 1024).toFixed(2)} GiB` : `${mib.toFixed(mib >= 100 ? 0 : 1)} MiB`;
};
const formatSessionBytes = (value: number | null | undefined) => value === 0 ? "0 B" : formatBytes(value);
const formatPercent = (value: number | null | undefined) => value == null ? "Unavailable" : `${value.toFixed(2)}%`;
function SessionCounter({ label, total, delta, intervalMs, slot }: {
  label: string; total?: number | null; delta?: number | null; intervalMs?: number | null; slot: string;
}) {
  return <p data-slot={slot} data-total={total ?? undefined} data-delta={delta ?? undefined}
    data-interval-ms={intervalMs ?? undefined} title="Delta between background cgroup samples; total is cumulative, not current pressure.">
    {label} {delta != null && intervalMs != null ? `+${delta} / ${intervalMs / 1000}s` : "Unavailable"}
    {total == null ? "" : ` (total ${total})`}
  </p>;
}
const titleState = (value: string) => value === "waiting"
  ? "Waiting" : value.charAt(0).toUpperCase() + value.slice(1);
const guardLabel = (
  state: MemoryGuardState | "waiting" | undefined,
  sample: MemoryMonitorSample | null | undefined,
) => {
  if (state !== "hard") return titleState(state ?? "waiting");
  if (!sample?.cgroupLimited || sample.cgroupMaxBytes <= 0 ||
      (sample.session ? !sample.session.currentAvailable : sample.cgroupCurrentBytes <= 0)) return "Hard";
  const headroom = sample.cgroupMaxBytes - sample.cgroupCurrentBytes;
  const critical = sample.cgroupCurrentBytes / sample.cgroupMaxBytes >= 0.9 ||
    headroom <= 1024 ** 3;
  return critical ? "Process high · raw session near limit" : "Process high · chat available";
};

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
  const orbRef = useRef<HTMLDivElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);
  const [panelLimits, setPanelLimits] = useState<{ maxHeight: number; maxWidth: number }>();
  const contentId = useId();
  useLayoutEffect(() => {
    const orb = orbRef.current;
    const panel = panelRef.current;
    if (!state.expanded || !orb || !panel) return;
    const host = orb.offsetParent;
    const measure = () => {
      const rect = panel.getBoundingClientRect();
      const bounds = host instanceof Element ? host.getBoundingClientRect() : null;
      const next = {
        maxHeight: Math.max(0, rect.bottom - Math.max(8, (bounds?.top ?? 0) + 8)),
        maxWidth: Math.max(0, rect.right - Math.max(8, (bounds?.left ?? 0) + 8)),
      };
      setPanelLimits((previous) => previous?.maxHeight === next.maxHeight &&
        previous.maxWidth === next.maxWidth ? previous : next);
    };
    measure();
    const observer = typeof ResizeObserver === "undefined" ? undefined : new ResizeObserver(measure);
    if (host instanceof Element) observer?.observe(host);
    window.addEventListener("resize", measure);
    return () => {
      observer?.disconnect();
      window.removeEventListener("resize", measure);
    };
  }, [state.expanded]);
  useEffect(() => {
    const unsubscribe = controller.subscribe(setState);
    setState(controller.snapshot());
    return () => {
      unsubscribe();
      memoryMonitor?.setVisible(false);
      controller.setExpanded(false);
    };
  }, [controller, memoryMonitor?.setVisible]);
  return (
    <div ref={orbRef} className="aui-performance-orb absolute bottom-3 end-3 z-30" data-slot="aui_performance_orb" data-severity={state.severity}>
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
        const session = memory?.session;
        const rawCurrent = memory && (session ? session.currentAvailable : memory.cgroupCurrentBytes > 0)
          ? memory.cgroupCurrentBytes : null;
        const limitKind = session?.limitKind ?? (memory?.cgroupLimited ? "limited" : "unknown");
        const rawLimit = limitKind === "limited" ? memory?.cgroupMaxBytes : null;
        const cgroupPercent = rawCurrent != null && rawLimit != null && rawLimit > 0
          ? Math.round(rawCurrent / rawLimit * 100)
          : null;
        const cgroupHeadroom = rawCurrent != null && rawLimit != null
          ? Math.max(0, rawLimit - rawCurrent)
          : null;
        const workingSet = rawCurrent != null && session?.inactiveFileBytes != null && session.inactiveFileBytes <= rawCurrent
          ? rawCurrent - session.inactiveFileBytes : null;
        return (
        <div ref={panelRef} id={contentId} role="status" aria-live="polite" style={panelLimits}
          className="bg-popover text-popover-foreground absolute end-0 bottom-11 w-64 overflow-y-auto rounded-lg border p-3 text-xs shadow-lg">
          <p className="font-medium">Performance</p>
          <p data-slot="aui_performance_activity">Chat {activity}</p>
          <div className="border-border/60 mt-2 border-t pt-2" data-slot="aui_backend_memory">
            <div className="flex items-center justify-between gap-2">
              <p className="font-medium">Backend memory</p>
              <button type="button" aria-label="Refresh backend memory"
                onClick={() => memoryMonitor?.refresh?.()}
                disabled={!memoryMonitor?.refresh || memoryMonitor.refreshing}
                className="border-border text-muted-foreground hover:text-foreground rounded border px-1.5 py-0.5 text-[10px] disabled:opacity-50">
                {memoryMonitor?.refreshing ? "Refreshing…" : "Refresh"}
              </button>
            </div>
            <p className="text-muted-foreground text-[10px]">Refresh reads the latest background sample.</p>
            <SnapshotTime label="Refreshed" timestamp={memoryMonitor?.receivedAt}
              slot="aui_memory_refresh_time" age={false} />
            <SnapshotTime label="Process sampled" timestamp={memory?.sampledAt}
              slot="aui_memory_sample_time" />
            <p data-slot="aui_process_guard">Plugin guard {guardLabel(memoryMonitor?.state, memory)}</p>
            <p className="text-muted-foreground text-[10px]">Guard follows plugin process PSS/RSS, not whole-session health.</p>
            <p>PSS {formatBytes(memory?.pssBytes)} · RSS {formatBytes(memory?.rssBytes)}</p>
            <p title="Addin R process plus the Claude CLI it spawned. Shared pages are counted once per process, so this is an upper bound.">
              Process tree {formatBytes(memory?.treeRssBytes)}
              {typeof memory?.treeProcessCount === "number" && memory.treeProcessCount > 0
                ? ` · ${memory.treeProcessCount} procs` : ""}
            </p>
            <SnapshotTime label="Tree sampled" timestamp={memory?.treeSampledAt}
              slot="aui_memory_tree_time" />
          </div>
          <div className="border-border/60 mt-2 border-t pt-2" data-slot="aui_session_memory">
            <p className="font-medium">Session memory</p>
            <SnapshotTime label="Session sampled" timestamp={memory?.cgroupSampledAt}
              slot="aui_memory_cgroup_time" />
            <p data-slot="aui_session_working_set" data-bytes={workingSet ?? undefined}
              title="Raw total minus inactive file pages. An estimate, not process RSS or guaranteed reclaimable memory.">
              Working set estimate {formatSessionBytes(workingSet)}
            </p>
            <p data-slot="aui_session_anon" data-bytes={session?.anonBytes ?? undefined}>Anon {formatSessionBytes(session?.anonBytes)}</p>
            <p data-slot="aui_session_file" data-bytes={session?.fileBytes ?? undefined}>File pages {formatSessionBytes(session?.fileBytes)}</p>
            <p data-slot="aui_session_inactive_file" data-bytes={session?.inactiveFileBytes ?? undefined}>Inactive file {formatSessionBytes(session?.inactiveFileBytes)}</p>
            <p data-slot="aui_session_shmem" data-bytes={session?.shmemBytes ?? undefined}>Shmem {formatSessionBytes(session?.shmemBytes)}</p>
            <p data-slot="aui_session_dirty" data-dirty-bytes={session?.dirtyFileBytes ?? undefined}
              data-writeback-bytes={session?.writebackFileBytes ?? undefined}>
              Dirty {formatSessionBytes(session?.dirtyFileBytes)} · Writeback {formatSessionBytes(session?.writebackFileBytes)}
            </p>
            <p data-slot="aui_session_raw_usage" data-bytes={rawCurrent ?? undefined} data-limit-bytes={rawLimit ?? undefined}>
              Raw total (includes cache) {formatSessionBytes(rawCurrent)} / {limitKind === "unlimited" ? "Unlimited" : formatSessionBytes(rawLimit)}{cgroupPercent == null ? "" : ` (${cgroupPercent}%)`}
            </p>
            <p>Raw headroom (before reclaim) {limitKind === "unlimited" ? "Unlimited" : formatSessionBytes(cgroupHeadroom)}</p>
            <p className="text-muted-foreground text-[10px]">Raw headroom is not an allocation budget. Not all file pages are reclaimable; file pages include shmem.</p>
            <SessionCounter label="Limit hits" slot="aui_session_limit_events" total={session?.limitEvents}
              delta={session?.limitEventsDelta} intervalMs={session?.intervalMs} />
            <SessionCounter label="OOM events" slot="aui_session_oom_events" total={session?.oomEvents}
              delta={session?.oomEventsDelta} intervalMs={session?.intervalMs} />
            <SessionCounter label="OOM kills" slot="aui_session_oom_kills" total={session?.oomKillEvents}
              delta={session?.oomKillEventsDelta} intervalMs={session?.intervalMs} />
            <p data-slot="aui_session_stalls" data-some={session?.psiSomeAvg10 ?? undefined}
              data-full={session?.psiFullAvg10 ?? undefined}
              title="10-second moving averages of memory-stalled time. Some: at least one task; full: all non-idle tasks.">
              Memory stalls (PSI avg10) some {formatPercent(session?.psiSomeAvg10)} · full {formatPercent(session?.psiFullAvg10)}
            </p>
          </div>
          <div className="border-border/60 mt-2 border-t pt-2" data-slot="aui_browser_performance">
            <p className="font-medium">Browser UI</p>
            <p>Frame p95 {state.p95IntervalMs == null ? "Waiting" : `${state.p95IntervalMs.toFixed(1)} ms`}</p>
            <p>Jank {state.jankCount} · Long tasks <span data-slot="aui_long_tasks"
              data-state={state.longTaskState}
              data-count={state.longTaskState === "supported" ? state.longTaskCount : undefined}>
              {state.longTaskState === "supported" ? state.longTaskCount : titleState(state.longTaskState)}
            </span></p>
            <p className="text-muted-foreground text-[10px]">Latest {MAX_FRAME_SAMPLES} frames · long tasks while open.</p>
            <p>Page JS heap {state.heapState === "supported" ? formatBytes(state.pageJsHeapBytes) : state.heapState}</p>
          </div>
          <p className="text-muted-foreground mt-2 text-[10px]">Privacy-filtered metrics only. No prompts, paths, IDs, or error text.</p>
        </div>
        );
      })()}
    </div>
  );
}
