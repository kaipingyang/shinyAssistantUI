import { describe, expect, it } from "vitest";
import type { ThreadMessageLike } from "@assistant-ui/core";
import {
  AppMessageRepository,
  BROWSER_MESSAGE_WINDOW,
  boundBrowserMessages,
} from "./message-repository";

const user = (id: string, text = id): ThreadMessageLike => ({
  id, role: "user", content: [{ type: "text", text }],
});
const assistant = (id: string, text = id): ThreadMessageLike => ({
  id, role: "assistant", content: [{ type: "text", text }],
});


describe("AppMessageRepository", () => {
  it("exports the same visible linear path after append and in-place updates", () => {
    const repository = new AppMessageRepository();
    repository.replaceVisiblePath([user("u1"), assistant("a1", "old")]);
    repository.replaceVisiblePath([
      user("u1"), assistant("a1", "updated"), user("u2"), assistant("a2"),
    ]);

    expect(repository.visibleMessages().map((message) => message.id)).toEqual([
      "u1", "a1", "u2", "a2",
    ]);
    expect(repository.visibleMessages()[1]?.content).toEqual([
      { type: "text", text: "updated" },
    ]);
    const exported = repository.export(false);
    expect(exported.headId).toBe("a2");
    expect(exported.messages.map((item) => item.parentId)).toEqual([
      null, "u1", "a1", "u2",
    ]);
  });

  it("keeps an edited suffix as a hot alternate while selecting the new head", () => {
    const repository = new AppMessageRepository();
    repository.replaceVisiblePath([
      user("u1"), assistant("a1"), user("u2"), assistant("a2-old"),
    ]);
    repository.replaceVisiblePath([
      user("u1"), assistant("a1"), user("u2-edit"), assistant("a2-new"),
    ]);

    expect(repository.visibleMessages().map((message) => message.id)).toEqual([
      "u1", "a1", "u2-edit", "a2-new",
    ]);
    const exported = repository.export(false);
    expect(exported.headId).toBe("a2-new");
    expect(exported.messages.map((item) => item.message.id)).toEqual(
      expect.arrayContaining(["u2", "a2-old", "u2-edit", "a2-new"]),
    );
  });

  it("normalizes ThreadMessageLike through the upstream converter", () => {
    const repository = new AppMessageRepository();
    repository.replaceVisiblePath([
      user("u1"),
      {
        id: "a1",
        role: "assistant",
        content: [{ type: "data-progress", data: { value: 1 } }],
      },
    ]);

    const message = repository.export(false).messages.find(
      (item) => item.message.id === "a1",
    )?.message;
    expect(message?.metadata.custom).toEqual({});
    expect(message?.status?.type).toBe("complete");
    expect(message?.content).toEqual([
      { type: "data", name: "progress", data: { value: 1 } },
    ]);
  });

  it("evicts old visible nodes from the exported repository and records a window root", () => {
    const repository = new AppMessageRepository({
      maxVisibleMessages: 6,
      maxAlternateMessages: 2,
    });
    repository.replaceVisiblePath([
      user("u1"), assistant("a1"), user("u2"), assistant("a2"),
      user("u3"), assistant("a3"), user("u4"), assistant("a4"),
    ]);

    expect(repository.visibleMessages().map((message) => message.id)).toEqual([
      "u2", "a2", "u3", "a3", "u4", "a4",
    ]);
    const snapshot = repository.snapshot();
    expect(snapshot.windowRootId).toBe("u2");
    expect(snapshot.evictedBefore).toBe(true);
    expect(snapshot.nodeCount).toBeLessThanOrEqual(8);
    expect(repository.export(false).messages.some(
      (item) => item.message.id === "u1" || item.message.id === "a1",
    )).toBe(false);
    expect(repository.export(false).messages[0]?.parentId).toBeNull();
  });

  it("does not start a bounded window in the middle of an ordinary turn", () => {
    const bounded = boundBrowserMessages([
      user("u1"), assistant("a1"), assistant("a1-tool"),
      user("u2"), assistant("a2"), user("u3"), assistant("a3"),
    ], 5);
    expect(bounded.map((message) => message.id)).toEqual([
      "u2", "a2", "u3", "a3",
    ]);
  });

  it("has a finite default browser window", () => {
    expect(BROWSER_MESSAGE_WINDOW).toBeGreaterThanOrEqual(100);
    expect(BROWSER_MESSAGE_WINDOW).toBeLessThanOrEqual(1000);
    const messages = Array.from({ length: BROWSER_MESSAGE_WINDOW + 50 }, (_, index) =>
      index % 2 === 0 ? user(`u-${index}`) : assistant(`a-${index}`),
    );
    expect(boundBrowserMessages(messages).length).toBeLessThanOrEqual(
      BROWSER_MESSAGE_WINDOW,
    );
  });
});


  it("drops obsolete branches on an authoritative reset", () => {
    const repository = new AppMessageRepository();
    repository.replaceVisiblePath([user("old-u"), assistant("old-a")]);
    repository.resetVisiblePath([user("new-u"), assistant("new-a")]);

    expect(repository.visibleMessages().map((message) => message.id)).toEqual([
      "new-u", "new-a",
    ]);
    expect(repository.export(false).messages.map((item) => item.message.id)).toEqual([
      "new-u", "new-a",
    ]);
  });

  it("reaches a fixed node plateau across repeated oversized replacements", () => {
    const repository = new AppMessageRepository({
      maxVisibleMessages: 40,
      maxAlternateMessages: 6,
    });
    for (let generation = 0; generation < 30; generation += 1) {
      repository.replaceVisiblePath(Array.from({ length: 200 }, (_, index) =>
        index % 2 === 0
          ? user(`g${generation}-u${index}`)
          : assistant(`g${generation}-a${index}`),
      ));
      expect(repository.snapshot().nodeCount).toBeLessThanOrEqual(46);
    }
  });
