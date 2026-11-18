/** @vitest-environment jsdom */
// Plan 165: Claude Code 2.1.3xx AskUserQuestion extended schema —
// top-level `title`, per-question `kind` (choice | text | number), `description`,
// text `placeholder`, number `min`/`max`/`step`/`defaultValue`/`unit`; plus the
// existing `metadata`/`annotations` input fields. Answers stay question → string.
import { cleanup, fireEvent, render } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { registerApprovalHandler, _clearApprovalHandlers } from "@/approval-registry";
import { parseAskUserQuestionArgs, parseAskUserQuestionInput } from "@/tool-views/ask-user-question-args";
import { resolveToolView } from "@/tool-views/resolve";
import { ToolArgsView } from "@/tool-views/ToolArgsView";
import { AskUserQuestionToolUI } from "./ask-user-question-tool";
import { _clearToolCardStateForTests } from "./tool-card-frame";

afterEach(() => {
  cleanup();
  _clearApprovalHandlers();
  _clearToolCardStateForTests();
});

const extended = {
  title: "Before I build your deck",
  questions: [
    { question: "What is the deck about?", header: "Topic", kind: "text",
      description: "One sentence is enough.", placeholder: "e.g. Q3 results" },
    { question: "How many slides?", header: "Length", kind: "number",
      min: 3, max: 20, step: 1, defaultValue: 8, unit: "slides" },
    { question: "Which style?", header: "Style", kind: "choice", multiSelect: false,
      options: [{ label: "Minimal" }, { label: "Bold", description: "Large type" }] },
  ],
  metadata: { source: "deck" },
};

function renderTool(args: unknown, inputId = "chat-ext", toolCallId = "ask-ext") {
  const props = {
    toolName: "AskUserQuestion",
    toolCallId,
    args,
    argsText: JSON.stringify(args),
    result: undefined,
    status: { type: "requires-action" },
    artifact: { requiresApproval: true, inputId, defaultOpen: true },
  } as never;
  return render(<AskUserQuestionToolUI {...props} />);
}

describe("parseAskUserQuestionInput (extended schema)", () => {
  it("accepts title, kinds, number bounds and metadata", () => {
    const parsed = parseAskUserQuestionInput(extended);
    expect(parsed?.title).toBe("Before I build your deck");
    expect(parsed?.items.map((item) => item.kind)).toEqual(["text", "number", "choice"]);
    expect(parsed?.items[0]).toMatchObject({ placeholder: "e.g. Q3 results", description: "One sentence is enough." });
    expect(parsed?.items[1]).toMatchObject({ min: 3, max: 20, step: 1, defaultValue: 8, unit: "slides" });
    expect(parseAskUserQuestionArgs(extended)?.length).toBe(3);
  });

  it("keeps old inputs working and defaults kind to choice", () => {
    const parsed = parseAskUserQuestionInput({
      questions: [{ question: "Pick?", multiSelect: false, options: [{ label: "A" }, { label: "B" }] }],
      annotations: { "Pick?": { notes: "x" } },
    });
    expect(parsed?.items[0]?.kind).toBe("choice");
    expect(parsed?.title).toBeUndefined();
  });

  it("rejects inputs that the CLI schema would reject", () => {
    const bad = [
      { questions: [{ question: "N?", kind: "number", min: 5, max: 5 }] },
      { questions: [{ question: "N?", kind: "number", min: 1, max: 9, defaultValue: 10 }] },
      { questions: [{ question: "T?", kind: "text", options: [{ label: "A" }, { label: "B" }] }] },
      { questions: [{ question: "T?", kind: "text", multiSelect: true }] },
      { questions: [{ question: "C?", kind: "choice", options: [{ label: "A" }] }] },
      { questions: [{ question: "C?", kind: "choice", placeholder: "x", options: [{ label: "A" }, { label: "B" }] }] },
      { questions: [{ question: "X?", kind: "slider", min: 1, max: 2 }] },
      { questions: [{ question: "N?", kind: "number", min: 1, max: 9, step: 0 }] },
      { title: 3, questions: [{ question: "T?", kind: "text" }] },
      { questions: [{ question: "T?", kind: "text", unknown: true }] },
    ];
    for (const input of bad) expect(parseAskUserQuestionInput(input), JSON.stringify(input)).toBeNull();
  });
});

