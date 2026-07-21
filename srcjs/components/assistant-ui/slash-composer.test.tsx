// @vitest-environment jsdom
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, waitFor, within } from "@testing-library/react";
import { AssistantRuntimeProvider, useAui, useLocalRuntime } from "@assistant-ui/react";
import { $createParagraphNode, $createTextNode, $getRoot, type LexicalEditor } from "lexical";
import { Thread } from "./thread";
import { ShinyConfigContext, type ShinyConfigCtx } from "../../shiny-config-context";

const noOpAdapter = {
  async run() {
    return { content: [{ type: "text" as const, text: "" }] };
  },
};

type RuntimeCapture = ReturnType<typeof useLocalRuntime>;
const runtimes: Record<string, RuntimeCapture> = {};

const baseContext: ShinyConfigCtx = {
  tools: [],
  commands: [],
  actionItems: [],
  showTimestamps: false,
  onEnqueue: () => {},
  onRename: () => {},
  onInvokeAction: () => {},
  selectionVisible: true,
  setSelectionVisible: () => {},
  refreshIdeContext: () => {},
  workspaceMentions: { enabled: false, query: "", items: [], loading: false },
  searchWorkspace: () => {},
};

function RuntimeCaptureMarker({ id }: { id: string }) {
  const aui = useAui();
  (runtimes[id] as unknown) = aui;
  return null;
}

function Widget({ id, context }: { id: string; context: Partial<ShinyConfigCtx> }) {
  const runtime = useLocalRuntime(noOpAdapter);
  return (
    <div data-testid={`widget-${id}`}>
      <AssistantRuntimeProvider runtime={runtime}>
        <ShinyConfigContext.Provider value={{ ...baseContext, ...context }}>
          <RuntimeCaptureMarker id={id} />
          <Thread />
        </ShinyConfigContext.Provider>
      </AssistantRuntimeProvider>
    </div>
  );
}

function editorIn(widget: HTMLElement): HTMLElement {
  const editor = widget.querySelector<HTMLElement>(".aui-lexical-input[contenteditable='true']");
  expect(editor, "composer must use LexicalComposerInput").not.toBeNull();
  return editor!;
}

async function setEditorText(editorElement: HTMLElement, text: string, cursor = text.length) {
  const editor = (editorElement as HTMLElement & { __lexicalEditor?: LexicalEditor }).__lexicalEditor;
  expect(editor, "Lexical editor instance must be attached to the contenteditable").toBeTruthy();
  await act(async () => {
    editor!.update(() => {
      const root = $getRoot();
      root.clear();
      const paragraph = $createParagraphNode();
      const textNode = $createTextNode(text);
      paragraph.append(textNode);
      root.append(paragraph);
      textNode.select(cursor, cursor);
    });
  });
}

function composerText(id: string): string {
  const aui = runtimes[id] as unknown as ReturnType<typeof useAui>;
  return aui.composer().getState().text;
}
  it("keeps the contenteditable borderless and overlays the placeholder inside one input surface", () => {
    const { getByTestId } = render(<Widget id="layout" context={{}} />);
    const widget = getByTestId("widget-layout");
    const editor = editorIn(widget);
    const shell = widget.querySelector<HTMLElement>(".aui-lexical-editor");
    const placeholder = widget.querySelector<HTMLElement>(".aui-lexical-placeholder");

    expect(shell).not.toBeNull();
    expect(placeholder).not.toBeNull();
    expect(getComputedStyle(shell!).position).toBe("relative");
    expect(getComputedStyle(shell!).width).toBe("100%");
    expect(getComputedStyle(editor).borderStyle).toBe("none");
    expect(getComputedStyle(editor).outlineStyle).toBe("none");
    expect(getComputedStyle(placeholder!).position).toBe("absolute");
    expect(getComputedStyle(placeholder!).pointerEvents).toBe("none");
    expect(shell!.style.position).toBe("relative");
    expect(shell!.style.width).toBe("100%");
    expect(editor.style.borderStyle).toBe("none");
    expect(editor.style.outlineStyle).toBe("none");
    expect(editor.style.width).toBe("100%");
    expect(placeholder!.style.position).toBe("absolute");
    expect(placeholder!.style.pointerEvents).toBe("none");
  });

