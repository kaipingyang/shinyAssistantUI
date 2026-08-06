/** @vitest-environment jsdom */
import { cleanup, fireEvent, render } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { registerApprovalHandler, _clearApprovalHandlers } from "@/approval-registry";
import { AskUserQuestionToolUI } from "./ask-user-question-tool";

afterEach(() => {
  cleanup();
  _clearApprovalHandlers();
});

function renderTool(args: unknown, result?: unknown) {
  const props = {
    toolName: "AskUserQuestion",
    toolCallId: "ask-malformed",
    args,
    argsText: JSON.stringify(args),
    result,
    status: result === undefined ? { type: "requires-action" } : { type: "complete" },
    artifact: {
      requiresApproval: result === undefined,
      inputId: "chat-ask",
      defaultOpen: true,
      ...(result === undefined ? {} : { approvalResult: "approved" }),
    },
  } as never;
  return render(<AskUserQuestionToolUI {...props} />);
}

describe("AskUserQuestionToolUI runtime validation", () => {
  it("falls back safely for malformed questions and still lets the user skip", () => {
    const decide = vi.fn();
    registerApprovalHandler("chat-ask", decide);

    const { container, getByText } = renderTool({ questions: "bad" });

    expect(container.querySelector('[data-args-format="json"]')).not.toBeNull();
    expect(container.querySelector('[data-ask-questions-invalid]')).not.toBeNull();
    expect(getByText(/Unable to display these questions/)).toBeTruthy();
    fireEvent.click(getByText("Skip"));
    expect(decide).toHaveBeenCalledWith("ask-malformed", false, {
      customMessage: "Skipped invalid AskUserQuestion payload",
    });
  });

  it("renders historical answers without restoring the interactive form", () => {
    const args = {
      questions: [{ question: "Fav color?", options: [{ label: "Blue" }] }],
      answers: { "Fav color?": "Teal" },
    };
    const { container, getByText } = renderTool(args, "Answers submitted");

    expect(container.querySelector('[data-arg-view="questions"]')).not.toBeNull();
    expect(container.querySelector('[data-slot="ask-user-question"]')).toBeNull();
    expect(getByText("Answer:")).toBeTruthy();
    expect(getByText("Teal")).toBeTruthy();
  });
});
