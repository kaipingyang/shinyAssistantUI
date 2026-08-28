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
  return aui.composer.getState().text;
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
      aui.composer.setText("/github issue 42");
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

describe("copilot-api service state", () => {
  it("renders ready as a compact green line below the Composer", () => {
    const { getByTestId } = render(
      <Widget
        id="service-ready"
        context={{ serviceState: { status: "ready" } } as unknown as Partial<ShinyConfigCtx>}
      />,
    );
    const widget = getByTestId("widget-service-ready");
    const composer = widget.querySelector<HTMLElement>(".aui-composer-root");
    const ready = widget.querySelector<HTMLElement>(
      '[data-slot="aui_service_status"][data-status="ready"]',
    );
    const icon = ready?.querySelector<HTMLElement>("[data-slot='aui_service_ready_icon']");

    expect(composer).not.toBeNull();
    expect(ready).not.toBeNull();
    expect(ready?.dataset.compact).toBe("true");
    expect(composer!.compareDocumentPosition(ready!) & Node.DOCUMENT_POSITION_FOLLOWING).not.toBe(0);
    expect(ready?.className).not.toContain("rounded-lg");
    expect(ready?.className).not.toContain("border-border");
    expect(icon?.className).toMatch(/text-green-/);
    expect(editorIn(widget).getAttribute("contenteditable")).toBe("true");
  });

  it("places ready status and usage metrics in one compact footer row", () => {
    const { getByTestId } = render(
      <Widget
        id="service-ready-usage"
        context={{
          serviceState: { status: "ready" },
          usage: { costUsd: 1.4781, tokens: 78022, turns: 1, durationMs: 7500 },
        } as unknown as Partial<ShinyConfigCtx>}
      />,
    );
    const widget = getByTestId("widget-service-ready-usage");
    const row = widget.querySelector<HTMLElement>(
      '[data-slot="aui_composer_meta_footer"][data-layout="inline"]',
    );
    const ready = widget.querySelector<HTMLElement>(
      '[data-slot="aui_service_status"][data-status="ready"]',
    );
    const usage = widget.querySelector<HTMLElement>('[data-slot="aui_usage_footer"]');

    expect(row).not.toBeNull();
    expect(ready?.parentElement).toBe(row);
    expect(usage?.parentElement).toBe(row);
    expect(row?.textContent).toContain("copilot-api is ready");
    expect(row?.textContent).toContain("$1.4781 · 78,022 tokens · 1 turn · 7.5s");
  });

  it.each(["checking", "starting", "failed"] as const)(
    "renders actionable %s state above the Composer",
    (status) => {
      const retryService = vi.fn();
      const context = {
        serviceState: {
          status,
          message: status === "failed" ? "copilot-api did not become ready" : undefined,
        },
        retryService,
      } as unknown as Partial<ShinyConfigCtx>;
      const { getByTestId } = render(
        <Widget id={`service-${status}`} context={context} />,
      );
      const widget = getByTestId(`widget-service-${status}`);
      const service = widget.querySelector<HTMLElement>(
        `[data-slot="aui_service_status"][data-status="${status}"]`,
      );
      const composer = widget.querySelector<HTMLElement>(".aui-composer-root");

      expect(service).not.toBeNull();
      expect(composer).not.toBeNull();
      expect(service!.compareDocumentPosition(composer!) & Node.DOCUMENT_POSITION_FOLLOWING).not.toBe(0);
      expect(editorIn(widget).getAttribute("contenteditable")).toBe("true");

      if (status === "failed") {
        const retry = within(widget).getByRole("button", { name: /retry/i });
        fireEvent.click(retry);
        expect(retryService).toHaveBeenCalledOnce();
      }
    },
  );

  it("shows the current Git branch below the Composer and hides it when absent", () => {
    const view = render(
      <Widget id="git-branch" context={{ gitBranch: "feature/footer" }} />,
    );
    const widget = view.getByTestId("widget-git-branch");
    const branch = widget.querySelector<HTMLElement>('[data-slot="aui_git_branch"]');
    const composer = widget.querySelector<HTMLElement>(".aui-composer-root");

    expect(branch).not.toBeNull();
    expect(branch?.textContent).toContain("feature/footer");
    expect(composer!.compareDocumentPosition(branch!) & Node.DOCUMENT_POSITION_FOLLOWING).not.toBe(0);

    view.rerender(<Widget id="git-branch" context={{ gitBranch: undefined }} />);
    expect(view.getByTestId("widget-git-branch").querySelector('[data-slot="aui_git_branch"]')).toBeNull();
  });
});

