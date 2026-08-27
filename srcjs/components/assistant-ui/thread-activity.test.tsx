/** @vitest-environment jsdom */
import { act, cleanup, render } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocked = vi.hoisted(() => ({ config: {} as Record<string, unknown> }));
vi.mock("@/shiny-config-context", () => ({
  useShinyConfig: () => mocked.config,
}));

import {
  hasAppendedUserMessage,
  hasNewUserMessage,
  resolveStreamingFollow,
  ShinyStatusPanels,
} from "./thread";

const startedAt = Date.parse("2026-01-01T00:00:05.000Z");

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-01-01T00:00:10.000Z"));
  mocked.config = {
    tasks: [{
      threadId: "thread-1",
      taskId: "agent-1",
      kind: "started",
      description: "Explore code",
      status: "running",
      toolName: "Agent",
      startedAt,
      updatedAt: startedAt + 1000,
      stopping: false,
    }],
    recentTasks: [],
  };
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

describe("ShinyStatusPanels active task heartbeat", () => {
  it("advances elapsed time without TaskProgress and stops its timer when inactive", async () => {
    const view = render(<ShinyStatusPanels />);
    const task = () => view.container.querySelector('[data-slot="aui_task_card"]');

    expect(task()?.textContent).toContain("5s");
    expect(task()?.getAttribute("data-task-active")).toBe("true");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(2000);
    });
    expect(task()?.textContent).toContain("7s");

    mocked.config = { tasks: [], recentTasks: [] };
    view.rerender(<ShinyStatusPanels />);
    expect(view.container.querySelector('[data-slot="aui_task_card"]')).toBeNull();
    expect(vi.getTimerCount()).toBe(0);
  });
});


describe("streaming viewport follow intent", () => {
  const bottom = { scrollTop: 600, scrollHeight: 1000, clientHeight: 400 };

  it("keeps following through content growth and reattaches at bottom", () => {
    expect(resolveStreamingFollow(
      bottom,
      { scrollTop: 600, scrollHeight: 1200, clientHeight: 400 },
      true,
    )).toBe(true);
    expect(resolveStreamingFollow(
      { scrollTop: 300, scrollHeight: 1200, clientHeight: 400 },
      { scrollTop: 800, scrollHeight: 1200, clientHeight: 400 },
      false,
    )).toBe(true);
  });

  it("detaches for upward scroll intent but not layout growth alone", () => {
    expect(resolveStreamingFollow(
      bottom,
      { scrollTop: 420, scrollHeight: 1000, clientHeight: 400 },
      true,
    )).toBe(false);
    expect(resolveStreamingFollow(
      bottom,
      { scrollTop: 600, scrollHeight: 1200, clientHeight: 400 },
      true,
      true,
    )).toBe(false);
  });
});


describe("new-turn follow activation", () => {
  it("activates only for a real user message appended after the prior tail", () => {
    const priorTail = { id: "assistant-old", role: "assistant" };
    expect(hasAppendedUserMessage("assistant-old", [
      priorTail,
      { id: "user-new", role: "user" },
      { id: "assistant-stream", role: "assistant" },
    ])).toBe(true);
    expect(hasAppendedUserMessage("assistant-old", [
      { id: "user-history", role: "user" },
      priorTail,
    ])).toBe(false);
    expect(hasNewUserMessage(new Set(["user-history"]), [
      { id: "user-history", role: "user" },
      { id: "user-new", role: "user" },
    ])).toBe(true);
    expect(hasNewUserMessage(new Set(["user-history", "user-new"]), [
      { id: "user-history", role: "user" },
      { id: "user-new", role: "user" },
    ])).toBe(false);
  });
});
