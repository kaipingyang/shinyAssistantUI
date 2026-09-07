import { describe, expect, it } from "vitest";
import { preprocessLatexMarkdown } from "./markdown-text";

describe("preprocessLatexMarkdown", () => {
  it("normalizes bracket delimiters and custom math tags", () => {
    expect(preprocessLatexMarkdown(String.raw`Inline \(x^2\) and \[y^2\]`))
      .toBe("Inline $x^2$ and $$y^2$$");
    expect(preprocessLatexMarkdown("[/inline]a+b[/inline]"))
      .toBe("$a+b$");
  });

  it("escapes currency without corrupting real math or code", () => {
    expect(preprocessLatexMarkdown("Costs $5 and $10; math $x^2$; code `$7`."))
      .toBe("Costs \\$5 and \\$10; math $x^2$; code `$7`.");
  });

  it("is stable for accumulated partial streaming text", () => {
    expect(preprocessLatexMarkdown(String.raw`partial \(x`))
      .toBe(String.raw`partial \(x`);
    expect(preprocessLatexMarkdown(String.raw`partial \(x\)`))
      .toBe("partial $x$");
  });
});
