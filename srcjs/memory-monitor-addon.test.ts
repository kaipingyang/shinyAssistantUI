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
  treeRssBytes: 260,
  treeProcessCount: 3,
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
  it("negotiates v3 real sample times while continuing to accept v2", () => {
    const config = { ...addon(70), version: 3 as const };
    expect(parseMemoryMonitorAddon({ addons: { memoryMonitor: config } })).toEqual(config);
    const timed = {
      ...frame(70, 1, 7), version: 3,
      sample: { ...sample, sampledAt: 1789723063000, treeSampledAt: 1789723053000, cgroupSampledAt: 1789723053000 },
    };
    expect(parseMemoryMonitorFrame(timed)).toEqual(timed);
    expect(parseMemoryMonitorFrame(frame(70, 1, 7))).toEqual(frame(70, 1, 7));
    expect(parseMemoryMonitorFrame({ ...timed, sample: { ...timed.sample, sampledAt: -1 } })).toBeUndefined();
    expect(parseMemoryMonitorFrame({ ...timed, sample: { ...timed.sample, sampledAt: Number.MAX_SAFE_INTEGER } })).toBeUndefined();
    expect(parseMemoryMonitorFrame({ ...timed, sample: { ...timed.sample, extra: 1 } })).toBeUndefined();
    expect(parseMemoryMonitorFrame({ ...timed, sample })).toBeUndefined();
    const inputId = `memory-v3-${serial}`;
    const bridge = createMemoryMonitorBridge(inputId, config);
    bridge.setVisible(true);
    expect(inputs.at(-1)?.value).toMatchObject({ version: 3, ownerId: 70 });
    handlers[`${inputId}:memory-monitor-sample`](frame(70, 1, 7));
    expect(bridge.snapshot()).toBeNull();
    handlers[`${inputId}:memory-monitor-sample`](timed);
    expect(bridge.snapshot()).toEqual(timed);
    bridge.dispose();
  });

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


it("refreshes one frozen opening with a higher openId and rejects stale frames", () => {
  const inputId = `memory-refresh-${serial}`;
  const bridge = createMemoryMonitorBridge(inputId, addon(50));
  const rows: MemoryMonitorFrame[] = [];
  bridge.onSample((value) => rows.push(value));

  expect(bridge.refresh()).toBe(false);
  expect(bridge.setVisible(true)).toBe(true);
  handlers[`${inputId}:memory-monitor-sample`](frame(50, 1, 7));
  expect(bridge.snapshot()?.revision).toBe(7);

  expect(bridge.refresh()).toBe(true);
  expect(inputs.at(-1)?.value).toEqual({
    version: 2, ownerId: 50, openId: 2, visible: true, revision: 7, sample: null,
  });
  expect(bridge.snapshot()).toBeNull();
  handlers[`${inputId}:memory-monitor-sample`](frame(50, 1, 8));
  expect(rows).toHaveLength(1);
  handlers[`${inputId}:memory-monitor-sample`](frame(50, 2, 8));
  expect(rows).toHaveLength(2);
  expect(bridge.snapshot()?.openId).toBe(2);

  bridge.dispose();
  expect(bridge.refresh()).toBe(false);
});

it("coalesces in-flight visibility and refresh changes without losing the revision acknowledgement", () => {
  const inputId = `memory-overlap-${serial}`;
  const bridge = createMemoryMonitorBridge(inputId, addon(80));
  const rows: MemoryMonitorFrame[] = [];
  bridge.onSample((value) => rows.push(value));
  bridge.setVisible(true);
  expect(bridge.refresh()).toBe(false);
  bridge.setVisible(false);
  bridge.setVisible(true);
  expect(inputs).toHaveLength(1);
  handlers[`${inputId}:memory-monitor-sample`](frame(80, 1, 7));
  expect(rows).toHaveLength(1);
  expect(bridge.refresh()).toBe(true);
  bridge.setVisible(false);
  expect(inputs).toHaveLength(2);
  handlers[`${inputId}:memory-monitor-sample`](frame(80, 2, 8));
  expect(rows).toHaveLength(1);
  expect(inputs.at(-1)?.value).toEqual({
    version: 2, ownerId: 80, openId: 2, visible: false, revision: 8, sample: null,
  });
  bridge.setVisible(true);
  expect(inputs.at(-1)?.value).toEqual({
    version: 2, ownerId: 80, openId: 3, visible: true, revision: 8, sample: null,
  });
  handlers[`${inputId}:memory-monitor-sample`](frame(80, 3, 9));
  expect(rows).toHaveLength(2);
  bridge.dispose();
});

