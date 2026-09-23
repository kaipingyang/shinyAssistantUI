// @vitest-environment jsdom
import { render } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ShinyToolResult } from "./shiny-tool-result";

const renderResult = (
  result: unknown,
  resultType = "auto",
  resultLang = "text",
  isError = false,
) => render(
  <ShinyToolResult
    result={result}
    resultType={resultType}
    resultLang={resultLang}
    isError={isError}
  />,
);

describe("ShinyToolResult auto renderer", () => {
  it("shares the scoped web-link palette and retains URL filtering in Markdown results", () => {
    const view = renderResult("[Docs](https://example.invalid/docs) [Unsafe](javascript:bad)", "markdown");
    const link = view.getByRole("link", { name: "Docs" });
    expect(link.className).toContain("aui-web-link");
    expect(link.className).not.toMatch(/text-primary/);
    expect(link.getAttribute("rel")).toBe("noopener noreferrer");
    expect(view.queryByRole("link", { name: "Unsafe" })).toBeNull();
    view.unmount();
  });

  it("reuses the JSON highlighter for object and array results", () => {
    for (const result of [{ query: "Shanghai", count: 2 }, [{ id: 1 }]]) {
      const { container, unmount } = renderResult(result);
      expect(container.querySelector('[data-result-view="json"]')).not.toBeNull();
      expect(container.querySelector('[data-syntax-highlighter="prism-json"]')).not.toBeNull();
      expect(container.querySelector('[data-result-view="console"]')).toBeNull();
      unmount();
    }
  });

  it("recognizes complete JSON object strings but leaves scalar and ordinary text alone", () => {
    const json = renderResult('{"query":"Shanghai","results":[]}');
    expect(json.container.querySelector('[data-result-view="json"]')?.textContent)
      .toContain('"query"');
    json.unmount();

    for (const text of ["42", '"plain JSON scalar"', "Search completed", "{partial"] ) {
      const plain = renderResult(text);
      expect(plain.container.querySelector('[data-result-view="console"]')?.textContent)
        .toBe(text);
      expect(plain.container.querySelector('[data-result-view="json"]')).toBeNull();
      plain.unmount();
    }
  });

  it("keeps explicit result types and errors authoritative", () => {
    const markdown = renderResult("**complete**", "markdown");
    expect(markdown.container.querySelector("strong")?.textContent).toBe("complete");
    expect(markdown.container.querySelector('[data-result-view="json"]')).toBeNull();
    markdown.unmount();

    const explicitCode = renderResult('{"ok":true}', "code", "json");
    expect(explicitCode.container.querySelector('[data-syntax-highlighter="prism-json"]')).toBeNull();
    expect(explicitCode.container.querySelector("code")).not.toBeNull();
    explicitCode.unmount();

    const error = renderResult({ error: "boom" }, "auto", "text", true);
    expect(error.container.querySelector('[data-result-view="console"]')?.className)
      .toContain("text-destructive");
    expect(error.container.querySelector('[data-result-view="json"]')).toBeNull();
  });
});
