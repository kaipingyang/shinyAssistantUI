import { describe, expect, it } from "vitest";
import {
  projectForThread,
  sessionsToWorkspaceThreads,
  groupWorkspaceThreads,
} from "./workspace-threads";

describe("workspace thread metadata", () => {
  const sessions = [
    { id: "a-1", title: "A one", preview: "", createdAt: "", project: "/work/a", projectLabel: "a" },
    { id: "b-1", title: "B one", preview: "", createdAt: "", project: "/work/b", projectLabel: "b" },
    { id: "a-2", title: "A two", preview: "", createdAt: "", project: "/work/a", projectLabel: "a" },
  ];

  it("preserves project identity in ExternalStore custom metadata", () => {
    const threads = sessionsToWorkspaceThreads(sessions, "regular");
    expect(threads[0]?.custom).toEqual({ project: "/work/a", projectLabel: "a" });
    expect(projectForThread(threads[1], "/fallback")).toBe("/work/b");
  });

  it("groups projects in first-seen order and counts active work", () => {
    const threads = sessionsToWorkspaceThreads(sessions, "regular").map((thread) => ({
      ...thread,
      custom: {
        ...thread.custom,
        ...(thread.id === "a-1" ? { runPhase: "running", activeTaskCount: 2 } : {}),
        ...(thread.id === "b-1" ? { runPhase: "queued" } : {}),
      },
    }));
    const byId = new Map(threads.map((thread) => [thread.id, thread]));
    const groups = groupWorkspaceThreads(threads.map((thread) => thread.id), byId);

    expect(groups.map((group) => group.label)).toEqual(["a", "b"]);
    expect(groups[0]).toMatchObject({ project: "/work/a", indices: [0, 2], activeRuns: 1, activeTasks: 2 });
    expect(groups[1]).toMatchObject({ project: "/work/b", indices: [1], activeRuns: 1, activeTasks: 0 });
  });

  it("assigns a new thread to the selected project", () => {
    expect(projectForThread({ id: "new", status: "regular", title: "New chat" }, "/work/current"))
      .toBe("/work/current");
  });
});


it("uses explicit Workspace project order ahead of thread first-seen order", () => {
  const orderedSessions = [
    { id: "a-local", title: "A local", preview: "", createdAt: "", project: "/work/a" },
    { id: "c-1", title: "C one", preview: "", createdAt: "", project: "/work/c" },
    { id: "b-1", title: "B one", preview: "", createdAt: "", project: "/work/b" },
    { id: "unknown", title: "Unknown", preview: "", createdAt: "", project: "/work/unknown" },
  ];
  const threads = sessionsToWorkspaceThreads(orderedSessions, "regular");
  const byId = new Map(threads.map((thread) => [thread.id, thread]));
  const groups = groupWorkspaceThreads(
    threads.map((thread) => thread.id),
    byId,
    ["/work/c", "/work/a", "/work/b"],
  );

  expect(groups.map((group) => group.project)).toEqual([
    "/work/c", "/work/a", "/work/b", "/work/unknown",
  ]);
});


it("materializes empty active Workspace projects from registry order", () => {
  const threads = sessionsToWorkspaceThreads([
    { id: "a-1", title: "A", preview: "", createdAt: "", project: "/work/a" },
  ], "regular");
  const byId = new Map(threads.map((thread) => [thread.id, thread]));
  const groups = groupWorkspaceThreads(
    threads.map((thread) => thread.id),
    byId,
    ["/work/a", "/work/empty"],
    true,
  );

  expect(groups.map((group) => ({ project: group.project, count: group.indices.length })))
    .toEqual([
      { project: "/work/a", count: 1 },
      { project: "/work/empty", count: 0 },
    ]);
});
