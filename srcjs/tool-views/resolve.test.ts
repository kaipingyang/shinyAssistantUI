import { describe, expect, it } from "vitest";
import { resolveToolView, langFromFileName } from "./resolve";

const at = (o: unknown) => JSON.stringify(o);

describe("langFromFileName", () => {
  it("maps known extensions to registered prism langs", () => {
    expect(langFromFileName("app.R")).toBe("r");
    expect(langFromFileName("script.py")).toBe("python");
    expect(langFromFileName("q.sql")).toBe("sql");
    expect(langFromFileName("a.ts")).toBe("typescript");
  });
  it("falls back to markdown for unknown / missing extension", () => {
    expect(langFromFileName("notes.txt")).toBe("markdown");
    expect(langFromFileName("Makefile")).toBe("markdown");
    expect(langFromFileName(undefined)).toBe("markdown");
  });
});

describe("resolveToolView", () => {
  it("Edit -> diff", () => {
    const args = { file_path: "a.R", old_string: "x<-1", new_string: "x<-2" };
    const v = resolveToolView("Edit", args, at(args));
    expect(v.kind).toBe("diff");
    if (v.kind === "diff") {
      expect(v.oldContent).toBe("x<-1");
      expect(v.newContent).toBe("x<-2");
      expect(v.fileName).toBe("a.R");
    }
  });

  it("MultiEdit -> diff", () => {
    const args = { file_path: "a.R", edits: [{ old_string: "a", new_string: "b" }] };
    const v = resolveToolView("MultiEdit", args, at(args));
    expect(v.kind).toBe("diff");
  });

  it("Bash -> code (bash) using command", () => {
    const args = { command: "ls -la", description: "list" };
    const v = resolveToolView("Bash", args, at(args));
    expect(v).toMatchObject({ kind: "code", lang: "bash", code: "ls -la" });
  });

  it("Write -> code with lang by extension", () => {
    const args = { file_path: "f.py", content: "print(1)" };
    const v = resolveToolView("Write", args, at(args));
    expect(v).toMatchObject({ kind: "code", lang: "python", code: "print(1)", fileName: "f.py" });
  });

  it("run_r MCP tool -> code (r) using code arg", () => {
    const args = { code: "x <- 1\nmean(x)" };
    const v = resolveToolView("mcp__r_session__run_r", args, at(args));
    expect(v).toMatchObject({ kind: "code", lang: "r", code: "x <- 1\nmean(x)" });
  });

  it("annotations.argsView (code) is the extension point", () => {
    const args = { sql: "SELECT 1" };
    const v = resolveToolView("mcp__db__query", args, at(args), {
      argsView: { kind: "code", field: "sql", lang: "sql" },
    });
    expect(v).toMatchObject({ kind: "code", lang: "sql", code: "SELECT 1" });
  });

  it("annotations.argsView overrides built-in tool rules (priority)", () => {
    const args = { command: "ls", note: "custom" };
    const v = resolveToolView("Bash", args, at(args), {
      argsView: { kind: "code", field: "note", lang: "markdown" },
    });
    expect(v).toMatchObject({ kind: "code", lang: "markdown", code: "custom" });
  });

  it("unknown tool -> json", () => {
    const args = { foo: 1, bar: [2, 3] };
    const v = resolveToolView("SomethingElse", args, at(args));
    expect(v.kind).toBe("json");
    if (v.kind === "json") expect(v.raw).toBe(false);
  });

  it("falls back to json when the expected field is missing/non-string", () => {
    const args = { command: 42 };
    const v = resolveToolView("Bash", args, at(args));
    expect(v.kind).toBe("json");
  });

  it("scalar argsText -> json raw", () => {
    const v = resolveToolView("Weird", "just a string", '"just a string"');
    expect(v).toMatchObject({ kind: "json", raw: true });
  });
});
