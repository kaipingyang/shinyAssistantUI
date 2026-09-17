import { describe, expect, it, vi } from "vitest";
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


describe("timedOwnedMarkdownPreprocess", () => {
  it("reports only the owned preprocessing call in integer microseconds", async () => {
    const { timedOwnedMarkdownPreprocess } = await import("./markdown-text");
    const report = vi.fn();
    const values = [10, 10.125];
    const result = timedOwnedMarkdownPreprocess("hello", (value) => value.toUpperCase(), report, () => values.shift()!);
    expect(result).toBe("HELLO");
    expect(report).toHaveBeenCalledWith(125);
  });

  it("does not rename timing as markdown render/commit and keeps preprocessing fail-open", async () => {
    const { timedOwnedMarkdownPreprocess } = await import("./markdown-text");
    const report = vi.fn(() => { throw new Error("telemetry unavailable"); });
    expect(timedOwnedMarkdownPreprocess("x", (value) => `${value}!`, report, () => 1)).toBe("x!");
    expect(report.mock.calls.flat().join(" ")).not.toMatch(/render|commit/i);
  });
});
