// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { render } from "@testing-library/react";
import { SyntaxHighlighter } from "./syntax-highlighter";

const noComponents = { Pre: () => null, Code: () => null } as never;

describe("markdown SyntaxHighlighter", () => {
  it("renders highlighted tokens for an R code block", () => {
    const { container } = render(
      <SyntaxHighlighter language="r" code={'x <- 1\nprint(x)'} components={noComponents} />,
    );
    // Prism 生成的 token span（语法高亮已生效，而非纯文本）
    const tokens = container.querySelectorAll("code span");
    expect(tokens.length).toBeGreaterThan(0);
    expect(container.textContent).toContain("print");
  });

  it("falls back to text for unknown language without crashing", () => {
    const { container } = render(
      <SyntaxHighlighter language="" code={"plain text"} components={noComponents} />,
    );
    expect(container.textContent).toContain("plain text");
  });
});
