// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render } from "@testing-library/react";
import { AskQuestionCard } from "./ask-question-card";

afterEach(cleanup);

const questions = [
  { question: "Fav color?", header: "Color", multiSelect: false, options: [{ label: "Red" }, { label: "Blue" }] },
  { question: "Which langs?", header: "Langs", multiSelect: true, options: [{ label: "R" }, { label: "Python" }] },
];

describe("AskQuestionCard", () => {
  it("single-select returns a string; multi-select returns an array (keyed by question text)", () => {
    const onSubmit = vi.fn();
    const { getByLabelText, getByText } = render(
      <AskQuestionCard questions={questions} onSubmit={onSubmit} onSkip={() => {}} />,
    );
    fireEvent.click(getByLabelText("Blue"));
    fireEvent.click(getByLabelText("R"));
    fireEvent.click(getByLabelText("Python"));
    fireEvent.click(getByText(/Submit answer/));
    expect(onSubmit).toHaveBeenCalledWith({ "Fav color?": "Blue", "Which langs?": ["R", "Python"] });
  });

  it("single-select is exclusive (picking again replaces)", () => {
    const onSubmit = vi.fn();
    const { getByLabelText, getByText } = render(
      <AskQuestionCard questions={[questions[0]]} onSubmit={onSubmit} onSkip={() => {}} />,
    );
    fireEvent.click(getByLabelText("Red"));
    fireEvent.click(getByLabelText("Blue"));
    fireEvent.click(getByText(/Submit answer/));
    expect(onSubmit).toHaveBeenCalledWith({ "Fav color?": "Blue" });
  });

  it("free-text (Other) becomes the answer value", () => {
    const onSubmit = vi.fn();
    const { getByText, container } = render(
      <AskQuestionCard questions={[questions[0]]} onSubmit={onSubmit} onSkip={() => {}} />,
    );
    const custom = container.querySelector('[data-ask-custom="0"]') as HTMLInputElement;
    fireEvent.change(custom, { target: { value: "Teal" } });
    fireEvent.click(getByText(/Submit answer/));
    expect(onSubmit).toHaveBeenCalledWith({ "Fav color?": "Teal" });
  });

  it("Submit is disabled until at least one answer; Skip always works", () => {
    const onSubmit = vi.fn();
    const onSkip = vi.fn();
    const { getByText } = render(
      <AskQuestionCard questions={[questions[0]]} onSubmit={onSubmit} onSkip={onSkip} />,
    );
    const submit = getByText(/Submit answer/).closest("button")!;
    expect(submit.disabled).toBe(true);
    fireEvent.click(getByText(/Skip/));
    expect(onSkip).toHaveBeenCalled();
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it("unanswered questions are omitted from the payload", () => {
    const onSubmit = vi.fn();
    const { getByLabelText, getByText } = render(
      <AskQuestionCard questions={questions} onSubmit={onSubmit} onSkip={() => {}} />,
    );
    fireEvent.click(getByLabelText("Red")); // only answer Q1
    fireEvent.click(getByText(/Submit answer/));
    expect(onSubmit).toHaveBeenCalledWith({ "Fav color?": "Red" });
  });
});


  it("single-select switches from a preset option to Other custom text", () => {
    const onSubmit = vi.fn();
    const { getByLabelText, getByText, container } = render(
      <AskQuestionCard questions={[questions[0]]} onSubmit={onSubmit} onSkip={() => {}} />,
    );
    const blue = getByLabelText("Blue") as HTMLInputElement;
    const other = getByLabelText("Use custom answer for Fav color?") as HTMLInputElement;
    const custom = container.querySelector('[data-ask-custom="0"]') as HTMLInputElement;

    fireEvent.click(blue);
    fireEvent.focus(custom);
    fireEvent.change(custom, { target: { value: "Teal" } });

    expect(blue.checked).toBe(false);
    expect(other.checked).toBe(true);
    fireEvent.click(getByText(/Submit answer/));
    expect(onSubmit).toHaveBeenCalledWith({ "Fav color?": "Teal" });
  });

  it("single-select switches back from Other to a preset option", () => {
    const onSubmit = vi.fn();
    const { getByLabelText, getByText, container } = render(
      <AskQuestionCard questions={[questions[0]]} onSubmit={onSubmit} onSkip={() => {}} />,
    );
    const custom = container.querySelector('[data-ask-custom="0"]') as HTMLInputElement;
    fireEvent.focus(custom);
    fireEvent.change(custom, { target: { value: "Teal" } });
    fireEvent.click(getByLabelText("Blue"));

    expect((getByLabelText("Use custom answer for Fav color?") as HTMLInputElement).checked).toBe(false);
    fireEvent.click(getByText(/Submit answer/));
    expect(onSubmit).toHaveBeenCalledWith({ "Fav color?": "Blue" });
  });

  it("disables Submit when the only active custom answer is cleared", () => {
    const { getByText, container } = render(
      <AskQuestionCard questions={[questions[0]]} onSubmit={() => {}} onSkip={() => {}} />,
    );
    const custom = container.querySelector('[data-ask-custom="0"]') as HTMLInputElement;
    fireEvent.focus(custom);
    fireEvent.change(custom, { target: { value: "Teal" } });
    fireEvent.change(custom, { target: { value: "" } });
    expect((getByText(/Submit answer/).closest("button") as HTMLButtonElement).disabled).toBe(true);
  });

  it("multi-select adds an active custom answer to preset choices", () => {
    const onSubmit = vi.fn();
    const { getByLabelText, getByText, container } = render(
      <AskQuestionCard questions={[questions[1]]} onSubmit={onSubmit} onSkip={() => {}} />,
    );
    fireEvent.click(getByLabelText("R"));
    const custom = container.querySelector('[data-ask-custom="0"]') as HTMLInputElement;
    fireEvent.focus(custom);
    fireEvent.change(custom, { target: { value: "SQL" } });

    expect((getByLabelText("Use custom answer for Which langs?") as HTMLInputElement).checked).toBe(true);
    fireEvent.click(getByText(/Submit answer/));
    expect(onSubmit).toHaveBeenCalledWith({ "Which langs?": ["R", "SQL"] });
  });

  it("multi-select can uncheck Other without discarding typed text", () => {
    const onSubmit = vi.fn();
    const { getByLabelText, getByText, container } = render(
      <AskQuestionCard questions={[questions[1]]} onSubmit={onSubmit} onSkip={() => {}} />,
    );
    fireEvent.click(getByLabelText("R"));
    const custom = container.querySelector('[data-ask-custom="0"]') as HTMLInputElement;
    fireEvent.focus(custom);
    fireEvent.change(custom, { target: { value: "SQL" } });
    fireEvent.click(getByLabelText("Use custom answer for Which langs?"));

    expect(custom.value).toBe("SQL");
    fireEvent.click(getByText(/Submit answer/));
    expect(onSubmit).toHaveBeenCalledWith({ "Which langs?": ["R"] });
  });
