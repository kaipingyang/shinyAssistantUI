// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { render } from "@testing-library/react";
import { SyntaxHighlighter, resolveCodeLanguage } from "./syntax-highlighter";

const noComponents = { Pre: () => null, Code: () => null } as never;

describe("resolveCodeLanguage", () => {
  it("defaults unlabeled / unknown code blocks to markdown (neutral, not R)", () => {
    expect(resolveCodeLanguage("")).toBe("markdown");
    expect(resolveCodeLanguage(undefined)).toBe("markdown");
    expect(resolveCodeLanguage("unknown")).toBe("markdown");
    expect(resolveCodeLanguage("UNKNOWN")).toBe("markdown");
  });
  it("keeps an explicit language untouched", () => {
    expect(resolveCodeLanguage("python")).toBe("python");
    expect(resolveCodeLanguage("bash")).toBe("bash");
    expect(resolveCodeLanguage("json")).toBe("json");
  });
});

describe("markdown SyntaxHighlighter", () => {
  it("renders highlighted tokens for an R code block", () => {
    const { container } = render(
      <SyntaxHighlighter language="r" code={'x <- 1\nprint(x)'} components={noComponents} />,
    );
    const tokens = container.querySelectorAll("code span");
    expect(tokens.length).toBeGreaterThan(0);
    expect(container.textContent).toContain("print");
  });

  it("treats an unknown/unlabeled block as R and highlights it (no crash)", () => {
    const { container } = render(
      <SyntaxHighlighter language="unknown" code={'y <- 2\nprint(y)'} components={noComponents} />,
    );
    expect(container.querySelectorAll("code span").length).toBeGreaterThan(0);
    expect(container.textContent).toContain("print");
  });
});
