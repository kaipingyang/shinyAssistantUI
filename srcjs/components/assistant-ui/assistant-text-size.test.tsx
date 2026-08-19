// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, waitFor } from "@testing-library/react";
import {
  AssistantRuntimeProvider,
  useExternalStoreRuntime,
  type ThreadMessageLike,
} from "@assistant-ui/react";
import { ShinyConfigContext, type ShinyConfigCtx } from "../../shiny-config-context";
import { Thread } from "./thread";

globalThis.ResizeObserver ??= class {
  observe() {}
  unobserve() {}
  disconnect() {}
} as any;
globalThis.IntersectionObserver ??= class {
  observe() {}
  unobserve() {}
  disconnect() {}
  takeRecords() { return []; }
} as any;
HTMLElement.prototype.scrollTo ??= vi.fn();
Element.prototype.scrollIntoView ??= vi.fn();

const baseContext: ShinyConfigCtx = {
  tools: [], commands: [], actionItems: [], showTimestamps: false,
  onEnqueue: () => {}, onRename: () => {}, onInvokeAction: () => {},
  selectionVisible: true, setSelectionVisible: () => {}, refreshIdeContext: () => {},
  workspaceMentions: { enabled: false, query: "", items: [], loading: false },
  searchWorkspace: () => {},
};

const messages: ThreadMessageLike[] = [
  { id: "u1", role: "user", content: [{ type: "text", text: "USER TEXT" } as any] },
  {
    id: "a1",
    role: "assistant",
    status: { type: "complete", reason: "stop" } as any,
    content: [
      { type: "text", text: "# HEADING\n\nASSISTANT BODY" } as any,
      { type: "source", url: "https://example.com", title: "SOURCE CHIP" } as any,
      {
        type: "tool-call", toolCallId: "tool-size", toolName: "Bash",
        args: { command: "printf tool" }, argsText: '{"command":"printf tool"}',
        result: "TOOL RESULT", isError: false,
      } as any,
    ],
  },
];

function Harness({ size }: { size?: "small" | "compact" | "medium" }) {
  const runtime = useExternalStoreRuntime({
    messages,
    isRunning: false,
    convertMessage: (message) => message,
    onNew: async () => {},
  });
  const context = {
    ...baseContext,
    ...(size ? { assistantTextSize: size } : {}),
  } as ShinyConfigCtx;
  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ShinyConfigContext.Provider value={context}>
        <Thread />
      </ShinyConfigContext.Provider>
    </AssistantRuntimeProvider>
  );
}

afterEach(cleanup);

describe("assistant response text size", () => {
  it.each([
    ["small"],
    ["compact"],
    ["medium"],
  ] as const)("scopes %s to assistant text and tool parts", async (size) => {
    const { container } = render(<Harness size={size} />);
    await waitFor(() => expect(container.querySelector('[data-slot="aui_assistant-text"]'))
      .not.toBeNull());
    const content = container.querySelector('[data-slot="aui_assistant-message-content"]') as HTMLElement;
    const text = container.querySelector('[data-slot="aui_assistant-text"]') as HTMLElement;
    const tool = container.querySelector(".aui-tool-group-trigger, .aui-shiny-tool") as HTMLElement;
    expect(content.dataset.assistantTextSize).toBe(size);
    expect(text.dataset.textSize).toBe(size);
    expect(text.className).not.toMatch(/\btext-(sm|base|lg)\b/);
    expect(text.textContent).toContain("ASSISTANT BODY");
    expect(text.querySelector(".aui-md-h1")?.className).toContain("text-xl");
    expect(text.className).toContain("[&_.aui-md-h1]:text-[1.25em]");
    expect(text.textContent).not.toContain("SOURCE CHIP");
    expect(tool).not.toBeNull();
    expect(content.contains(tool)).toBe(true);
    expect(container.querySelector(".aui-user-message-content")?.textContent)
      .toContain("USER TEXT");
  });

  it("defaults missing configuration to Default (medium canonical value)", async () => {
    const { container } = render(<Harness />);
    await waitFor(() => expect(container.querySelector('[data-slot="aui_assistant-text"]'))
      .not.toBeNull());
    const content = container.querySelector('[data-slot="aui_assistant-message-content"]') as HTMLElement;
    const text = container.querySelector('[data-slot="aui_assistant-text"]') as HTMLElement;
    expect(content.dataset.assistantTextSize).toBe("medium");
    expect(text.dataset.textSize).toBe("medium");
    expect(text.className).not.toMatch(/\btext-(sm|base|lg)\b/);
  });
});
