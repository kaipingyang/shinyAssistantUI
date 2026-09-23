// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { createPerformanceOrbController, PerformanceOrb } from "./performance-orb";
import type { MemoryMonitorSample } from "./memory-monitor-addon";

const cacheHeavySample = (): MemoryMonitorSample => ({
  state: "normal", pssBytes: 300 * 1024 ** 2, rssBytes: 335 * 1024 ** 2,
  treeRssBytes: 600 * 1024 ** 2, treeProcessCount: 2,
  cgroupCurrentBytes: 28 * 1024 ** 3, cgroupMaxBytes: 30 * 1024 ** 3, cgroupLimited: true,
  softPssBytes: 1024 ** 3, hardPssBytes: 2 * 1024 ** 3,
  softRssBytes: 1.25 * 1024 ** 3, hardRssBytes: 2.25 * 1024 ** 3,
  session: {
    currentAvailable: true, limitKind: "limited",
    anonBytes: 1.75 * 1024 ** 3, fileBytes: 26.25 * 1024 ** 3,
    inactiveFileBytes: 26 * 1024 ** 3, shmemBytes: 0,
    dirtyFileBytes: 0, writebackFileBytes: 0,
    limitEvents: 12529, oomEvents: 0, oomKillEvents: 0,
    limitEventsDelta: 3, oomEventsDelta: 0, oomKillEventsDelta: 0,
    intervalMs: 10000, psiSomeAvg10: 0.25, psiFullAvg10: 0,
  },
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

describe("PerformanceOrb UI", () => {
  it("does not remeasure panel layout on frame-statistic updates", () => {
    vi.useFakeTimers();
    const measure = vi.spyOn(HTMLElement.prototype, "getBoundingClientRect");
    let nextFrame: FrameRequestCallback | undefined;
    const controller = createPerformanceOrbController({
      document, requestAnimationFrame: (callback) => { nextFrame = callback; return 1; },
      cancelAnimationFrame: vi.fn(),
    });
    try {
      render(<PerformanceOrb controller={controller} />);
      fireEvent.click(screen.getByRole("button", { name: "Performance diagnostics" }));
      const openingMeasurements = measure.mock.calls.length;
      expect(openingMeasurements).toBeGreaterThan(0);
      act(() => {
        for (let index = 0; index < 70; index += 1) nextFrame?.(index * 16);
        vi.advanceTimersByTime(1000);
      });
      expect(controller.snapshot().frameCount).toBe(69);
      expect(measure).toHaveBeenCalledTimes(openingMeasurements);
    } finally {
      controller.dispose();
      measure.mockRestore();
    }
  });

  it("distinguishes accepted refresh time from actual cached sample times", () => {
    vi.useFakeTimers();
    const now = new Date("2026-09-18T09:20:00Z").getTime();
    vi.setSystemTime(now);
    const controller = createPerformanceOrbController({
      document, requestAnimationFrame: () => 1, cancelAnimationFrame: vi.fn(),
    });
    const memoryMonitor = {
      state: "normal" as const, setVisible: vi.fn(), refresh: vi.fn(),
      receivedAt: now - 1000,
      sample: {
        state: "normal" as const, pssBytes: 80, rssBytes: 90,
        treeRssBytes: 260, treeProcessCount: 3,
        cgroupCurrentBytes: 1000, cgroupMaxBytes: 2000, cgroupLimited: true,
        softPssBytes: 100, hardPssBytes: 200, softRssBytes: 125, hardRssBytes: 225,
        sampledAt: now - 120000, treeSampledAt: now - 150000, cgroupSampledAt: now - 150000,
      },
    };
    const rendered = render(<PerformanceOrb controller={controller} memoryMonitor={memoryMonitor} />);
    fireEvent.click(screen.getByRole("button", { name: "Performance diagnostics" }));
    const sampleTime = () => rendered.container.querySelector('[data-slot="aui_memory_sample_time"]');
    const refreshTime = () => rendered.container.querySelector('[data-slot="aui_memory_refresh_time"]');
    expect(sampleTime()?.getAttribute("data-timestamp")).toBe(String(now - 120000));
    expect(sampleTime()?.textContent).toContain("2m ago");
    expect(refreshTime()?.getAttribute("data-timestamp")).toBe(String(now - 1000));
    fireEvent.click(screen.getByRole("button", { name: "Refresh backend memory" }));
    expect(refreshTime()?.getAttribute("data-timestamp")).toBe(String(now - 1000));
    rendered.rerender(<PerformanceOrb controller={controller} memoryMonitor={{ ...memoryMonitor, receivedAt: now }} />);
    expect(refreshTime()?.getAttribute("data-timestamp")).toBe(String(now));
    expect(sampleTime()?.getAttribute("data-timestamp")).toBe(String(now - 120000));
    expect(rendered.container.querySelector('[data-slot="aui_memory_tree_time"]')?.getAttribute("data-timestamp"))
      .toBe(String(now - 150000));
    expect(rendered.container.querySelector('[data-slot="aui_memory_cgroup_time"]')?.getAttribute("data-timestamp"))
      .toBe(String(now - 150000));
    controller.dispose();
  });

  it("shows dynamic chat activity plus process, cgroup, and browser memory", () => {
    const setVisible = vi.fn();
    const refresh = vi.fn();
    const controller = createPerformanceOrbController({
      document,
      performance: { memory: { usedJSHeapSize: 113765972 } },
      requestAnimationFrame: () => 7,
      cancelAnimationFrame: vi.fn(),
    });
    render(<PerformanceOrb controller={controller} activity="Streaming" memoryMonitor={{
      state: "normal",
      sample: {
        state: "normal", pssBytes: 0, rssBytes: 269 * 1024 ** 2,
        treeRssBytes: 849 * 1024 ** 2, treeProcessCount: 3,
        cgroupCurrentBytes: 2465 * 1024 ** 2,
        cgroupMaxBytes: 29296 * 1024 ** 2,
        cgroupLimited: true,
        softPssBytes: 1024 ** 3, hardPssBytes: 2 * 1024 ** 3,
        softRssBytes: 1.25 * 1024 ** 3, hardRssBytes: 2.25 * 1024 ** 3,
      },
      setVisible,
      refresh,
    }} />);
    fireEvent.click(screen.getByRole("button", { name: "Performance diagnostics" }));
    expect(setVisible).toHaveBeenCalledWith(true);
    fireEvent.click(screen.getByRole("button", { name: "Refresh backend memory" }));
    expect(refresh).toHaveBeenCalledTimes(1);
    expect(screen.getByText("Chat Streaming")).toBeTruthy();
    expect(screen.getByText("Plugin guard Normal")).toBeTruthy();
    expect(screen.getByText("PSS Unavailable · RSS 269 MiB")).toBeTruthy();
    expect(screen.getByText("Process tree 849 MiB · 3 procs")).toBeTruthy();
    expect(screen.getByText("Raw total (includes cache) 2.41 GiB / 28.61 GiB (8%)")).toBeTruthy();
    expect(screen.getByText("Page JS heap 108 MiB")).toBeTruthy();
    expect(screen.getByText("Raw headroom (before reclaim) 26.20 GiB")).toBeTruthy();
    expect(screen.getByText("Working set estimate Unavailable")).toBeTruthy();
    controller.dispose();
  });

  it("labels process hard pressure as chat-available when cgroup is safe", () => {
    const controller = createPerformanceOrbController({ document, performance: {} });
    render(<PerformanceOrb controller={controller} memoryMonitor={{
      state: "hard",
      sample: {
        state: "hard",
        pssBytes: 2.58 * 1024 ** 3,
        rssBytes: 2.60 * 1024 ** 3,
        treeRssBytes: 3.10 * 1024 ** 3,
        treeProcessCount: 2,
        cgroupCurrentBytes: 3.46 * 1024 ** 3,
        cgroupMaxBytes: 15.26 * 1024 ** 3,
        cgroupLimited: true,
        softPssBytes: 1024 ** 3,
        hardPssBytes: 2 * 1024 ** 3,
        softRssBytes: 1.25 * 1024 ** 3,
        hardRssBytes: 2.25 * 1024 ** 3,
      },
      setVisible: vi.fn(),
    }} />);
    fireEvent.click(screen.getByRole("button", { name: "Performance diagnostics" }));
    expect(screen.getByText("Plugin guard Process high · chat available")).toBeTruthy();
    controller.dispose();
  });

  it("separates cache-heavy raw usage from working set and time-window pressure", () => {
    const controller = createPerformanceOrbController({ document, performance: {} });
    const setVisible = vi.fn();
    const rendered = render(<PerformanceOrb controller={controller} memoryMonitor={{
      state: "normal", sample: cacheHeavySample(), setVisible,
    }} />);
    fireEvent.click(screen.getByRole("button", { name: "Performance diagnostics" }));
    expect(screen.getByText("Plugin guard Normal")).toBeTruthy();
    expect(screen.getByText("Working set estimate 2.00 GiB")).toBeTruthy();
    expect(screen.getByText("Raw total (includes cache) 28.00 GiB / 30.00 GiB (93%)")).toBeTruthy();
    expect(screen.getByText("Anon 1.75 GiB")).toBeTruthy();
    expect(screen.getByText("File pages 26.25 GiB")).toBeTruthy();
    expect(screen.getByText("Inactive file 26.00 GiB")).toBeTruthy();
    expect(screen.getByText("Shmem 0 B")).toBeTruthy();
    expect(screen.getByText("Dirty 0 B · Writeback 0 B")).toBeTruthy();
    expect(screen.getByText("Limit hits +3 / 10s (total 12529)")).toBeTruthy();
    expect(screen.getByText("OOM events +0 / 10s (total 0)")).toBeTruthy();
    expect(screen.getByText("OOM kills +0 / 10s (total 0)")).toBeTruthy();
    expect(screen.getByText("Memory stalls (PSI avg10) some 0.25% · full 0.00%")).toBeTruthy();
    expect(rendered.container.querySelector('[data-slot="aui_session_working_set"]')?.getAttribute("data-bytes"))
      .toBe(String(2 * 1024 ** 3));
    expect(screen.getByText(/not an allocation budget/i)).toBeTruthy();
    expect(screen.getByText(/not all file pages are reclaimable/i)).toBeTruthy();

    const anon = cacheHeavySample();
    anon.session = { ...anon.session!, anonBytes: 27 * 1024 ** 3, fileBytes: 1024 ** 3,
      inactiveFileBytes: 0.25 * 1024 ** 3, psiSomeAvg10: 15 };
    rendered.rerender(<PerformanceOrb controller={controller} memoryMonitor={{
      state: "normal", sample: anon, setVisible,
    }} />);
    expect(screen.getByText("Working set estimate 27.75 GiB")).toBeTruthy();
    expect(screen.getByText("Memory stalls (PSI avg10) some 15.00% · full 0.00%")).toBeTruthy();
    controller.dispose();
  });

  it("keeps missing, inconsistent and first-sample data unknown instead of inventing zero or unlimited", () => {
    const controller = createPerformanceOrbController({ document, performance: {} });
    const sample = cacheHeavySample();
    sample.session = { ...sample.session!, inactiveFileBytes: 29 * 1024 ** 3,
      limitKind: "unknown", limitEventsDelta: null, intervalMs: null, psiSomeAvg10: null };
    sample.cgroupLimited = false;
    const setVisible = vi.fn();
    const rendered = render(<PerformanceOrb controller={controller} memoryMonitor={{
      state: "normal", sample, setVisible,
    }} />);
    fireEvent.click(screen.getByRole("button", { name: "Performance diagnostics" }));
    expect(screen.getByText("Working set estimate Unavailable")).toBeTruthy();
    expect(screen.getByText("Raw total (includes cache) 28.00 GiB / Unavailable")).toBeTruthy();
    expect(screen.getByText("Raw headroom (before reclaim) Unavailable")).toBeTruthy();
    expect(screen.getByText("Limit hits Unavailable (total 12529)")).toBeTruthy();
    expect(screen.getByText("Memory stalls (PSI avg10) some Unavailable · full 0.00%")).toBeTruthy();
    expect(rendered.container.querySelector('[data-slot="aui_session_working_set"]')?.hasAttribute("data-bytes")).toBe(false);

    sample.session = { ...sample.session, currentAvailable: false, inactiveFileBytes: 0 };
    rendered.rerender(<PerformanceOrb controller={controller} memoryMonitor={{ state: "normal", sample, setVisible }} />);
    expect(screen.getByText("Raw total (includes cache) Unavailable / Unavailable")).toBeTruthy();
    expect(screen.getByText("Working set estimate Unavailable")).toBeTruthy();
    sample.cgroupCurrentBytes = 0;
    sample.session = { ...sample.session, currentAvailable: true, limitKind: "unlimited" };
    rendered.rerender(<PerformanceOrb controller={controller} memoryMonitor={{ state: "normal", sample, setVisible }} />);
    expect(screen.getByText("Raw total (includes cache) 0 B / Unlimited")).toBeTruthy();
    expect(screen.getByText("Working set estimate 0 B")).toBeTruthy();
    controller.dispose();
  });

  it("is collapsed and accessible by default, then removes expanded work on hide/unmount", () => {
    const cancel = vi.fn();
    const controller = createPerformanceOrbController({
      document,
      performance: {},
      requestAnimationFrame: () => 7,
      cancelAnimationFrame: cancel,
    });
    const rendered = render(<PerformanceOrb controller={controller} />);
    const trigger = screen.getByRole("button", { name: "Performance diagnostics" });
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    expect(trigger.getAttribute("aria-controls")).toBeTruthy();

    fireEvent.click(trigger);
    expect(trigger.getAttribute("aria-expanded")).toBe("true");
    expect(screen.getByRole("status").textContent).toContain("No prompts, paths, IDs, or error text.");
    rendered.unmount();
    expect(controller.snapshot().expanded).toBe(false);
    expect(cancel).toHaveBeenCalledWith(7);
    controller.dispose();
  });
});
