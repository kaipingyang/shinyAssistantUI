import { afterEach, describe, expect, it, vi } from "vitest";
import {
  createDiagnosticsMonitor,
  parseDiagnosticsConfig,
  sanitizeDiagnosticsEvent,
  type DiagnosticsBatch,
} from "./diagnostics";

const config = (over: Record<string, unknown> = {}) => ({
  version: 2,
  enabled: true,
  schema: 1,
  batchMax: 50,
  queueMax: 100,
  batchMaxBytes: 65536,
  eventMaxBytes: 4096,
  ...over,
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("diagnostics v2 event-driven transport", () => {
  it("accepts only exact config and exact event metrics", () => {
    expect(parseDiagnosticsConfig(config())).toEqual(config());
    expect(parseDiagnosticsConfig({ ...config(), session: "raw-id" })).toBeNull();
    expect(parseDiagnosticsConfig({ ...config(), batchMax: 0 })).toBeNull();

    expect(sanitizeDiagnosticsEvent("chunk_summary", { count: 1, bytes: 2 }, 10)).toEqual({
      schema: 1, event: "chunk_summary", ts: 10, metrics: { count: 1, bytes: 2 },
    });
    expect(sanitizeDiagnosticsEvent("chunk_summary", { count: 1 }, 10)).toBeNull();
    expect(sanitizeDiagnosticsEvent("chunk_summary", { count: 1, bytes: 2, text: "secret" }, 10)).toBeNull();
    expect(sanitizeDiagnosticsEvent("owned_markdown_preprocess_summary", {
      count: 2, durationUs: 30, maxUs: 20,
    }, 10)?.event).toBe("owned_markdown_preprocess_summary");
    expect(sanitizeDiagnosticsEvent("memory_guard_sample", {
      state: "recovering", pssBytes: 1, rssBytes: 1,
      cgroupCurrentBytes: 3, cgroupMaxBytes: 4, cgroupLimit: "limited",
      softPssBytes: 1,
      hardPssBytes: 2, softRssBytes: 1, hardRssBytes: 2,
    }, 10)).toBeNull();
    expect(sanitizeDiagnosticsEvent("memory_guard_sample", {
      state: "unsupported", pssBytes: 1, rssBytes: 1,
      cgroupCurrentBytes: 3, cgroupMaxBytes: 4, cgroupLimit: "limited",
      softPssBytes: 1,
      hardPssBytes: 2, softRssBytes: 1, hardRssBytes: 2,
    }, 10)?.metrics.state).toBe("unsupported");
  });

  it("uses one-shot drain, coalesces summaries, and has no fixed interval/rAF/DOM poll", () => {
    vi.useFakeTimers();
    const interval = vi.spyOn(globalThis, "setInterval");
    const query = vi.fn();
    const raf = vi.fn();
    const sent: DiagnosticsBatch[] = [];
    const monitor = createDiagnosticsMonitor(config(), (batch) => sent.push(batch), {
      document: { querySelectorAll: query } as unknown as Document,
      requestAnimationFrame: raf,
      nowEpochSeconds: () => 100,
    });
    monitor.record("chunk_summary", { count: 1, bytes: 2 });
    monitor.record("chunk_summary", { count: 3, bytes: 4 });
    expect(interval).not.toHaveBeenCalled();
    expect(raf).not.toHaveBeenCalled();
    expect(query).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(1);
    vi.runOnlyPendingTimers();
    expect(vi.getTimerCount()).toBe(0);
    expect(sent.flatMap((batch) => batch.rows).find((row) => row.event === "chunk_summary")?.metrics)
      .toEqual({ count: 4, bytes: 6 });
    monitor.close();
    vi.runOnlyPendingTimers();
    expect(vi.getTimerCount()).toBe(0);
  });


  it("prefers a browser idle one-shot so telemetry serialization does not contend with rendering", () => {
    const sent: DiagnosticsBatch[] = [];
    let idleCallback: (() => void) | undefined;
    const requestIdleCallback = vi.fn((callback: () => void) => {
      idleCallback = callback;
      return 17;
    });
    const cancelIdleCallback = vi.fn();
    const timeout = vi.spyOn(globalThis, "setTimeout");
    const monitor = createDiagnosticsMonitor(config(), (batch) => sent.push(batch), {
      requestIdleCallback,
      cancelIdleCallback,
      nowEpochSeconds: () => 125,
    });
    monitor.record("chunk_summary", { count: 1, bytes: 2 });
    expect(requestIdleCallback).toHaveBeenCalledTimes(1);
    expect(timeout).not.toHaveBeenCalled();
    expect(sent).toHaveLength(0);
    idleCallback?.();
    expect(sent.flatMap((batch) => batch.rows).some((row) => row.event === "chunk_summary")).toBe(true);
    monitor.close();
    expect(requestIdleCallback).toHaveBeenCalledTimes(2);
    monitor.close();
    expect(cancelIdleCallback).not.toHaveBeenCalled();
  });
  it("keeps serialization and send out of record, flush, and close callback stacks", () => {
    vi.useFakeTimers();
    const sent: DiagnosticsBatch[] = [];
    const monitor = createDiagnosticsMonitor(config(), (batch) => sent.push(batch), {
      nowEpochSeconds: () => 150,
    });
    vi.runOnlyPendingTimers();
    sent.length = 0;
    const stringify = vi.spyOn(JSON, "stringify");

    monitor.record("chunk_summary", { count: 1, bytes: 2 });
    monitor.flush();
    expect(stringify).not.toHaveBeenCalled();
    expect(sent).toHaveLength(0);
    expect(vi.getTimerCount()).toBe(1);

    vi.runOnlyPendingTimers();
    expect(stringify).toHaveBeenCalled();
    expect(sent.flatMap((batch) => batch.rows).some((row) => row.event === "chunk_summary")).toBe(true);
    stringify.mockClear();
    const beforeClose = sent.length;
    monitor.close();
    expect(stringify).not.toHaveBeenCalled();
    expect(sent).toHaveLength(beforeClose);
    expect(vi.getTimerCount()).toBe(1);
    vi.runOnlyPendingTimers();
    expect(sent.flatMap((batch) => batch.rows).some((row) => row.event === "frontend_unmount")).toBe(true);
  });

  it("keeps one longtask observer for diagnostics lifetime and flushes aggregate once", () => {
    vi.useFakeTimers();
    const sent: DiagnosticsBatch[] = [];
    let callback: ((entries: { getEntries(): Array<{ duration: number; startTime?: number }> }) => void) | undefined;
    const disconnect = vi.fn();
    class Observer {
      constructor(cb: typeof callback) { callback = cb; }
      observe = vi.fn();
      disconnect() { disconnect(); }
    }
    const monitor = createDiagnosticsMonitor(config(), (batch) => sent.push(batch), {
      PerformanceObserver: Observer,
      nowEpochSeconds: () => 200,
    });
    callback?.({ getEntries: () => [{ duration: 12, startTime: 1 }, { duration: 12, startTime: 1 }] });
    vi.runOnlyPendingTimers();
    const row = sent.flatMap((batch) => batch.rows).find((item) => item.event === "longtask_summary");
    expect(row?.metrics).toEqual({ count: 1, durationUs: 12000, maxUs: 12000 });
    monitor.close();
    expect(disconnect).toHaveBeenCalledOnce();
  });

  it("samples page heap only on explicit open/semantic request and labels it truthfully", () => {
    vi.useFakeTimers();
    const sent: DiagnosticsBatch[] = [];
    const monitor = createDiagnosticsMonitor(config(), (batch) => sent.push(batch), {
      performance: { memory: { usedJSHeapSize: 1234 } },
      nowEpochSeconds: () => 300,
    });
    vi.runOnlyPendingTimers();
    expect(sent.flatMap((batch) => batch.rows).some((row) => row.event === "page_js_heap_sample")).toBe(false);
    monitor.samplePageHeap();
    vi.runOnlyPendingTimers();
    expect(sent.flatMap((batch) => batch.rows).find((row) => row.event === "page_js_heap_sample")?.metrics)
      .toEqual({ pageJsHeapBytes: 1234 });
    monitor.close();
  });
});
