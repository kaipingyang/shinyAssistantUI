import { describe, expect, it } from "vitest";
import { projectPartialWriteArgs } from "./partial-tool-args";

describe("projectPartialWriteArgs", () => {
  it("projects Markdown path and a growing content string before JSON closes", () => {
    const first = projectPartialWriteArgs(
      '{"file_path":"report.md","content":"# Title\\n\\n- one',
    );
    expect(first).toEqual({
      file_path: "report.md",
      content: "# Title\n\n- one",
    });

    const second = projectPartialWriteArgs(
      '{"file_path":"report.md","content":"# Title\\n\\n- one\\n- two"}',
    );
    expect(second).toEqual({
      file_path: "report.md",
      content: "# Title\n\n- one\n- two",
    });
  });

  it("decodes escaped quotes, slashes, controls, and complete unicode", () => {
    expect(projectPartialWriteArgs(
      '{"file_path":"notes.md","content":"say \\\"hi\\\" \\\\ path\\t\\u00e9"}',
    )).toEqual({
      file_path: "notes.md",
      content: 'say "hi" \\ path\té',
    });
  });

  it("withholds split escapes and surrogate pairs until they are complete", () => {
    expect(projectPartialWriteArgs(
      '{"file_path":"emoji.md","content":"ok \\u00',
    )).toEqual({ file_path: "emoji.md", content: "ok " });

    expect(projectPartialWriteArgs(
      '{"file_path":"emoji.md","content":"ok \\uD83D',
    )).toEqual({ file_path: "emoji.md", content: "ok " });

    expect(projectPartialWriteArgs(
      '{"file_path":"emoji.md","content":"ok \\uD83D\\uDE00"}',
    )).toEqual({ file_path: "emoji.md", content: "ok 😀" });
  });

  it("skips unknown nested values and supports either target-field order", () => {
    expect(projectPartialWriteArgs(
      '{"metadata":{"nested":[1,{"x":"comma, brace }"}]},"content":"body","file_path":"x.md"}',
    )).toEqual({ file_path: "x.md", content: "body" });
  });

  it("returns only safely available top-level string fields", () => {
    expect(projectPartialWriteArgs('{"file_path":"draft')).toEqual({
      file_path: "draft",
    });
    expect(projectPartialWriteArgs('{"content":42,"file_path":"x.md"}')).toEqual({
      file_path: "x.md",
    });
    expect(projectPartialWriteArgs("not-json")).toEqual({});
  });
});
