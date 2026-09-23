// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, waitFor, within } from "@testing-library/react";
import { useEffect, useState } from "react";
import { AssistantRuntimeProvider, useExternalStoreRuntime } from "@assistant-ui/react";
import type { ExternalStoreThreadData, ThreadMessageLike } from "@assistant-ui/core";
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
  threads: initialThreads,
  archivedThreads: initialArchived = [],
  workspaceMode = false,
  onSwitch = () => {},
  onNew = () => {},
  snapshot,
}: {
  threads: ExternalStoreThreadData<"regular">[];
  archivedThreads?: ExternalStoreThreadData<"archived">[];
  workspaceMode?: boolean;
  onSwitch?: (id: string) => void;
  onNew?: () => void;
  snapshot?: ExternalStoreThreadData<"regular">[];
}) {
  const [threads, setThreads] = useState(initialThreads);
  const [archivedThreads, setArchived] = useState(initialArchived);
  const [threadId, setThreadId] = useState(initialThreads[0]?.id ?? "new");
  useEffect(() => {
    if (snapshot) setThreads(snapshot);
  }, [snapshot]);
  const newThread = () => {
    onNew();
    setThreads((previous) => [{ id: "new-chat", status: "regular", title: "New Chat" }, ...previous]);
    setThreadId("new-chat");
  };
  const runtime = useExternalStoreRuntime({
    messages: [] as ThreadMessageLike[], isRunning: false,
    onNew: async () => {}, convertMessage: (message) => message,
    adapters: {
      threadList: {
        threadId, threads, archivedThreads,
        onSwitchToNewThread: newThread,
        onSwitchToThread: (id) => { setThreadId(id); onSwitch(id); },
        onArchive: (id) => {
          const item = threads.find((thread) => thread.id === id)!;
          setThreads((previous) => previous.filter((thread) => thread.id !== id));
          setArchived((previous) => [{ ...item, status: "archived" }, ...previous]);
        },
        onUnarchive: (id) => {
          const item = archivedThreads.find((thread) => thread.id === id)!;
          setArchived((previous) => previous.filter((thread) => thread.id !== id));
          setThreads((previous) => [{ ...item, status: "regular" }, ...previous]);
        },
        onDelete: () => {},
      },
    },
  });
  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ShinyConfigContext.Provider value={{
        ...baseContext, workspaceMode, workingDir: "/work/a",
        workspaceProjectOrder: ["/work/a", "/work/b", "/work/empty"],
        newThreadInProject: newThread,
        onRename: (id, title) => setThreads((previous) =>
          previous.map((item) => item.id === id ? { ...item, title } : item)),
      }}>
        <ThreadList />
        <span data-testid="selected">{threadId}</span>
      </ShinyConfigContext.Provider>
    </AssistantRuntimeProvider>
  );
}

const threads: ExternalStoreThreadData<"regular">[] = [
  { id: "alpha", status: "regular", title: "Alpha report",
    custom: { project: "/work/a", projectLabel: "Project A", preview: "Routine analysis" } },
  { id: "beta", status: "regular", title: "历史讨论",
    custom: { project: "/work/b", projectLabel: "Project B", preview: "Needle [a.*] archived topic" } },
  { id: "gamma", status: "regular", title: "Gamma",
    custom: { project: "/work/b", projectLabel: "Project B" } },
];
const archivedThreads: ExternalStoreThreadData<"archived">[] = [
  { id: "old", status: "archived", title: "Old overview",
    custom: { project: "/work/b", projectLabel: "Project B", preview: "Needle [a.*] from before" } },
];
const ids = (container: HTMLElement, archived = false) => Array.from(
  container.querySelectorAll(
    `[data-slot=aui_thread-list-${archived ? "archived-item" : "item"}]`,
  ),
).map((element) => element.getAttribute("data-thread-id"));

afterEach(cleanup);