beforeAll(() => {
  Element.prototype.scrollIntoView ??= vi.fn();
  globalThis.ResizeObserver = class ResizeObserver {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
});

afterEach(() => {
  cleanup();
  for (const key of Object.keys(runtimes)) delete runtimes[key];
});

describe("Lexical slash composer", () => {
  it("uses a full-width popover and inserts a blue directive chip at the exact middle caret", async () => {
    const { getByTestId } = render(
      <Widget
        id="middle"
        context={{
          commands: [{ name: "github", prompt: "/github", description: "GitHub skill", category: "Skills" }],
        }}
      />,
    );
    const widget = getByTestId("widget-middle");
    const editor = editorIn(widget);
    await setEditorText(editor, "before /gi after", "before /gi".length);

    const popover = await waitFor(() => {
      const element = widget.querySelector<HTMLElement>(".aui-slash-popover");
      expect(element).not.toBeNull();
      return element!;
    });
    expect(popover.className).toContain("inset-x-0");
    expect(popover.className).toContain("w-full");
    expect(popover.className).not.toMatch(/\bw-80\b/);
    expect(popover.querySelector("[data-trigger-section='Skills']")?.textContent).toBe("Skills");

    fireEvent.keyDown(editor, { key: "Enter" });
    await waitFor(() => expect(composerText("middle")).toBe("before /github after"));
    const chip = widget.querySelector<HTMLElement>("[data-directive-type='slash'][data-directive-id='github']");
    expect(chip).not.toBeNull();
    expect(chip!.className).toMatch(/bg-blue-/);
    expect(chip!.className).toMatch(/text-blue-/);
  });

  it("inserts a blue directive chip for an action selected with Enter", async () => {
    const { getByTestId } = render(
      <Widget
        id="action-enter"
        context={{
          actionItems: [{ id: "compact", command: "compact", label: "Compact", section: "Actions" }],
        }}
      />,
    );
    const widget = getByTestId("widget-action-enter");
    const editor = editorIn(widget);
    await setEditorText(editor, "/comp");
    await waitFor(() => expect(widget.querySelector("[data-slash-action='compact']")).not.toBeNull());

    fireEvent.keyDown(editor, { key: "Enter" });
    // 视觉上 action 与 skill 一致：生成蓝色 directive chip（功能区分留待提交时路由）。
    const chip = await waitFor(() => {
      const element = widget.querySelector<HTMLElement>("[data-directive-type='slash-action'][data-directive-id='compact']");
      expect(element).not.toBeNull();
      return element!;
    });
    expect(chip.style.backgroundColor).not.toBe("");
    expect(chip.style.color).not.toBe("");
    await waitFor(() => expect(composerText("action-enter")).toBe("/compact"));
  });

  it("inserts a blue directive chip for an action selected with click", async () => {
    const { getByTestId } = render(
      <Widget
        id="action-click"
        context={{
          actionItems: [{ id: "compact", command: "compact", label: "Compact", section: "Actions" }],
        }}
      />,
    );
    const widget = getByTestId("widget-action-click");
    const editor = editorIn(widget);
    await setEditorText(editor, "/comp");
    const action = await waitFor(() => {
      const item = widget.querySelector<HTMLElement>("[data-slash-action='compact']");
      expect(item).not.toBeNull();
      return item!;
    });

    fireEvent.click(action);
    const chip = await waitFor(() => {
      const element = widget.querySelector<HTMLElement>("[data-directive-type='slash-action'][data-directive-id='compact']");
      expect(element).not.toBeNull();
      return element!;
    });
    expect(chip.style.backgroundColor).not.toBe("");
    await waitFor(() => expect(composerText("action-click")).toBe("/compact"));
  });

  it("handles Arrow keys, Enter, Tab and Escape in the current widget only, while leaving Shift+Tab alone", async () => {
    const contextA = {
      actionItems: [
        { id: "first", command: "first", label: "First", section: "Actions" },
        { id: "second", command: "second", label: "Second", section: "Actions" },
      ],
    };
    const contextB = { ...contextA };
    const { getByTestId } = render(
      <>
        <Widget id="a" context={contextA} />
        <Widget id="b" context={contextB} />
      </>,
    );
    const widgetA = getByTestId("widget-a");
    const widgetB = getByTestId("widget-b");
    const editorA = editorIn(widgetA);
    const editorB = editorIn(widgetB);
    await setEditorText(editorA, "/");
    await setEditorText(editorB, "/");
    await waitFor(() => {
      expect(widgetA.querySelectorAll("[data-slash-action]")).toHaveLength(2);
      expect(widgetB.querySelectorAll("[data-slash-action]")).toHaveLength(2);
    });

    // ArrowDown/Up navigation stays scoped to widget A; Enter inserts the chip there only.
    fireEvent.keyDown(editorA, { key: "ArrowDown" });
    fireEvent.keyDown(editorA, { key: "ArrowUp" });
    fireEvent.keyDown(editorA, { key: "ArrowDown" });
    fireEvent.keyDown(editorA, { key: "Enter" });
    await waitFor(() => expect(widgetA.querySelector("[data-directive-id='second']")).not.toBeNull());
    expect(widgetB.querySelector("[data-directive-type='slash-action']")).toBeNull();

    await setEditorText(editorB, "/fi");
    await waitFor(() => expect(widgetB.querySelector(".aui-slash-popover")).not.toBeNull());
    // Shift+Tab remains native (not intercepted) and does not complete.
    const shiftTabAllowed = fireEvent.keyDown(editorB, { key: "Tab", shiftKey: true });
    expect(shiftTabAllowed).toBe(true);
    expect(widgetB.querySelector("[data-directive-type='slash-action']")).toBeNull();
    expect(widgetB.querySelector(".aui-slash-popover")).not.toBeNull();

    // Tab now completes an action as a blue chip (consistent with skills), scoped to widget B.
    const tabAllowed = fireEvent.keyDown(editorB, { key: "Tab" });
    expect(tabAllowed).toBe(false);
    await waitFor(() => expect(widgetB.querySelector("[data-directive-id='first']")).not.toBeNull());
    expect(widgetB.querySelector(".aui-slash-popover")).toBeNull();

    await setEditorText(editorB, "/se");
    await waitFor(() => expect(widgetB.querySelector(".aui-slash-popover")).not.toBeNull());
    fireEvent.keyDown(editorB, { key: "Escape" });
    await waitFor(() => expect(widgetB.querySelector(".aui-slash-popover")).toBeNull());
  });

  it("keeps skill arguments literal and preserves @ mention selection", async () => {
    const searchWorkspace = vi.fn();
    const { getByTestId } = render(
      <Widget
        id="literal"
        context={{
          commands: [{ name: "github", prompt: "/github", description: "GitHub skill", category: "Skills" }],
          tools: [{ name: "calculator", description: "Calculate" }],
          workspaceMentions: {
            enabled: true,
            query: "app",
            loading: false,
            items: [{ kind: "file", path: "R/app.R", insertText: "@R/app.R" }],
          },
          searchWorkspace,
        }}
      />,
    );
    const widget = getByTestId("widget-literal");
    const editor = editorIn(widget);

    await setEditorText(editor, "/git");
    await waitFor(() => expect(widget.querySelector("[data-slash-cmd='github']")).not.toBeNull());
    fireEvent.keyDown(editor, { key: "Enter" });
    await waitFor(() => expect(widget.querySelector("[data-directive-id='github']")).not.toBeNull());
    await act(async () => {
      const aui = runtimes.literal as unknown as ReturnType<typeof useAui>;
      aui.composer().setText("/github issue 42");
    });
    await waitFor(() => expect(composerText("literal")).toBe("/github issue 42"));
    expect(widget.querySelector("[data-directive-id='github']")).not.toBeNull();

    await setEditorText(editor, "use @cal now", "use @cal".length);
    await waitFor(() => expect(searchWorkspace).toHaveBeenCalledWith("cal"));
    const mentionPopover = await waitFor(() => {
      const element = widget.querySelector<HTMLElement>(".aui-mention-popover");
      expect(element).not.toBeNull();
      return element!;
    });
    expect(within(mentionPopover).getByText("@calculator")).toBeTruthy();
    fireEvent.keyDown(editor, { key: "Enter" });
    await waitFor(() => expect(composerText("literal")).toBe("use @calculator now"));
    expect(widget.querySelector("[data-directive-type='tool']")).not.toBeNull();
  });

  it("scrolls the keyboard-highlighted slash item into view", async () => {
    const scrollSpy = vi
      .spyOn(Element.prototype, "scrollIntoView")
      .mockImplementation(() => {});
    try {
      const commands = Array.from({ length: 12 }, (_, i) => ({
        name: `cmd${i}`,
        prompt: `/cmd${i}`,
        description: `Command ${i}`,
        category: "Skills",
      }));
      const { getByTestId } = render(<Widget id="scroll" context={{ commands }} />);
      const widget = getByTestId("widget-scroll");
      const editor = editorIn(widget);

      await setEditorText(editor, "/cmd");
      await waitFor(() =>
        expect(widget.querySelectorAll("[data-slash-cmd]").length).toBeGreaterThan(8),
      );
      scrollSpy.mockClear();
      for (let i = 0; i < 8; i++) fireEvent.keyDown(editor, { key: "ArrowDown" });

      await waitFor(() => expect(scrollSpy).toHaveBeenCalled());
      const lastCallArg = scrollSpy.mock.calls.at(-1)?.[0] as ScrollIntoViewOptions;
      expect(lastCallArg?.block).toBe("nearest");
    } finally {
      scrollSpy.mockRestore();
    }
  });

  it("gives the skill directive chip inline critical colors for RStudio Viewer", async () => {
    const { getByTestId } = render(
      <Widget
        id="chip-inline"
        context={{
          commands: [
            { name: "github", prompt: "/github", description: "GitHub skill", category: "Skills" },
          ],
        }}
      />,
    );
    const widget = getByTestId("widget-chip-inline");
    const editor = editorIn(widget);

    await setEditorText(editor, "/git");
    await waitFor(() => expect(widget.querySelector("[data-slash-cmd='github']")).not.toBeNull());
    fireEvent.keyDown(editor, { key: "Tab" });
    const chip = await waitFor(() => {
      const element = widget.querySelector<HTMLElement>("[data-directive-id='github']");
      expect(element).not.toBeNull();
      return element!;
    });
    // Viewer 外部 tailwind CSS 不可靠：关键蓝色必须以 inline style 兜底
    expect(chip.style.backgroundColor).not.toBe("");
    expect(chip.style.color).not.toBe("");
  });
});


describe("historical thread paging controls", () => {
  it("renders reading and restoring as separate phases", () => {
    const { getByTestId, rerender } = render(
      <Widget id="history-status" context={{ readingHistory: true } as Partial<ShinyConfigCtx>} />,
    );
    const widget = getByTestId("widget-history-status");
    expect(widget.querySelector("[data-slot='aui_history_reading']")?.textContent)
      .toContain("Loading history…");
    expect(widget.querySelector("[data-slot='aui_warming']")).toBeNull();

    rerender(
      <Widget id="history-status" context={{ warming: true } as Partial<ShinyConfigCtx>} />,
    );
    expect(widget.querySelector("[data-slot='aui_history_reading']")).toBeNull();
    // 新对话（无 resuming）显示冷启动文案
    expect(widget.querySelector("[data-slot='aui_warming']")?.textContent)
      .toContain("Starting Claude Code…");

    rerender(
      <Widget id="history-status" context={{ warming: true, warmingResuming: true } as Partial<ShinyConfigCtx>} />,
    );
    // 恢复历史（resuming）显示恢复文案
    expect(widget.querySelector("[data-slot='aui_warming']")?.getAttribute("data-resuming")).toBe("true");
    expect(widget.querySelector("[data-slot='aui_warming']")?.textContent)
      .toContain("Resuming Claude Code session…");
  });

  it("offers a top load-older control and guards repeated loads", () => {
    const loadOlderHistory = vi.fn();
    const { getByTestId } = render(
      <Widget
        id="history-more"
        context={{
          historyHasMore: true,
          loadingOlder: false,
          loadOlderHistory,
        } as Partial<ShinyConfigCtx>}
      />,
    );
    const widget = getByTestId("widget-history-more");
    const button = widget.querySelector<HTMLButtonElement>("[data-slot='aui_load_older']");
    expect(button).not.toBeNull();
    fireEvent.click(button!);
    expect(loadOlderHistory).toHaveBeenCalledTimes(1);
  });
});
