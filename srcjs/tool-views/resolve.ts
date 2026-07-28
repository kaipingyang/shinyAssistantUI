// 纯函数:把 (toolName, args, argsText, annotations) 解析成一个 ToolView。
// 无 React 依赖 → 可直接单测。渲染由 ToolArgsView 负责(dumb)。
import type { ArgsViewHint, ToolView } from "./types";
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
      return { kind: "diff", oldContent: oldC, newContent: newC, fileName };
    }
  }

  // 2) 内建 diff:Edit / MultiEdit(复用现有 helper)。
  const diff = getEditDiff(toolName, args);
  if (diff) return { kind: "diff", ...diff };

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

  // 4) 兜底:JSON(保留 raw/json 双态)。
  return jsonFallback(argsText);
}
