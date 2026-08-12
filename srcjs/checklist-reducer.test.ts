import { describe, expect, it } from "vitest";
import {
  buildChecklistPreview,
  buildChecklistSnapshot,
  reduceChecklistMessages,
} from "./checklist-reducer";

type ToolPartOptions = {
  args?: unknown;
  argsText?: string;
  result?: unknown;
};

function toolMessage(
  id: string,
  toolName: string,
  options: ToolPartOptions,
) {
  return {
    id: `message-${id}`,
    role: "assistant",
    content: [{
      type: "tool-call",
      toolCallId: id,
      toolName,
      ...options,
    }],
  };
}

describe("reduceChecklistMessages", () => {
  it("treats each TodoWrite call as a full snapshot", () => {
    const messages = [
      toolMessage("todo-1", "TodoWrite", {
        args: {
          todos: [
            { content: "obsolete", status: "pending", activeForm: "Obsoleting" },
            { content: "also obsolete", status: "in_progress", activeForm: "Working" },
          ],
        },
      }),
      toolMessage("todo-2", "TodoWrite", {
        args: {
          todos: [
            { content: "replacement", status: "completed", activeForm: "Replacing" },
          ],
        },
      }),
    ];

    expect(reduceChecklistMessages(messages)).toEqual([
      expect.objectContaining({ content: "replacement", status: "completed" }),
    ]);
  });

  it("creates a provisional TaskCreate item, adopts its result id, then applies TaskUpdate", () => {
    const createdWithoutResult = reduceChecklistMessages([
      toolMessage("create-call", "TaskCreate", {
        args: {
          subject: "Implement reducer",
          description: "Keep checklist state separate from SDK tasks",
          activeForm: "Implementing reducer",
        },
      }),
    ]);
    expect(createdWithoutResult).toEqual([
      expect.objectContaining({ content: "Implement reducer", status: "pending" }),
    ]);

    const messages = [
      toolMessage("create-call", "TaskCreate", {
        args: {
          subject: "Implement reducer",
          description: "Keep checklist state separate from SDK tasks",
          activeForm: "Implementing reducer",
        },
        result: { taskId: "task-7" },
      }),
      toolMessage("update-call", "TaskUpdate", {
        args: { taskId: "task-7", status: "in_progress", subject: "Implement pure reducer" },
      }),
    ];

    expect(reduceChecklistMessages(messages)).toEqual([
      expect.objectContaining({
        id: "task-7",
        content: "Implement pure reducer",
        status: "in_progress",
      }),
    ]);
  });

  it("adopts a real task id from TaskUpdate when TaskCreate only reports Completed", () => {
    const messages = [
      toolMessage("create-real", "TaskCreate", {
        args: { subject: "Production task", activeForm: "Working" },
        result: "Completed",
      }),
      toolMessage("update-real", "TaskUpdate", {
        args: { taskId: "42", status: "completed" },
      }),
    ];

    expect(reduceChecklistMessages(messages)).toEqual([
      expect.objectContaining({ id: "42", content: "Production task", status: "completed" }),
    ]);

    expect(reduceChecklistMessages([
      toolMessage("create-text", "TaskCreate", {
        args: { subject: "Text result task" },
        result: "Task #task-9 created successfully",
      }),
    ])).toEqual([expect.objectContaining({ id: "task-9" })]);
  });

  it("adopts nested task ids from real Claude Code TaskCreate results", () => {
    const messages = [
      toolMessage("create-a", "TaskCreate", {
        args: { subject: "Task A" }, result: { task: { id: "1", subject: "Task A" } },
      }),
      toolMessage("create-b", "TaskCreate", {
        args: { subject: "Task B" }, result: { task: { id: "2", subject: "Task B" } },
      }),
      toolMessage("update-a", "TaskUpdate", {
        args: { taskId: "1", status: "completed" },
      }),
      toolMessage("update-b", "TaskUpdate", {
        args: { taskId: "2", status: "completed" },
      }),
    ];

    expect(reduceChecklistMessages(messages)).toEqual([
      expect.objectContaining({ id: "1", content: "Task A", status: "completed" }),
      expect.objectContaining({ id: "2", content: "Task B", status: "completed" }),
    ]);
  });

  it("does not guess between multiple provisional TaskCreate items", () => {
    const messages = [
      toolMessage("create-a", "TaskCreate", {
        args: { subject: "Task A" }, result: "Completed",
      }),
      toolMessage("create-b", "TaskCreate", {
        args: { subject: "Task B" }, result: "Completed",
      }),
      toolMessage("update-b", "TaskUpdate", {
        args: { taskId: "task-b", status: "completed" },
      }),
    ];
    expect(reduceChecklistMessages(messages)).toEqual([
      expect.objectContaining({ id: "create:create-a", content: "Task A", status: "pending" }),
      expect.objectContaining({ id: "create:create-b", content: "Task B", status: "pending" }),
    ]);
  });

  it("ignores malformed JSON and malformed tool payloads without losing valid items", () => {
    const messages = [
      toolMessage("valid", "TodoWrite", {
        args: { todos: [{ content: "keep me", status: "pending" }] },
      }),
      toolMessage("bad-json", "TodoWrite", { argsText: "{not-json" }),
      toolMessage("bad-todos", "TodoWrite", { args: { todos: "not-an-array" } }),
      toolMessage("bad-create", "TaskCreate", { args: { subject: 42 } }),
      toolMessage("bad-update", "TaskUpdate", { args: { status: "completed" } }),
    ];

    expect(() => reduceChecklistMessages(messages)).not.toThrow();
    expect(reduceChecklistMessages(messages)).toEqual([
      expect.objectContaining({ content: "keep me", status: "pending" }),
    ]);
  });

  it("returns at most five visible items and an exact overflow count", () => {
    const items = reduceChecklistMessages([
      toolMessage("seven", "TodoWrite", {
        args: {
          todos: Array.from({ length: 7 }, (_, index) => ({
            content: `item ${index + 1}`,
            status: "pending",
          })),
        },
      }),
    ]);

    const preview = buildChecklistPreview(items);
    expect(preview.visibleItems.map((item) => item.content)).toEqual([
      "item 1", "item 2", "item 3", "item 4", "item 5",
    ]);
    expect(preview.overflowCount).toBe(2);
  });

  it("recomputes deterministically for restored history and prepended older pages", () => {
    const olderPage = [
      toolMessage("old-create", "TaskCreate", {
        argsText: JSON.stringify({ subject: "superseded task", activeForm: "Working" }),
        result: { taskId: "old-task" },
      }),
    ];
    const currentPage = [
      toolMessage("current-snapshot", "TodoWrite", {
        argsText: JSON.stringify({
          todos: [{ content: "current truth", status: "in_progress", activeForm: "Working" }],
        }),
      }),
    ];

    const beforePrepend = reduceChecklistMessages(currentPage);
    const afterPrepend = reduceChecklistMessages([...olderPage, ...currentPage]);
    expect(afterPrepend).toEqual(beforePrepend);
    expect(afterPrepend).toEqual([
      expect.objectContaining({ content: "current truth", status: "in_progress" }),
    ]);
  });

  it("derives state only from the supplied thread messages", () => {
    const threadA = [toolMessage("a", "TodoWrite", {
      args: { todos: [{ content: "thread A", status: "pending" }] },
    })];
    const threadB = [toolMessage("b", "TodoWrite", {
      args: { todos: [{ content: "thread B", status: "completed" }] },
    })];

    expect(reduceChecklistMessages(threadA).map((item) => item.content)).toEqual(["thread A"]);
    expect(reduceChecklistMessages(threadB).map((item) => item.content)).toEqual(["thread B"]);
    expect(reduceChecklistMessages(threadA).map((item) => item.content)).toEqual(["thread A"]);
  });
});