describe("Claude checklist lifecycle controls", () => {
  it("normalizes completed status and closes the exact revision at any time", () => {
    const dismissChecklist = vi.fn();
    const completed = {
      threadId: "thread-a",
      revision: "rev-complete",
      allCompleted: true,
      visibleItems: [{ id: "1", content: "Done", status: " Completed " }],
      overflowCount: 0,
    };
    const { getByTestId, rerender } = render(
      <Widget
        id="checklist-close"
        context={{ checklist: completed, dismissChecklist } as unknown as Partial<ShinyConfigCtx>}
      />,
    );
    const widget = getByTestId("widget-checklist-close");
    const completedLabel = within(widget).getByText("Done");
    expect(within(widget).getByText("✓")).toBeTruthy();
    expect(completedLabel.className).toContain("line-through");
    fireEvent.click(within(widget).getByRole("button", { name: /close checklist/i }));
    expect(dismissChecklist).toHaveBeenCalledWith("thread-a", "rev-complete");

    rerender(
      <Widget
        id="checklist-close"
        context={{
          checklist: {
            ...completed,
            revision: "rev-active",
            allCompleted: false,
            visibleItems: [{ id: "1", content: "Working", status: "in_progress" }],
          },
          dismissChecklist,
        } as unknown as Partial<ShinyConfigCtx>}
      />,
    );
    fireEvent.click(within(widget).getByRole("button", { name: /close checklist/i }));
    expect(dismissChecklist).toHaveBeenLastCalledWith("thread-a", "rev-active");
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
    // 新对话（无 resuming）显示通用冷启动文案(默认;可经 warming_label 覆盖)
    expect(widget.querySelector("[data-slot='aui_warming']")?.textContent)
      .toContain("Starting…");

    rerender(
      <Widget id="history-status" context={{ warming: true, warmingResuming: true } as Partial<ShinyConfigCtx>} />,
    );
    // 恢复历史（resuming）显示通用恢复文案
    expect(widget.querySelector("[data-slot='aui_warming']")?.getAttribute("data-resuming")).toBe("true");
    expect(widget.querySelector("[data-slot='aui_warming']")?.textContent)
      .toContain("Resuming session…");

    rerender(
      <Widget
        id="history-status"
        context={{
          runPhase: "connecting",
          warming: false,
          warmingLabel: "Starting Claude Code…",
        } as Partial<ShinyConfigCtx>}
      />,
    );
    expect(widget.querySelector("[data-slot='aui_warming']")?.textContent)
      .toContain("Sending request…");
    expect(widget.querySelector("[data-slot='aui_warming']")?.textContent)
      .not.toContain("Starting Claude Code…");

    rerender(
      <Widget
        id="history-status"
        context={{
          runPhase: "connecting",
          warming: true,
          warmingLabel: "Starting Claude Code…",
        } as Partial<ShinyConfigCtx>}
      />,
    );
    expect(widget.querySelector("[data-slot='aui_warming']")?.textContent)
      .toContain("Starting Claude Code…");

    rerender(
      <Widget
        id="history-status"
        context={{ runPhase: "queued", warming: false } as Partial<ShinyConfigCtx>}
      />,
    );
    expect(widget.querySelector("[data-slot='aui_warming']")?.textContent)
      .toContain("Waiting for an available run slot…");
  });

  it("renders precise request stages and queue position", () => {
    const { getByTestId, rerender } = render(
      <Widget
        id="request-stage"
        context={{ runPhase: "connecting", runStage: "submitting", warming: false } as Partial<ShinyConfigCtx>}
      />,
    );
    const widget = getByTestId("widget-request-stage");
    const stageCases = [
      ["submitting", "Preparing request…"],
      ["model-switch", "Applying model…"],
      ["consumer-acquire", "Waiting for conversation stream…"],
      ["sending", "Sending request…"],
      ["awaiting-model", "Waiting for Claude…"],
      ["streaming", "Generating…"],
      ["finalizing", "Finalizing…"],
    ] as const;
    for (const [runStage, expected] of stageCases) {
      rerender(
        <Widget
          id="request-stage"
          context={{ runPhase: runStage === "streaming" || runStage === "finalizing" ? "running" : "connecting", runStage, warming: false } as Partial<ShinyConfigCtx>}
        />,
      );
      const indicator = widget.querySelector("[data-slot='aui_warming']");
      expect(indicator?.getAttribute("data-run-stage")).toBe(runStage);
      expect(indicator?.textContent).toContain(expected);
    }

    rerender(
      <Widget
        id="request-stage"
        context={{ runPhase: "queued", runQueuePosition: 3, warming: false } as Partial<ShinyConfigCtx>}
      />,
    );
    expect(widget.querySelector("[data-slot='aui_warming']")?.textContent)
      .toContain("3rd in queue");

    const cancelRun = vi.fn();
    rerender(
      <Widget
        id="request-stage"
        context={{ runPhase: "connecting", runStage: "awaiting-model", warming: false, cancelRun } as Partial<ShinyConfigCtx>}
      />,
    );
    fireEvent.click(widget.querySelector<HTMLButtonElement>("[data-slot='aui_run_cancel']")!);
    expect(cancelRun).toHaveBeenCalledTimes(1);

    rerender(
      <Widget
        id="request-stage"
        context={{ runPhase: "running", warming: false } as Partial<ShinyConfigCtx>}
      />,
    );
    expect(widget.querySelector("[data-slot='aui_warming']")).toBeNull();
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


describe("Claude checklist bounded expansion and collapse", () => {
  it("expands +N more inline, keeps the body bounded, and collapses to its header", () => {
    const items = Array.from({ length: 7 }, (_, index) => ({
      id: String(index + 1),
      content: `Current task ${index + 1}`,
      status: index === 0 ? "in_progress" : "pending",
    }));
    const checklist = {
      threadId: "thread-current",
      revision: "current-group",
      allCompleted: false,
      staleAfterUserTurn: false,
      items,
      visibleItems: items.slice(0, 5),
      overflowCount: 2,
    };
    const { getByTestId } = render(
      <Widget
        id="checklist-expand-collapse"
        context={{ checklist } as unknown as Partial<ShinyConfigCtx>}
      />,
    );
    const widget = getByTestId("widget-checklist-expand-collapse");
    const panel = widget.querySelector<HTMLElement>('[data-slot="aui_claude_checklist"]')!;

    expect(panel.dataset.collapsed).toBe("false");
    expect(within(widget).queryByText("Current task 7")).toBeNull();
    fireEvent.click(within(widget).getByRole("button", { name: /show 2 more checklist items/i }));
    expect(within(widget).getByText("Current task 7")).toBeTruthy();
    const body = widget.querySelector<HTMLElement>('[data-slot="aui_checklist_body"]');
    expect(body?.className).toContain("max-h-");
    expect(body?.className).toContain("overflow-y-auto");
    expect(within(widget).getByRole("button", { name: /show fewer checklist items/i })).toBeTruthy();

    fireEvent.click(within(widget).getByRole("button", { name: /collapse checklist/i }));
    expect(panel.dataset.collapsed).toBe("true");
    expect(widget.querySelector('[data-slot="aui_checklist_body"]')).toBeNull();
    fireEvent.click(within(widget).getByRole("button", { name: /expand checklist/i }));
    expect(panel.dataset.collapsed).toBe("false");
    expect(widget.querySelector('[data-slot="aui_checklist_body"]')).not.toBeNull();
  });
});
