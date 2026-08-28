/** @vitest-environment jsdom */
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ShinyConfigContext } from "@/shiny-config-context";
import { ShinyToolFallback } from "@/shiny-tool-fallback";
import { createLazyToolResultClient, type LazyToolResultDescriptor } from "@/lazy-tool-result";
import { _clearToolCardStateForTests } from "./tool-card-frame";

const descriptor: LazyToolResultDescriptor = {
  kind: "lazy-tool-result", version: 1, handle: "lazy-ui", generation: 1,
  threadId: "thread-ui", toolCallId: "tool-ui",
  originalBytes: 100, sourceBytes: 100, truncated: false,
  chunkBytes: 25, summary: "100 byte result",
};

const baseConfig = {
  tools: [], commands: [], actionItems: [], showTimestamps: false,
  onEnqueue: () => {}, onRename: () => {}, onInvokeAction: () => {},
  selectionVisible: true, setSelectionVisible: () => {}, refreshIdeContext: () => {},
  workspaceMentions: { enabled: false, query: "", items: [], loading: false },
  searchWorkspace: () => {},
};

function renderLazy(defaultOpen = false) {
  const send = vi.fn();
  const client = createLazyToolResultClient(send, { retainedBytes: 50 });
  const props = {
    toolName: "Bash", toolCallId: "tool-ui", args: { command: "seq 100" },
    argsText: '{"command":"seq 100"}', result: descriptor,
    status: { type: "complete" },
    artifact: { inputId: "chat_input", threadId: "thread-ui", defaultOpen },
  } as never;
  const view = render(
    <ShinyConfigContext.Provider value={{ ...baseConfig, lazyToolResults: client }}>
      <ShinyToolFallback {...props} />
    </ShinyConfigContext.Provider>,
  );
  return { ...view, send, client };
}

afterEach(() => {
  cleanup();
  _clearToolCardStateForTests();
});

describe("ToolCardFrame lazy result", () => {
  it("keeps a collapsed result metadata-only and requests exactly once when opened", () => {
    const view = renderLazy(false);
    expect(view.send).not.toHaveBeenCalled();
    expect(view.container.textContent).not.toContain("Result:");

    fireEvent.click(view.container.querySelector('[data-slot="tool-fallback-trigger"]')!);
    expect(view.send).toHaveBeenCalledTimes(1);
    expect(view.container.querySelector("[data-lazy-tool-result]")).not.toBeNull();
    expect(view.container.textContent).toContain("100 byte result");
  });

  it("requests the next chunk near the bottom without pagination controls", () => {
    const view = renderLazy(true);
    expect(view.send).toHaveBeenCalledTimes(1);
    const first = view.send.mock.calls[0][0];
    view.client.accept({ ...first, text: "first chunk\n", nextOffset: 12, done: false });

    const viewport = view.container.querySelector<HTMLElement>('[data-slot="tool-result-scroll"]')!;
    Object.defineProperty(viewport, "scrollHeight", { configurable: true, value: 1000 });
    Object.defineProperty(viewport, "clientHeight", { configurable: true, value: 100 });
    viewport.scrollTop = 850;
    fireEvent.scroll(viewport);
    fireEvent.scroll(viewport);

    expect(view.send).toHaveBeenCalledTimes(2);
    expect(view.queryByRole("button", { name: /next|previous|page/i })).toBeNull();
  });


  it("preserves released logical height after old chunks are evicted", () => {
    const view = renderLazy(true);
    const first = view.send.mock.calls[0][0];
    act(() => view.client.accept({
      ...first, text: "line-1\nline-2\nline-3\n", nextOffset: 21, done: false,
    }));
    view.client.requestNext(descriptor, "thread-ui", "tool-ui");
    const second = view.send.mock.calls[1][0];
    act(() => view.client.accept({
      ...second, text: "line-4\nline-5\nline-6\nline-7\nline-8\n", nextOffset: 56, done: false,
    }));

    const spacer = view.container.querySelector<HTMLElement>("[data-lazy-result-spacer]");
    expect(spacer).not.toBeNull();
    expect(Number.parseFloat(spacer?.style.height ?? "0")).toBeGreaterThan(0);
  });

  it.each(["Write", "Edit", "MultiEdit"])("keeps %s default-open", (toolName) => {
    const props = {
      toolName, toolCallId: `open-${toolName}`, args: {}, argsText: "{}",
      result: "done", status: { type: "complete" }, artifact: {},
    } as never;
    const view = render(<ShinyToolFallback {...props} />);
    expect(view.container.querySelector('[data-slot="tool-fallback-trigger"]')?.getAttribute("aria-expanded"))
      .toBe("true");
  });
});