describe("buildChecklistSnapshot", () => {
  it("computes completion from every item, including overflow", () => {
    const pendingOverflow = [toolMessage("six", "TodoWrite", {
      args: {
        todos: Array.from({ length: 6 }, (_, index) => ({
          content: `item ${index + 1}`,
          status: index < 5 ? "completed" : "pending",
        })),
      },
    })];
    expect(buildChecklistSnapshot(pendingOverflow).allCompleted).toBe(false);

    const allComplete = [toolMessage("six-done", "TodoWrite", {
      args: {
        todos: Array.from({ length: 6 }, (_, index) => ({
          content: `item ${index + 1}`,
          status: "completed",
        })),
      },
    })];
    expect(buildChecklistSnapshot(allComplete).allCompleted).toBe(true);
    expect(buildChecklistSnapshot(allComplete).overflowCount).toBe(1);
  });

  it("keeps revision stable across history prepend and changes it for new task state", () => {
    const current = [toolMessage("current", "TodoWrite", {
      args: { todos: [{ content: "current", status: "pending" }] },
    })];
    const old = toolMessage("old", "TaskCreate", {
      args: { subject: "superseded" }, result: { taskId: "old-task" },
    });
    const before = buildChecklistSnapshot(current);
    const afterPrepend = buildChecklistSnapshot([old, ...current]);
    expect(afterPrepend.revision).toBe(before.revision);

    const changed = buildChecklistSnapshot([
      ...current,
      toolMessage("current-done", "TodoWrite", {
        args: { todos: [{ content: "current", status: "completed" }] },
      }),
    ]);
    expect(changed.revision).not.toBe(before.revision);
  });

  it("marks a completed checklist stale after a later real user turn", () => {
    const complete = toolMessage("done", "TodoWrite", {
      args: { todos: [{ content: "finished", status: "completed" }] },
    });
    expect(buildChecklistSnapshot([complete]).staleAfterUserTurn).toBe(false);
    expect(buildChecklistSnapshot([
      complete,
      { id: "user-next", role: "user", content: [{ type: "text", text: "new request" }] },
    ]).staleAfterUserTurn).toBe(true);
    expect(buildChecklistSnapshot([
      complete,
      {
        id: "local-action",
        role: "user",
        content: [{ type: "text", text: "/context" }],
        metadata: { custom: { shinyAction: true } },
      },
    ]).staleAfterUserTurn).toBe(false);
  });

  it("uses an empty revision for an authoritative empty TodoWrite snapshot", () => {
    const snapshot = buildChecklistSnapshot([
      toolMessage("old", "TaskCreate", {
        args: { subject: "old" }, result: { taskId: "old-task" },
      }),
      toolMessage("clear", "TodoWrite", { args: { todos: [] } }),
    ]);
    expect(snapshot.visibleItems).toEqual([]);
    expect(snapshot.revision).toBe("");
    expect(snapshot.allCompleted).toBe(false);
  });
});
