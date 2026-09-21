// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { createPerformanceOrbController, PerformanceOrb } from "./performance-orb";

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
    expect(screen.getByText("Guard Normal")).toBeTruthy();
    expect(screen.getByText("PSS Unavailable · RSS 269 MiB")).toBeTruthy();
    expect(screen.getByText("Process tree 849 MiB · 3 procs")).toBeTruthy();
    expect(screen.getByText("Session 2.41 GiB / 28.61 GiB (8%)")).toBeTruthy();
    expect(screen.getByText("Page JS heap 108 MiB")).toBeTruthy();
    expect(screen.getByText("Headroom 26.20 GiB")).toBeTruthy();
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
    expect(screen.getByText("Guard Process high · chat available")).toBeTruthy();
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
