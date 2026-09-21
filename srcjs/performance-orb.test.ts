import { afterEach, describe, expect, it, vi } from "vitest";
import { createPerformanceOrbController } from "./performance-orb";

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("Performance Orb scheduler", () => {
  it("bounds the frame window and expires old jank while left expanded", () => {
    let nextFrame: FrameRequestCallback | undefined;
    const controller = createPerformanceOrbController({
      requestAnimationFrame: (callback) => { nextFrame = callback; return 1; },
      cancelAnimationFrame: vi.fn(),
    });
    controller.setExpanded(true);
    nextFrame?.(0);
    nextFrame?.(80);
    for (let index = 1; index <= 2000; index += 1) nextFrame?.(80 + index * 16);
    expect(controller.snapshot()).toMatchObject({
      frameCount: 600, p95IntervalMs: 16, maxIntervalMs: 16, jankCount: 0,
    });
    controller.dispose();
  });

  it("does not report an unobserved long-task stream as a measured zero", () => {
    const controller = createPerformanceOrbController({ observeLongTasks: false });
    controller.setExpanded(true);
    expect(controller.snapshot()).toMatchObject({ longTaskState: "unknown" });
    controller.dispose();
  });

  it("is default-collapsed with zero product rAF, fixed interval, or DOM polling", () => {
    vi.useFakeTimers();
    const raf = vi.fn(() => 1);
    const interval = vi.spyOn(globalThis, "setInterval");
    const query = vi.fn();
    const controller = createPerformanceOrbController({
      requestAnimationFrame: raf,
      cancelAnimationFrame: vi.fn(),
      document: { visibilityState: "visible", querySelectorAll: query } as unknown as Document,
    });
    expect(controller.snapshot().expanded).toBe(false);
    expect(raf).not.toHaveBeenCalled();
    expect(interval).not.toHaveBeenCalled();
    expect(query).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(0);
    controller.dispose();
  });

  it("samples frames only expanded+visible and rejects a stale callback after collapse", () => {
    const callbacks = new Map<number, FrameRequestCallback>();
    let next = 0;
    const cancel = vi.fn((id: number) => callbacks.delete(id));
    const doc = new EventTarget() as Document;
    Object.defineProperty(doc, "visibilityState", { configurable: true, value: "visible" });
    const controller = createPerformanceOrbController({
      requestAnimationFrame: (cb) => { const id = ++next; callbacks.set(id, cb); return id; },
      cancelAnimationFrame: cancel,
      document: doc,
      now: () => 0,
    });
    const fire = (callback: FrameRequestCallback, timestamp: number) => {
      const entry = [...callbacks.entries()].find(([, value]) => value === callback);
      if (entry) callbacks.delete(entry[0]);
      callback(timestamp);
    };
    controller.setExpanded(true);
    expect(callbacks.size).toBe(1);
    const first = callbacks.values().next().value as FrameRequestCallback;
    fire(first, 10);
    const second = [...callbacks.values()].at(-1)!;
    fire(second, 30);
    expect(controller.snapshot().frameCount).toBe(1);

    const stale = [...callbacks.values()].at(-1)!;
    controller.setExpanded(false);
    const before = controller.snapshot().frameCount;
    stale(60);
    expect(controller.snapshot().frameCount).toBe(before);
    expect(cancel).toHaveBeenCalled();

    Object.defineProperty(doc, "visibilityState", { configurable: true, value: "hidden" });
    controller.setExpanded(true);
    expect(callbacks.size).toBe(0);
    Object.defineProperty(doc, "visibilityState", { configurable: true, value: "visible" });
    doc.dispatchEvent(new Event("visibilitychange"));
    expect(callbacks.size).toBe(1);
    controller.dispose();
  });

  it("reports unsupported APIs as grey and reads page heap only when opened", () => {
    const controller = createPerformanceOrbController({
      document: new EventTarget() as Document,
      performance: {},
    });
    expect(controller.snapshot().heapState).toBe("unknown");
    controller.setExpanded(true);
    expect(controller.snapshot().heapState).toBe("unsupported");
    expect(controller.snapshot().severity).not.toBe("healthy");
    controller.dispose();
  });

  it("samples semantic-terminal heap without notifying a collapsed Orb subscriber", () => {
    const onPageHeap = vi.fn();
    const listener = vi.fn();
    const controller = createPerformanceOrbController({
      performance: { memory: { usedJSHeapSize: 4096 } },
      onPageHeap,
    });
    controller.subscribe(listener);
    controller.sampleSemanticTerminal();
    expect(onPageHeap).toHaveBeenCalledWith(4096);
    expect(controller.snapshot().pageJsHeapBytes).toBe(4096);
    expect(listener).not.toHaveBeenCalled();
    controller.dispose();
  });
});
