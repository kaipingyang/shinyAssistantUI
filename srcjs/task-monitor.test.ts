import { describe, expect, it } from "vitest";
import {
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

  it("keeps an explicit terminal status sticky against a late non-terminal event", () => {
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
    state = reduceTaskMonitorEvent(state, {
      threadId: "thread-a",
      taskId: "failed-task",
      kind: "progress",
      status: "running",
    }, 300);

    const monitor = selectThreadTaskMonitor(state, "thread-a");
    expect(monitor.active).toEqual([]);
    expect(monitor.recentTerminal).toEqual([
      expect.objectContaining({
        taskId: "failed-task",
        status: "failed",
        summary: "Tests failed",
        startedAt: 100,
        updatedAt: 300,
      }),
    ]);
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

  it("treats the SDK killed status as terminal and disables Stop", () => {
    const killed = reduceTaskMonitorEvent(createTaskMonitorState(), {
      threadId: "thread-a",
      taskId: "killed-task",
      kind: "updated",
      status: "killed",
    }, 100);

    const monitor = selectThreadTaskMonitor(killed, "thread-a");
    expect(monitor.active).toEqual([]);
    expect(monitor.recentTerminal[0]).toMatchObject({
      taskId: "killed-task",
      status: "killed",
    });
    expect(requestTaskStop(killed, "thread-a", "killed-task", 200).shouldDispatch).toBe(false);
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
