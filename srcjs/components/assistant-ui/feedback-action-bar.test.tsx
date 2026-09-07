// @vitest-environment jsdom
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import {
  AssistantRuntimeProvider,
  useExternalStoreRuntime,
  type FeedbackAdapter,
  type ThreadMessageLike,
} from "@assistant-ui/react";
import { Thread } from "./thread";
import { ShinyConfigContext, type ShinyConfigCtx } from "../../shiny-config-context";

const baseContext: ShinyConfigCtx = {
  tools: [], commands: [], actionItems: [], showTimestamps: false,
  onEnqueue: () => {}, onRename: () => {}, onInvokeAction: () => {},
  selectionVisible: true, setSelectionVisible: () => {}, refreshIdeContext: () => {},
  workspaceMentions: { enabled: false, query: "", items: [], loading: false },
  searchWorkspace: () => {},
};

const assistantMessage: ThreadMessageLike = {
  id: "assistant-feedback",
  role: "assistant",
  status: { type: "complete", reason: "stop" },
  content: [{ type: "text", text: "A useful response" }],
};

function Harness({ feedback }: { feedback?: FeedbackAdapter }) {
  const runtime = useExternalStoreRuntime({
    messages: [assistantMessage],
    isRunning: false,
    convertMessage: (message) => message,
    adapters: { feedback },
  });
  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ShinyConfigContext.Provider value={baseContext}>
        <Thread />
      </ShinyConfigContext.Provider>
    </AssistantRuntimeProvider>
  );
}

beforeAll(() => {
  Element.prototype.scrollIntoView ??= vi.fn();
  HTMLElement.prototype.scrollTo ??= vi.fn();
  globalThis.ResizeObserver ??= class ResizeObserver {
    observe() {} unobserve() {} disconnect() {}
  };
  globalThis.IntersectionObserver ??= class IntersectionObserver {
    observe() {} unobserve() {} disconnect() {}
    takeRecords() { return []; }
    readonly root = null; readonly rootMargin = ""; readonly thresholds = [];
  } as never;
});

afterEach(() => cleanup());

describe("assistant feedback action bar", () => {
  it("hides feedback controls when no adapter capability is present", () => {
    render(<Harness />);
    expect(screen.queryByRole("button", { name: "Good response" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Bad response" })).toBeNull();
  });

  it("submits positive and negative feedback through the adapter", async () => {
    const submit = vi.fn();
    render(<Harness feedback={{ submit }} />);

    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Good response" })));
    expect(submit).toHaveBeenLastCalledWith(expect.objectContaining({
      type: "positive",
      message: expect.objectContaining({ id: "assistant-feedback" }),
    }));

    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Bad response" })));
    expect(submit).toHaveBeenLastCalledWith(expect.objectContaining({
      type: "negative",
      message: expect.objectContaining({ id: "assistant-feedback" }),
    }));
  });
});
