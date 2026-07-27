// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render } from "@testing-library/react";
import { ShinyToolFallback } from "./shiny-tool-fallback";
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

describe("ShinyToolFallback approval — always-allow & deny feedback", () => {
  it("renders one Always-allow button per suggestion with human labels", () => {
    const { getByText } = renderCard("chatA", "tc-labels");
    expect(getByText("Always allow edits")).toBeTruthy();
    expect(getByText("Always allow Bash(git status:*)")).toBeTruthy();
  });

  it("clicking Always-allow sends approved=true with the suggestionIdx", () => {
    const spy = vi.fn();
    registerApprovalHandler("chatA", spy);
    const { getByText } = renderCard("chatA", "tc-always");
    fireEvent.click(getByText("Always allow Bash(git status:*)"));
    expect(spy).toHaveBeenCalledWith("tc-always", true, { suggestionIdx: 1 });
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

  it("renders no Always-allow button when there are no suggestions", () => {
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
