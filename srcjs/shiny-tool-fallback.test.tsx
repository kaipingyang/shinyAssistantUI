// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render } from "@testing-library/react";
import { ShinyToolFallback } from "./shiny-tool-fallback";
import { _clearToolCardStateForTests } from "./tool-ui/tool-card-frame";
import { registerApprovalHandler, _clearApprovalHandlers } from "./approval-registry";

afterEach(() => {
  cleanup();
  _clearApprovalHandlers();
});

const suggestions = [
  { type: "setMode", mode: "acceptEdits", destination: "session" },
  {
    type: "addRules",
    rules: [{ toolName: "Bash", ruleContent: "git status:*" }],
    behavior: "allow",
    destination: "session",
  },
];

function renderCard(inputId: string, toolCallId: string) {
  // ToolCallMessagePartComponent 只吃 props；用 any 绕过完整 part 类型。
  const props = {
    toolName: "Bash",
    toolCallId,
    argsText: "{}",
    args: { command: "git status" },
    result: undefined,
    status: { type: "requires-action" },
    artifact: { requiresApproval: true, inputId, suggestions },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any;
  return render(<ShinyToolFallback {...props} />);
}

describe("ShinyToolFallback approval — always-allow (multi-select) & deny feedback", () => {
  it("shows an 'Always allow…' toggle (suggestions hidden until opened)", () => {
    const { getByText, queryByText } = renderCard("chatA", "tc-labels");
    // 默认收起:建议标签不直接可见,只有 ▾ 触发器。
    expect(getByText(/Always allow/)).toBeTruthy();
    expect(queryByText("Always allow edits")).toBeNull();
    fireEvent.click(getByText(/Always allow/));
    // 展开后每条建议一个复选项,带人性化标签。
    expect(getByText("Always allow edits")).toBeTruthy();
    expect(getByText("Always allow Bash(git status:*)")).toBeTruthy();
  });

  it("checking one suggestion + Approve&remember sends suggestionIdxs=[i]", () => {
    const spy = vi.fn();
    registerApprovalHandler("chatA", spy);
    const { getByText, getByLabelText } = renderCard("chatA", "tc-one");
    fireEvent.click(getByText(/Always allow…/));
    fireEvent.click(getByLabelText("Always allow Bash(git status:*)"));
    fireEvent.click(getByText(/Approve & remember/));
    expect(spy).toHaveBeenCalledWith("tc-one", true, { suggestionIdxs: [1] });
  });

  it("checking multiple suggestions applies them all in one approve", () => {
    const spy = vi.fn();
    registerApprovalHandler("chatA", spy);
    const { getByText, getByLabelText } = renderCard("chatA", "tc-multi");
    fireEvent.click(getByText(/Always allow…/));
    fireEvent.click(getByLabelText("Always allow edits"));
    fireEvent.click(getByLabelText("Always allow Bash(git status:*)"));
    fireEvent.click(getByText(/Approve & remember/));
    expect(spy).toHaveBeenCalledWith("tc-multi", true, { suggestionIdxs: [0, 1] });
  });

  it("Approve & remember is disabled until at least one is checked", () => {
    const { getByText } = renderCard("chatA", "tc-disabled");
    fireEvent.click(getByText(/Always allow…/));
    const apply = getByText(/Approve & remember/).closest("button")!;
    expect(apply.disabled).toBe(true);
  });

  it("plain Approve sends approved=true with no opts", () => {
    const spy = vi.fn();
    registerApprovalHandler("chatA", spy);
    const { getByText } = renderCard("chatA", "tc-approve");
    fireEvent.click(getByText("Approve"));
    expect(spy).toHaveBeenCalledWith("tc-approve", true, undefined);
  });

  it("Deny & tell Claude sends approved=false with a customMessage", () => {
    const spy = vi.fn();
    registerApprovalHandler("chatA", spy);
    const { getByText, getByPlaceholderText } = renderCard("chatA", "tc-deny");
    fireEvent.click(getByText(/Deny & tell Claude/));
    fireEvent.change(getByPlaceholderText(/Tell Claude/), {
      target: { value: "use grep instead" },
    });
    fireEvent.click(getByText(/Send & deny/));
    expect(spy).toHaveBeenCalledWith("tc-deny", false, {
      customMessage: "use grep instead",
    });
  });

  it("Send & deny with empty text sends customMessage undefined", () => {
    const spy = vi.fn();
    registerApprovalHandler("chatA", spy);
    const { getByText } = renderCard("chatA", "tc-deny-empty");
    fireEvent.click(getByText(/Deny & tell Claude/));
    fireEvent.click(getByText(/Send & deny/));
    expect(spy).toHaveBeenCalledWith("tc-deny-empty", false, {
      customMessage: undefined,
    });
  });

  it("renders no 'Always allow' toggle when there are no suggestions", () => {
    const props = {
      toolName: "Bash",
      toolCallId: "tc-none",
      argsText: "{}",
      args: { command: "ls" },
      result: undefined,
      status: { type: "requires-action" },
      artifact: { requiresApproval: true, inputId: "chatA", suggestions: [] },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any;
    const { getByText, queryByText } = render(<ShinyToolFallback {...props} />);
    expect(getByText("Approve")).toBeTruthy();
    expect(queryByText(/Always allow/)).toBeNull();
  });
});


describe("ShinyToolFallback result viewport", () => {
  it("bounds long Bash/default results in one shared scroll container", () => {
    const result = Array.from({ length: 200 }, (_, index) => `line ${index + 1}`).join("\n");
    const props = {
      toolName: "Bash",
      toolCallId: "tc-long-result",
      argsText: '{"command":"seq 200"}',
      args: { command: "seq 200" },
      result,
      status: { type: "complete" },
      artifact: { defaultOpen: true },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any;

    const { container } = render(<ShinyToolFallback {...props} />);
    const viewport = container.querySelector('[data-slot="tool-result-scroll"]');
    expect(viewport).not.toBeNull();
    expect(viewport?.className).toContain("max-h-96");
    expect(viewport?.className).toContain("overflow-auto");
    expect(viewport?.textContent).toContain("line 200");
  });
});


describe("ShinyToolFallback persistent tool view state", () => {
  afterEach(() => _clearToolCardStateForTests());

  it("restores a Write Markdown preview scroll position after the card remounts", () => {
    const descriptor = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "scrollHeight");
    const clientDescriptor = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "clientHeight");
    Object.defineProperty(HTMLElement.prototype, "scrollHeight", { configurable: true, get: () => 1000 });
    Object.defineProperty(HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 100 });
    const props = {
      toolName: "Write",
      toolCallId: "write-md-scroll",
      argsText: "{}",
      args: { file_path: "report.md", content: "# Report\n\n" + "Paragraph\n\n".repeat(100) },
      result: "File written",
      status: { type: "complete" },
      artifact: { inputId: "chatA" },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any;

    try {
      const first = render(<ShinyToolFallback {...props} />);
      const firstPreview = first.container.querySelector<HTMLElement>("[data-markdown-preview=true]")!;
      expect(firstPreview).toBeTruthy();
      firstPreview.scrollTop = 900;
      fireEvent.scroll(firstPreview);
      first.unmount();

      const second = render(<ShinyToolFallback {...props} />);
      const secondPreview = second.container.querySelector<HTMLElement>("[data-markdown-preview=true]")!;
      expect(secondPreview).toBeTruthy();
      expect(secondPreview).not.toBe(firstPreview);
      expect(secondPreview.scrollTop).toBe(900);
      expect(second.container.querySelector('[data-slot="tool-fallback-trigger"]')?.getAttribute("aria-expanded"))
        .toBe("true");
    } finally {
      if (descriptor) Object.defineProperty(HTMLElement.prototype, "scrollHeight", descriptor);
      else delete (HTMLElement.prototype as any).scrollHeight;
      if (clientDescriptor) Object.defineProperty(HTMLElement.prototype, "clientHeight", clientDescriptor);
      else delete (HTMLElement.prototype as any).clientHeight;
    }
  });
});
