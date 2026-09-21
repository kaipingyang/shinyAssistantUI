// @vitest-environment jsdom
import { useRef } from "react";
import { act, cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  AssistantRuntimeProvider,
  ComposerPrimitive,
  useAuiState,
  useExternalStoreRuntime,
  type AssistantRuntime,
  type ThreadMessageLike,
} from "@assistant-ui/react";
import { VirtualizedMessages } from "./virtualized-messages";

const renders = vi.fn();
const observed = vi.fn();
let runtime: AssistantRuntime;
const messages: ThreadMessageLike[] = Array.from({ length: 240 }, (_, i) => ({
  id: `m${i}`,
  role: i % 2 ? "assistant" : "user",
  content: [{ type: "text", text: `Message ${i}` }],
}));

class TestResizeObserver implements ResizeObserver {
  observe(element: Element) { observed(element); }
  unobserve() {}
  disconnect() {}
}

function Message() {
  const id = useAuiState((s) => s.message.id);
  const editing = useAuiState((s) => s.message.composer.isEditing);
  renders(id);
  return editing
    ? <ComposerPrimitive.Input data-testid={`edit-${id}`} />
    : <div data-testid={id}>{id}</div>;
}

function Harness({ items = messages }: { items?: ThreadMessageLike[] }) {
  const viewportRef = useRef<HTMLDivElement>(null);
  const followingRef = useRef(false);
  runtime = useExternalStoreRuntime({
    messages: items,
    convertMessage: (message) => message,
    isRunning: false,
    onNew: async () => {},
    onEdit: async () => {},
  });
  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <div ref={viewportRef} data-testid="viewport">
        <VirtualizedMessages viewportRef={viewportRef} followingRef={followingRef}>
          {Message}
        </VirtualizedMessages>
      </div>
    </AssistantRuntimeProvider>
  );
}

beforeEach(() => {
  vi.stubGlobal("ResizeObserver", TestResizeObserver);
  vi.spyOn(HTMLElement.prototype, "clientHeight", "get").mockReturnValue(600);
  vi.spyOn(HTMLElement.prototype, "clientWidth", "get").mockReturnValue(800);
  vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
    const isRow = this.dataset.slot === "aui_message-slot";
    const height = isRow ? 100 + Number.parseFloat(this.style.paddingBottom || "0") : 600;
    const top = this.dataset.slot === "aui_virtualized-messages"
      ? -(this.parentElement?.scrollTop ?? 0) : 0;
    return new DOMRect(0, top, 800, height);
  });
  renders.mockClear();
  observed.mockClear();
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("virtualized messages use the real assistant-ui runtime", () => {
  it("mounts a bounded window and spacer runs, not 240 observed placeholders", async () => {
    const view = render(<Harness />);
    await waitFor(() => {
      const rows = view.container.querySelectorAll('[data-slot="aui_message-slot"]');
      expect(rows.length).toBeGreaterThan(0);
      expect(rows.length).toBeLessThanOrEqual(48);
    });
    expect(view.getByTestId("m239")).toBeTruthy();
    expect(view.container.querySelector('[data-slot="aui_message-spacer"]')).not.toBeNull();
    expect(view.container.querySelectorAll('[data-mounted="false"]')).toHaveLength(0);
  });

  it("keeps short threads complete and does not rerender messages on composer input", async () => {
    const view = render(<Harness items={messages.slice(0, 20)} />);
    await waitFor(() => expect(view.queryAllByTestId(/^m\d+$/)).toHaveLength(20));
    renders.mockClear();
    act(() => runtime.thread.composer.setText("typing without touching the list"));
    expect(renders).not.toHaveBeenCalled();
  });

  it("subscribes after the ancestor viewport ref is attached", () => {
    const view = render(<Harness />);
    expect(observed).toHaveBeenCalledWith(view.getByTestId("viewport"));
  });

  it("retains an offscreen edited message and its draft", async () => {
    const view = render(<Harness />);
    act(() => {
      runtime.thread.getMessageById("m0").composer.beginEdit();
      runtime.thread.getMessageById("m0").composer.setText("unsent edit");
    });
    await waitFor(() => expect(view.getByTestId("edit-m0")).toBeTruthy());
    const input = view.getByTestId("edit-m0");
    input.blur();
    fireEvent.scroll(view.getByTestId("viewport"), { target: { scrollTop: 10000 } });
    await waitFor(() => {
      const indices = Array.from(
        view.container.querySelectorAll<HTMLElement>("[data-message-index]"),
        (element) => Number(element.dataset.messageIndex),
      );
      expect(indices.some((index) => index >= 60 && index < 120)).toBe(true);
    });
    expect(view.getByTestId("edit-m0")).toBe(input);
    expect(runtime.thread.getMessageById("m0").composer.getState().text).toBe("unsent edit");
  });

  it("does not transiently unmount the reading window while prepending history", async () => {
    const original = messages.slice(0, 90);
    const view = render(<Harness items={original} />);
    fireEvent.scroll(view.getByTestId("viewport"), { target: { scrollTop: 6000 } });
    await waitFor(() => expect(view.getByTestId("m42")).toBeTruthy());
    const readingNode = view.getByTestId("m42");
    const older = Array.from({ length: 60 }, (_, i): ThreadMessageLike => ({
      id: `older-${i}`, role: "user", content: [{ type: "text", text: `Older ${i}` }],
    }));
    view.rerender(<Harness items={[...older, ...original]} />);
    await waitFor(() => expect(view.getByTestId("m42")).toBeTruthy());
    expect(view.getByTestId("m42")).toBe(readingNode);
    expect(readingNode.isConnected).toBe(true);
  });

  it("drops removed IDs on history replacement without stale message providers", async () => {
    const view = render(<Harness />);
    view.rerender(<Harness items={[{
      id: "replacement", role: "user", content: [{ type: "text", text: "New history" }],
    }]} />);
    await waitFor(() => expect(view.getByTestId("replacement")).toBeTruthy());
    expect(view.queryByTestId("m239")).toBeNull();
    expect(view.container.querySelectorAll('[data-slot="aui_message-slot"]')).toHaveLength(1);
  });
});
