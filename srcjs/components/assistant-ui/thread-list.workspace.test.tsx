// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { useState } from "react";
import {
  AssistantRuntimeProvider,
  useExternalStoreRuntime,
} from "@assistant-ui/react";
import type {
  AppendMessage,
  ExternalStoreThreadData,
  ThreadMessageLike,
} from "@assistant-ui/core";
import { ShinyConfigContext, type ShinyConfigCtx } from "../../shiny-config-context";
import { ThreadList } from "./thread-list";

const baseContext: ShinyConfigCtx = {
  tools: [], commands: [], actionItems: [], showTimestamps: false,
  onEnqueue: () => {}, onRename: () => {}, onInvokeAction: () => {},
  selectionVisible: true, setSelectionVisible: () => {}, refreshIdeContext: () => {},
  workspaceMentions: { enabled: false, query: "", items: [], loading: false },
  searchWorkspace: () => {},
};

function Harness({
  workspaceMode,
  threads,
  archivedThreads = [],
}: {
  workspaceMode: boolean;
  threads: ExternalStoreThreadData<"regular">[];
  archivedThreads?: ExternalStoreThreadData<"archived">[];
}) {
  const [threadId, setThreadId] = useState(threads[0]?.id ?? "new");
  const runtime = useExternalStoreRuntime({
    messages: [] as ThreadMessageLike[],
    isRunning: false,
    onNew: async (_message: AppendMessage) => {},
    convertMessage: (message) => message,
    adapters: {
      threadList: {
        threadId,
        threads,
        archivedThreads,
        onSwitchToNewThread: () => {},
        onSwitchToThread: setThreadId,
        onArchive: () => {},
        onUnarchive: () => {},
        onDelete: () => {},
      },
    },
  });
  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ShinyConfigContext.Provider value={{ ...baseContext, workspaceMode }}>
        <div className="w-40 overflow-hidden"><ThreadList /></div>
      </ShinyConfigContext.Provider>
    </AssistantRuntimeProvider>
  );
}

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

