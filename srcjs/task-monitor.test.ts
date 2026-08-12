import { describe, expect, it } from "vitest";
import {
  completeRunningTasks,
  createTaskMonitorState,
  reduceTaskMonitorEvent,
  requestTaskStop,
  selectThreadTaskMonitor,
} from "./task-monitor";

describe("Task monitor reducer", () => {
  it("sets startedAt once and advances updatedAt on every event", () => {
    const initial = createTaskMonitorState();
    const started = reduceTaskMonitorEvent(initial, {
      threadId: "thread-a",
      taskId: "task-1",
      kind: "started",
      description: "Inspect repository",
      status: "running",
    }, 1_000);
    const progressed = reduceTaskMonitorEvent(started, {
      threadId: "thread-a",
      taskId: "task-1",
      kind: "progress",
      summary: "Found the reducer boundary",
    }, 1_750);

    const [task] = selectThreadTaskMonitor(progressed, "thread-a").active;
    expect(task).toMatchObject({
      taskId: "task-1",
      startedAt: 1_000,
      updatedAt: 1_750,
      status: "running",
      summary: "Found the reducer boundary",
    });
  });

  it("keeps an explicit terminal status sticky against generic run completion", () => {
    let state = createTaskMonitorState();
    state = reduceTaskMonitorEvent(state, {
      threadId: "thread-a",
      taskId: "failed-task",
      kind: "started",
      status: "running",
    }, 100);
    state = reduceTaskMonitorEvent(state, {
      threadId: "thread-a",
      taskId: "failed-task",
      kind: "updated",
      status: "failed",
      summary: "Tests failed",
    }, 200);
    state = completeRunningTasks(state, "thread-a", 300);

    const monitor = selectThreadTaskMonitor(state, "thread-a");
    expect(monitor.active).toEqual([]);
    expect(monitor.recentTerminal).toEqual([
      expect.objectContaining({
        taskId: "failed-task",
        status: "failed",
        summary: "Tests failed",
        startedAt: 100,
        updatedAt: 200,
      }),
    ]);
  });

  it("marks only non-terminal tasks completed in the run-done fallback", () => {
    let state = createTaskMonitorState();
    state = reduceTaskMonitorEvent(state, {
      threadId: "thread-a",
      taskId: "running-task",
      kind: "progress",
      status: "running",
    }, 100);
    state = reduceTaskMonitorEvent(state, {
      threadId: "thread-a",
      taskId: "stopped-task",
      kind: "updated",
      status: "stopped",
    }, 150);

    state = completeRunningTasks(state, "thread-a", 250);
    const terminal = selectThreadTaskMonitor(state, "thread-a").recentTerminal;
    expect(terminal).toEqual(expect.arrayContaining([
      expect.objectContaining({ taskId: "running-task", status: "completed", updatedAt: 250 }),
      expect.objectContaining({ taskId: "stopped-task", status: "stopped", updatedAt: 150 }),
    ]));
  });

  it("de-duplicates Stop while stopping and clears the guard at terminal update", () => {
    let state = reduceTaskMonitorEvent(createTaskMonitorState(), {
      threadId: "thread-a",
      taskId: "task-1",
      kind: "started",
      status: "running",
    }, 100);

    const first = requestTaskStop(state, "thread-a", "task-1", 200);
    expect(first.shouldDispatch).toBe(true);
    expect(selectThreadTaskMonitor(first.state, "thread-a").active[0]).toMatchObject({
      taskId: "task-1",
      stopping: true,
    });

    const duplicate = requestTaskStop(first.state, "thread-a", "task-1", 210);
    expect(duplicate.shouldDispatch).toBe(false);

    state = reduceTaskMonitorEvent(duplicate.state, {
      threadId: "thread-a",
      taskId: "task-1",
      kind: "updated",
      status: "stopped",
    }, 300);
    expect(selectThreadTaskMonitor(state, "thread-a").recentTerminal[0]).toMatchObject({
      taskId: "task-1",
      status: "stopped",
      stopping: false,
      updatedAt: 300,
    });
  });

  it("does not dispatch Stop for missing or terminal tasks", () => {
    const empty = requestTaskStop(createTaskMonitorState(), "thread-a", "missing", 100);
    expect(empty.shouldDispatch).toBe(false);

    const completed = reduceTaskMonitorEvent(createTaskMonitorState(), {
      threadId: "thread-a",
      taskId: "done",
      kind: "updated",
      status: "completed",
    }, 100);
    const terminal = requestTaskStop(completed, "thread-a", "done", 200);
    expect(terminal.shouldDispatch).toBe(false);
  });
});
