// 纯函数:把 (toolName, args, argsText, annotations) 解析成一个 ToolView。
// 无 React 依赖 → 可直接单测。渲染由 ToolArgsView 负责(dumb)。
import type { ArgsViewHint, ToolView, TodoItem, QueryField } from "./types";
import { parseAskUserQuestionArgs } from "./ask-user-question-args";
import { getEditDiff, formatToolArgs } from "../helpers";

// 文件扩展名 → 已在 syntax-highlighter 注册的 prism 语言;未知 → "markdown"(中性,
// 呼应 resolveCodeLanguage 的"不硬套 R"策略,避免把纯文本误标成代码)。
const EXT_LANG: Record<string, string> = {
  r: "r", rmd: "markdown",
  py: "python",
  js: "javascript", mjs: "javascript", cjs: "javascript",
  ts: "typescript", tsx: "tsx", jsx: "jsx",
  sh: "bash", bash: "bash",
  sql: "sql",
  json: "json",
  yaml: "yaml", yml: "yaml",
  md: "markdown", markdown: "markdown",
  css: "css",
};

export function langFromFileName(name?: string): string {
  if (!name) return "markdown";
  const m = /\.([A-Za-z0-9]+)\s*$/.exec(name);
  const ext = m?.[1]?.toLowerCase();
  return (ext && EXT_LANG[ext]) || "markdown";
}

const isRunR = (toolName?: string): boolean =>
  toolName === "mcp__r_session__run_r" || /(?:^|__)run_r$/.test(toolName ?? "");

const fileNameOf = (a: Record<string, unknown>): string | undefined => {
  if (typeof a.file_path === "string" && a.file_path) return a.file_path;
  if (typeof a.path === "string" && a.path) return a.path;
  return undefined;
};

const asString = (v: unknown): string | undefined =>
  typeof v === "string" ? v : undefined;

function jsonFallback(argsText: string | undefined): ToolView {
  const f = formatToolArgs(argsText);
  if (!f) return { kind: "json", text: "", raw: true };
  return { kind: "json", text: f.text, raw: f.kind === "raw" };
}

export function resolveToolView(
  toolName: string | undefined,
  args: unknown,
  argsText: string | undefined,
  annotations?: Record<string, unknown>,
): ToolView {
  const a = (args ?? {}) as Record<string, unknown>;
  const startLine =
    typeof annotations?.diffStartLine === "number"
      ? (annotations.diffStartLine as number)
      : undefined;

  // 1) 扩展点:R / MCP 工具声明的 argsView(最高优先级)。
  const hint = annotations?.argsView as ArgsViewHint | undefined;
  if (hint?.kind === "code") {
    const code = asString(a[hint.field ?? "code"]);
    if (code !== undefined)
      return { kind: "code", code, lang: hint.lang || "markdown", fileName: fileNameOf(a) };
  } else if (hint?.kind === "diff") {
    const oldC = asString(a[hint.oldField ?? "old_string"]);
    const newC = asString(a[hint.newField ?? "new_string"]);
    if (oldC !== undefined && newC !== undefined) {
      const fileName = asString(a[hint.fileField ?? "file_path"]) ?? fileNameOf(a);
      return { kind: "diff", oldContent: oldC, newContent: newC, fileName, startLine };
    }
  }

  // 2) 内建 diff:Edit / MultiEdit(复用现有 helper)。
  const diff = getEditDiff(toolName, args);
  if (diff) return { kind: "diff", ...diff, startLine };

  // 3) 内建 code 工具。
  if (toolName === "Bash") {
    const cmd = asString(a.command);
    if (cmd !== undefined) return { kind: "code", code: cmd, lang: "bash" };
  }
  if (toolName === "Write") {
    const content = asString(a.content);
    if (content !== undefined) {
      const fileName = fileNameOf(a);
      return { kind: "code", code: content, lang: langFromFileName(fileName), fileName };
    }
  }
  if (isRunR(toolName)) {
    const code = asString(a.code);
    if (code !== undefined) return { kind: "code", code, lang: "r" };
  }

  // 4) AskUserQuestion：把 questions JSON 转成稳定的可读摘要；任一字段 malformed
  // 就整体回落 JSON，避免“美化”吞掉调试信息。
  if (toolName === "AskUserQuestion") {
    const questions = parseAskUserQuestionArgs(args);
    if (questions) return { kind: "questions", items: questions };
  }

  // 5) 内建 checklist:TodoWrite。
  if (toolName === "TodoWrite" && Array.isArray(a.todos)) {
    const items: TodoItem[] = a.todos.map((t) => {
      const o = (t ?? {}) as Record<string, unknown>;
      return {
        content: asString(o.content) ?? asString(o.activeForm) ?? "",
        status: asString(o.status) ?? "pending",
        activeForm: asString(o.activeForm),
      };
    });
    if (items.length) return { kind: "todos", items };
  }

  // 5) 内建 query 摘要:Grep / Glob / WebSearch / WebFetch。
  const q = queryFieldsFor(toolName, a);
  if (q && q.length) return { kind: "query", fields: q };

  // 6) 兜底:JSON(保留 raw/json 双态)。
  return jsonFallback(argsText);
}

function queryFieldsFor(
  toolName: string | undefined,
  a: Record<string, unknown>,
): QueryField[] | null {
  const fields: QueryField[] = [];
  const push = (label: string, v: unknown, href?: string) => {
    const s = asString(v);
    if (s) fields.push(href ? { label, value: s, href } : { label, value: s });
    else if (typeof v === "number" || typeof v === "boolean")
      fields.push({ label, value: String(v) });
  };
  switch (toolName) {
    case "Grep":
    case "Glob":
      push("pattern", a.pattern);
      push("path", a.path);
      push("glob", a.glob);
      push("type", a.type);
      push("output", a.output_mode);
      return fields.length ? fields : null;
    case "WebSearch":
      push("query", a.query);
      return fields.length ? fields : null;
    case "WebFetch": {
      const url = asString(a.url);
      if (url) fields.push({ label: "url", value: url, href: url });
      push("prompt", a.prompt);
      return fields.length ? fields : null;
    }
    default:
      return null;
  }
}
