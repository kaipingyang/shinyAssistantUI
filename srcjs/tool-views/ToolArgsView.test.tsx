/** @vitest-environment jsdom */
import { cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
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
    const { container, getByText } = render(
      <ToolArgsView
        view={{
          kind: "questions",
          items: [
            {
              question: "Fav color?",
              multiSelect: false,
              options: [{ label: "Blue" }],
              answer: "Blue",
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

    expect(getByText("R, SQL")).toBeTruthy();
    const blue = container.querySelector('[data-question-option="Blue"]');
    const r = container.querySelector('[data-question-option="R"]');
    const sql = container.querySelector('[data-question-option="SQL"]');
    expect(blue?.getAttribute("data-question-selected")).toBe("true");
    expect(blue?.textContent).toContain("◉");
    expect(r?.getAttribute("data-question-selected")).toBe("true");
    expect(r?.textContent).toContain("☑");
    expect(sql).toBeNull();
  });
});


const clipboardWrite = vi.fn<(text: string) => Promise<void>>();
beforeEach(() => {
  clipboardWrite.mockReset();
  clipboardWrite.mockResolvedValue(undefined);
  Object.defineProperty(navigator, "clipboard", {
    configurable: true,
    value: { writeText: clipboardWrite },
  });
});

describe("ToolArgsView markdown", () => {
  const tableMarkdown = "# Plan\n\n| Step | State |\n| --- | --- |\n| Test | Ready |";

  it("renders a real GFM table in Preview and keeps Source prominent", async () => {
    const { container, getByRole } = render(
      <ToolArgsView view={{
        kind: "markdown",
        text: tableMarkdown,
        defaultMode: "preview",
        sourceControl: "prominent",
      } as never} />,
    );

    await waitFor(() => expect(container.querySelector("table")).not.toBeNull());
    expect(container.querySelector('[data-arg-view="markdown"]')).not.toBeNull();
    expect(getByRole("button", { name: "Source" }).getAttribute("data-prominent")).toBe("true");
    expect(container.querySelector('[data-markdown-source="true"]')).toBeNull();
  });

  it("toggles Preview/Source while preserving source byte-for-byte", async () => {
    const original = "# Heading\n\nline  \nwith trailing spaces\n";
    const { container, getByRole } = render(
      <ToolArgsView view={{
        kind: "markdown",
        text: original,
        defaultMode: "preview",
        sourceControl: "prominent",
      } as never} />,
    );

    fireEvent.click(getByRole("button", { name: "Source" }));
    const source = container.querySelector('[data-markdown-source="true"]')!;
    expect(source.textContent).toBe(original);
    expect(source.querySelector('[data-syntax-highlighter="prism"]')).not.toBeNull();
    expect(source.getAttribute("data-source-language")).toBe("markdown");
    fireEvent.click(getByRole("button", { name: "Preview" }));
    await waitFor(() => expect(container.querySelector("h1")?.textContent).toBe("Heading"));
  });

  it("defaults other text Write views to Source and offers Preview as Markdown", async () => {
    const text = "# Could be Markdown";
    const { container, getByRole } = render(
      <ToolArgsView view={{
        kind: "markdown",
        text,
        defaultMode: "source",
        sourceControl: "prominent",
      } as never} />,
    );

    expect(container.querySelector('[data-markdown-source="true"]')?.textContent).toBe(text);
    fireEvent.click(getByRole("button", { name: "Preview as Markdown" }));
    await waitFor(() => expect(container.querySelector("h1")?.textContent).toBe("Could be Markdown"));
  });

  it("copies the untouched original Markdown", () => {
    const original = "| a | b |\n| - | - |\n";
    const { getByRole } = render(
      <ToolArgsView view={{
        kind: "markdown",
        text: original,
        defaultMode: "preview",
        sourceControl: "subtle",
      } as never} />,
    );
    fireEvent.click(getByRole("button", { name: "Copy source" }));
    expect(clipboardWrite).toHaveBeenCalledWith(original);
  });

  it("does not execute or mount raw HTML from Preview", async () => {
    const { container } = render(
      <ToolArgsView view={{
        kind: "markdown",
        text: "# Safe\n\n<script>window.__toolViewPwned = true</script>",
        defaultMode: "preview",
        sourceControl: "subtle",
      } as never} />,
    );
    await waitFor(() => expect(container.querySelector("h1")).not.toBeNull());
    expect(container.querySelector("script")).toBeNull();
    expect((window as any).__toolViewPwned).toBeUndefined();
  });


  it("copies an empty source exactly", () => {
    const { getByRole } = render(
      <ToolArgsView view={{
        kind: "markdown",
        text: "",
        defaultMode: "source",
        sourceControl: "prominent",
      } as never} />,
    );
    fireEvent.click(getByRole("button", { name: "Copy source" }));
    expect(clipboardWrite).toHaveBeenCalledWith("");
  });
});


describe("ToolArgsView code and delimited tables", () => {
  it("renders known code through Prism and plain text without an unregistered grammar", () => {
    const python = render(
      <ToolArgsView view={{ kind: "code", code: "print(1)", lang: "python" } as never} />,
    );
    expect(python.container.querySelector('[data-arg-view="code"][data-arg-lang="python"]')).not.toBeNull();
    expect(python.container.querySelector('[data-syntax-highlighter="prism"]')).not.toBeNull();
    python.unmount();

    const plain = render(
      <ToolArgsView view={{ kind: "code", code: "literal source", lang: "text" } as never} />,
    );
    expect(plain.container.querySelector('[data-plain-source="true"]')?.textContent).toBe("literal source");
    expect(plain.container.querySelector('[data-syntax-highlighter]')).toBeNull();
  });

  it("renders a semantic CSV preview, keeps values inert, and toggles to exact Source", () => {
    const source = 'name,note\r\nAlice,"hello, world"\r\nFormula,=1+1\r\nHTML,<script>alert(1)</script>\r\n';
    const { container, getByRole, getByText } = render(
      <ToolArgsView view={{
        kind: "table",
        text: source,
        rows: [
          ["name", "note"],
          ["Alice", "hello, world"],
          ["Formula", "=1+1"],
          ["HTML", "<script>alert(1)</script>"],
        ],
        delimiter: "comma",
        truncatedRows: false,
        truncatedColumns: false,
        truncatedCells: false,
        fileName: "people.csv",
      } as never} />,
    );

    expect(container.querySelector('[data-arg-view="table"][data-table-format="csv"]')).not.toBeNull();
    expect(container.querySelector('[data-table-mode="preview"]')).not.toBeNull();
    expect(getByRole("columnheader", { name: "name" })).toBeTruthy();
    expect(getByText("hello, world")).toBeTruthy();
    expect(getByText("=1+1")).toBeTruthy();
    expect(container.querySelector("script")).toBeNull();

    fireEvent.click(getByRole("button", { name: "Source" }));
    expect(container.querySelector('[data-table-source="true"]')?.textContent).toBe(source);
    fireEvent.click(getByRole("button", { name: "Copy source" }));
    expect(clipboardWrite).toHaveBeenCalledWith(source);
  });

  it("shows honest empty and truncation states", () => {
    const truncated = render(
      <ToolArgsView view={{
        kind: "table",
        text: "a,b\n1,2",
        rows: [["a", "b"], ["1", "2"]],
        delimiter: "tab",
        truncatedRows: true,
        truncatedColumns: true,
        truncatedCells: true,
      } as never} />,
    );
    expect(truncated.container.querySelector('[data-table-format="tsv"]')).not.toBeNull();
    expect(truncated.container.querySelector('[data-table-truncation="true"]')?.textContent).toContain("limited");
    truncated.unmount();

    const empty = render(
      <ToolArgsView view={{
        kind: "table",
        text: "",
        rows: [],
        delimiter: "comma",
        truncatedRows: false,
        truncatedColumns: false,
        truncatedCells: false,
      } as never} />,
    );
    expect(empty.container.querySelector('[data-table-empty="true"]')).not.toBeNull();
  });
});
