/** @vitest-environment jsdom */
import { cleanup, render } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { ToolArgsView } from "./ToolArgsView";

afterEach(cleanup);

describe("ToolArgsView questions", () => {
  it("renders a readable question summary instead of JSON", () => {
    const { container, getByText } = render(
      <ToolArgsView
        view={{
          kind: "questions",
          items: [{
            header: "Color",
            question: "Fav color?",
            multiSelect: false,
            options: [
              { label: "Red", description: "Warm" },
              { label: "Blue" },
            ],
          }],
        } as never}
      />,
    );

    expect(container.querySelector('[data-arg-view="questions"]')).not.toBeNull();
    expect(container.querySelector('[data-args-format="json"]')).toBeNull();
    expect(getByText("Fav color?")).toBeTruthy();
    expect(getByText("Single choice")).toBeTruthy();
    expect(getByText("Red")).toBeTruthy();
    expect(getByText("Warm")).toBeTruthy();
  });
});


describe("ToolArgsView historical AskUserQuestion answers", () => {
  it("renders single and multiple submitted answers readably", () => {
    const { getByText } = render(
      <ToolArgsView
        view={{
          kind: "questions",
          items: [
            {
              question: "Fav color?",
              multiSelect: false,
              options: [{ label: "Blue" }],
              answer: "Teal",
            },
            {
              question: "Which langs?",
              multiSelect: true,
              options: [{ label: "R" }],
              answer: ["R", "SQL"],
            },
          ],
        } as never}
      />,
    );

    expect(getByText("Teal")).toBeTruthy();
    expect(getByText("R, SQL")).toBeTruthy();
  });
});