describe("AskUserQuestionToolUI extended kinds", () => {
  it("renders the title, a text box, a number control and choices, then submits strings", () => {
    const decide = vi.fn();
    registerApprovalHandler("chat-ext", decide);
    const view = renderTool(extended);
    expect(view.container.querySelector("[data-ask-questions-invalid]")).toBeNull();
    expect(view.getByText("Before I build your deck")).toBeTruthy();
    expect(view.getByText("One sentence is enough.")).toBeTruthy();

    const text = view.getByLabelText("What is the deck about?") as HTMLTextAreaElement;
    expect(text.getAttribute("placeholder")).toBe("e.g. Q3 results");
    fireEvent.change(text, { target: { value: "Q3 results" } });

    const number = view.getByLabelText("How many slides?") as HTMLInputElement;
    expect(number.type).toBe("number");
    expect(number.min).toBe("3");
    expect(number.max).toBe("20");
    expect(number.value).toBe("8");
    expect(view.getByText("slides")).toBeTruthy();
    fireEvent.change(number, { target: { value: "12" } });

    fireEvent.click(view.getByLabelText(/Bold/));
    fireEvent.click(view.getByText("Submit answers"));
    expect(decide).toHaveBeenCalledExactlyOnceWith("ask-ext", true, {
      answers: { "What is the deck about?": "Q3 results", "How many slides?": "12", "Which style?": "Bold" },
    });
  });

  it("submits the default number when untouched and omits an empty text answer", () => {
    const decide = vi.fn();
    registerApprovalHandler("chat-default", decide);
    const view = renderTool({
      questions: [
        { question: "Notes?", header: "Notes", kind: "text" },
        { question: "Count?", header: "Count", kind: "number", min: 0, max: 10, defaultValue: 4 },
      ],
    }, "chat-default", "ask-default");
    fireEvent.click(view.getByText("Submit answers"));
    expect(decide).toHaveBeenCalledExactlyOnceWith("ask-default", true, { answers: { "Count?": "4" } });
  });

  it("keeps an out-of-range number from being submitted", () => {
    const decide = vi.fn();
    registerApprovalHandler("chat-range", decide);
    const view = renderTool({ questions: [{ question: "Count?", header: "Count", kind: "number", min: 1, max: 5 }] },
      "chat-range", "ask-range");
    const submit = view.getByText("Submit answer") as HTMLButtonElement;
    expect(submit.disabled).toBe(true);               // no default and nothing entered
    fireEvent.change(view.getByLabelText("Count?"), { target: { value: "9" } });
    expect(view.getByRole("alert").textContent).toMatch(/between 1 and 5/);
    expect(submit.disabled).toBe(true);
    fireEvent.change(view.getByLabelText("Count?"), { target: { value: "5" } });
    fireEvent.click(submit);
    expect(decide).toHaveBeenCalledExactlyOnceWith("ask-range", true, { answers: { "Count?": "5" } });
  });

  it("summarises text and number questions in the args view", () => {
    const view = render(<ToolArgsView view={resolveToolView("AskUserQuestion", extended, JSON.stringify(extended))} />);
    const kinds = [...view.container.querySelectorAll("[data-question-kind]")]
      .map((node) => node.getAttribute("data-question-kind"));
    expect(kinds).toEqual(["text", "number", "single"]);
    expect(view.getByText("Number 3 – 20 slides")).toBeTruthy();
    expect(view.getByText("One sentence is enough.")).toBeTruthy();
  });
});

describe("review follow-ups", () => {
  it("keeps legacy inputs lenient but applies the extended rules to explicit kinds", () => {
    const five = [1, 2, 3, 4, 5].map((n) => ({ label: `O${n}` }));
    expect(parseAskUserQuestionInput({ questions: [{ question: "Legacy?", options: five }] })).not.toBeNull();
    expect(parseAskUserQuestionInput({ questions: [{ question: "C?", header: "C", kind: "choice", options: five }] })).toBeNull();
    expect(parseAskUserQuestionInput({ questions: [{ question: "T?", kind: "text" }] })).toBeNull();          // header required
    expect(parseAskUserQuestionInput({ questions: [{ question: "T?", header: "T", kind: "text", multiSelect: false }] })).toBeNull();
    expect(parseAskUserQuestionInput({ questions: [{ question: "T?", header: "T", kind: "text" }] })).not.toBeNull();
  });

  it("validates number steps from min", () => {
    const decide = vi.fn();
    registerApprovalHandler("chat-step", decide);
    const view = renderTool({ questions: [{ question: "Odd?", header: "Odd", kind: "number", min: 3, max: 9, step: 2 }] },
      "chat-step", "ask-step");
    const input = view.getByLabelText("Odd?");
    fireEvent.change(input, { target: { value: "4" } });
    expect(view.getByRole("alert").textContent).toMatch(/steps of 2/);
    expect((view.getByText("Submit answer") as HTMLButtonElement).disabled).toBe(true);
    expect(input.getAttribute("aria-describedby")).toContain(view.getByRole("alert").id);
    fireEvent.change(input, { target: { value: "5" } });
    fireEvent.click(view.getByText("Submit answer"));
    expect(decide).toHaveBeenCalledExactlyOnceWith("ask-step", true, { answers: { "Odd?": "5" } });
  });

  it("groups choice options under their question for assistive technology", () => {
    const view = renderTool(extended, "chat-a11y", "ask-a11y");
    const group = view.getByRole("group", { name: /Which style\?/ });
    expect(group.firstElementChild?.tagName).toBe("LEGEND");
    expect(group.querySelectorAll("input[type=radio]").length).toBeGreaterThanOrEqual(2);
  });

  it("history marks every option of a comma-joined multi-select answer and keeps the title", () => {
    const args = {
      title: "Stack choices",
      questions: [{ question: "Which langs?", header: "Langs", kind: "choice", multiSelect: true,
        options: [{ label: "R" }, { label: "Python" }, { label: "Julia, Lang" }] }],
      answers: { "Which langs?": 'R, "Julia, Lang"' },
    };
    const view = render(<ToolArgsView view={resolveToolView("AskUserQuestion", args, JSON.stringify(args))} />);
    const selected = [...view.container.querySelectorAll("[data-question-selected=true]")]
      .map((node) => node.getAttribute("data-question-option"));
    expect(selected).toEqual(["R", "Julia, Lang"]);
    expect(view.container.querySelector("[data-question-title]")?.textContent).toBe("Stack choices");
  });

  it("decodes an unquoted comma answer as separate labels even when a joined label exists", () => {
    const args = {
      questions: [{ question: "Pick?", header: "Pick", kind: "choice", multiSelect: true,
        options: [{ label: "A" }, { label: "B" }, { label: "A, B" }] }],
      answers: { "Pick?": "A, B" },
    };
    const view = render(<ToolArgsView view={resolveToolView("AskUserQuestion", args, JSON.stringify(args))} />);
    const selected = [...view.container.querySelectorAll("[data-question-selected=true]")]
      .map((node) => node.getAttribute("data-question-option"));
    expect(selected).toEqual(["A", "B"]);
  });
});