describe("ThreadList workspace grouping", () => {
  it("renders project headings and active run/Task counts for regular and archived threads", async () => {
    const threads: ExternalStoreThreadData<"regular">[] = [
      { id: "a-1", status: "regular", title: "A one", custom: {
        project: "/very/long/workspace/project-a", projectLabel: "Project A",
        runPhase: "running", activeTaskCount: 2,
      } },
      { id: "b-1", status: "regular", title: "B one", custom: {
        project: "/work/b", projectLabel: "Project B", runPhase: "queued",
      } },
    ];
    const archivedThreads: ExternalStoreThreadData<"archived">[] = [
      { id: "a-old", status: "archived", title: "A old", custom: {
        project: "/very/long/workspace/project-a", projectLabel: "Project A",
      } },
    ];
    const { container } = render(
      <Harness workspaceMode threads={threads} archivedThreads={archivedThreads} />,
    );

    await waitFor(() => expect(
      container.querySelectorAll("[data-slot=aui_workspace-project-header]").length,
    ).toBe(3));
    expect(Array.from(container.querySelectorAll("[data-slot=aui_workspace-project-label]"))
      .map((node) => node.textContent)).toEqual(["Project A", "Project B", "Project A"]);
    expect(container.querySelector("[data-slot=aui_workspace-run-count]")?.textContent).toBe("1 run");
    expect(container.querySelector("[data-slot=aui_workspace-task-count]")?.textContent).toBe("2 tasks");
    expect(container.querySelector("[data-slot=aui_thread-list-archived] [data-project='/very/long/workspace/project-a']"))
      .not.toBeNull();
  });

  it("keeps ordinary Chat date grouping and omits project headings", async () => {
    const now = new Date();
    const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    type DatedThread = ExternalStoreThreadData<"regular"> & { lastMessageAt: Date };
    const threads: DatedThread[] = [
      { id: "today", status: "regular", title: "Today", lastMessageAt: new Date(startOfToday + 3_600_000) },
      { id: "yesterday", status: "regular", title: "Yesterday", lastMessageAt: new Date(startOfToday - 3_600_000) },
      { id: "earlier", status: "regular", title: "Earlier", lastMessageAt: new Date(startOfToday - 3 * 86_400_000) },
    ];
    const { container } = render(<Harness workspaceMode={false} threads={threads} />);

    await waitFor(() => expect(
      container.querySelectorAll("[data-slot=aui_thread-list-group-label]").length,
    ).toBe(3));
    expect(Array.from(container.querySelectorAll("[data-slot=aui_thread-list-group-label]"))
      .map((node) => node.textContent)).toEqual(["Today", "Yesterday", "Earlier"]);
    expect(container.querySelector("[data-slot=aui_workspace-project-header]")) .toBeNull();
  });

  it("uses truncating, min-width-safe classes in a narrow sidebar", async () => {
    const threads: ExternalStoreThreadData<"regular">[] = [{
      id: "narrow", status: "regular", title: "Long session title", custom: {
        project: "/an/extremely/long/project/path", projectLabel: "Extremely long project label",
      },
    }];
    const { container } = render(<Harness workspaceMode threads={threads} />);
    await waitFor(() => expect(container.querySelector("[data-slot=aui_workspace-project-label]"))
      .not.toBeNull());

    expect(container.querySelector("[data-slot=aui_thread-list-root]")?.className)
      .toContain("min-w-0");
    expect(container.querySelector("[data-slot=aui_workspace-project-label]")?.className)
      .toContain("truncate");
    expect(container.querySelector("[data-slot=aui_thread-list-new]")?.className)
      .toContain("min-w-0");
  });

  it("initializes only the current project open, then leaves every folder under user control", async () => {
    const threads: ExternalStoreThreadData<"regular">[] = [
      { id: "a-1", status: "regular", title: "A one", custom: {
        project: "/work/a", projectLabel: "Project A", runPhase: "running", activeTaskCount: 2,
      } },
      { id: "a-2", status: "regular", title: "A two", custom: {
        project: "/work/a", projectLabel: "Project A",
      } },
      { id: "b-1", status: "regular", title: "B one", custom: {
        project: "/work/b", projectLabel: "Project B",
      } },
    ];
    const archivedThreads: ExternalStoreThreadData<"archived">[] = [{
      id: "a-old", status: "archived", title: "A old", custom: {
        project: "/work/a", projectLabel: "Project A",
      },
    }];
    const { container } = render(
      <Harness workspaceMode threads={threads} archivedThreads={archivedThreads} />,
    );

    await waitFor(() => expect(
      container.querySelectorAll("[data-slot=aui_workspace-project-header]").length,
    ).toBe(3));
    const groupA = container.querySelector(
      "[data-slot=aui_workspace-project-group][data-project='/work/a']:not([data-archived='true'])",
    ) as HTMLElement;
    const groupB = container.querySelector(
      "[data-slot=aui_workspace-project-group][data-project='/work/b']",
    ) as HTMLElement;
    const archivedGroupA = container.querySelector(
      "[data-slot=aui_workspace-project-group][data-project='/work/a'][data-archived='true']",
    ) as HTMLElement;
    const toggleA = groupA.querySelector(
      "[data-slot=aui_workspace-project-header]",
    ) as HTMLButtonElement;
    const toggleB = groupB.querySelector(
      "[data-slot=aui_workspace-project-header]",
    ) as HTMLButtonElement;
    const archivedToggleA = archivedGroupA.querySelector(
      "[data-slot=aui_workspace-project-header]",
    ) as HTMLButtonElement;
    const bodyA = groupA.querySelector(
      "[data-slot=aui_workspace-project-threads]",
    ) as HTMLElement;

    expect(toggleA.tagName).toBe("BUTTON");
    expect(toggleA.getAttribute("aria-expanded")).toBe("true");
    expect(toggleA.getAttribute("aria-label")).toMatch(/collapse project a/i);
    expect(toggleB.getAttribute("aria-expanded")).toBe("false");
    expect(archivedToggleA.getAttribute("aria-expanded")).toBe("false");
    expect(groupA.querySelector("[data-slot=aui_workspace-project-folder]")).not.toBeNull();
    expect(groupA.querySelector("[data-slot=aui_workspace-thread-count]")?.textContent).toBe("2");
    expect(bodyA.className).toContain("max-h-64");
    expect(bodyA.className).toContain("overflow-y-auto");
    expect(bodyA.className).toContain("overscroll-contain");
    expect(groupA.textContent).toContain("A one");
    expect(groupB.textContent).not.toContain("B one");

    // Opening B must not close A.
    fireEvent.click(toggleB);
    expect(toggleA.getAttribute("aria-expanded")).toBe("true");
    expect(toggleB.getAttribute("aria-expanded")).toBe("true");
    expect(groupA.textContent).toContain("A two");
    expect(groupB.textContent).toContain("B one");

    // Switching the current thread must not reset either mounted folder.
    fireEvent.click(groupB.querySelector(
      "[data-slot=aui_thread-list-item-trigger]",
    ) as HTMLButtonElement);
    await waitFor(() => expect(toggleA.getAttribute("aria-expanded")).toBe("true"));
    expect(toggleB.getAttribute("aria-expanded")).toBe("true");

    // Closing A must leave B open and keep run/Task summaries in A's header.
    fireEvent.click(toggleA);
    expect(toggleA.getAttribute("aria-expanded")).toBe("false");
    expect(toggleA.getAttribute("aria-label")).toMatch(/expand project a/i);
    expect(groupA.querySelector("[data-slot=aui_workspace-project-threads]")).toBeNull();
    expect(groupB.textContent).toContain("B one");
    expect(groupA.querySelector("[data-slot=aui_workspace-run-count]")?.textContent).toBe("1 run");
    expect(groupA.querySelector("[data-slot=aui_workspace-task-count]")?.textContent).toBe("2 tasks");

    const outer = container.querySelector(
      "[data-slot=aui_thread-list-outer-scroll]",
    ) as HTMLElement;
    const outerContent = container.querySelector(
      "[data-slot=aui_thread-list-outer-scroll-content]",
    ) as HTMLElement;
    expect(outer.className).toContain("overflow-y-scroll");
    expect(outer.className).toContain("[scrollbar-gutter:stable]");
    expect(outer.className).toContain("[&::-webkit-scrollbar]:w-3");
    expect(outerContent.className).toContain("pe-3");
  });

  it("keeps ordinary Chat on the original automatic outer scrollbar without a dedicated gutter", async () => {
    const threads: ExternalStoreThreadData<"regular">[] = [{
      id: "chat-1", status: "regular", title: "Chat one",
    }];
    const { container } = render(<Harness workspaceMode={false} threads={threads} />);

    await waitFor(() => expect(container.querySelector(
      "[data-slot=aui_thread-list-outer-scroll]",
    )).not.toBeNull());
    const outer = container.querySelector(
      "[data-slot=aui_thread-list-outer-scroll]",
    ) as HTMLElement;
    const outerContent = container.querySelector(
      "[data-slot=aui_thread-list-outer-scroll-content]",
    ) as HTMLElement;
    expect(outer.className).toContain("overflow-y-auto");
    expect(outer.className).not.toContain("[scrollbar-gutter:stable]");
    expect(outerContent.className).not.toContain("pe-3");
  });

});
