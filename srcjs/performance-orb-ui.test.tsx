// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { createPerformanceOrbController, PerformanceOrb } from "./performance-orb";

afterEach(cleanup);

describe("PerformanceOrb UI", () => {
  it("shows dynamic chat activity plus process, cgroup, and browser memory", () => {
    const setVisible = vi.fn();
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
        cgroupCurrentBytes: 2465 * 1024 ** 2,
        cgroupMaxBytes: 29296 * 1024 ** 2,
        cgroupLimited: true,
        softPssBytes: 1024 ** 3, hardPssBytes: 2 * 1024 ** 3,
        softRssBytes: 1.25 * 1024 ** 3, hardRssBytes: 2.25 * 1024 ** 3,
      },
      setVisible,
    }} />);
    fireEvent.click(screen.getByRole("button", { name: "Performance diagnostics" }));
    expect(setVisible).toHaveBeenCalledWith(true);
    expect(screen.getByText("Chat Streaming")).toBeTruthy();
    expect(screen.getByText("Guard Normal")).toBeTruthy();
    expect(screen.getByText("PSS Unavailable · RSS 269 MiB")).toBeTruthy();
    expect(screen.getByText("Session 2.41 GiB / 28.61 GiB (8%)")).toBeTruthy();
    expect(screen.getByText("Page JS heap 108 MiB")).toBeTruthy();
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
