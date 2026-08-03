// @vitest-environment jsdom
// Plan 47 Phase B — PromptForm: generic param form (radio/select/slider/text/checkbox) driven by
// a fields spec, collecting {name: value} on submit. Mirrors AskQuestionCard's tested pattern.
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render } from "@testing-library/react";
import { PromptForm, type PromptField } from "@/generative/prompt-form";

afterEach(cleanup);

const fields: PromptField[] = [
  { name: "test", type: "radio", label: "Test", options: ["t-test", "ANOVA", "Wilcoxon"], default: "t-test" },
  { name: "viz", type: "select", label: "Plot", options: ["box", "violin"], default: "box" },
  { name: "alpha", type: "slider", label: "alpha", min: 0, max: 1, step: 0.01, default: 0.05 },
  { name: "note", type: "text", label: "Note", default: "" },
  { name: "log", type: "checkbox", label: "log-scale", default: false },
];

describe("PromptForm", () => {
  it("collects field values by name on submit (defaults + edits)", () => {
    const onSubmit = vi.fn();
    const { getByLabelText, getByText, container } = render(
      <PromptForm fields={fields} onSubmit={onSubmit} onSkip={() => {}} />,
    );
    fireEvent.click(getByLabelText("ANOVA")); // radio
    fireEvent.change(container.querySelector('[data-field="alpha"]')!, { target: { value: "0.1" } });
    fireEvent.change(container.querySelector('[data-field="note"]')!, { target: { value: "check outliers" } });
    fireEvent.click(container.querySelector('[data-field="log"]')!); // checkbox → true
    fireEvent.click(getByText(/Submit/));
    expect(onSubmit).toHaveBeenCalledWith({
      test: "ANOVA",
      viz: "box",
      alpha: 0.1,
      note: "check outliers",
      log: true,
    });
  });

  it("Skip fires onSkip, not onSubmit", () => {
    const onSubmit = vi.fn();
    const onSkip = vi.fn();
    const { getByText } = render(<PromptForm fields={fields} onSubmit={onSubmit} onSkip={onSkip} />);
    fireEvent.click(getByText(/Skip/));
    expect(onSkip).toHaveBeenCalled();
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it("submit is once-only (guards double-submit)", () => {
    const onSubmit = vi.fn();
    const { getByText } = render(<PromptForm fields={[fields[0]]} onSubmit={onSubmit} onSkip={() => {}} />);
    fireEvent.click(getByText(/Submit/));
    fireEvent.click(getByText(/Submit/));
    expect(onSubmit).toHaveBeenCalledTimes(1);
  });
});
