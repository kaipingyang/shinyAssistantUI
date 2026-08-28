/** @vitest-environment jsdom */
import { cleanup, fireEvent, render } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { registerApprovalHandler, _clearApprovalHandlers } from "@/approval-registry";
import { AskUserQuestionToolUI } from "./ask-user-question-tool";
import { _clearToolCardStateForTests } from "./tool-card-frame";

afterEach(() => {
  cleanup();
  _clearApprovalHandlers();
  _clearToolCardStateForTests();
});

function renderTool(args: unknown, result?: unknown, toolCallId = "ask-malformed", inputId = "chat-ask") {
  const props = {
    toolName: "AskUserQuestion",
    toolCallId,
    args,
    argsText: JSON.stringify(args),
    result,
    status: result === undefined ? { type: "requires-action" } : { type: "complete" },
    artifact: {
      requiresApproval: result === undefined,
      inputId,
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

    const trigger = container.querySelector('[data-slot="tool-fallback-trigger"]')!;
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    expect(container.querySelector('[data-args-format="json"]')).toBeNull();
    expect(container.querySelector('[data-ask-questions-invalid]')).not.toBeNull();
    expect(getByText(/Unable to display these questions/)).toBeTruthy();
    fireEvent.click(trigger);
    expect(container.querySelector('[data-args-format="json"]')).not.toBeNull();
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

    const trigger = container.querySelector('[data-slot="tool-fallback-trigger"]')!;
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    fireEvent.click(trigger);
    expect(container.querySelector('[data-arg-view="questions"]')).not.toBeNull();
    expect(container.querySelector('[data-slot="ask-user-question"]')).toBeNull();
    expect(getByText("Answer:")).toBeTruthy();
    expect(getByText("Teal")).toBeTruthy();
  });

  it("keeps the pending card collapsed while choices remain operable, then permits manual reopen", () => {
    const decide = vi.fn();
    registerApprovalHandler("chat-settle", decide);
    const args = {
      questions: [{ question: "Continue?", options: [{ label: "Yes" }] }],
    };
    const view = renderTool(args, undefined, "ask-settle", "chat-settle");
    const trigger = view.container.querySelector('[data-slot="tool-fallback-trigger"]')!;

    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    expect(view.container.querySelector('[data-slot="ask-user-question"]')).not.toBeNull();
    fireEvent.click(trigger);
    expect(trigger.getAttribute("aria-expanded")).toBe("true");
    fireEvent.click(view.getByLabelText("Yes"));
    fireEvent.click(view.getByText("Submit answer"));
    expect(trigger.getAttribute("aria-expanded")).toBe("false");

    fireEvent.click(trigger);
    expect(trigger.getAttribute("aria-expanded")).toBe("true");
    expect(view.container.querySelector('[data-question-option="Yes"]')?.getAttribute("data-question-selected"))
      .toBe("true");
  });

  it("closes once after skip and can be reopened", () => {
    const decide = vi.fn();
    registerApprovalHandler("chat-skip", decide);
    const args = {
      questions: [{ question: "Continue?", options: [{ label: "Yes" }] }],
    };
    const view = renderTool(args, undefined, "ask-skip", "chat-skip");
    const trigger = view.container.querySelector('[data-slot="tool-fallback-trigger"]')!;
    fireEvent.click(view.getByText("Skip"));
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    fireEvent.click(trigger);
    expect(trigger.getAttribute("aria-expanded")).toBe("true");
  });

  it("keeps submitted options visibly selected in the tool record and across remount", () => {
    const decide = vi.fn();
    registerApprovalHandler("chat-live", decide);
    const args = {
      questions: [{
        question: "Which langs?",
        multiSelect: true,
        options: [{ label: "R" }, { label: "Python" }],
      }],
    };

    const first = renderTool(args, undefined, "ask-live-selection", "chat-live");
    fireEvent.click(first.getByLabelText("R"));
    fireEvent.click(first.getByText("Submit answer"));

    expect(decide).toHaveBeenCalledWith("ask-live-selection", true, {
      answers: { "Which langs?": ["R"] },
    });
    expect(first.container.querySelector('[data-slot="ask-user-question"]')).toBeNull();
    const firstTrigger = first.container.querySelector('[data-slot="tool-fallback-trigger"]')!;
    expect(firstTrigger.getAttribute("aria-expanded")).toBe("false");
    fireEvent.click(firstTrigger);
    const selected = first.container.querySelector('[data-question-option="R"]');
    expect(selected?.getAttribute("data-question-selected")).toBe("true");
    expect(selected?.textContent).toContain("☑");
    first.unmount();

    const restored = renderTool(args, "Answers submitted", "ask-live-selection", "chat-live");
    expect(restored.container.querySelector('[data-question-option="R"]')?.getAttribute("data-question-selected")).toBe("true");
    restored.unmount();

    const isolated = renderTool(args, "Answers submitted", "ask-other", "chat-live");
    const isolatedTrigger = isolated.container.querySelector('[data-slot="tool-fallback-trigger"]')!;
    expect(isolatedTrigger.getAttribute("aria-expanded")).toBe("false");
    fireEvent.click(isolatedTrigger);
    expect(isolated.container.querySelector('[data-question-option="R"]')?.getAttribute("data-question-selected")).toBe("false");
  });

});
