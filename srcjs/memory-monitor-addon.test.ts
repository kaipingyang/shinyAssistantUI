import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  createMemoryMonitorBridge,
  parseMemoryMonitorAddon,
  parseMemoryMonitorFrame,
  type MemoryMonitorFrame,
} from "./memory-monitor-addon";

type Handler = (data: unknown) => void;
let handlers: Record<string, Handler>;
let inputs: Array<{ id: string; value: unknown; opts?: unknown }>;
let serial = 0;

const addon = (ownerSeed = 10, lastRevision = 0) => ({ version: 2 as const, ownerSeed, lastRevision });
const sample = {
  state: "normal" as const,
  pssBytes: 80,
  rssBytes: 90,
  cgroupCurrentBytes: 2465 * 1024 ** 2,
  cgroupMaxBytes: 29296 * 1024 ** 2,
  cgroupLimited: true,
  softPssBytes: 100,
  hardPssBytes: 200,
  softRssBytes: 125,
  hardRssBytes: 225,
};
const frame = (ownerId: number, openId: number, revision: number): MemoryMonitorFrame => ({
  version: 2, ownerId, openId, revision, sample,
});

beforeEach(() => {
  handlers = {};
  inputs = [];
  serial += 1;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (globalThis as any).Shiny = {
    addCustomMessageHandler: (type: string, handler: Handler) => { handlers[type] = handler; },
    setInputValue: (id: string, value: unknown, opts?: unknown) => inputs.push({ id, value, opts }),
  };
});

describe("memory monitor exact v2 latest snapshot", () => {
  it("accepts only exact v2 config/frame and all six independent wire states", () => {
    expect(parseMemoryMonitorAddon({ addons: { memoryMonitor: addon() } })).toEqual(addon());
    expect(parseMemoryMonitorAddon({ addons: { memoryMonitor: { ...addon(), state: "waiting" } } })).toBeUndefined();
    for (const state of ["normal", "soft", "hard", "recovering", "disabled", "unknown"] as const) {
      expect(parseMemoryMonitorFrame({ ...frame(10, 1, 1), sample: { ...sample, state } })?.sample.state).toBe(state);
    }
    expect(parseMemoryMonitorFrame({ ...frame(10, 1, 1), sample: { ...sample, state: "unsupported" } })).toBeUndefined();
    expect(parseMemoryMonitorFrame({ ...frame(10, 1, 1), path: "/secret" })).toBeUndefined();
    expect(parseMemoryMonitorFrame({ ...frame(10, 1, 1), sample: { ...sample, pssBytes: 1.5 } })).toBeUndefined();
    expect(parseMemoryMonitorFrame({ ...frame(10, 1, 1), revision: Number.MAX_SAFE_INTEGER + 1 })).toBeUndefined();
  });

  it("opens/closes with exact owner/open/revision envelopes and freezes first frame", () => {
    const inputId = `memory-v2-${serial}`;
    const bridge = createMemoryMonitorBridge(inputId, addon(10));
    const snapshots: MemoryMonitorFrame[] = [];
    bridge.onSample((value) => snapshots.push(value));

    expect(bridge.setVisible(true)).toBe(true);
    expect(inputs[0]).toEqual({
      id: `${inputId}_memory_monitor_visible`,
      value: { version: 2, ownerId: 10, openId: 1, visible: true, revision: 0, sample: null },
      opts: { priority: "event" },
    });
    handlers[`${inputId}:memory-monitor-sample`](frame(10, 1, 7));
    handlers[`${inputId}:memory-monitor-sample`](frame(10, 1, 8));
    expect(snapshots).toEqual([frame(10, 1, 7)]);
    expect(bridge.snapshot()).toEqual(frame(10, 1, 7));

    expect(bridge.setVisible(false)).toBe(true);
    expect(inputs[1].value).toEqual({
      version: 2, ownerId: 10, openId: 1, visible: false, revision: 7, sample: null,
    });
    expect(bridge.setVisible(true)).toBe(true);
    expect(inputs[2].value).toEqual({
      version: 2, ownerId: 10, openId: 2, visible: true, revision: 7, sample: null,
    });
    handlers[`${inputId}:memory-monitor-sample`](frame(9, 2, 9));
    handlers[`${inputId}:memory-monitor-sample`](frame(10, 1, 9));
    handlers[`${inputId}:memory-monitor-sample`](frame(10, 2, 6));
    expect(snapshots).toHaveLength(1);
    handlers[`${inputId}:memory-monitor-sample`](frame(10, 2, 9));
    expect(snapshots).toHaveLength(2);
    expect(bridge.snapshot()?.revision).toBe(9);
    bridge.dispose();
  });

  it("increments owner across remount and rejects stale owner/open/collapsed frames", () => {
    const inputId = `memory-remount-${serial}`;
    const first = createMemoryMonitorBridge(inputId, addon(30));
    first.setVisible(true);
    first.dispose();

    const second = createMemoryMonitorBridge(inputId, addon(30));
    const rows: MemoryMonitorFrame[] = [];
    second.onSample((value) => rows.push(value));
    second.setVisible(true);
    const open = inputs.at(-1)?.value as { ownerId: number; openId: number };
    expect(open.ownerId).toBe(31);
    handlers[`${inputId}:memory-monitor-sample`](frame(30, 1, 1));
    handlers[`${inputId}:memory-monitor-sample`](frame(31, 0, 1));
    handlers[`${inputId}:memory-monitor-sample`](frame(31, open.openId, 1));
    expect(rows).toHaveLength(1);
    second.setVisible(false);
    handlers[`${inputId}:memory-monitor-sample`](frame(31, open.openId, 2));
    expect(rows).toHaveLength(1);
    second.dispose();
  });

  it("does one zero-delay retry after send throw without looping", () => {
    vi.useFakeTimers();
    const inputId = `memory-retry-${serial}`;
    let calls = 0;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (globalThis as any).Shiny.setInputValue = () => {
      calls += 1;
      if (calls === 1) throw new Error("once");
    };
    const bridge = createMemoryMonitorBridge(inputId, addon(50));
    expect(bridge.setVisible(true)).toBe(false);
    expect(calls).toBe(1);
    vi.runOnlyPendingTimers();
    expect(calls).toBe(2);
    expect(vi.getTimerCount()).toBe(0);
    bridge.dispose();
    vi.useRealTimers();
  });
});
