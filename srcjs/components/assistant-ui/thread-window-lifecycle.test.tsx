// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  AssistantRuntimeProvider,
  useExternalStoreRuntime,
  type ThreadMessageLike,
} from "@assistant-ui/react";
import { ShinyConfigContext, type ShinyConfigCtx } from "../../shiny-config-context";
import { Thread } from "./thread";

const context: ShinyConfigCtx = {
  tools: [], commands: [], actionItems: [], showTimestamps: false,
  onEnqueue: () => {}, onRename: () => {}, onInvokeAction: () => {},
  selectionVisible: true, setSelectionVisible: () => {}, refreshIdeContext: () => {},
  workspaceMentions: { enabled: false, query: "", items: [], loading: false },
  searchWorkspace: () => {},
};
const initial: ThreadMessageLike[] = Array.from({ length: 90 }, (_, i) => ({
  id: `m${i}`, role: i % 2 ? "assistant" : "user",
  content: [{ type: "text", text: `Message ${i}` }],
}));
const threads = [
  { id: "a", status: "regular", title: "First" },
  { id: "b", status: "regular", title: "Second" },
] as const;
const AssistantMessage = () => <div>Assistant</div>;
const components = { AssistantMessage };
let listInset = 0;

function Harness({ threadId = "a", messages = initial }: {
  threadId?: string;
  messages?: ThreadMessageLike[];
}) {
  const runtime = useExternalStoreRuntime({
    messages,
    convertMessage: (message) => message,
    onNew: async () => {},
    adapters: {
      threadList: {
        threadId, threads,
        onSwitchToThread: () => {},
        onSwitchToNewThread: () => {},
      },
    },
  });
  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ShinyConfigContext.Provider value={context}>
        <Thread components={components} />
      </ShinyConfigContext.Provider>
    </AssistantRuntimeProvider>
  );
}

beforeEach(() => {
  listInset = 0;
  vi.stubGlobal("ResizeObserver", class {
    observe() {}
    unobserve() {}
    disconnect() {}
  });
  vi.spyOn(HTMLElement.prototype, "clientHeight", "get").mockReturnValue(600);
  vi.spyOn(HTMLElement.prototype, "clientWidth", "get").mockReturnValue(800);
  vi.spyOn(HTMLElement.prototype, "scrollHeight", "get").mockReturnValue(10000);
  vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
    const viewport = this.closest<HTMLElement>('[data-slot="aui_thread-viewport"]');
    const top = this.dataset.slot === "aui_virtualized-messages"
      ? listInset - (viewport?.scrollTop ?? 0) : 0;
    const height = this.dataset.slot === "aui_message-slot"
      ? 100 + Number.parseFloat(this.style.paddingBottom || "0") : 600;
    return new DOMRect(0, top, 800, height);
  });
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("thread selection resets follow intent independently of message IDs", () => {
  it.each(["same-ids", "assistant-only"] as const)(
    "opens a cached %s thread at its latest messages after reading older history",
    async (kind) => {
      const view = render(<Harness />);
      const viewport = view.container.querySelector<HTMLElement>('[data-slot="aui_thread-viewport"]')!;
      await waitFor(() => expect(viewport.scrollTop).toBeGreaterThanOrEqual(9400));
      fireEvent.wheel(viewport, { deltaY: -600 });
      fireEvent.scroll(viewport, { target: { scrollTop: 1500 } });
      await act(async () => { await new Promise((resolve) => setTimeout(resolve, 40)); });
      expect(viewport.scrollTop).toBeGreaterThan(1000);
      expect(viewport.scrollTop).toBeLessThan(2000);
      const messages = kind === "same-ids" ? initial : initial.map(
        (message): ThreadMessageLike => ({
          ...message, id: `other-${message.id}`, role: "assistant",
        }),
      );
      view.rerender(<Harness threadId="b" messages={messages} />);
      await waitFor(() => expect(viewport.scrollTop).toBeGreaterThanOrEqual(9400));
    },
  );
});

describe("current question follows the visible turn", () => {
  it.each([6, 90])(
    "shows the first question above the first row in a %i-message thread",
    async (count) => {
      listInset = 80;
      const view = render(<Harness messages={initial.slice(0, count)} />);
      const viewport = view.container.querySelector<HTMLElement>('[data-slot="aui_thread-viewport"]')!;
      const question = () => view.container.querySelector('[data-slot="aui_current_question"]')?.textContent;
      await waitFor(() => expect(viewport.scrollTop).toBeGreaterThanOrEqual(9400));

      fireEvent.wheel(viewport, { deltaY: -10000 });
      fireEvent.scroll(viewport, { target: { scrollTop: 0 } });
      await waitFor(() => expect(question()).toContain("Message 0"));

      fireEvent.scroll(viewport, { target: { scrollTop: 300 } });
      await waitFor(() => expect(question()).toContain("Message 2"));
    },
  );
});