describe("history sidebar search", () => {
  it("keeps a confirmation open when a catalog refresh changes the matching row's original index", async () => {
    const view = render(<Harness threads={threads} />);
    fireEvent.change(view.getByRole("searchbox"), { target: { value: "历史" } });
    await waitFor(() => expect(ids(view.container)).toEqual(["beta"]));
    const row = view.container.querySelector("[data-thread-id=beta]");
    fireEvent.keyDown(view.getByRole("button", { name: "More options" }), { key: "ArrowRight" });
    const deleteItem = await view.findByRole("menuitem", { name: "Delete" });
    fireEvent.click(deleteItem);
    await waitFor(() => expect(view.getByText("Delete this conversation permanently?")).toBeTruthy());
    view.rerender(<Harness threads={threads} snapshot={[threads[1], threads[2], threads[0]]} />);
    await waitFor(() => expect(view.container.querySelector("[data-thread-id=beta]")).toBe(row));
    expect(view.getByText("Delete this conversation permanently?")).toBeTruthy();
    expect(view.getByRole("button", { name: "Cancel" })).toBeTruthy();
  });

  it("filters titles without changing selection or submitting through Enter", async () => {
    const onSwitch = vi.fn();
    const onNew = vi.fn();
    const onSubmit = vi.fn((event: React.FormEvent) => event.preventDefault());
    const view = render(
      <form onSubmit={onSubmit}><Harness threads={threads} onSwitch={onSwitch} onNew={onNew} /></form>,
    );
    const input = view.getByRole("searchbox", { name: "Search history" });
    fireEvent.change(input, { target: { value: "  ALpHa  " } });
    await waitFor(() => expect(ids(view.container)).toEqual(["alpha"]));
    fireEvent.keyDown(input, { key: "Enter", code: "Enter" });
    expect(view.getByTestId("selected").textContent).toBe("alpha");
    expect(onSwitch).not.toHaveBeenCalled();
    expect(onNew).not.toHaveBeenCalled();
    expect(onSubmit).not.toHaveBeenCalled();
    fireEvent.change(input, { target: { value: "历史" } });
    await waitFor(() => expect(ids(view.container)).toEqual(["beta"]));
    fireEvent.click(view.container.querySelector("[data-slot=aui_thread-list-item-trigger]")!);
    await waitFor(() => expect(onSwitch).toHaveBeenCalledWith("beta"));
    expect(view.getByTestId("selected").textContent).toBe("beta");
  });

  it("matches previews in both sections and restores archived results using the original index", async () => {
    const view = render(<Harness threads={threads} archivedThreads={archivedThreads} />);
    fireEvent.change(view.getByRole("searchbox"), { target: { value: "[A.*]" } });
    await waitFor(() => expect(ids(view.container)).toEqual(["beta"]));
    expect(ids(view.container, true)).toEqual(["old"]);
    expect(view.getByRole("status").textContent).toContain("2 conversations");
    fireEvent.click(view.getByRole("button", { name: "Unarchive" }));
    await waitFor(() => expect(ids(view.container)).toEqual(["old", "beta"]));
    expect(ids(view.container, true)).toEqual([]);
    expect(view.getByRole("searchbox").getAttribute("value")).toBe("[A.*]");
  });

  it("clears with the button or Escape, retains focus and does not clear during IME composition", async () => {
    const view = render(<Harness threads={threads} />);
    const input = view.getByRole("searchbox") as HTMLInputElement;
    input.focus();
    fireEvent.change(input, { target: { value: "alpha" } });
    fireEvent.keyDown(input, { key: "Escape", isComposing: true });
    expect(input.value).toBe("alpha");
    fireEvent.keyDown(input, { key: "Escape" });
    await waitFor(() => expect(ids(view.container)).toEqual(["alpha", "beta", "gamma"]));
    expect(input.value).toBe("");
    expect(document.activeElement).toBe(input);
    fireEvent.change(input, { target: { value: "gamma" } });
    fireEvent.click(view.getByRole("button", { name: "Clear search" }));
    expect(input.value).toBe("");
    expect(document.activeElement).toBe(input);
  });

  it("shows a truthful no-results state and clears search for New Thread", async () => {
    const onNew = vi.fn();
    const view = render(<Harness threads={threads} onNew={onNew} />);
    const input = view.getByRole("searchbox") as HTMLInputElement;
    fireEvent.change(input, { target: { value: "not-present" } });
    await waitFor(() => expect(view.getByText("No matching conversations.")).toBeTruthy());
    expect(view.getByText("Titles and previews, including archived")).toBeTruthy();
    expect(ids(view.container)).toEqual([]);
    fireEvent.click(view.getByRole("button", { name: "New Thread" }));
    await waitFor(() => expect(onNew).toHaveBeenCalledOnce());
    expect(input.value).toBe("");
    expect(ids(view.container)).toContain("new-chat");
  });

  it("distinguishes an empty catalog from a query with no matches", () => {
    const view = render(<Harness threads={[]} />);
    expect(view.getByText("No conversations yet.")).toBeTruthy();
    expect(view.queryByText("No matching conversations.")).toBeNull();
  });

  it("temporarily reveals Workspace results without overwriting folder expansion choices", async () => {
    const view = render(<Harness workspaceMode threads={threads} archivedThreads={archivedThreads} />);
    const group = (project: string, archived = false) => view.container.querySelector(
      `[data-slot=aui_workspace-project-group][data-project='${project}'][data-archived='${archived}']`,
    ) as HTMLElement;
    const a = group("/work/a");
    const b = group("/work/b");
    const old = group("/work/b", true);
    expect(a.dataset.expanded).toBe("true");
    expect(b.dataset.expanded).toBe("false");
    fireEvent.click(a.querySelector("button")!);
    fireEvent.change(view.getByRole("searchbox"), { target: { value: "needle" } });
    await waitFor(() => expect(ids(view.container)).toEqual(["beta"]));
    expect(ids(view.container, true)).toEqual(["old"]);
    expect(a.hidden).toBe(true);
    expect(b.dataset.expanded).toBe("true");
    expect(old.dataset.expanded).toBe("true");
    fireEvent.keyDown(view.getByRole("searchbox"), { key: "Escape" });
    await waitFor(() => expect(a.hidden).toBe(false));
    expect(group("/work/a")).toBe(a);
    expect(a.dataset.expanded).toBe("false");
    expect(b.dataset.expanded).toBe("false");
    expect(old.dataset.expanded).toBe("false");
  });

  it("bounds initial rows, searches beyond the first page and keeps original runtime indices", async () => {
    const onSwitch = vi.fn();
    const many: ExternalStoreThreadData<"regular">[] = Array.from({ length: 205 }, (_, i) => ({
      id: `many-${i}`, status: "regular", title: `Session ${i}`,
      custom: { preview: i === 204 ? "deep needle" : "ordinary" },
    }));
    const view = render(<Harness threads={many} onSwitch={onSwitch} />);
    await waitFor(() => expect(ids(view.container).length).toBe(100));
    fireEvent.click(view.getByRole("button", { name: "Show more conversations" }));
    expect(ids(view.container).length).toBe(200);
    fireEvent.change(view.getByRole("searchbox"), { target: { value: "deep needle" } });
    await waitFor(() => expect(ids(view.container)).toEqual(["many-204"]));
    fireEvent.click(view.container.querySelector("[data-slot=aui_thread-list-item-trigger]")!);
    await waitFor(() => expect(onSwitch).toHaveBeenCalledWith("many-204"));
    fireEvent.keyDown(view.getByRole("searchbox"), { key: "Escape" });
    await waitFor(() => expect(ids(view.container).length).toBe(100));
  });

  it("caps Workspace search globally instead of mounting a full page for every folder", async () => {
    const many: ExternalStoreThreadData<"regular">[] = Array.from({ length: 220 }, (_, i) => ({
      id: `folder-${i}`, status: "regular", title: `Matching ${i}`,
      custom: { project: `/work/${i % 4}`, preview: "common needle" },
    }));
    const view = render(<Harness workspaceMode threads={many} />);
    fireEvent.change(view.getByRole("searchbox"), { target: { value: "common needle" } });
    await waitFor(() => expect(ids(view.container).length).toBe(100));
    expect(view.getByRole("status").textContent).toContain("220 conversations");
    fireEvent.click(view.getByRole("button", { name: "Show more conversations" }));
    expect(ids(view.container).length).toBe(200);
  });

  it("keeps queries isolated between two widgets", async () => {
    const view = render(
      <><section data-testid="one"><Harness threads={threads} /></section>
        <section data-testid="two"><Harness threads={threads} /></section></>,
    );
    const one = view.getByTestId("one");
    const two = view.getByTestId("two");
    fireEvent.change(within(one).getByRole("searchbox"), { target: { value: "gamma" } });
    await waitFor(() => expect(ids(one)).toEqual(["gamma"]));
    expect(ids(two)).toEqual(["alpha", "beta", "gamma"]);
    expect((within(two).getByRole("searchbox") as HTMLInputElement).value).toBe("");
  });
});