it("allows retry after both transport attempts fail without advancing the unacknowledged opening", () => {
  vi.useFakeTimers();
  let attempts = 0;
  const sent: unknown[] = [];
  vi.stubGlobal("Shiny", {
    addCustomMessageHandler: (type: string, handler: Handler) => { handlers[type] = handler; },
    setInputValue: (_id: string, value: unknown) => {
      attempts += 1;
      if (attempts <= 2) throw new Error("transport unavailable");
      sent.push(value);
    },
  });
  const inputId = `memory-failed-retry-${serial}`;
  const bridge = createMemoryMonitorBridge(inputId, addon(90));
  try {
    expect(bridge.setVisible(true)).toBe(false);
    vi.runOnlyPendingTimers();
    expect(attempts).toBe(2);
    expect(bridge.refresh()).toBe(true);
    expect(sent).toEqual([{ version: 2, ownerId: 90, openId: 1, visible: true, revision: 0, sample: null }]);
    handlers[`${inputId}:memory-monitor-sample`](frame(90, 1, 7));
    expect(bridge.snapshot()?.revision).toBe(7);
  } finally {
    bridge.dispose();
    vi.useRealTimers();
    vi.unstubAllGlobals();
  }
});

it("retries the same opening when reopened after exhausted transport retries", () => {
  vi.useFakeTimers();
  let available = false;
  const sent: unknown[] = [];
  vi.stubGlobal("Shiny", {
    addCustomMessageHandler: (type: string, handler: Handler) => { handlers[type] = handler; },
    setInputValue: (_id: string, value: unknown) => {
      if (!available) throw new Error("transport unavailable");
      sent.push(value);
    },
  });
  const bridge = createMemoryMonitorBridge(`memory-reopen-failed-${serial}`, addon(95));
  try {
    bridge.setVisible(true);
    vi.runOnlyPendingTimers();
    bridge.setVisible(false);
    available = true;
    expect(bridge.setVisible(true)).toBe(true);
    expect(sent).toEqual([{ version: 2, ownerId: 95, openId: 1, visible: true, revision: 0, sample: null }]);
  } finally {
    bridge.dispose();
    vi.useRealTimers();
    vi.unstubAllGlobals();
  }
});

it("requires the process tree fields and still rejects unknown ones", () => {
  const inputId = `memory-tree-${serial}`;
  const bridge = createMemoryMonitorBridge(inputId, addon(50));
  const frames: MemoryMonitorFrame[] = [];
  bridge.onSample((frame) => frames.push(frame));
  bridge.setVisible(true);
  const envelope = inputs.at(-1)?.value as { ownerId: number; openId: number };

  const dispatch = (s: Record<string, unknown>) => handlers[`${inputId}:memory-monitor-sample`]?.({
    version: 2, ownerId: envelope.ownerId, openId: envelope.openId, revision: 1, sample: s,
  });

  const { treeRssBytes: _omitted, ...withoutTree } = sample;
  dispatch(withoutTree);
  expect(frames).toHaveLength(0);

  dispatch({ ...sample, unexpectedField: 1 });
  expect(frames).toHaveLength(0);

  dispatch({ ...sample, treeRssBytes: -1 });
  expect(frames).toHaveLength(0);

  dispatch(sample);
  expect(frames).toHaveLength(1);
  expect(frames[0]?.sample.treeRssBytes).toBe(260);
  expect(frames[0]?.sample.treeProcessCount).toBe(3);
  bridge.dispose();
});
