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
  it("falls back to plain text for unknown / missing extension", () => {
    expect(langFromFileName("notes.txt")).toBe("text");
    expect(langFromFileName("Makefile")).toBe("text");
    expect(langFromFileName(undefined)).toBe("text");
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

  it("Edit diff picks up annotations.diffStartLine (real file line numbers)", () => {
    const args = { file_path: "a.R", old_string: "x<-1", new_string: "x<-2" };
    const v = resolveToolView("Edit", args, at(args), { diffStartLine: 42 });
    expect(v.kind).toBe("diff");
    if (v.kind === "diff") expect(v.startLine).toBe(42);
  });

  it("diff startLine is undefined without the annotation", () => {
    const args = { file_path: "a.R", old_string: "x<-1", new_string: "x<-2" };
    const v = resolveToolView("Edit", args, at(args));
    if (v.kind === "diff") expect(v.startLine).toBeUndefined();
  });

  it("Bash -> code (bash) using command", () => {
    const args = { command: "ls -la", description: "list" };
    const v = resolveToolView("Bash", args, at(args));
    expect(v).toMatchObject({ kind: "code", lang: "bash", code: "ls -la" });
  });

  it.each([
    ["f.py", "print(1)", "python"],
    ["analysis.R", "x <- 1", "r"],
    ["app.ts", "const x = 1", "typescript"],
    ["config.yaml", "key: value", "yaml"],
  ])("Write code %s -> syntax-highlighted code view", (fileName, content, lang) => {
    const args = { file_path: fileName, content };
    expect(resolveToolView("Write", args, at(args))).toMatchObject({
      kind: "code",
      code: content,
      lang,
      fileName,
    });
  });

  it.each(["README", "payload.bin", "book.xlsx"])(
    "Write unknown/plain %s -> inert text code view without Markdown preview",
    (fileName) => {
      const args = { file_path: fileName, content: "# literal" };
      expect(resolveToolView("Write", args, at(args))).toMatchObject({
        kind: "code",
        code: args.content,
        lang: "text",
        fileName,
      });
    },
  );

  it("Write CSV parses RFC 4180 quoting while preserving exact source", () => {
    const content = 'name,note,blank\r\nAlice,"hello, ""world""",\r\nBob,"line 1\nline 2",x\r\n';
    const args = { file_path: "nested/PEOPLE.CSV", content };
    const view = resolveToolView("Write", args, at(args));
    expect(view.kind).toBe("table");
    if (view.kind === "table") {
      expect(view).toMatchObject({
        text: content,
        delimiter: "comma",
        fileName: args.file_path,
        truncatedRows: false,
        truncatedColumns: false,
        truncatedCells: false,
      });
      expect(view.rows).toEqual([
        ["name", "note", "blank"],
        ["Alice", 'hello, "world"', ""],
        ["Bob", "line 1\nline 2", "x"],
      ]);
    }
  });

  it("Write TSV parses tabs independently from commas", () => {
    const content = "name\tnote\nAlice\thello, world\n";
    const args = { path: "C:\\data\\people.tsv", content };
    const view = resolveToolView("Write", args, at(args));
    expect(view.kind).toBe("table");
    if (view.kind === "table") {
      expect(view.delimiter).toBe("tab");
      expect(view.rows).toEqual([["name", "note"], ["Alice", "hello, world"]]);
      expect(view.text).toBe(content);
    }
  });

  it("bounded table preview reports row, column and cell truncation", () => {
    const header = Array.from({ length: 31 }, (_, i) => `c${i}`).join(",");
    const longCell = "x".repeat(501);
    const content = [header, `${longCell},value`, ...Array.from({ length: 100 }, (_, i) => `${i},v`)].join("\n");
    const args = { file_path: "large.csv", content };
    const view = resolveToolView("Write", args, at(args));
    expect(view.kind).toBe("table");
    if (view.kind === "table") {
      expect(view.rows).toHaveLength(100);
      expect(view.rows[0]).toHaveLength(30);
      expect(view.rows[1][0]).toHaveLength(501);
      expect(view.rows[1][0].endsWith("…")).toBe(true);
      expect(view).toMatchObject({
        truncatedRows: true,
        truncatedColumns: true,
        truncatedCells: true,
      });
      expect(view.text).toBe(content);
    }
  });

  it("does not truncate at exact table limits", () => {
    const header = Array.from({ length: 30 }, (_, i) => `c${i}`).join(",");
    const exactCell = "x".repeat(500);
    const row = [exactCell, ...Array.from({ length: 29 }, () => "v")].join(",");
    const content = [header, row, ...Array.from({ length: 98 }, (_, i) => `${i},v`)].join("\n");
    const args = { file_path: "exact.csv", content };
    const view = resolveToolView("Write", args, at(args));
    expect(view.kind).toBe("table");
    if (view.kind === "table") {
      expect(view.rows).toHaveLength(100);
      expect(view.rows[0]).toHaveLength(30);
      expect(view.rows[1][0]).toBe(exactCell);
      expect(view).toMatchObject({
        truncatedRows: false,
        truncatedColumns: false,
        truncatedCells: false,
      });
    }
  });

  it("counts Unicode code points without splitting surrogate pairs", () => {
    const exact = `${"a".repeat(499)}😀`;
    const over = `${exact}b`;
    const content = `value\n"${exact}"\n"${over}"`;
    const args = { file_path: "unicode.csv", content };
    const view = resolveToolView("Write", args, at(args));
    expect(view.kind).toBe("table");
    if (view.kind === "table") {
      expect(view.rows[1][0]).toBe(exact);
      expect(view.rows[2][0]).toBe(`${exact}…`);
      expect(Array.from(view.rows[2][0].slice(0, -1))).toHaveLength(500);
      expect(/[\uD800-\uDFFF]/u.test(Array.from(view.rows[2][0]).filter((c) => c.length === 1).join(""))).toBe(false);
      expect(view.truncatedCells).toBe(true);
    }
  });

  it("explicit Markdown annotation overrides CSV built-in classification", () => {
    const args = { file_path: "data.csv", content: "# explicitly markdown" };
    expect(resolveToolView("Write", args, at(args), {
      argsView: { kind: "markdown", defaultMode: "preview" },
    })).toMatchObject({ kind: "markdown", text: args.content });
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

  it("TodoWrite -> todos checklist", () => {
    const args = { todos: [
      { content: "write tests", status: "completed", activeForm: "writing tests" },
      { content: "ship it", status: "pending", activeForm: "shipping" },
    ] };
    const v = resolveToolView("TodoWrite", args, at(args));
    expect(v.kind).toBe("todos");
    if (v.kind === "todos") {
      expect(v.items).toHaveLength(2);
      expect(v.items[0]).toMatchObject({ content: "write tests", status: "completed" });
      expect(v.items[1].status).toBe("pending");
    }
  });

  it("Grep -> query with pattern/path fields", () => {
    const args = { pattern: "TODO", path: "src", output_mode: "content" };
    const v = resolveToolView("Grep", args, at(args));
    expect(v.kind).toBe("query");
    if (v.kind === "query") {
      const labels = v.fields.map((f) => f.label);
      expect(labels).toContain("pattern");
      expect(v.fields.find((f) => f.label === "pattern")?.value).toBe("TODO");
    }
  });

  it("WebFetch -> query with url as href + prompt", () => {
    const args = { url: "https://example.com/x", prompt: "summarize" };
    const v = resolveToolView("WebFetch", args, at(args));
    expect(v.kind).toBe("query");
    if (v.kind === "query") {
      const url = v.fields.find((f) => f.label === "url");
      expect(url?.href).toBe("https://example.com/x");
      expect(v.fields.some((f) => f.label === "prompt")).toBe(true);
    }
  });

  it("WebSearch -> query with query field", () => {
    const args = { query: "r shiny htmlwidget" };
    const v = resolveToolView("WebSearch", args, at(args));
    expect(v).toMatchObject({ kind: "query" });
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


  it("AskUserQuestion -> structured questions instead of raw JSON", () => {
    const args = { questions: [
      {
        question: "Fav color?",
        header: "Color",
        multiSelect: false,
        options: [
          { label: "Red", description: "Warm" },
          { label: "Blue" },
        ],
      },
      {
        question: "Which langs?",
        multiSelect: true,
        options: [{ label: "R" }, { label: "Python" }],
      },
    ] };
    const v = resolveToolView("AskUserQuestion", args, at(args));
    expect(v.kind).toBe("questions");
    if (v.kind === "questions") {
      expect(v.items).toHaveLength(2);
      expect(v.items[0]).toMatchObject({
        header: "Color",
        question: "Fav color?",
        multiSelect: false,
        options: [{ label: "Red", description: "Warm" }, { label: "Blue" }],
      });
      expect(v.items[1].multiSelect).toBe(true);
    }
  });

  it("AskUserQuestion with empty/malformed questions falls back to JSON", () => {
    expect(resolveToolView("AskUserQuestion", { questions: [] }, '{"questions":[]}').kind).toBe("json");
    expect(resolveToolView("AskUserQuestion", { questions: [{ question: 42 }] }, '{"questions":[{"question":42}]}').kind).toBe("json");
  });


  it("AskUserQuestion preserves submitted answers in the structured history view", () => {
    const args = {
      questions: [
        { question: "Fav color?", options: [{ label: "Blue" }] },
        { question: "Which langs?", multiSelect: true, options: [{ label: "R" }] },
      ],
      answers: { "Fav color?": "Teal", "Which langs?": ["R", "SQL"] },
    };
    const v = resolveToolView("AskUserQuestion", args, at(args));
    expect(v.kind).toBe("questions");
    if (v.kind === "questions") {
      expect(v.items[0].answer).toBe("Teal");
      expect(v.items[1].answer).toEqual(["R", "SQL"]);
    }
  });

  it("AskUserQuestion with unknown fields falls back to JSON instead of hiding data", () => {
    const topLevelExtra = {
      questions: [{ question: "Continue?", options: [{ label: "Yes" }] }],
      futureMetadata: { source: "new-sdk" },
    };
    const questionExtra = {
      questions: [{ question: "Continue?", futureField: true, options: [{ label: "Yes" }] }],
    };
    expect(resolveToolView("AskUserQuestion", topLevelExtra, at(topLevelExtra)).kind).toBe("json");
    expect(resolveToolView("AskUserQuestion", questionExtra, at(questionExtra)).kind).toBe("json");
  });


describe("resolveToolView markdown views", () => {
  it("explicit markdown annotation has highest priority and supports a custom field", () => {
    const args = { command: "echo ignored", document: "# Annotated" };
    const view = resolveToolView("Bash", args, at(args), {
      argsView: {
        kind: "markdown",
        field: "document",
        defaultMode: "source",
        sourceControl: "prominent",
      },
    });
    expect(view).toMatchObject({
      kind: "markdown",
      text: "# Annotated",
      defaultMode: "source",
      sourceControl: "prominent",
    });
  });

  it("ExitPlanMode plan defaults to rendered Markdown without depending on its path", () => {
    const args = { plan: "# Plan\n\n| Step | State |\n| --- | --- |\n| Test | Ready |", planFilePath: "/totally/custom/location/plan.txt" };
    expect(resolveToolView("ExitPlanMode", args, at(args))).toMatchObject({
      kind: "markdown",
      text: args.plan,
      defaultMode: "preview",
      sourceControl: "subtle",
    });
  });

  it.each([
    ["file_path", "/any/directory/PLAN.md"],
    ["path", "C:\\custom\\nested\\PLAN.MARKDOWN"],
  ] as const)("Write recognizes markdown from arbitrary %s paths", (field, fileName) => {
    const args = { [field]: fileName, content: "# Plan" };
    expect(resolveToolView("Write", args, at(args))).toMatchObject({
      kind: "markdown",
      text: "# Plan",
      defaultMode: "preview",
      sourceControl: "prominent",
      fileName,
    });
  });

  it("other textual Write args default to exact source but allow Markdown preview", () => {
    const args = { file_path: "/tmp/report.txt", content: "# Literal source\n" };
    expect(resolveToolView("Write", args, at(args))).toMatchObject({
      kind: "markdown",
      text: args.content,
      defaultMode: "source",
      sourceControl: "prominent",
      fileName: args.file_path,
    });
  });

  it("malformed markdown candidates preserve existing fallback behavior", () => {
    const exitArgs = { plan: { unexpected: true } };
    const writeArgs = { file_path: "notes.md", content: 42 };
    expect(resolveToolView("ExitPlanMode", exitArgs, at(exitArgs)).kind).toBe("json");
    expect(resolveToolView("Write", writeArgs, at(writeArgs)).kind).toBe("json");
  });
});
