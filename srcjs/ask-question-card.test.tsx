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
